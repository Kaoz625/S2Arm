// 随包资源包落点驱动（tests/ota_bundled_test.py 编它）：跑真 ios/ota_place.m 的 s2a_ota_place_bundled，把 <ota 目录> 放进 <进程级 Documents>/games/<游戏号>/资源包。
//   用法：bundled <ota 目录> <进程级 Documents> <游戏号> [杀在第 N 个文件前]   —— 给 N 时进度回调到第 N 个文件（从 0 起）就 _exit(9)，模拟放到一半被杀
//   输出 键=值：rc（0 成功）、why、cloned（全程 APFS 克隆 1 / 有真拷贝 0）、calls（进度回调次数）
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#import "../../ios/ota_place.h"
uint64_t now_ns(void) { return 0; }
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 4) return 2;
        long kill_at = argc > 4 ? atol(argv[4]) : -1; __block int calls = 0;
        NSString *gd = [[@(argv[2]) stringByAppendingPathComponent:@"games"] stringByAppendingPathComponent:@(argv[3])];
        BOOL cloned = NO;
        NSString *why = s2a_ota_place_bundled(@(argv[1]), gd, @(argv[3]), ^long long { return -1; }, ^(long long d, long long t, NSUInteger i, NSUInteger n) {
            (void)d; (void)t; (void)n; calls++;
            if (kill_at >= 0 && (long)i == kill_at) { printf("killed_at=%ld\n", kill_at); fflush(stdout); _exit(9); }
        }, &cloned);
        printf("rc=%d\nwhy=%s\ncloned=%d\ncalls=%d\n", why ? 1 : 0, why ? why.UTF8String : "", cloned, calls);
        return 0;
    }
}
