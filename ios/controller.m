// iOS 直接消费系统手柄和 NS2 Pro BLE，不建立虚拟 HID 或本地网络服务。
#import <GameController/GameController.h>
#import <CoreHaptics/CoreHaptics.h>
#import "controller.h"
#import "s2a_l10n.h"
#import <UIKit/UIGestureRecognizerSubclass.h>   // S2ATouchWatch 要改 state
#include "native.h"
#include "s2a_pad.h"
#include "NS2Module.h"
#include "pad_liveness.h"
#include "haptic_retry.h"
#include <dlfcn.h>
#include <stdatomic.h>
#include <pthread.h>
#include <math.h>
#include <string.h>
#include <time.h>
// 手机自身当掌机（phone_motion.m）：没有外接 NS2 Pro 时，六轴取手机陀螺仪、震动走手机马达
int s2a_phone_motion_available(void); void s2a_phone_motion_enable(int on); int s2a_phone_motion_read(s2a_pad_motion *out);
uint64_t s2a_phone_rumble_session(void); void s2a_phone_rumble_pair(const s2a_pad_vibration v[2]); void s2a_phone_rumble_stop(void);

@interface S2AController : NSObject
- (instancetype)initWithRoot:(UIView *)root touchEnabled:(void (^)(BOOL))callback;
- (void)setForeground:(BOOL)foreground;
- (void)bleStatus:(ns2_status)status message:(NSString *)message;
@end
static S2AController *g_controller;
static NSString *const adapterPreference = @"S2ANS2ProAdapterEnabled";
static _Atomic int g_adapter_enabled;
// Objective-C 模块首次启用后保留到进程结束；默认关闭的冷启动不加载镜像。
static _Atomic(const ns2_api *) g_ns2;
static _Atomic uint64_t g_session;
static _Atomic uint64_t g_feedback_session;
static _Atomic int g_ble_ready;
static _Atomic int g_ble_foreground;
static _Atomic int g_motion_requested;
static _Atomic int g_phone_motion_wanted;   // 游戏要六轴（不论有没有外接手柄）
static pthread_mutex_t g_motion_mu = PTHREAD_MUTEX_INITIALIZER;
// ready / 连接代次变更与震动 mailbox 写入必须原子，拒绝暂停前挂起的旧请求。
static pthread_mutex_t g_feedback_mu = PTHREAD_MUTEX_INITIALIZER;
#define SYSTEM_SESSION_BASE 0x5359000000000000ull
#define MOTION_ONLY_SESSION 0x535a000000000001ull
#define PHONE_SESSION_BASE 0x5350000000000000ull
static dispatch_queue_t g_system_haptics_queue;
static GCController *g_haptic_device; // 只在 g_system_haptics_queue 上访问
static CHHapticEngine *g_haptic_engine;
static id<CHHapticAdvancedPatternPlayer> g_haptic_player;
static dispatch_source_t g_haptic_timer;
static BOOL g_haptic_playing;
static s2a_hp_state g_haptic_retry;   // 只在 g_system_haptics_queue 上访问：失败退避与判死（ios/haptic_retry.h）
// 下列字段由 g_feedback_mu 保护，提交方只更新固定快照。
static uint64_t g_system_epoch;
static BOOL g_system_present, g_system_supported, g_system_selected, g_system_pending, g_system_transition;
static s2a_pad_vibration g_system_pair[2];
static BOOL g_phone_selected, g_phone_available, g_phone_pending, g_phone_stop;
static uint64_t g_phone_epoch;
static s2a_pad_vibration g_phone_pair[2];

