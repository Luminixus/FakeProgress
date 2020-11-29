//
//  TRYFakeProgress.h
//  TRYFakeProgress
//
//  Created by Troyan on 2020/11/27.
//  Copyright © 2020 Mastercom. All rights reserved.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 状态
typedef enum : NSUInteger {
    /// 初始化。可转入 TRYFakeProgressProviderStateResumed
    TRYFakeProgressProviderStateInitialized,
    /// 执行中。可转入 TRYFakeProgressProviderStateSuspended、TRYFakeProgressProviderStateReseted、TRYFakeProgressProviderStateFinished
    TRYFakeProgressProviderStateResumed,
    /// 已挂起。供内部使用的状态。可转入 TRYFakeProgressProviderStateResumed、TRYFakeProgressProviderStateReseted
    TRYFakeProgressProviderStateSuspended,
    /// 已重置。可转入 TRYFakeProgressProviderStateResumed
    TRYFakeProgressProviderStateReseted,
    /// 已完成。可转入 TRYFakeProgressProviderStateReseted
    TRYFakeProgressProviderStateFinished,
    
} TRYFakeProgressProviderState;


/// 耗时估算策略
typedef enum : NSUInteger {
    /// 取最近
    TRYFakeProgressEstimateStrategyRecent,
    /// 取已完成平均
    TRYFakeProgressEstimateStrategyAverage

} TRYFakeProgressEstimateStrategy;


/// 伪进度模拟。NOTE: 对模拟并发任务进度的场景测试并不是很全面
@interface TRYFakeProgressProvider : NSObject

/// 状态
@property(nonatomic, readonly) TRYFakeProgressProviderState state;

/// 耗时估算策略
@property(nonatomic, readonly) double progress;

/// 进度估算策略
@property(nonatomic, readonly) TRYFakeProgressEstimateStrategy estimateStrategy;

/// 步数
@property(nonatomic, readonly) NSUInteger steps;

/// 每步并发过程数。默认为 1，指定为 n 个时，则需调用 n 次 finishStep 才能触发该步完成
@property(strong, nonatomic, readonly) NSMutableArray *stepConcurrencies;

/// 每步权重预估。例如，三步走，预估第一步完成则整体完成10%，第二步完成则整体完成50%，第三步完成整体完成100%，则weights参数应设置为@[@(0.1), @(0.5), @(1.0) ]
@property(strong, nonatomic, readonly) NSArray *accumulatedWeights;

/// 构造器，默认使用最近策略 TRYFakeProgressEstimateStrategyRecent
-(instancetype)init;

/// 构造器。进入 Initialized 状态
-(instancetype)initWithEstimateStrategy:(TRYFakeProgressEstimateStrategy)estimateStrategy;

/**
 设置步数和预估权重。只能在 Initialized 或者 Reseted 状态时调用
 @param steps 进度所包含的步数
 @param stepConcurrencies 步骤包含的并发过程数
 @param accumulatedWeights 预估每步完成时的进度权重值，传入空时自动平均分配权重
 */
-(void)setupWithSteps:(NSUInteger)steps
    stepConcurrencies:(NSArray * _Nullable)stepConcurrencies
   accumulatedWeights:(NSArray * _Nullable)accumulatedWeights;

/// 注册进度和完成监听器，注意新注册的进度、完成监听器会覆盖旧的监听器，重置或完成时不重置进度、完成监听器。只能在 Initialized 或者 Reseted 状态时调用
-(void)registerProgressListener:(void(^)(double progress))progressListener completion:(void(^)(void))completion;

/// 开始时，需要预估第一步耗时，后续步骤耗时根据进度估算策略 estimateStrategy 进行估算。调用后转入 Resumed 执行中阶段
-(void)startWithInitialEstimatedOccupation:(NSTimeInterval)occupation;

/**
 动态添加步数和预估权重。只能在 Resumed 或者 Suspended 状态时调用
 @param steps 进度所包含的步数
 @param stepConcurrencies 步骤包含的并发过程数
 @param accumulatedWeights 预估每步完成时的进度权重值，传入空时自动平均分配权重
 */
-(void)dynamiclyAddSteps:(NSUInteger)steps
       stepConcurrencies:(NSArray * _Nullable)stepConcurrencies
      accumulatedWeights:(NSArray * _Nullable)accumulatedWeights;

/// 对于并发量设置为 n 的步骤，需要调用 n 次 finishStep 才能触发步骤完成。当调用后所有步骤均完成且总进度达到 100%，转入 Finished 已完成阶段
-(void)finishStep;

/// 取消或者重置。调用后转入 Reseted 已重置阶段
-(void)reset;

@end

NS_ASSUME_NONNULL_END
