//
//  TRYFakeProgress.m
//  TRYFakeProgress
//
//  Created by Troyan on 2020/11/27.
//  Copyright © 2020 Mastercom. All rights reserved.
//

#import "TRYFakeProgressProvider.h"

#define MaxIncompleteProgress 0.99
#define CompleteProgress 1
#define DefaultStepConcurrency 1
#define DefaultRefreshInterval 0.0167

@interface TRYFakeProgressProvider()

@property(nonatomic) TRYFakeProgressProviderState state;

@property(nonatomic) double progress;

@property(nonatomic) TRYFakeProgressEstimateStrategy estimateStrategy;

@property(nonatomic) NSUInteger steps;

@property(strong, nonatomic, nullable) NSMutableArray *stepConcurrencies;

@property(strong, nonatomic, nullable) NSMutableArray *accumulatedWeights;

@property(copy, nonatomic) void(^progressListener)(double progress);

@property(copy, nonatomic) void(^completion)(void);

//MARK: 以下属性用于运行状态控制

/// 接口保护锁
@property(strong, nonatomic) NSLock *lock;

/// 定时器，每20ms刷新
@property(strong, nonatomic) NSTimer *timer;

/// 记录起始时间点，以及每步完成的时间点
@property(strong, nonatomic) NSMutableArray *mileStones;

/// 记录当前步
@property(nonatomic) NSInteger currentStep;

/// 记录当前步的估算时长。根据进度估算策略，用前面步骤的时长综合计算得出
@property(nonatomic) double currentEstimatedOccupation;

/// 记录当前已完成的步骤的权重（不包含当前步骤的进度）。为了保证进度条的流畅，该进度在某些情况下，可能会落后于已完成的步骤累加权重，因此会在更新进度时，对其进行补偿
@property(nonatomic) double currentAccumulatedWeights;

/// 记录当前步骤的已完成并发数
@property(nonatomic) double currentStepFinishedConcurrencies;

@end

@implementation TRYFakeProgressProvider

-(instancetype)init{
    return [self initWithEstimateStrategy:TRYFakeProgressEstimateStrategyRecent];
}

-(instancetype)initWithEstimateStrategy:(TRYFakeProgressEstimateStrategy)estimateStrategy{
    if(self = [super init]){
        _state = TRYFakeProgressProviderStateInitialized;
        _progress = 0;
        _estimateStrategy = estimateStrategy;
    }
    return self;
}

-(void)registerProgressListener:(void (^)(double))progressListener completion:(nonnull void (^)(void))completion{
    [self.lock lock];
    
    NSAssert((self.state == TRYFakeProgressProviderStateInitialized
              || self.state == TRYFakeProgressProviderStateReseted),
             ([NSString stringWithFormat:@"%s只能在 Initialized 或者 Reseted 状态时调用", __func__]));
    
    self.progressListener = progressListener;
    self.completion = completion;
    
    [self.lock unlock];
}

-(void)setupWithSteps:(NSUInteger)steps
    stepConcurrencies:(NSArray * _Nullable)stepConcurrencies
   accumulatedWeights:(NSArray * _Nullable)accumulatedWeights{
    
    [self.lock lock];
    
    NSAssert((self.state == TRYFakeProgressProviderStateInitialized
              || self.state == TRYFakeProgressProviderStateReseted),
             ([NSString stringWithFormat:@"%s只能在 Initialized 或者 Reseted 状态时调用", __func__]));
    
    [self _addSteps:steps stepConcurrencies:stepConcurrencies accumulatedWeights:accumulatedWeights];
    
    [self.lock unlock];
}

-(void)startWithInitialEstimatedOccupation:(NSTimeInterval)occupation{
    [self.lock lock];
    
    NSAssert((self.state == TRYFakeProgressProviderStateInitialized
              || self.state == TRYFakeProgressProviderStateReseted),
             ([NSString stringWithFormat:@"%s只能在 Initialized 或者 Reseted 状态时调用", __func__]));
    
#if DEBUG
    NSAssert(self.steps, @"步数必须大于零");
    NSAssert(self.steps == self.accumulatedWeights.count, @"步数和权重数量必须一致");
    for(int i = 0; i < self.steps - 1; i++)
        NSAssert([self.accumulatedWeights[i+1] doubleValue] > [self.accumulatedWeights[i] doubleValue], @"权重必须单调递增");
#endif
    
    self.currentEstimatedOccupation = occupation;
    [self.mileStones addObject:[NSDate date]];
    
    [self addObserver:self forKeyPath:@"progress" options:NSKeyValueObservingOptionNew context:nil];
    
    [self _resume];
    
    [self.lock unlock];
}