static void system_stop_on_queue(void) {
    if (g_haptic_player && g_haptic_playing) [g_haptic_player stopAtTime:CHHapticTimeImmediate error:nil];
    g_haptic_playing = NO;
    if (g_haptic_timer) dispatch_source_set_timer(g_haptic_timer, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
}
static void system_reset_on_queue(void) {
    system_stop_on_queue();
    [g_haptic_engine stopWithCompletionHandler:nil];
    g_haptic_player = nil; g_haptic_engine = nil;
}
void s2a_rumble_apply_settings(void);
// 游戏震动的总开关和强度（设置页「按键显示与触感」）：提交前按倍率缩放振幅，手机马达 / 实体手柄 / NS2 Pro 共用
static _Atomic float g_rumble_gain = 1;
static float finite_clamp(float x, float lo, float hi);
static float rumble_scaled(float amp) { return finite_clamp(amp * atomic_load(&g_rumble_gain), 0, 1); }
static void rumble_scale_pair(const s2a_pad_vibration in[2], s2a_pad_vibration out[2]) {
    for (int i = 0; i < 2; i++) { out[i] = in[i]; out[i].low_amp = rumble_scaled(in[i].low_amp); out[i].high_amp = rumble_scaled(in[i].high_amp); }
}
static float finite_clamp(float x, float lo, float hi) {
    return isfinite(x) ? fminf(hi, fmaxf(lo, x)) : lo;
}
// 震动失败只从这里归档：一行诊断 + 退避 / 判死（决策在 ios/haptic_retry.h，可在 Mac 宿主单测）。
//   带上 domain / code 而不是只有 localizedDescription——「Couldn't communicate with a helper application.」是
//   NSCocoaErrorDomain 4097（NSXPCConnectionInvalid），只看描述分不出是环境连不上还是 pattern 非法。
static void system_fail_on_queue(const char *what, NSError *error) {
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    const char *domain = error.domain.UTF8String ?: "-";
    long code = error ? (long)error.code : 0;
    BOOL died = s2a_hp_on_fail(&g_haptic_retry, now);
    if (!g_haptic_retry.reported) {
        g_haptic_retry.reported = YES;
        LOG("【红】系统手柄震动：%s（%s/%ld）%s——本设备本局最多再试 %d 次（退避 %u ms、%u ms），仍失败就判死，"
            "不再逐帧重建引擎与播放器",
            what, domain, code,
            error.localizedDescription.UTF8String ?: "unknown",
            S2A_HP_MAX_FAILS - 1, S2A_HP_BACKOFF_MS(1), S2A_HP_BACKOFF_MS(2));
    }
    if (died) LOG("【红】系统手柄震动：本设备本局停用（连续 %d 次失败，最后一次 %s/%ld）；换手柄或重新接入会再试一次",
                  S2A_HP_MAX_FAILS, domain, code);
}
static void system_play_on_queue(s2a_pad_vibration pair[2]) {
    float amplitude = 0, weighted = 0, weights = 0;
    for (int i = 0; i < 2; i++) {
        float lo = finite_clamp(pair[i].low_amp, 0, 1), hi = finite_clamp(pair[i].high_amp, 0, 1);
        amplitude = fmaxf(amplitude, fmaxf(lo, hi));
        weighted += lo * finite_clamp(pair[i].low_hz, 0, 1250) + hi * finite_clamp(pair[i].high_hz, 0, 1250);
        weights += lo + hi;
    }
    if (amplitude <= 0.001f) { system_stop_on_queue(); return; }
    // 退避期 / 已判死：一个 CoreHaptics 调用都不碰。游戏每秒提交约 29 次震动，这条路径必须廉价。
    if (s2a_hp_should_try(&g_haptic_retry, clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) == S2A_HP_SKIP) return;
    float hz = weights > 0 ? weighted / weights : 160;
    float sharp = finite_clamp((hz - 160) / 160 * 0.5f + 0.3f, 0, 1);
    NSError *error = nil;
    if (!g_haptic_engine) {
        g_haptic_engine = [g_haptic_device.haptics createEngineWithLocality:GCHapticsLocalityDefault];
        if (!g_haptic_engine) { system_fail_on_queue("无法创建引擎", nil); return; }
        g_haptic_engine.playsHapticsOnly = YES;
        // 回调不在本队列执行，且旧引擎的回调可能晚于设备切换。
        __weak CHHapticEngine *weakEngine = g_haptic_engine;
        void (^invalidate)(void) = ^{
            CHHapticEngine *engine = weakEngine;
            if (!engine) return;
            dispatch_async(g_system_haptics_queue, ^{
                if (g_haptic_engine == engine) system_reset_on_queue();
            });
        };
        g_haptic_engine.resetHandler = ^{ invalidate(); };
        g_haptic_engine.stoppedHandler = ^(CHHapticEngineStoppedReason reason) { (void)reason; invalidate(); };
        // 只打一次：下一次真机日志用这一行就能区分「引擎没建起来」「玩家关了手柄震动」「locality 不对」。
        if (!g_haptic_retry.diagnosed) {
            g_haptic_retry.diagnosed = YES;
            NSArray *localities = g_haptic_device.haptics.supportedLocalities.allObjects;
            LOG("系统手柄震动：引擎已建（locality Default；手柄 %s 支持 %lu 个 locality：%s）",
                g_haptic_device.vendorName.UTF8String ?: "?",
                (unsigned long)localities.count,
                [localities componentsJoinedByString:@","].UTF8String ?: "");
        }
    }
    if (!g_haptic_player) {
        if (![g_haptic_engine startAndReturnError:&error]) { system_fail_on_queue("启动引擎失败", error); system_reset_on_queue(); return; }
        CHHapticEvent *event = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous parameters:@[
            [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:1],
            [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0.5]] relativeTime:0 duration:30];
        CHHapticPattern *pattern = [[CHHapticPattern alloc] initWithEvents:@[event] parameters:@[] error:&error];
        g_haptic_player = pattern ? [g_haptic_engine createAdvancedPlayerWithPattern:pattern error:&error] : nil;
        if (!g_haptic_player) { system_fail_on_queue("创建播放器失败", error); system_reset_on_queue(); return; }
        g_haptic_player.loopEnabled = YES;
    }
    if (!g_haptic_playing && ![g_haptic_player startAtTime:CHHapticTimeImmediate error:&error]) {
        system_fail_on_queue("播放失败", error); system_reset_on_queue(); return;
    }
    g_haptic_playing = YES;
    if (![g_haptic_player sendParameters:@[
        [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl value:amplitude relativeTime:0],
        [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticSharpnessControl value:sharp - 0.5f relativeTime:0]] atTime:CHHapticTimeImmediate error:&error]) {
        system_fail_on_queue("更新强度失败", error); system_reset_on_queue(); return;
    }
    s2a_hp_on_ok(&g_haptic_retry);   // 真正播起来了才清零连续失败
    static BOOL logged; if (!logged) { logged = YES; LOG("系统手柄震动：播放 强度 %.2f 锐度 %.2f", amplitude, sharp); }
    if (!g_haptic_timer) {
        g_haptic_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, g_system_haptics_queue);
        dispatch_source_set_event_handler(g_haptic_timer, ^{ system_stop_on_queue(); });
        dispatch_resume(g_haptic_timer);
    }
    dispatch_source_set_timer(g_haptic_timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), DISPATCH_TIME_FOREVER, 0);
}

