#ifndef S2A_PAD_H
#define S2A_PAD_H
#include <stdint.h>

// 固定三路输入，不合并不同手柄。系统手柄 > NS2 Pro BLE > 触屏；连着实体手柄时按最后一次输入切换（维护者 10-24）：
//   屏幕被碰（s2a_pad_prefer_touch）→ 触屏接管，实体手柄有按键 / 摇杆动作 → 切回手柄。
typedef enum { S2A_PAD_TOUCH, S2A_PAD_BLE, S2A_PAD_SYSTEM, S2A_PAD_COUNT } s2a_pad_source;
// buttons 仅用 Nintendo 标准位 0..15；axes 为左 x/y、右 x/y，±32767，上为正。
void s2a_pad_update(s2a_pad_source source, int connected, uint32_t buttons, const int32_t axes[4]);
void s2a_pad_set_active(int active);
// 进程内重启（runtime/src/host_main.c s2a_host_rebuild）：清掉上一局的按键 / 摇杆快照、换输入纪元；活跃状态不变（后台时不会被打开）
void s2a_pad_session_reset(void);
int s2a_pad_has_controller(void);   // 当前生效的是实体手柄（触屏接管时为 0）
// 屏幕被碰：连着实体手柄时改由触屏生效（虚拟按键要显示），返回 1 = 发生了切换
int s2a_pad_prefer_touch(void);
uint32_t s2a_pad_read(int32_t axes[4], s2a_pad_source *source);
// 快捷菜单的手柄入口（情报 10-28：接外接手柄时只有四指长按能开菜单）：实体手柄「+」（bit10）或 Home（扩展位 bit16，#276）每按下一次记一个序号；
//   按着时返回当前序号，没按着返回 0。iOS 记下新序号、1.5 秒后再问一次仍是它 = 一直按着没松，开菜单（ios/controller.m）
uint64_t s2a_pad_plus_press(void);
void s2a_pad_stick(float x, float y, int32_t axes[2]);
// 系统手柄的 ABXY：多数手柄按物理方位上报（buttonA 在南侧），任天堂手柄（Pro、Joy-Con）按键帽字母上报（印 A 的右键 = buttonA）。
// category / vendor 取 GCController 的 productCategory / vendorName，可为 NULL。iOS 与 Mac 共用这一个判断（#40）。
int s2a_pad_labels_abxy(const char *category, const char *vendor);
// 把系统的 buttonA/B/X/Y（下标 0/1/2/3）排成 Nintendo 位序 A、B、X、Y：out[i] = 第 i 位该读系统的哪个键
void s2a_pad_abxy_order(int labelled, int out[4]);

// 原子快照，固定 56 字节。epoch 在切源/前后台切换时变化，旧短按不得跨 epoch 回放。
typedef struct {
    uint64_t notification_seq, input_epoch, host_timestamp_us, read_timestamp_us;
    uint32_t buttons, source;
    int32_t axes[4];
} s2a_pad_snapshot;
void s2a_pad_read_ex(s2a_pad_snapshot *out);
uint64_t s2a_pad_now_us(void); // CLOCK_MONOTONIC，wait 与延迟测量使用同一时间轴。
// 锁内重查 observed_seq；绝对单调 deadline 到达返回 0，通知变化返回 1。
int s2a_pad_wait(uint64_t observed_seq, uint64_t deadline_us);
void s2a_pad_wake(void); // Stop/玩家改配也必须改变序号，避免读后等之前丢失通知。
typedef struct {
    uint64_t samples, host_total_us, read_total_us, host_max_us, read_max_us;
} s2a_pad_latency;
void s2a_pad_record_commit(const s2a_pad_snapshot *snapshot);
void s2a_pad_get_latency(s2a_pad_latency *out, int reset);

// iOS 可选导出：游戏侧按符号查询，其他宿主不必提供。
// 运动保持 NS2 原始坐标，单位 g、度/秒；单调接收时间，结构体 32 字节。
typedef struct {
    uint64_t host_timestamp_us;
    float acceleration_x, acceleration_y, acceleration_z;
    float gyro_x, gyro_y, gyro_z;
} s2a_pad_motion;
uint64_t s2a_pad_rumble_session(void); // 0 = 不可用；重连、前后台切换后会变化。
// 与游戏 VibrationValue 同序，每侧 16 字节；一次提交左右完整帧。
typedef struct {
    float low_amp, low_hz, high_amp, high_hz;
} s2a_pad_vibration;
void s2a_pad_set_rumble_pair(uint64_t session, const s2a_pad_vibration values[2]);
void s2a_pad_set_rumble(uint64_t session, unsigned side, float low_amp, float low_hz, float high_amp, float high_hz);
void s2a_pad_stop_rumble(uint64_t session);
void s2a_pad_set_motion_enabled(int enabled);
int s2a_pad_read_motion(s2a_pad_motion *out);
#endif