-(void)dynamiclyAddSteps:(NSUInteger)steps
       stepConcurrencies:(NSArray * _Nullable)stepConcurrencies
      accumulatedWeights:(NSArray * _Nullable)accumulatedWeights{
    
    [self.lock lock];
    
    NSAssert((self.state == TRYFakeProgressProviderStateResumed
              || self.state == TRYFakeProgressProviderStateSuspended),
             ([NSString stringWithFormat:@"%s只能在 Resumed 或者 Suspended 状态时调用", __func__]));
    
    [self _addSteps:steps stepConcurrencies:stepConcurrencies accumulatedWeights:accumulatedWeights];
    
    // 当进度挂起时，需要恢复执行
    if(self.state == TRYFakeProgressProviderStateSuspended){
        [self _updateProgressControlStates];
        [self _resume];
    }
    
    [self.lock unlock];
}

-(void)finishStep{
    [self.lock lock];
    
    NSAssert((self.state == TRYFakeProgressProviderStateResumed),
             ([NSString stringWithFormat:@"%s只能在 Resumed 状态时调用", __func__]));
    
    if(self.currentStep + 1 < self.steps){
        [self _updateProgressControlStates];
    }else if([self.accumulatedWeights.lastObject doubleValue] < MaxIncompleteProgress){
        [self _suspend];
    }else if([self _updateStepFinishedConcurrency]){
        [self _finish];
    }
    
    [self.lock unlock];
}

-(void)reset{
    [self.lock lock];
    
    NSAssert((self.state == TRYFakeProgressProviderStateResumed
              || self.state == TRYFakeProgressProviderStateSuspended
              || self.state == TRYFakeProgressProviderStateFinished),
             ([NSString stringWithFormat:@"%s只能在 Resumed、Suspended 或者 Finished 状态时调用", __func__]));
    
    self.state = TRYFakeProgressProviderStateReseted;
    [self _clearSetups];
    
    [self.lock unlock];
}

#pragma mark - supporting methods

/// 单纯添加步数和权重
-(void)_addSteps:(NSUInteger)steps
stepConcurrencies:(NSArray * _Nonnull)stepConcurrencies
accumulatedWeights:(NSArray * _Nonnull)accumulatedWeights{
    
#if DEBUG
    NSAssert(steps, @"步数必须大于零");
    NSAssert(steps == accumulatedWeights.count, @"步数和权重数量必须一致");
    NSAssert([accumulatedWeights.firstObject doubleValue] > [self.accumulatedWeights.lastObject doubleValue], @"动态添加权重必须单调递增");
    for(int i = 0; i < steps - 1; i++)
        NSAssert([accumulatedWeights[i+1] doubleValue] > [accumulatedWeights[i] doubleValue], @"动态添加权重必须单调递增");
#endif
    
    self.steps += steps;
    
    NSMutableArray *mutableAccumulatedWeights = [accumulatedWeights mutableCopy];
    if(!mutableAccumulatedWeights.count){
        mutableAccumulatedWeights = [[NSMutableArray alloc] init];
        double lastWeight = [self.accumulatedWeights.lastObject doubleValue];
        for(int i = 0; i < steps; i++){
            double weight = (1.0-lastWeight)/steps*(i+1) + lastWeight;
            [mutableAccumulatedWeights addObject:[NSNumber numberWithDouble:weight]];
        }
    }
    //避免以100%进度等待
    if([mutableAccumulatedWeights[mutableAccumulatedWeights.count-1] doubleValue] >= 1)
        mutableAccumulatedWeights[mutableAccumulatedWeights.count-1] = @(MaxIncompleteProgress);
    [(NSMutableArray*)self.accumulatedWeights addObjectsFromArray:mutableAccumulatedWeights];
    
    NSMutableArray *mutableStepConcurrencies = [stepConcurrencies mutableCopy];
    if(!mutableStepConcurrencies.count){
        mutableStepConcurrencies = [[NSMutableArray alloc] init];
        for(int i = 0; i < steps; i++){
            [mutableStepConcurrencies addObject:[NSNumber numberWithUnsignedInteger:DefaultStepConcurrency]];
        }
    }
    [(NSMutableArray*)self.stepConcurrencies addObjectsFromArray:mutableStepConcurrencies];
}

-(void)_clearSetups{
    [self.timer invalidate];
    self.timer = nil;
    
    self.progress = 0;
    self.steps = 0;
    self.stepConcurrencies = nil;
    self.accumulatedWeights = nil;
    
    self.mileStones = nil;
    self.currentStep = 0;
    self.currentEstimatedOccupation = 0;
    self.currentAccumulatedWeights = 0;
    self.currentStepFinishedConcurrencies = 0;
}

-(void)_finish{
    self.state = TRYFakeProgressProviderStateFinished;
    if(self.progressListener)
        self.progressListener(CompleteProgress);
    if(self.completion){
        [self removeObserver:self forKeyPath:@"progress"];
        self.completion();
    }
    return [self _clearSetups];
}

-(void)_suspend{
    self.state = TRYFakeProgressProviderStateSuspended;
    [self.timer invalidate];
    self.timer = nil;
}

-(void)_resume{
    self.state = TRYFakeProgressProviderStateResumed;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:DefaultRefreshInterval repeats:YES block:^(NSTimer * _Nonnull timer) {
        [self _updateProgressValue];
    }];
}