static void system_select_device(GCController *device) {
    pthread_mutex_lock(&g_feedback_mu);
    g_system_present = device != nil; g_system_supported = device.haptics != nil;
    g_system_selected = NO;
    uint64_t epoch = ++g_system_epoch; g_system_pending = NO; g_system_transition = YES;
    memset(g_system_pair, 0, sizeof g_system_pair);
    dispatch_async(g_system_haptics_queue, ^{
        system_reset_on_queue(); g_haptic_device = device;
        s2a_hp_rearm(&g_haptic_retry);   // 换手柄 / 重新接入 = 新机会；已经报过的红不再刷屏
        pthread_mutex_lock(&g_feedback_mu);
        if (epoch == g_system_epoch) g_system_transition = NO;
        pthread_mutex_unlock(&g_feedback_mu);
        s2a_pad_wake();
    });
    pthread_mutex_unlock(&g_feedback_mu);
    if (device) LOG("系统手柄震动：%s", device.haptics ? "支持" : "不支持震动");
}
static void system_sync_selection(void) {
    pthread_mutex_lock(&g_feedback_mu);
    BOOL external = s2a_pad_has_controller();
    BOOL selected = g_system_present && external;
    BOOL phone = atomic_load(&g_ble_foreground) && !external;
    BOOL phone_changed = phone != g_phone_selected;
    if (phone != g_phone_selected) {
        g_phone_selected = phone; g_phone_epoch++; g_phone_pending = NO; g_phone_stop = NO;
        memset(g_phone_pair, 0, sizeof g_phone_pair);
        if (!phone) dispatch_async(g_system_haptics_queue, ^{ s2a_phone_rumble_stop(); });
    }
    if (selected != g_system_selected) {
        g_system_selected = selected; uint64_t epoch = ++g_system_epoch; g_system_pending = NO; g_system_transition = YES;
        memset(g_system_pair, 0, sizeof g_system_pair);
        dispatch_async(g_system_haptics_queue, ^{
            system_stop_on_queue();
            pthread_mutex_lock(&g_feedback_mu);
            if (epoch == g_system_epoch) g_system_transition = NO;
            pthread_mutex_unlock(&g_feedback_mu);
            s2a_pad_wake();
        });
    }
    pthread_mutex_unlock(&g_feedback_mu);
    if (phone_changed) s2a_pad_wake();
}
// 设置 / 设备能力在主线程读取，游戏线程只读取受锁保护的快照。
static void phone_refresh_availability(void) {
    BOOL available = s2a_phone_rumble_session() != 0;
    pthread_mutex_lock(&g_feedback_mu);
    BOOL changed = available != g_phone_available;
    if (changed) {
        g_phone_available = available; g_phone_epoch++; g_phone_pending = NO; g_phone_stop = NO;
        memset(g_phone_pair, 0, sizeof g_phone_pair);
        if (!available) dispatch_async(g_system_haptics_queue, ^{ s2a_phone_rumble_stop(); });
    }
    pthread_mutex_unlock(&g_feedback_mu);
    if (changed) s2a_pad_wake();
}
static void phone_submit_locked(const s2a_pad_vibration pair[2], BOOL stop) {
    if (!g_phone_selected || !g_phone_available || g_system_transition || !atomic_load(&g_ble_foreground) || s2a_pad_has_controller()) return;
    if (pair) memcpy(g_phone_pair, pair, sizeof g_phone_pair);
    g_phone_stop = stop;
    if (g_phone_pending) return;
    g_phone_pending = YES;
    uint64_t epoch = g_phone_epoch;
    dispatch_async(g_system_haptics_queue, ^{
        s2a_pad_vibration copy[2]; BOOL valid, stop_now = NO;
        pthread_mutex_lock(&g_feedback_mu);
        valid = epoch == g_phone_epoch && g_phone_selected && g_phone_available && !g_system_transition && atomic_load(&g_ble_foreground);
        if (epoch == g_phone_epoch) g_phone_pending = NO;
        if (valid) { memcpy(copy, g_phone_pair, sizeof copy); stop_now = g_phone_stop; }
        pthread_mutex_unlock(&g_feedback_mu);
        if (valid) { if (stop_now) s2a_phone_rumble_stop(); else s2a_phone_rumble_pair(copy); }
    });
}
static void system_submit_locked(uint64_t session, const s2a_pad_vibration pair[2]) {
    if (!session || session != (SYSTEM_SESSION_BASE | g_system_epoch) || !g_system_selected || !g_system_supported || g_system_transition || !s2a_pad_has_controller()) return;
    memcpy(g_system_pair, pair, sizeof g_system_pair);
    if (g_system_pending) return;
    g_system_pending = YES;
    dispatch_async(g_system_haptics_queue, ^{
        s2a_pad_vibration copy[2]; BOOL valid;
        pthread_mutex_lock(&g_feedback_mu);
        valid = session == (SYSTEM_SESSION_BASE | g_system_epoch) && g_system_selected && g_system_supported && !g_system_transition;
        if (valid) { memcpy(copy, g_system_pair, sizeof copy); g_system_pending = NO; }
        pthread_mutex_unlock(&g_feedback_mu);
        if (valid) system_play_on_queue(copy);
    });
}
_Static_assert(sizeof(s2a_pad_motion) == 32, "C# motion ABI requires 32 bytes");
_Static_assert(sizeof(s2a_pad_vibration) == 16, "C# vibration ABI requires 16 bytes per side");

// 外设 UUID 只是重连候选，保存在当前 App 沙盒，不需要额外签名权限。
static NSDictionary *read_record(BOOL *ok) {
    *ok = NO;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *identifier = [defaults stringForKey:@"S2ArmNS2ProLastReadyPeripheralIdentifier"];
    if (!identifier) { *ok = YES; return nil; }
    if (![[NSUUID alloc] initWithUUIDString:identifier]) {
        LOG("【红】手柄记忆：本 App 的设备标识无效"); return nil;
    }
    *ok = YES;
    return @{@"identifier": identifier, @"automatic": @([defaults boolForKey:@"S2ANS2ProEnabled"])};
}
static BOOL write_record(NSString *identifier, BOOL automatic) {
    if (![[NSUUID alloc] initWithUUIDString:identifier]) { LOG("【红】手柄记忆：设备标识无效"); return NO; }
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:identifier forKey:@"S2ArmNS2ProLastReadyPeripheralIdentifier"];
    [defaults setBool:automatic forKey:@"S2ANS2ProEnabled"];
    LOG("手柄记忆：已保存本 App 记录，自动连接 %s", automatic ? "开" : "关"); return YES;
}

// 手柄 / 触屏按最后一次输入切换（维护者 10-24）：实体手柄输入可能把生效来源从触屏切回手柄（pad.c 触屏接管），
//   这里在输入队列 / BLE 回调里发现变化后派回主线程更新虚拟按键显示；没变时只读一个原子量
static _Atomic int g_shown_external = -1;   // 虚拟按键当前按「实体手柄生效」隐藏着（1）/ 显示着（0）
static void pad_selection_check(void);
static void pad_face_sync(void);

// BLE 队列已缓存样本；新运动通知唤醒同一 HID 线程，不另建采样线程。
static void ble_motion(const ns2_motion *motion, void *context) {
    if (motion->known && (uintptr_t)context == atomic_load(&g_session) && atomic_load(&g_ble_ready)) s2a_pad_wake();
}

static void ble_input(const ns2_state *state, void *context) {
    pthread_mutex_lock(&g_feedback_mu);
    if (atomic_load(&g_adapter_enabled) && (uintptr_t)context == atomic_load(&g_session) && atomic_load(&g_ble_ready)) {
        int32_t axes[4] = { state->lx, state->ly, state->rx, state->ry };
        s2a_pad_update(S2A_PAD_BLE, 1, (uint32_t)state->buttons, axes);
    }
    pthread_mutex_unlock(&g_feedback_mu);
    pad_selection_check();
}
static void ble_status(ns2_status status, const char *message, void *context) {
    uint64_t session = (uintptr_t)context;
    pthread_mutex_lock(&g_feedback_mu);
    if (session != atomic_load(&g_session)) { pthread_mutex_unlock(&g_feedback_mu); return; }
    BOOL ready = atomic_load(&g_adapter_enabled) && status == NS2_STATUS_READY && atomic_load(&g_ble_foreground);
    if (ready && !atomic_load(&g_ble_ready)) atomic_fetch_add(&g_feedback_session, 1);
    atomic_store(&g_ble_ready, ready);
    int32_t axes[4] = {0}; s2a_pad_update(S2A_PAD_BLE, ready, 0, axes);
    pthread_mutex_unlock(&g_feedback_mu);
    pad_selection_check();
    NSString *text = [NSString stringWithUTF8String:message ?: ""];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (session == atomic_load(&g_session)) [g_controller bleStatus:status message:text];
    });
}

