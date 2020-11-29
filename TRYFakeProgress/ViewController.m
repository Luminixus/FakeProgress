//
//  ViewController.m
//  TRYFakeProgress
//
//  Created by Troyan on 2020/11/27.
//  Copyright © 2020 Mastercom. All rights reserved.
//

#import "ViewController.h"
#import "TRYFakeProgressProvider.h"

@interface ViewController ()

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
        NSLog(@"下载完成");
    }];
    self.progress = progress;
    [self.progress startWithInitialEstimatedOccupation:1];
    
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