#pragma mark - core methods

-(void)_updateProgressValue{
    // 补偿缺失的进度
    if(self.progress < [self _getLastFullAccumulatedWeight]){
        self.currentAccumulatedWeights = self.progress;
    }
        
    NSDate *recent = self.mileStones.lastObject;
    NSDate *current = [NSDate date];
    NSTimeInterval interval = [current timeIntervalSinceDate:recent];
    double currentStepWeight = [self _getCurrentStepWeight];
    double newProgress = interval / self.currentEstimatedOccupation * currentStepWeight + self.currentAccumulatedWeights;
    if(newProgress >= [self.accumulatedWeights[self.currentStep] doubleValue]){
        newProgress = [self.accumulatedWeights[self.currentStep] doubleValue];
    }
    self.progress = newProgress;
}

- (void)_updateProgressControlStates {
    /// 当前步骤未达到最大并发数则直接返回
    if(![self _updateStepFinishedConcurrency])
        return;
    
    self.currentStepFinishedConcurrencies = 0;
    NSDate *current = [NSDate date];
    NSDate *recent = self.mileStones.lastObject;
    
    // 设置累加进度为当前进度。保证进度条的流畅性，尽量减少进度跳变
    self.currentAccumulatedWeights = self.progress;
    
    [self _updateEstimatedOccupation:current recent:recent];
    
    [self.mileStones addObject:current];
    self.currentStep += 1;
}

/// 更新当前步骤的已完成并发数
/// @return 若达到所有并发返回 YES
-(BOOL)_updateStepFinishedConcurrency{
    NSUInteger currentStepConcurrency = [self.stepConcurrencies[self.currentStep] unsignedIntegerValue];
    if(self.currentStepFinishedConcurrencies + 1 < currentStepConcurrency){
        self.currentStepFinishedConcurrencies += 1;
        return NO;
    }
    return YES;
}

-(void)_updateEstimatedOccupation:(NSDate *)current recent:(NSDate *)recent{
    switch (self.estimateStrategy) {
        case TRYFakeProgressEstimateStrategyRecent:{
            NSTimeInterval interval = [current timeIntervalSinceDate:recent];
            self.currentEstimatedOccupation = interval/[self _getCurrentStepWeight]*[self _getNextStepWeight];
        }break;
        
        case TRYFakeProgressEstimateStrategyAverage:{
            NSDate *start = self.mileStones.firstObject;
            NSTimeInterval interval = [current timeIntervalSinceDate:start];
            // 方式一：以当前步的累计权重为分母求平均，比较准确，但是会稍稍没那么平滑
            self.currentEstimatedOccupation = interval/[self _getCurrentFullAccumulatedWeight]*[self _getNextStepWeight];
            // 方式二：以当前进度条上的已完成进度为分母求平均，没那么准确，但是会稍稍比较平滑
            // self.currentEstimatedOccupation = interval/self.currentAccumulatedWeights*[self getNextStepWeight];
        }break;
    }
}

#pragma mark - utilities
/// 获取当前步的单步权重
-(double)_getCurrentStepWeight{
    return (self.currentStep > 0
            ? [self.accumulatedWeights[self.currentStep] doubleValue] - [self.accumulatedWeights[self.currentStep-1] doubleValue]
            : [self.accumulatedWeights[self.currentStep] doubleValue]);
}

/// 获取下一步的单步权重
-(double)_getNextStepWeight{
    return [self.accumulatedWeights[self.currentStep+1] doubleValue] - [self.accumulatedWeights[self.currentStep] doubleValue];
}

/// 获取上一步的累计权重
-(double)_getLastFullAccumulatedWeight{
    return (self.currentStep > 0 ? [self.accumulatedWeights[self.currentStep-1] doubleValue] : 0);
}

/// 获取当前步的累计权重
-(double)_getCurrentFullAccumulatedWeight{
    return [self.accumulatedWeights[self.currentStep] doubleValue];
}

#pragma mark - other methods
-(NSMutableArray *)mileStones{
    if(!_mileStones){
        _mileStones = [[NSMutableArray alloc] init];
    }
    return _mileStones;
}

-(NSArray *)accumulatedWeights{
    if(!_accumulatedWeights){
        _accumulatedWeights = [[NSMutableArray alloc] init];
    }
    return _accumulatedWeights;
}

-(NSArray *)stepConcurrencies{
    if(!_stepConcurrencies){
        _stepConcurrencies = [[NSMutableArray alloc] init];
    }
    return _stepConcurrencies;
}

-(NSLock *)lock{
    if(!_lock){
        _lock = [[NSLock alloc] init];
    }
    return _lock;
}

-(void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context{
    if([@"progress" isEqualToString:keyPath]){
        if(self.progressListener){
            self.progressListener([change[NSKeyValueChangeNewKey] floatValue]);
        }
    }
}

@end