@implementation S2AController {
    __weak UIView *_root;
    UIButton *_connect;
    void (^_touchEnabled)(BOOL);
    dispatch_queue_t _inputQueue;
    GCController *_system; // 仅 inputQueue 访问。
    uint64_t _systemRev;      // 仅 inputQueue 访问：断开复查代次，旧 timer 靠它作废。
    BOOL _systemRecheck;      // 仅 inputQueue 访问：已排了一次延迟复查。
    NSString *_rememberedIdentifier;
    BOOL _adapterEnabled, _foreground, _hasSystem, _bleStarted, _bleBusy, _bleWanted, _blePaused, _bleResuming;
}
- (instancetype)initWithRoot:(UIView *)root touchEnabled:(void (^)(BOOL))callback {
    if (!(self = [super init])) return nil;
    _touchEnabled = [callback copy];
    _root = root;
    _inputQueue = dispatch_queue_create("s2arm.controller.input", DISPATCH_QUEUE_SERIAL);
    g_system_haptics_queue = dispatch_queue_create("s2arm.controller.haptics", DISPATCH_QUEUE_SERIAL);
    s2a_rumble_apply_settings();
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(systemChanged:) name:GCControllerDidConnectNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(systemChanged:) name:GCControllerDidDisconnectNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(settingsChanged:) name:NSUserDefaultsDidChangeNotification object:nil];
    pad_face_sync();
    return self;
}
- (void)createConnectionButton {
    UIView *root = _root;
    _connect = [UIButton buttonWithType:UIButtonTypeSystem];
    _connect.translatesAutoresizingMaskIntoConstraints = NO;
    UIButtonConfiguration *configuration = UIButtonConfiguration.filledButtonConfiguration;
    configuration.baseBackgroundColor = [UIColor colorWithWhite:0 alpha:.7];
    configuration.baseForegroundColor = UIColor.whiteColor;
    configuration.title = S2AL(@"controller.connect.title");
    _connect.configuration = configuration;
    _connect.titleLabel.adjustsFontForContentSizeCategory = YES;
    _connect.accessibilityHint = S2AL(@"controller.connect.hint");
    [_connect addTarget:self action:@selector(connectTapped) forControlEvents:UIControlEventTouchUpInside];
    _connect.layer.zPosition = 1001;
    [root addSubview:_connect];
    [NSLayoutConstraint activateConstraints:@[
        [_connect.centerXAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.centerXAnchor],
        [_connect.topAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.topAnchor constant:52],
        [_connect.heightAnchor constraintGreaterThanOrEqualToConstant:44],
        [_connect.leadingAnchor constraintGreaterThanOrEqualToAnchor:root.safeAreaLayoutGuide.leadingAnchor constant:16],
        [_connect.trailingAnchor constraintLessThanOrEqualToAnchor:root.safeAreaLayoutGuide.trailingAnchor constant:-16]
    ]];
}
- (BOOL)loadModule {
    if (atomic_load(&g_ns2)) return YES;
    NSString *path = [NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"NS2Pro.framework/NS2Pro"];
    void *image = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!image) { LOG("【红】NS2 Pro：模块加载失败，%s", dlerror()); return NO; }
    const ns2_api *(*entry)(void) = dlsym(image, "ns2_module_api");
    const ns2_api *api = entry ? entry() : NULL;
    if (!api || api->abi_version != NS2_MODULE_ABI_VERSION || api->struct_size != sizeof(ns2_api)) {
        LOG("【红】NS2 Pro：模块接口版本不匹配"); return NO;
    }
    atomic_store(&g_ns2, api);
    LOG("NS2 Pro：已按设置加载适配模块");
    return YES;
}
- (void)reloadAdapterPreference {
    // 缺少设置值即关闭；历史连接意愿不能打开这个每 App 开关。
    BOOL enabled = [NSUserDefaults.standardUserDefaults boolForKey:adapterPreference];
    if (enabled == _adapterEnabled) return;
    _adapterEnabled = enabled;
    pthread_mutex_lock(&g_feedback_mu);
    atomic_store(&g_adapter_enabled, enabled);
    pthread_mutex_unlock(&g_feedback_mu);
    if (enabled) {
        [self createConnectionButton];
    } else {
        [self stopBLE:"adapter disabled in Settings"];
        pthread_mutex_lock(&g_motion_mu);
        atomic_store(&g_motion_requested, 0);
        pthread_mutex_unlock(&g_motion_mu);
        _bleWanted = NO; _rememberedIdentifier = nil;
        [_connect removeFromSuperview]; _connect = nil;
    }
    s2a_pad_wake();
    LOG("NS2 Pro：本 App 适配%s", enabled ? "开启" : "关闭");
}
// 手柄按键对应（定义表 game_settings.v1.json 的 padFace：letter 按字母（缺省）/ position 按位置）：偏好一变就转给 pad.c，下一次按键即按新口径（不用重启）
static void pad_face_sync(void) {
    NSString *v = [NSUserDefaults.standardUserDefaults stringForKey:@"padFace"];
    if (v) s2a_pad_face_set(![v isEqualToString:@"position"]);
}
- (void)settingsChanged:(NSNotification *)notification {
    pad_face_sync();
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self->_foreground) return;
        s2a_phone_motion_enable(atomic_load(&g_phone_motion_wanted) && !atomic_load(&g_ble_ready));
        phone_refresh_availability();
        BOOL previous = self->_adapterEnabled;
        [self reloadAdapterPreference];
        if (previous == self->_adapterEnabled) return;
        if (self->_adapterEnabled) [self reloadRecord];
        [self selectSystem];
        if (self->_adapterEnabled && !self->_hasSystem && self->_bleWanted) [self resumeBLE];
        [self updateVisibility];
    });
}
- (void)setTitle:(NSString *)title hint:(NSString *)hint {
    UIButtonConfiguration *configuration = _connect.configuration; configuration.title = title;
    _connect.configuration = configuration; _connect.accessibilityHint = hint;
}
- (void)reloadRecord {
    if (!_adapterEnabled) return;
    BOOL ok; NSDictionary *record = read_record(&ok);
    if (!ok) { _bleWanted = NO; return; }
    if (record) {
        _rememberedIdentifier = record[@"identifier"];
        _bleWanted = [record[@"automatic"] boolValue];
        [NSUserDefaults.standardUserDefaults setObject:_rememberedIdentifier forKey:@"S2ArmNS2ProLastReadyPeripheralIdentifier"];
        LOG("手柄记忆：读取本 App 设备记录，自动连接 %s", _bleWanted ? "开" : "关");
    } else {
        _rememberedIdentifier = nil;
        _bleWanted = NO;
    }
}
- (void)updateVisibility {
    BOOL external = s2a_pad_has_controller();
    atomic_store(&g_shown_external, external);
    _connect.hidden = !_adapterEnabled || !_foreground || external;
    _touchEnabled(_foreground && !external);
}
- (void)publishSystem:(GCExtendedGamepad *)pad {
    // GameController 的 ABXY 通常按物理方位定义（南/东/西/北 → Nintendo B/A/Y/X）；任天堂手柄按键帽字母上报（#40），判断同 Mac 侧 front_mac.m。
    // buttonOptions（「-」）在部分手柄上为 nil；位序不能动，bit11 留给它，nil 时该位恒 0（与 Mac 侧 front_mac.m 一致）。
    GCControllerButtonInput *options = pad.buttonOptions;
    GCControllerButtonInput *face[4] = {pad.buttonA, pad.buttonB, pad.buttonX, pad.buttonY};
    int order[4]; s2a_pad_abxy_order(s2a_pad_kind(pad.controller.productCategory.UTF8String, [pad isKindOfClass:GCXboxGamepad.class],
        [pad isKindOfClass:GCDualShockGamepad.class] || [pad isKindOfClass:GCDualSenseGamepad.class]), s2a_pad_face_by_letter(), order);   // 按字母 / 按位置（pad.c）
    GCControllerButtonInput *keys[16] = {face[order[0]], face[order[1]], face[order[2]], face[order[3]],
        pad.leftThumbstickButton, pad.rightThumbstickButton, pad.leftShoulder, pad.rightShoulder,
        pad.leftTrigger, pad.rightTrigger, pad.buttonMenu, options,
        pad.dpad.left, pad.dpad.up, pad.dpad.right, pad.dpad.down};
    uint32_t buttons = 0;
    for (int i = 0; i < 16; i++) if (keys[i].isPressed) buttons |= 1u << i;
    int32_t axes[4];
    s2a_pad_stick(pad.leftThumbstick.xAxis.value, pad.leftThumbstick.yAxis.value, axes);
    s2a_pad_stick(pad.rightThumbstick.xAxis.value, pad.rightThumbstick.yAxis.value, axes + 2);
    s2a_pad_update(S2A_PAD_SYSTEM, 1, buttons, axes);
    pad_selection_check();
}
// 换到另一个系统手柄对象：旧对象的 handler 必须摘掉（它已经不在快照里），新对象装上同一套回调。
// 只在 inputQueue 上跑。
- (void)attachSystem:(GCController *)next {
    if (next == _system) return;
    _system.extendedGamepad.valueChangedHandler = nil;
    _system = next;
    _systemRev++;          // 挂起的延迟复查作废：已经有新对象了
    _systemRecheck = NO;
    system_select_device(next);   // 震动侧跟着换设备（原 selectSystem 里的调用，挪到这里）
    next.handlerQueue = _inputQueue;
    // 「-」（buttonOptions）默认是 GCSystemGestureStateEnabled：系统手势识别器先跑、之后才把输入给 app，
    //   短按要等它判定失败才转发（真机约 1 秒），长按完全不转发；iOS 还拿它触发录屏。
    //   Disabled 的语义是「手势识别器完全不跑，输入直接给 app」（GCControllerElement.h:45），这才是我们要的。
    //   不要用 AlwaysReceive：它已废弃（API_DEPRECATED_WITH_REPLACEMENT(…Disabled, ios(14.0, 27.0))），
    //   而且语义是「同时发给 app 和手势识别器」——录屏照旧触发。
    //   「+」（buttonMenu）不设：头文件没有把它标成系统保留键（系统保留做截图/录屏的是 buttonShare / buttonHome），
    //   且真机实测「+」本来即时响应（Enabled 下若绑了手势，短按必然延迟），没有现象就不改。
    GCExtendedGamepad *pad = next.extendedGamepad;
    if (@available(iOS 14.0, *)) {
        if (pad.buttonOptions) pad.buttonOptions.preferredSystemGestureState = GCSystemGestureStateDisabled;
    }
    __weak S2AController *weakSelf = self;
    next.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *pad, GCControllerElement *element) {
        S2AController *owner = weakSelf;
        if (owner && pad == owner->_system.extendedGamepad) [owner publishSystem:pad];
    };
    LOG("系统手柄：接入 %s", next.vendorName.UTF8String ?: "GameController");
}
// 确认断开：摘 handler 并把共享内存里的系统手柄状态清零。只在 inputQueue 上跑。
- (void)clearSystem {
    GCController *old = _system;
    _system = nil;
    _systemRev++;
    _systemRecheck = NO;
    system_select_device(nil);    // 震动侧一并摘掉（原 selectSystem 里 next 为 nil 时同样会调）
    old.extendedGamepad.valueChangedHandler = nil;
    s2a_pad_update(S2A_PAD_SYSTEM, 0, 0, NULL);
}
// 第一次发现当前手柄不可用：不立刻清零，S2A_SYSTEM_RECHECK_MS 后复查一次。只在 inputQueue 上跑。
- (void)scheduleSystemRecheck {
    _systemRecheck = YES;
    uint64_t rev = ++_systemRev;
    __weak S2AController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(S2A_SYSTEM_RECHECK_MS * NSEC_PER_MSEC)), _inputQueue, ^{
        S2AController *owner = weakSelf;
        if (!owner) return;
        // 期间已重新接入 / 已有更新的决定：本次复查不生效。
        if (rev != owner->_systemRev || !owner->_systemRecheck) return;
        owner->_systemRecheck = NO;
        // 复查一律按前台语义：真切了后台时 setForeground: 自己会走 selectSystem 立刻清零，不靠这条 timer。
        [owner selectSystemLocked:YES mayClear:YES];
        BOOL hasSystem = owner->_system != nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            S2AController *inner = weakSelf;
            if (!inner) return;
            inner->_hasSystem = hasSystem;
            [inner updateVisibility];
        });
    });
}
// 只在 inputQueue 上跑：判活、换对象、延迟复查、确认清零的唯一入口。
- (void)selectSystemLocked:(BOOL)foreground mayClear:(BOOL)mayClear {
    NSArray<GCController *> *controllers = GCController.controllers;
    GCController *current = _system;
    GCController *candidate = nil;
    for (GCController *other in controllers)
        if (other != current && other.extendedGamepad) { candidate = other; break; }
    s2a_sys_state state = {
        .foreground = foreground,
        .has_current = current != nil,
        .current_alive = current.extendedGamepad != nil,
        .candidate_ready = candidate != nil,
        .may_clear = mayClear,
    };
    const char *name = current.vendorName.UTF8String ?: "GameController";
    switch (s2a_system_action(state)) {
        case S2A_SYS_PUBLISH:
            if (mayClear) LOG("系统手柄：%s 已恢复，保留 handler", name);
            [self publishSystem:current.extendedGamepad];
            break;
        case S2A_SYS_ATTACH:
            [self attachSystem:candidate];
            [self publishSystem:candidate.extendedGamepad];
            break;
        case S2A_SYS_DEFER:
            // 抖动期不清 handler、不清零：这期间实体手柄的按键仍然走 publishSystem 进共享内存。
            // 每条通知都打一行（诊断用：日志里数得出 iOS 到底发了几次 Disconnect），复查只排一次。
            LOG("系统手柄：%s 从快照消失（%d 个在场），延迟确认中", name, (int)controllers.count);
            if (!_systemRecheck) [self scheduleSystemRecheck];
            break;
        case S2A_SYS_CLEAR:
            if (mayClear) LOG("系统手柄：%s 确认断开（%d ms 复查仍不可用，%d 个在场），清零并摘 handler", name, S2A_SYSTEM_RECHECK_MS, (int)controllers.count);
            else LOG("系统手柄：%s 断开（不在前台），清零并摘 handler", name);
            [self clearSystem];
            break;
        case S2A_SYS_NONE:
        default:
            break;
    }
}
- (void)selectSystem {
    __block BOOL hasSystem;
    BOOL foreground = _foreground;
    dispatch_sync(_inputQueue, ^{
        [self selectSystemLocked:foreground mayClear:NO];
        hasSystem = self->_system != nil;
    });
    _hasSystem = hasSystem;
    if (_foreground && _hasSystem) [self stopBLE:"system controller selected"];
    [self updateVisibility];
}
- (void)systemChanged:(NSNotification *)notification {
    // 框架通知线程不作假设，设备输入本身仍只在 inputQueue 处理。
    dispatch_async(dispatch_get_main_queue(), ^{ [self selectSystem]; });
}
- (void)stopBLE:(const char *)reason {
    _blePaused = _bleResuming = NO;
    if (!_bleStarted) return;
    pthread_mutex_lock(&g_feedback_mu);
    atomic_fetch_add(&g_session, 1); atomic_store(&g_ble_ready, 0);
    s2a_pad_update(S2A_PAD_BLE, 0, 0, NULL);
    pthread_mutex_unlock(&g_feedback_mu);
    atomic_load(&g_ns2)->shutdown(reason, 0); // 不在主线程等待电机或连接完成。
    s2a_pad_wake();
    _bleStarted = _bleBusy = NO;
    [self setTitle:S2AL(@"controller.connect.title") hint:S2AL(@"controller.connect.hint")];
}
- (void)startBLE {
    if (!_adapterEnabled || !_foreground || _hasSystem) return;
    if (![self loadModule]) { [self setTitle:S2AL(@"controller.moduleFailed.title") hint:S2AL(@"controller.moduleFailed.hint")]; return; }
    const ns2_api *api = atomic_load(&g_ns2);
    if (_bleStarted) { if (api->rescan()) _bleBusy = YES; return; }
    pthread_mutex_lock(&g_feedback_mu);
    uint64_t session = atomic_fetch_add(&g_session, 1) + 1;
    pthread_mutex_unlock(&g_feedback_mu);
    _bleStarted = api->start_with_motion(ble_input, ble_status, ble_motion, (void *)(uintptr_t)session) != 0;
    if (_bleStarted) {
        pthread_mutex_lock(&g_motion_mu);
        api->set_motion_enabled(atomic_load(&g_motion_requested));
        pthread_mutex_unlock(&g_motion_mu);
    }
    _bleBusy = _bleStarted;
    if (!_bleStarted) [self setTitle:S2AL(@"controller.connectFailed.title") hint:S2AL(@"controller.connectFailed.hint")];
}
- (void)resumeBLE {
    if (!_adapterEnabled || !_foreground || _hasSystem) return;
    if (_bleStarted) {
        if (_blePaused && atomic_load(&g_ns2)->resume()) {
            _bleResuming = YES;
            _bleBusy = YES;
            [self setTitle:S2AL(@"controller.resuming.title") hint:S2AL(@"controller.resuming.hint")];
            return;
        }
        // A retained link may have disconnected while iOS suspended the app. Start one bounded known-device attempt.
        [self stopBLE:"retained link unavailable on foreground"];
    }
    [self startBLE];
}
- (void)connectTapped {
    if (!_adapterEnabled || !_foreground) return;
    if (![self loadModule]) { [self setTitle:S2AL(@"controller.moduleFailed.title") hint:S2AL(@"controller.moduleFailed.hint")]; return; }
    if (atomic_load(&g_ns2)->authorization_denied()) {
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:UIApplicationOpenSettingsURLString] options:@{} completionHandler:nil];
        return;
    }
    if (_bleBusy) {
        // 取消当前前台尝试，不清除本 App 的成功记录。
        _bleWanted = NO;
        [self stopBLE:"player cancelled"]; [self updateVisibility]; return;
    }
    [self startBLE];
}
- (void)bleStatus:(ns2_status)status message:(NSString *)message {
    if (!_adapterEnabled) return;
    // UIKit may receive a queued READY after entering the background; it must not reopen the logical session.
    if (status == NS2_STATUS_READY && (!_foreground || !atomic_load(&g_ble_ready))) return;
    LOG("NS2 Pro：状态 %d，%s", status, message.UTF8String);
    if (status == NS2_STATUS_READY) {
        _blePaused = _bleResuming = NO;
        _bleWanted = YES;
        ns2_info info; atomic_load(&g_ns2)->get_info(&info);
        _rememberedIdentifier = [NSString stringWithUTF8String:info.identifier];
        write_record(_rememberedIdentifier, YES);
    }
    if (status == NS2_STATUS_DISCONNECTED || status == NS2_STATUS_UNAVAILABLE || status == NS2_STATUS_ERROR || status == NS2_STATUS_STOPPED) {
        BOOL retry = _bleResuming && _foreground && !_hasSystem && _bleWanted;
        _blePaused = _bleResuming = NO;
        if (retry) {
            // One failed soft resume may rebuild the link; a failure of that new connection does not retry again.
            [self stopBLE:"soft resume failed"];
            [self startBLE];
            return;
        }
    }
    _bleBusy = _bleResuming || status == NS2_STATUS_SCANNING || status == NS2_STATUS_CONNECTING || status == NS2_STATUS_INITIALIZING ||
        status == NS2_STATUS_SUSPENDING || status == NS2_STATUS_RESUMING;
    if (_bleBusy) [self setTitle:status == NS2_STATUS_SCANNING ? S2AL(@"controller.scanning.title") : S2AL(@"controller.connecting.title") hint:S2AL(@"controller.busy.hint")];
    else if (status != NS2_STATUS_READY) {
        BOOL denied = atomic_load(&g_ns2)->authorization_denied();
        [self setTitle:denied ? S2AL(@"controller.allowBluetooth.title") : status == NS2_STATUS_UNAVAILABLE ? S2AL(@"controller.bluetoothOff.title") : S2AL(@"controller.reconnect.title") hint:message];
    }
    [self updateVisibility];
}
- (void)setForeground:(BOOL)foreground {
    if (_foreground == foreground) { if (foreground) [self settingsChanged:nil]; return; }
    _foreground = foreground;
    pthread_mutex_lock(&g_feedback_mu);
    BOOL wasReady = atomic_load(&g_ble_ready);
    atomic_store(&g_ble_foreground, foreground);
    if (!foreground) atomic_store(&g_ble_ready, 0);
    pthread_mutex_unlock(&g_feedback_mu);
    s2a_pad_set_active(foreground);
    if (foreground) { phone_refresh_availability(); [self reloadAdapterPreference]; if (_adapterEnabled) [self reloadRecord]; }
    if (!foreground && _bleStarted) {
        _bleResuming = NO;
        // Preserve the physical callback context; resume creates a fresh feedback epoch only after new input is ready.
        if ((wasReady || _blePaused) && atomic_load(&g_ns2)->suspend()) {
            _blePaused = YES;
            _bleBusy = NO;
            s2a_pad_update(S2A_PAD_BLE, 0, 0, NULL);
            LOG("NS2 Pro：后台暂停输入和反馈，保留 BLE 链路候选");
        } else [self stopBLE:"scene background before a retainable link"];
    }
    [self selectSystem];
    system_sync_selection();
    if (foreground && _adapterEnabled && !_hasSystem) {
        if (_bleWanted) [self resumeBLE];
        else if (_blePaused) [self stopBLE:"automatic connection disabled"];
    }
    if (foreground) [self settingsChanged:nil];
    else { s2a_phone_motion_enable(0); s2a_phone_rumble_stop(); }
}
@end

