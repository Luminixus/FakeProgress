# Objective-C实现假进度生成器

*2020-11-29*

在业务开发过程中常常会遇到这样的场景，对进度无法准确度量的过程模拟一个假进度，假进度不能过分偏离过程的实际进度，过渡要尽量平滑。对于过程较为复杂的场景，可能在业务代码中引入大量的假进度模拟逻辑。最好的方式是，将假进度模拟逻辑提取到单独的模块，提供少量的接口给业务代码调用。

## 一、进度模拟策略

首先是单个过程内的进度推进策略。为了实现简单，这里就采用最简单的**线性推进策略**。对于单步过程，只要提供一个过程预估时间 ${t}$，假进度模拟模块就会以 ${v = 1/t}$ 的速率逐渐趋近 1。

对于多步过程，则需要提前给步骤预估权重值，本方案采用的是**累加权重**的方式。累加权重表示过程中某个步骤完成时，总体进度的完成比例。例如三步走的过程，首先预估累加权重为 ${[W_1, W_2, W_3]}$，其中，${W_1}$ 表示步骤一完成时则总进度完成 ${W_1}$，以此类推。因此有 $W_1 < W_2 < W_3 <= 1$ 的约束。

如果简单参照单步过程的处理方式，则对多步过程的每一步都要预估时间，未免太过繁琐。因此再引入**耗时估算策略**。当过程包含多步时，可以根据前面已完成步骤的实际耗时来估算当前步的耗时，这样只要提供的第一步的预估耗时即可，后续步骤预估耗时都通过耗时估算策略动态计算得出。还是选择较为简单的方式，这里提供两种选项：

- 以**最近完成步骤**的实际耗时为参考（Recently）：例如，第一步的单步权重为 $w_1$ 实际耗时 $t_1$，则单步权重为 $w_2$ 的第二步的预估耗时为 ${t_2 = w_2 / w_1 * t_1}$。注意这里的单步权重指，单个步骤在总进度中所占比例，因此累加权重和单步权重的转换关系为 ${w_n = W_n - W_{n-1}}$；
- 以**已完成所有步骤**的实际耗时为参考（Average）：例如，第一步实际耗时 $t_1$，第二步的累加权重为 $W_2$ 实际耗时 $t_2$，则单步权重为 ${w_3}$ 的第三步的预估耗时为 ${t_3 = w_3 / W_2 * (t_1 + t_2)}$；

>注意：本方案之所以选择使用累加权重而不使用单步权重的原因是，利用单步权重计算累加权重的时间复杂度是 ${O(N)}$，而利用累加权重反推单步权重的时间复杂度只有 $O(1)$。

## 二、接口设计

确定了进度模拟策略后，接口就可以基本定下来了。首先定义两种耗时估算策略：

```objc
/// 耗时估算策略
typedef enum : NSUInteger {
    /// 取最近
    TRYFakeProgressEstimateStrategyRecent,
    /// 取已完成平均
    TRYFakeProgressEstimateStrategyAverage

} TRYFakeProgressEstimateStrategy;
```

其次记录家进度模拟过程的各种状态，主要作用是限制接口的调用，避免在特定的执行状态下调用不适当的接口使假进度模拟模块产生错误的控制效果。代码定义如下：

```objc
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
```

根据上面进度模拟过程的状态转换限制规则，可以画出模块的状态机示意图如下图所示：

![状态机](https://p3-juejin.byteimg.com/tos-cn-i-k3u1fbpfcp/1b77f08f64c246b4bc736e6b7124366f~tplv-k3u1fbpfcp-zoom-1.image)

任务开始之前需要调用`setupWithSteps`设置进度估算所需的必要参数，并调用`registerProgressListener`注册监听器。需要注意，伪进度模拟模块实现内部会持有监听器 Block，所以使用时需要注意避免循环引用的问题。

然后设置`finishStep`接口，通知假进度模拟模块步骤完成。这里还要考虑如果单个步骤存在多个并发任务的问题，也就是说步骤包含的多有并发任务完成时，步骤才能算真正完成。这里为每个步骤设置一个并发量的参数，并发量为 1 时，只要接收到一次`finishStep`消息，则表示步骤完成；步骤并发量为 ${n}$ 时，则需要接收到 ${n}$ 次`finishStep`消息，步骤才真正完成。

最后，考虑到有时在任务开始阶段并不能确定所有步骤，因此设置`dynamiclyAddSteps`接口用于动态添加步骤。另外，有时需要在任务任务取消时要重置进度，因此设置`reset`接口。

```objc
/// 伪进度模拟。NOTE: 对模拟并发任务进度的场景测试并不是很全面
@interface TRYFakeProgressProvider : NSObject

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
```

## 三、示例代码

以下是简单的使用实例代码，模拟一个包含 5 个步骤的过程，其中第 5 个步骤包含 2 个并发过程，且第 5 个步骤在第 4 步完成时才动态添加。

```objc
#import "TRYFakeProgressProvider.h"

@interface ViewController : UIViewController

@property(strong, nonatomic) TRYFakeProgressProvider *progress;

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    UIProgressView *progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleBar];
    progressView.frame = CGRectMake(0, 100, [UIScreen mainScreen].bounds.size.width, 4);
    progressView.progressTintColor = [UIColor systemRedColor];
    [self.view addSubview:progressView];

    //平均策略通常比最近策略更加平缓，后期尤为明显
    TRYFakeProgressProvider *progress = [[TRYFakeProgressProvider alloc] initWithEstimateStrategy:TRYFakeProgressEstimateStrategyRecent];
    [progress setupWithSteps:4 stepConcurrencies:nil accumulatedWeights:@[@(0.1), @(0.3), @(0.6), @(0.75)]];
    [progress registerProgressListener:^(CGFloat progress) {
        progressView.progress = progress;
    } completion:^{
        NSLog(@"加载完成");
    }];
    self.progress = progress;
    [self.progress startWithInitialEstimatedOccupation:1];

    // 模拟任务执行过程
    [self simulateTaskProcess]
}

-(void)simulateTaskProcess{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self.progress finishStep];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self.progress finishStep];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self.progress finishStep];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(7 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self.progress finishStep];

        [self.progress dynamiclyAddSteps:1 stepConcurrencies:@[@(2)]  accumulatedWeights:@[@(1)]];
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self.progress finishStep];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(11 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self.progress finishStep];
    });
}

@end
```

## 四、使用场景局限

本方案的虽然能适配简单的并发场景，但是使用场景还是只能局限于线性拓扑或者类线性拓扑结构的任务流程。不适用于对于图型拓扑结构的过程进度模拟的场景。
