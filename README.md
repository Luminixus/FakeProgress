# Objective-C实现假进度生成器

在业务开发过程中常常会遇到这样的场景，对进度无法准确度量的过程模拟一个假进度，假进度不能过分偏离过程的实际进度，过渡要尽量平滑。对于过程较为复杂的场景，可能在业务代码中引入大量的假进度模拟逻辑。最好的方式是，将假进度模拟逻辑提取到单独的模块，提供少量的接口给业务代码调用。

## 一、进度模拟策略

Github 不能正常解析公式，具体内容见：[Objective-C实现假进度生成器](https://juejin.cn/post/6900416346745569288/)。

## 二、示例代码

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
    // 1. 构建实例
    TRYFakeProgressProvider *progress = [[TRYFakeProgressProvider alloc] initWithEstimateStrategy:TRYFakeProgressEstimateStrategyRecent];

    // 2. 设置静态步骤权重和并发数
    [progress setupWithSteps:4 stepConcurrencies:nil accumulatedWeights:@[@(0.1), @(0.3), @(0.6), @(0.75)]];

    // 3. 注册进度和完成监听器
    [progress registerProgressListener:^(CGFloat progress) {
        progressView.progress = progress;
    } completion:^{
        NSLog(@"加载完成");
    }];
    self.progress = progress;

    // 4. 预估第一步耗时 1 秒
    [self.progress startWithInitialEstimatedOccupation:1];

    // 5. 调用 finishStep 以及 dynamiclyAddSteps 动态添加步骤
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

## 三、使用场景局限

本方案的虽然能适配简单的并发场景，但是使用场景还是只能局限于线性拓扑或者类线性拓扑结构的任务流程。不适用于对于图型拓扑结构的过程进度模拟的场景。