// 长按「+」开快捷菜单（外接手柄时四指长按够不着屏幕）：每个新按下的序号交给 diag.m 计时复查（s2a_diag_menu_hold）
static void menu_hold_check(void) {
    static _Atomic uint64_t armed;
    uint64_t press = s2a_pad_plus_press();
    if (!press || atomic_exchange(&armed, press) == press) return;
    void s2a_diag_menu_hold(uint64_t press); s2a_diag_menu_hold(press);
}
static void pad_selection_check(void) {
    menu_hold_check();
    system_sync_selection();
    int external = s2a_pad_has_controller();
    if (atomic_load(&g_shown_external) != external) dispatch_async(dispatch_get_main_queue(), ^{ [g_controller updateVisibility]; });
}
// 屏幕被碰（含虚拟按键隐藏时碰到游戏画面）：连着实体手柄时改由触屏生效、显示虚拟按键。只观察、不拦截任何触摸
@interface S2ATouchWatch : UIGestureRecognizer
@end
@implementation S2ATouchWatch
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)touches; (void)event;
    if (s2a_pad_prefer_touch()) {
        system_sync_selection();
        pthread_mutex_lock(&g_feedback_mu);
        if (atomic_load(&g_ble_ready)) {
            atomic_fetch_add(&g_feedback_session, 1);
            atomic_load(&g_ns2)->stop_rumble();
        }
        pthread_mutex_unlock(&g_feedback_mu);
        [g_controller updateVisibility];
    }
    self.state = UIGestureRecognizerStateFailed;
}
@end
void s2a_controller_attach(UIView *root, void (^touchEnabled)(BOOL)) {
    if (g_controller) return;
    g_controller = [[S2AController alloc] initWithRoot:root touchEnabled:touchEnabled];
    [g_controller setForeground:YES];
    S2ATouchWatch *watch = [S2ATouchWatch new];   // 不吃游戏 / 虚拟按键的触摸（同 diag.m 四指长按的设法）
    watch.cancelsTouchesInView = NO; watch.delaysTouchesBegan = NO; watch.delaysTouchesEnded = NO;
    [root addGestureRecognizer:watch];
}
void s2a_controller_set_foreground(int foreground) { [g_controller setForeground:foreground != 0]; }

// C# 反馈提交只碰固定 mailbox / 快照，不从游戏线程等待 CoreBluetooth 或 UIKit。
__attribute__((visibility("default"), used)) uint64_t s2a_pad_rumble_session(void) {
    pthread_mutex_lock(&g_feedback_mu);
    BOOL external = s2a_pad_has_controller();
    BOOL system = external && g_system_present;
    uint64_t session = !g_system_transition && system && g_system_selected ? (SYSTEM_SESSION_BASE | g_system_epoch) :
        (!g_system_transition && !system && external && atomic_load(&g_adapter_enabled) && atomic_load(&g_ble_ready) ? atomic_load(&g_feedback_session) : 0);
    BOOL foreground = atomic_load(&g_ble_foreground);
    BOOL phone = !g_system_transition && g_phone_selected && g_phone_available && foreground && !external;
    uint64_t phone_epoch = g_phone_epoch;
    pthread_mutex_unlock(&g_feedback_mu);
    if (session) return session;
    if (phone) return PHONE_SESSION_BASE | phone_epoch;
    return foreground ? MOTION_ONLY_SESSION : 0;
}
__attribute__((visibility("default"), used)) void s2a_pad_set_rumble_pair(uint64_t session, const s2a_pad_vibration raw[2]) {
    if (!raw) return;
    s2a_pad_vibration values[2]; rumble_scale_pair(raw, values);
    if ((session & 0xffff000000000000ull) == PHONE_SESSION_BASE) {
        pthread_mutex_lock(&g_feedback_mu);
        if (session == (PHONE_SESSION_BASE | g_phone_epoch)) phone_submit_locked(values, NO);
        pthread_mutex_unlock(&g_feedback_mu); return;
    }
    pthread_mutex_lock(&g_feedback_mu);
    if ((session & 0xffff000000000000ull) == SYSTEM_SESSION_BASE) {
        system_submit_locked(session, values);
    } else if (!g_system_present && s2a_pad_has_controller() && atomic_load(&g_adapter_enabled) && session && session == atomic_load(&g_feedback_session) && atomic_load(&g_ble_ready)) {
        ns2_vibration pair[2] = {
            { values[0].low_amp, values[0].low_hz, values[0].high_amp, values[0].high_hz },
            { values[1].low_amp, values[1].low_hz, values[1].high_amp, values[1].high_hz }
        };
        atomic_load(&g_ns2)->send_pair_lease(pair, 1000);
    }
    pthread_mutex_unlock(&g_feedback_mu);
}
__attribute__((visibility("default"), used)) void s2a_pad_set_rumble(uint64_t session, unsigned side, float low_amp, float low_hz, float high_amp, float high_hz) {
    low_amp = rumble_scaled(low_amp); high_amp = rumble_scaled(high_amp);
    if ((session & 0xffff000000000000ull) == PHONE_SESSION_BASE) {   // 手机马达只有一个，合成两侧
        pthread_mutex_lock(&g_feedback_mu);
        if (side < 2 && session == (PHONE_SESSION_BASE | g_phone_epoch)) {
            s2a_pad_vibration pair[2] = {g_phone_pair[0], g_phone_pair[1]};
            pair[side] = (s2a_pad_vibration){low_amp, low_hz, high_amp, high_hz};
            phone_submit_locked(pair, NO);
        }
        pthread_mutex_unlock(&g_feedback_mu); return;
    }
    pthread_mutex_lock(&g_feedback_mu);
    if ((session & 0xffff000000000000ull) == SYSTEM_SESSION_BASE) {
        if (side < 2 && session == (SYSTEM_SESSION_BASE | g_system_epoch)) {
            s2a_pad_vibration pair[2] = {g_system_pair[0], g_system_pair[1]};
            pair[side] = (s2a_pad_vibration){low_amp, low_hz, high_amp, high_hz};
            system_submit_locked(session, pair);
        }
    } else if (!g_system_present && s2a_pad_has_controller() && atomic_load(&g_adapter_enabled) && session && session == atomic_load(&g_feedback_session) && atomic_load(&g_ble_ready))
        atomic_load(&g_ns2)->send_lease(side, low_amp, low_hz, high_amp, high_hz, 1000);
    pthread_mutex_unlock(&g_feedback_mu);
}
// 设置页改了开关或强度：立即生效。关掉时三路马上停，不等游戏下一次提交
void s2a_rumble_apply_settings(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    static const float gains[5] = {0.35f, 0.7f, 1, 1.4f, 1.8f};
    id on = [d objectForKey:@"S2ARumbleOn"], level = [d objectForKey:@"S2ARumbleLevel"];
    int lv = level ? (int)[level integerValue] : 2; lv = lv < 0 ? 0 : lv > 4 ? 4 : lv;
    float gain = (on && ![on boolValue]) ? 0 : gains[lv];
    float old = atomic_exchange(&g_rumble_gain, gain);
    if (gain == 0 && old != 0 && g_system_haptics_queue) {
        dispatch_async(g_system_haptics_queue, ^{ system_stop_on_queue(); s2a_phone_rumble_stop(); });
        if (atomic_load(&g_adapter_enabled) && atomic_load(&g_ble_ready)) atomic_load(&g_ns2)->stop_rumble();
    }
    LOG("游戏震动：%s，强度档 %d（倍率 %.2f）", gain > 0 ? "开" : "关", lv, gain);
}
// 菜单里切震动档位 / 打开游戏震动时试震一下（11-09 维护者：「点击强弱机器是没有反应的……切换的时候手机震一下让玩家有感知」）：
//   走游戏震动同一条出口（s2a_pad_rumble_session 选手机马达或手柄，s2a_pad_set_rumble_pair 按当前档位倍率缩放），震 0.3 秒，几档之间摸得出差别。
//   基准振幅 0.5：弱 0.18、较弱 0.35、标准 0.5、较强 0.7、强 0.9（倍率见 s2a_rumble_apply_settings），强档不被 1.0 截平
void s2a_rumble_preview(void) {
    if (atomic_load(&g_rumble_gain) <= 0) return;
    uint64_t session = s2a_pad_rumble_session(); if (!session) { LOG("游戏震动：试震跳过（现在没有可震的设备）"); return; }
    const s2a_pad_vibration v[2] = {{0.5f, 160, 0.5f, 320}, {0.5f, 160, 0.5f, 320}};
    s2a_pad_set_rumble_pair(session, v);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ s2a_pad_stop_rumble(session); });
}
__attribute__((visibility("default"), used)) void s2a_pad_stop_rumble(uint64_t session) {
    if ((session & 0xffff000000000000ull) == PHONE_SESSION_BASE) {
        pthread_mutex_lock(&g_feedback_mu);
        if (session == (PHONE_SESSION_BASE | g_phone_epoch)) phone_submit_locked(NULL, YES);
        pthread_mutex_unlock(&g_feedback_mu); return;
    }
    pthread_mutex_lock(&g_feedback_mu);
    if ((session & 0xffff000000000000ull) == SYSTEM_SESSION_BASE) {
        s2a_pad_vibration zero[2] = {0}; system_submit_locked(session, zero);
    } else if (atomic_load(&g_adapter_enabled) && session && session == atomic_load(&g_feedback_session) && atomic_load(&g_ble_ready)) atomic_load(&g_ns2)->stop_rumble();
    pthread_mutex_unlock(&g_feedback_mu);
}
__attribute__((visibility("default"), used)) void s2a_pad_set_motion_enabled(int enabled) {
    pthread_mutex_lock(&g_motion_mu);
    int want = !!enabled;
    atomic_store(&g_phone_motion_wanted, want);
    enabled = want && atomic_load(&g_adapter_enabled);
    const ns2_api *api = atomic_load(&g_ns2);
    if (atomic_exchange(&g_motion_requested, enabled) != enabled && api && atomic_load(&g_adapter_enabled)) api->set_motion_enabled(enabled);
    int ns2 = enabled && atomic_load(&g_ble_ready);
    pthread_mutex_unlock(&g_motion_mu);
    s2a_phone_motion_enable(want && atomic_load(&g_ble_foreground) && !ns2);   // 后台与游戏不要六轴时关闭。
}
__attribute__((visibility("default"), used)) int s2a_pad_read_motion(s2a_pad_motion *out) {
    if (!out) return 0;
    ns2_motion motion = {0};
    pthread_mutex_lock(&g_motion_mu);
    if (atomic_load(&g_adapter_enabled) && atomic_load(&g_ble_ready) && atomic_load(&g_motion_requested)) atomic_load(&g_ns2)->get_motion(&motion);
    pthread_mutex_unlock(&g_motion_mu);
    *out = (s2a_pad_motion){0};
    if (!motion.known) {
        // 没有外接手柄的样本：手机自身当掌机六轴（游戏要六轴时才开着）；中途连上了外接手柄则在它出样本那次关掉手机传感器
        return atomic_load(&g_phone_motion_wanted) ? s2a_phone_motion_read(out) : 0;
    }
    s2a_phone_motion_enable(0);
    *out = (s2a_pad_motion){motion.host_timestamp_us,
        motion.acceleration_x, motion.acceleration_y, motion.acceleration_z,
        motion.gyro_x, motion.gyro_y, motion.gyro_z};
    return 1;
}
