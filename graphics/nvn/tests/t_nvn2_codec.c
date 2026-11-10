// nvn2_codec.c（Switch 2 直连档的视频解码接管）：经装载器同一个入口 s2a_codec_entry 取函数，照 subsdk2 movie 库的调用次序走一遍
//   （图像池 → 解码器初始化 → 登记缓冲 → 开始 → 提交 → 取缓冲 + 同步点事件等帧 → 帧属性 → 读像素 → 释放 → 结束）。
// 期望值不跑被测实现得出：
//   - 测试流是 ffmpeg 9 从同一份 64x64 原始 YUV（Y 81、U 90、V 240，两帧）编的：VP9 用 libvpx-vp9 -lossless 1（解出来 YUV 原样），
//     AV1 用 libsvtav1 -crf 10（有损，只比大致颜色）。BT.601 视频范围（片子没声明矩阵、64 行 < 720）手算：
//     R = 1.1644·(81−16) + 1.5960·(240−128) = 75.7 + 178.8 → 254；G = 75.7 − 0.3918·(90−128) − 0.8130·112 = 75.7 + 14.9 − 91.1 → 0（钳）；
//     B = 75.7 + 2.0172·(90−128) = 75.7 − 76.7 → 0（钳）。即 RGBA (254, 0, 0, 255)，容差 ±1。
//   - av1C：ffmpeg 把同一条 AV1 流封进 WebM 时写的 CodecPrivate（ffprobe -show_data 读出）= 81 00 0c 00 + 序列头 OBU（0a 0b …）。
//   - AV1 软件解码（dav1d，S2A_AV1_SOFT=1 强制）：解出的 YUV 逐帧 MD5 对 ffmpeg 9 + libdav1d 解同一条流的 framemd5（AV1 解码按标准逐位确定，参考与被测是两个程序）：
//     ts_av1 = ffmpeg -f lavfi -i testsrc2=size=96x64:rate=30 -frames:v 6 -pix_fmt yuv420p -c:v libsvtav1 -crf 30 -preset 8 -g 6 -f ivf，
//     red10_av1 = 上面那份红色原始 YUV 的 10 位版（Y 324、U 360、V 960）-pix_fmt yuv420p10le -c:v libsvtav1 -crf 10；
//     经整条接管路径（强制软解）出的像素：8 位、10 位都按上面手算的 (254, 0, 0, 255)，有损 ±3。
//   - H.264 宿主没接：初始化回失败（不出假画面）。
//   - 同步句柄：模式 1 比 64 位、其它 32 位回绕比；全 0 句柄算达到。
// 可选参数 <时间单元文件> <av1C 文件>：再核一对真片子的数据（一次性核对用，不进门禁）
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdatomic.h>
#include <unistd.h>
#include <time.h>
#include <sys/wait.h>
#include <pthread.h>
#include <VideoToolbox/VideoToolbox.h>
// ffmpeg framemd5 是 MD5：CommonCrypto 标了弃用（不作安全用途），本单测照用
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#include <CommonCrypto/CommonDigest.h>
#include "nvn_obj.h"
#include "t_nvn2_codec_av1.inc"

static unsigned checks;
#define CHECK(c) do { checks++; if (!(c)) { fprintf(stderr, "t_nvn2_codec:%d 失败：%s\n", __LINE__, #c); exit(1); } } while (0)

// ---------- 替身：原生层 / 直连层其余部分 / 游戏 SDK ----------
int g_s2a_logfd = 2, g_s2a_confd = -1;
int s2a_platform_ounce(void) { return 1; }
// nvn2.c 的 nn::vi 部分要它（本单测不用）
int dm_opmode(void) { return 0; }
uint64_t now_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec; }
void s2a_core_block_begin(void) {}
void s2a_core_block_end(void) {}
uint8_t *s2a_far_g2h(uint64_t a) { (void)a; return NULL; }
void dm_guest_write_prepare(void *addr, size_t len) { (void)addr; (void)len; }
static _Atomic uint64_t g_ser;
uint64_t nvn_new_serial(void) { return ++g_ser; }
static int g_tex_inits, g_pool_adds, g_pool_dels, g_alias_drops;
static const void *g_alias_drop_last;
void nvn_be_tex_init(const tex_t *t) { (void)t; g_tex_inits++; }
void nvn_be_pool_add(const void *mem, uint64_t size) { (void)mem; (void)size; g_pool_adds++; }
void nvn_be_pool_del(const void *mem) { (void)mem; g_pool_dels++; }
void nvn_be_alias_drop_pool(const void *pool) { g_alias_drop_last = pool; g_alias_drops++; }
// 原生事件：事件号 = 下标 + 1；读端句柄 = 0x100 + 下标
static struct { _Atomic int sig; int refs; } g_ev[256]; static int g_nev;
uint64_t s2a_event_create(uint32_t *hr, uint32_t *hw) { int i = g_nev++; g_ev[i].refs = 2; *hr = 0x100 + (uint32_t)i; if (hw) *hw = 0; return (uint64_t)i + 1; }
// 读档自中止复现钩子（11-06 时之笛）：对 g_hook_ev 的下一次触发，先让 g_hook_fn 在另一条线程上跑、最多等它 300 ms，再真正置位。
//   旧实现在锁外触发，另一条线程这时能完成「取消 + 重新请求」，迟到的触发落在新请求上；修好后触发在锁内，另一条线程要等它
static _Atomic uint64_t g_hook_ev; static void *(*g_hook_fn)(void *); static _Atomic int g_hook_done, g_hook_fired;
void s2a_event_signal(uint64_t ev) {
    if (ev && atomic_load(&g_hook_ev) == ev && atomic_exchange(&g_hook_ev, 0) == ev) {
        pthread_t th; CHECK(!pthread_create(&th, NULL, g_hook_fn, NULL)); pthread_detach(th);
        for (int t = 0; t < 300 && !atomic_load(&g_hook_done); t++) usleep(1000);
        atomic_store(&g_ev[ev - 1].sig, 1); atomic_store(&g_hook_fired, 1); return;
    }
    atomic_store(&g_ev[ev - 1].sig, 1);
}
void s2a_event_clear(uint64_t ev) { atomic_store(&g_ev[ev - 1].sig, 0); }
void s2a_event_release(uint64_t ev) { g_ev[ev - 1].refs--; }
static _Atomic unsigned g_gen = 1;   // 会话代号替身（runtime/src/session.c）：进程内重启 = 加一
unsigned s2a_session_generation(void) { return atomic_load(&g_gen); }
// 游戏 SDK 的 nn::os：SystemEventType 里只记读端句柄（替身自己的约定）；自动清除的事件 TryWait 后清掉
typedef struct { uint32_t handle, mode, destroyed; } fake_sev;
static int g_holders, g_destroys;
static void g_attach(void *sev, uint32_t h, int managed, int mode) { fake_sev *s = sev; s->handle = h; s->mode = (uint32_t)mode; s->destroyed = 0; CHECK(managed == 1); }
static void *g_sp_sev;
static void g_holder(void *holder, void *sev) { (void)holder; CHECK(((fake_sev *)sev)->handle >= 0x100); g_sp_sev = sev; g_holders++; }
static void g_destroy(void *sev) { ((fake_sev *)sev)->destroyed = 1; g_destroys++; }
static int g_trywait(void *sev) { fake_sev *s = sev; int i = (int)s->handle - 0x100; int v = atomic_load(&g_ev[i].sig); if (v && s->mode == 1) atomic_store(&g_ev[i].sig, 0); return v; }
// 游戏 sdk 的软件 Opus 解码器替身（硬件 Opus 接管换成它）：状态里记采样率 / 声道 / 工作缓冲；「解码」按包第一个字节填满一帧 960 个样本，
//   第一个字节 0xEE 的包回失败（期望接管层出静音）；Finalize / Reset 计次。工作缓冲大小 = 0x100 + 声道 × 0x40（与真 sdk 无关，只核接管层原样转交）
typedef struct { int rate, ch, streams, stereo, inited; void *work; uint64_t wsize; } fake_opus;
static int g_opus_fini, g_opus_reset, g_opus_dec_calls;
static uint64_t fo_wsize(int rate, int ch) { (void)rate; return 0x100 + (uint64_t)ch * 0x40; }
static uint32_t fo_init(void *s, int rate, int ch, void *buf, uint64_t size) {
    if (ch < 1 || ch > 2) return 0x3a6f;
    fake_opus *o = s; CHECK(buf && size == fo_wsize(rate, ch)); o->rate = rate; o->ch = ch; o->work = buf; o->wsize = size; o->inited = 1; return 0;
}
static uint32_t fo_decode(void *s, uint64_t *used, int *samples, int16_t *out, uint64_t out_size, const void *in, uint64_t n) {
    fake_opus *o = s; const uint8_t *p = in; g_opus_dec_calls++;
    CHECK(o->inited && n >= 8);
    uint32_t len = (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];   // 任天堂 8 字节头：大端包长、终止区间
    CHECK(len + 8 == n);
    if (p[8] == 0xEE) return 0x3a6f;
    CHECK(out_size >= 960u * (uint64_t)o->ch * 2);
    for (int i = 0; i < 960 * o->ch; i++) out[i] = (int16_t)p[8];
    *used = n; *samples = 960; return 0;
}
static void fo_fini(void *s) { ((fake_opus *)s)->inited = 0; g_opus_fini++; }
static void fo_reset(void *s) { (void)s; g_opus_reset++; }
static int fo_rate(const void *s) { return ((const fake_opus *)s)->rate; }
static int fo_ch(const void *s) { return ((const fake_opus *)s)->ch; }
static uint64_t fo_ms_wsize(int rate, int ch, int streams, int stereo) { (void)rate; return 0x200 + (uint64_t)(ch + streams + stereo) * 0x10; }
static uint32_t fo_ms_init(void *s, int rate, int ch, int streams, int stereo, const uint8_t *map, void *buf, uint64_t size) {
    fake_opus *o = s; CHECK(map && buf && size == fo_ms_wsize(rate, ch, streams, stereo)); o->rate = rate; o->ch = ch; o->streams = streams; o->stereo = stereo; o->inited = 1; return 0;
}
static int fo_ms_total(const void *s) { return ((const fake_opus *)s)->streams; }
static int fo_ms_stereo(const void *s) { return ((const fake_opus *)s)->stereo; }
static void *opus_fake(const char *n) {
    static const struct { const char *n; void *f; } t[] = {
        { "_ZN2nn5codec28GetOpusDecoderWorkBufferSizeEii", (void *)fo_wsize },
        { "_ZN2nn5codec21InitializeOpusDecoderEPNS0_15OpusDecoderTypeEiiPvm", (void *)fo_init },
        { "_ZN2nn5codec21DecodeOpusInterleavedEPNS0_15OpusDecoderTypeEPmPiPsmPKvm", (void *)fo_decode },
        { "_ZN2nn5codec19FinalizeOpusDecoderEPNS0_15OpusDecoderTypeE", (void *)fo_fini },
        { "_ZN2nn5codec16ResetOpusDecoderEPNS0_15OpusDecoderTypeE", (void *)fo_reset },
        { "_ZN2nn5codec24GetOpusDecoderSampleRateEPKNS0_15OpusDecoderTypeE", (void *)fo_rate },
        { "_ZN2nn5codec26GetOpusDecoderChannelCountEPKNS0_15OpusDecoderTypeE", (void *)fo_ch },
        { "_ZN2nn5codec39GetOpusMultiStreamDecoderWorkBufferSizeEiiii", (void *)fo_ms_wsize },
        { "_ZN2nn5codec32InitializeOpusMultiStreamDecoderEPNS0_26OpusMultiStreamDecoderTypeEiiiiPKhPvm", (void *)fo_ms_init },
        { "_ZN2nn5codec30FinalizeOpusMultiStreamDecoderEPNS0_26OpusMultiStreamDecoderTypeE", (void *)fo_fini },
        { "_ZN2nn5codec35GetOpusMultiStreamDecoderSampleRateEPKNS0_26OpusMultiStreamDecoderTypeE", (void *)fo_rate },
        { "_ZN2nn5codec37GetOpusMultiStreamDecoderChannelCountEPKNS0_26OpusMultiStreamDecoderTypeE", (void *)fo_ch },
        { "_ZN2nn5codec41GetOpusMultiStreamDecoderTotalStreamCountEPKNS0_26OpusMultiStreamDecoderTypeE", (void *)fo_ms_total },
        { "_ZN2nn5codec42GetOpusMultiStreamDecoderStereoStreamCountEPKNS0_26OpusMultiStreamDecoderTypeE", (void *)fo_ms_stereo },
        { "_ZN2nn5codec27ResetOpusMultiStreamDecoderEPNS0_26OpusMultiStreamDecoderTypeE", (void *)fo_reset },
        { "_ZN2nn5codec32DecodeOpusMultiStreamInterleavedEPNS0_26OpusMultiStreamDecoderTypeEPmPiPsmPKvm", (void *)fo_decode },
    };
    for (unsigned i = 0; i < sizeof t / sizeof *t; i++) if (!strcmp(n, t[i].n)) return t[i].f;
    return NULL;
}
void *guest_sym(const char *n) {
    { void *o = opus_fake(n); if (o) return o; }
    if (strstr(n, "AttachReadableHandleToSystemEvent")) return (void *)g_attach;
    if (strstr(n, "InitializeMultiWaitHolder")) return (void *)g_holder;
    if (strstr(n, "DestroySystemEvent")) return (void *)g_destroy;
    if (strstr(n, "TryWaitSystemEvent")) return (void *)g_trywait;
    return NULL;
}

void *s2a_codec_entry(const char *name);
size_t nvn2_av1c_from_tu(const uint8_t *tu, size_t n, uint8_t *out, size_t cap);
void *s2a_av1_open(int threads);
int s2a_av1_decode(void *h, const uint8_t *data, uint32_t len, uint8_t **planes, int32_t *strides, int32_t *info);
void s2a_av1_close(void *h);
// 4:2:0 三平面按 ffmpeg framemd5 的字节序（行连续，Y 后 U 后 V；>8 位为 16 位小端）算 MD5，十六进制
static void md5_420(uint8_t **pl, const int32_t *st, int w, int h, int bps, char out[33]) {
    CC_MD5_CTX x; CC_MD5_Init(&x);
    for (int p = 0; p < 3; p++) { int pw = p ? (w + 1) / 2 : w, ph = p ? (h + 1) / 2 : h; for (int r = 0; r < ph; r++) CC_MD5_Update(&x, pl[p] + (size_t)r * st[p], (CC_LONG)(pw * bps)); }
    uint8_t md[16]; CC_MD5_Final(md, &x); for (int i = 0; i < 16; i++) snprintf(out + 2 * i, 3, "%02x", md[i]);
}
static void *E(const char *n) { void *f = s2a_codec_entry(n); if (!f) { fprintf(stderr, "t_nvn2_codec：入口没有 %s\n", n); exit(1); } return f; }

typedef uint32_t Result;
typedef struct { uint32_t id_inv, mode; uint64_t value; } sync_h;
typedef Result (*f_psize)(uint64_t *, uint64_t *, const uint32_t *, uint32_t);
typedef Result (*f_pinit)(void *, void *, uint64_t, const uint32_t *, uint32_t);
typedef void (*f_pfini)(void *);
typedef uint32_t (*f_phandle)(const void *, uint32_t);
typedef Result (*f_init_tm)(void *, void *, uint64_t, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t, uint64_t, uint64_t);
typedef Result (*f_t)(void *);
typedef void (*f_v)(void *);
typedef void *(*f_ev)(void *);
typedef Result (*f_reg)(void *, uint32_t, void *, uint32_t);
typedef Result (*f_sub)(uint64_t *, void *, const void *, uint64_t, int64_t, uint32_t);
typedef Result (*f_acq)(uint32_t *, sync_h *, void *);
typedef void (*f_rel)(void *, uint32_t, uint64_t, uint64_t);
typedef Result (*f_props)(uint16_t *, uint16_t *, uint16_t *, uint16_t *, int64_t *, uint8_t *, void *, uint32_t);
typedef Result (*f_rgba)(const void *, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, void *, uint64_t, uint64_t);
typedef Result (*f_spc)(uint32_t *);
typedef void (*f_spv)(uint32_t *);
typedef void (*f_spr)(uint32_t *, const sync_h *);
typedef void (*f_sph)(void *, uint32_t *);
typedef int (*f_gstw)(const sync_h *);

struct codec { const char *init, *fini, *reg, *start, *ready, *sub, *acq, *rel, *props; };
#define CODEC(C, L) { "_ZN2nn5codec" L "Initialize" C "DecoderByTransferMemoryEPNS0_14" C "DecoderTypeEPvmmttjNS0_23VideoDecoderInputFormatENS0_24VideoDecoderOutputFormatENS0_22VideoDecoderOutputModeE", \
    "_ZN2nn5codec18Finalize" C "DecoderEPNS0_14" C "DecoderTypeE", "_ZN2nn5codec24Register" C "DecoderBufferEPNS0_14" C "DecoderTypeEjPNS0_25VideoDecoderImagePoolTypeEj", \
    "_ZN2nn5codec15Start" C "DecoderEPNS0_14" C "DecoderTypeE", "_ZN2nn5codec33Get" C "DecoderSubmissionReadyEventEPNS0_14" C "DecoderTypeE", \
    "_ZN2nn5codec27Submit" C "DecoderInputBufferEPmPNS0_14" C "DecoderTypeEPKvmNS_8TimeSpanEb", "_ZN2nn5codec29Acquire" C "DecoderOutputBufferEPjPNS_2gs16NativeSyncHandleEPNS0_14" C "DecoderTypeE", \
    "_ZN2nn5codec29Release" C "DecoderOutputBufferEPNS0_14" C "DecoderTypeEjNS_2gs16NativeSyncHandleE", "_ZN2nn5codec35Get" C "DecoderOutputBufferPropertiesEPtS1_S1_S1_PNS_8TimeSpanEPbPNS0_14" C "DecoderTypeEj" }
static const struct codec VP9 = CODEC("Vp9", "36"), AV1 = CODEC("Av1", "36");
static const struct codec H264 = { "_ZN2nn5codec37InitializeH264DecoderByTransferMemoryEPNS0_15H264DecoderTypeEPvmmttjNS0_23VideoDecoderInputFormatENS0_24VideoDecoderOutputFormatENS0_22VideoDecoderOutputModeEPKvm",
    "_ZN2nn5codec19FinalizeH264DecoderEPNS0_15H264DecoderTypeE", "_ZN2nn5codec25RegisterH264DecoderBufferEPNS0_15H264DecoderTypeEjPNS0_25VideoDecoderImagePoolTypeEj",
    "_ZN2nn5codec16StartH264DecoderEPNS0_15H264DecoderTypeE", "_ZN2nn5codec34GetH264DecoderSubmissionReadyEventEPNS0_15H264DecoderTypeE",
    "_ZN2nn5codec28SubmitH264DecoderInputBufferEPmPNS0_15H264DecoderTypeEPKvmNS_8TimeSpanEb", "_ZN2nn5codec30AcquireH264DecoderOutputBufferEPjPNS_2gs16NativeSyncHandleEPNS0_15H264DecoderTypeE",
    "_ZN2nn5codec30ReleaseH264DecoderOutputBufferEPNS0_15H264DecoderTypeEjNS_2gs16NativeSyncHandleE", "_ZN2nn5codec36GetH264DecoderOutputBufferPropertiesEPtS1_S1_S1_PNS_8TimeSpanEPbPNS0_15H264DecoderTypeEj" };
#define POOL_SIZE "_ZN2nn5codec31CalculateDecoderImagePoolBufferEPmS1_RKNS0_27VideoDecoderImagePreferenceEj"
#define POOL_INIT "_ZN2nn5codec26InitializeDecoderImagePoolEPNS0_25VideoDecoderImagePoolTypeEPvmRKNS0_27VideoDecoderImagePreferenceEj"
#define POOL_FINI "_ZN2nn5codec24FinalizeDecoderImagePoolEPNS0_25VideoDecoderImagePoolTypeE"
#define POOL_HANDLE "_ZN2nn5codec36GetDecoderImagePoolNativeImageHandleEPKNS0_25VideoDecoderImagePoolTypeEj"
#define READ_RGBA "_ZN2nn5codec26ReadDecoderOutputImageRgbaEPKNS0_25VideoDecoderImagePoolTypeEjttttPvmm"
#define SP_CREATE "_ZN2nn6syncpt3sdk20CreateSyncPointEventEPNS1_18SyncPointEventTypeE"
#define SP_DESTROY "_ZN2nn6syncpt3sdk21DestroySyncPointEventEPNS1_18SyncPointEventTypeE"
#define SP_REQUEST "_ZN2nn6syncpt3sdk21RequestSyncPointEventEPNS1_18SyncPointEventTypeERKNS1_15SyncPointHandleE"
#define SP_HOLDER "_ZN2nn6syncpt3sdk25InitializeMultiWaitHolderEPNS_2os19MultiWaitHolderTypeEPNS1_18SyncPointEventTypeE"
#define GS_TRYWAIT "_ZN2nn2gs17TryWaitNativeSyncERKNS0_16NativeSyncHandleE"

static const uint8_t red_vp9_0[] = {0x82, 0x49, 0x83, 0x42, 0x00, 0x03, 0xf0, 0x03, 0xf6, 0x00, 0x38, 0x24, 0x1c, 0x18, 0x00, 0x00, 0x00, 0x20, 0x00, 0x00, 0x78, 0xb9, 0xff, 0xff, 0xfc, 0x8d, 0x78, 0x03, 0x1f, 0xff, 0xff, 0xfe, 0xcf, 0xc8, 0x70, 0xff, 0xff, 0xff, 0xf6, 0xc8, 0xc0, 0x33, 0x35, 0x88, 0x48, 0x00};
static const uint8_t red_vp9_1[] = {0x86, 0x00, 0x40, 0x92, 0x9c, 0x00, 0x40, 0x00, 0x00, 0x02, 0x00, 0x00, 0x54, 0x70};
static const uint8_t red_av1_0[] = {0x12, 0x00, 0x0a, 0x0b, 0x02, 0x00, 0x00, 0x05, 0x55, 0x7f, 0xfc, 0x6a, 0xf9, 0x80, 0x40, 0x32, 0x17, 0x10, 0x00, 0x88, 0x82, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80, 0x00, 0x04, 0x90, 0x1c, 0xa6, 0x3c, 0xff, 0x00, 0x57, 0x0b, 0x7f, 0x53, 0x48};
static const uint8_t red_av1_1[] = {0x12, 0x00, 0x32, 0x11, 0x30, 0x02, 0x00, 0x00, 0x00, 0x00, 0x7a, 0x50, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x9c, 0x50};
static const uint8_t av1c_want[] = {0x81, 0x00, 0x0c, 0x00, 0x0a, 0x0b, 0x02, 0x00, 0x00, 0x05, 0x55, 0x7f, 0xfc, 0x6a, 0xf9, 0x80, 0x40};

// 一个解码器 + 2 张图像（各一个池，同火纹 subsdk2+0xf7a8 每池 1 张），偏好 = 图块模式 2、输出格式 2（布局码 5，RGBA）
typedef struct { _Alignas(16) uint8_t obj[0x400]; _Alignas(16) uint8_t pool[2][0x20]; uint8_t *mem[2]; uint64_t size; } rig;
static void rig_up(rig *r, const struct codec *c, uint32_t w, uint32_t h) {
    memset(r, 0, sizeof *r);
    uint32_t pref[16] = {0, 5, (w - 1) | (h - 1) << 16};
    uint64_t align = 0;
    CHECK(((f_psize)E(POOL_SIZE))(&r->size, &align, pref, 1) == 0 && align >= 0x1000 && r->size >= (uint64_t)w * h * 4);
    for (int i = 0; i < 2; i++) {
        CHECK(!posix_memalign((void **)&r->mem[i], (size_t)align, (size_t)r->size)); memset(r->mem[i], 0xcd, (size_t)r->size);
        CHECK(((f_pinit)E(POOL_INIT))(r->pool[i], r->mem[i], r->size, pref, 1) == 0);
    }
    CHECK(((f_init_tm)E(c->init))(r->obj, NULL, 0, 0, w, h, 0, 0, 2, 0) == 0);
    for (uint32_t i = 0; i < 2; i++) CHECK(((f_reg)E(c->reg))(r->obj, i, r->pool[i], 0) == 0);
    CHECK(((f_reg)E(c->reg))(r->obj, 0, r->pool[0], 0) != 0);
    CHECK(((f_t)E(c->start))(r->obj) == 0);
    CHECK(((f_ev)E(c->ready))(r->obj) == r->obj + 8);
}
static void rig_down(rig *r, const struct codec *c) {
    int d0 = g_destroys;
    ((f_t)E(c->fini))(r->obj);
    CHECK(g_destroys == d0 + 1 && ((fake_sev *)(r->obj + 8))->destroyed);
    for (int i = 0; i < 2; i++) { ((f_pfini)E(POOL_FINI))(r->pool[i]); free(r->mem[i]); }
}
// 取一个缓冲并等它的帧：同 subsdk2——Acquire 拿序号与句柄，同步点事件 Request 这个句柄，等事件触发
static uint32_t take(rig *r, const struct codec *c, uint32_t *spev, sync_h *hout) {
    uint32_t idx = 99; sync_h h;
    CHECK(((f_acq)E(c->acq))(&idx, &h, r->obj) == 0 && idx < 2 && h.mode == 1);
    ((f_spr)E(SP_REQUEST))(spev, &h);
    // 槽的 SystemEventType 由 InitializeMultiWaitHolder 交给替身（g_sp_sev）；手动清除，TryWait 不清
    for (int t = 0; t < 2000 && !g_trywait(g_sp_sev); t++) usleep(1000);
    CHECK(g_trywait(g_sp_sev) && ((f_gstw)E(GS_TRYWAIT))(&h));
    *hout = h;
    return idx;
}
static void px(rig *r, uint32_t img, uint8_t out[4]) { CHECK(((f_rgba)E(READ_RGBA))(r->pool[img], 0, 3, 5, 1, 1, out, 4, 4) == 0); }

// 读档自中止竞态的「Flush 一侧」（同 movie 库 subsdk0+0x36e0 → 0x45d0 → 0x4670）：环头 h1 达到就弹出，Cancel + Request 下一帧 h2
static uint32_t *g_race_spev; static sync_h g_race_h1, g_race_h2; static int g_race_saw_h1;
static void *race_flush_side(void *unused) {
    (void)unused;
    g_race_saw_h1 = ((f_gstw)E(GS_TRYWAIT))(&g_race_h1);
    ((f_spv)E("_ZN2nn6syncpt3sdk20CancelSyncPointEventEPNS1_18SyncPointEventTypeE"))(g_race_spev);
    ((f_spr)E(SP_REQUEST))(g_race_spev, &g_race_h2);
    atomic_store(&g_hook_done, 1);
    return NULL;
}
void *s2a_nv_entry(const char *name);
void *nvn2_vi_entry(const char *name);
void *nvn2_red(const char *name, const char *why);
const char *nvn2_red_of(const void *f);
int nvn2_gs_booted(void);
// 红桩 / 中止路径：子进程里调，期望非正常退出
static int dies1(void *f, uintptr_t a0, uintptr_t a1) { fflush(stdout); fflush(stderr); pid_t p = fork(); if (!p) { ((void (*)(uintptr_t, uintptr_t))f)(a0, a1); _exit(0); } int st = 0; waitpid(p, &st, 0); return !(WIFEXITED(st) && WEXITSTATUS(st) == 0); }
// 覆盖率统计（03_SDK接管层_报告）：--cover <名字表>，逐个按装载器同一次序问入口（runtime/src/gfxmode.c：nn::vi 先问显示层、再 nv、再视频解码），
//   每行出「名字<TAB>H|R|-」：H 宿主实现、R 红桩（宿主做不到，调用即中止点名）、- 回 NULL 照原路径。SetLayerCrop 由 host_adapt.m 接（本单测不链），记 H
static int cover(const char *path) {
    FILE *f = fopen(path, "r"); if (!f) { perror(path); return 2; }
    char line[1024];
    while (fgets(line, sizeof line, f)) {
        line[strcspn(line, "\r\n")] = 0; if (!line[0]) continue;
        void *fn = NULL;
        if (!strcmp(line, "_ZN2nn2vi12SetLayerCropEPNS0_5LayerEiiii")) { printf("%s\tH\n", line); continue; }
        if (!strncmp(line, "_ZN2nn2vi", 9) || !strncmp(line, "_ZNK2nn2vi", 10)) fn = nvn2_vi_entry(line);
        if (!fn && (!strncmp(line, "_Z", 2) || !strncmp(line, "Nv", 2))) { fn = s2a_nv_entry(line); if (!fn) fn = s2a_codec_entry(line); }
        printf("%s\t%s\n", line, !fn ? "-" : nvn2_red_of(fn) ? "R" : "H");
    }
    fclose(f); return 0;
}
int main(int argc, char **argv) {
    if (argc == 3 && !strcmp(argv[1], "--cover")) return cover(argv[2]);
    // ---------- av1C ----------
    uint8_t c[256];
    CHECK(nvn2_av1c_from_tu(red_av1_0, sizeof red_av1_0, c, sizeof c) == sizeof av1c_want && !memcmp(c, av1c_want, sizeof av1c_want));
    CHECK(nvn2_av1c_from_tu(red_av1_1, sizeof red_av1_1, c, sizeof c) == 0);
    if (argc == 3) {
        FILE *f = fopen(argv[1], "rb"), *g = fopen(argv[2], "rb"); CHECK(f && g);
        static uint8_t tu[1 << 22], want[512]; size_t n = fread(tu, 1, sizeof tu, f), wn = fread(want, 1, sizeof want, g); fclose(f); fclose(g);
        size_t got = nvn2_av1c_from_tu(tu, n, c, sizeof c);
        printf("真片子 av1C：%zu 字节（期望 %zu）%s\n", got, wn, got == wn && !memcmp(c, want, wn) ? "一致" : "不一致");
        CHECK(got == wn && !memcmp(c, want, wn));
    }

    // ---------- 入口：接管的名字有、偏好与音频照走 SDK ----------
    CHECK(s2a_codec_entry("_ZN2nn5codec5video10InitializeEv") && ((Result (*)(void))s2a_codec_entry("_ZN2nn5codec5video10InitializeEv"))() == 0);
    CHECK(!s2a_codec_entry("_ZN2nn5codec25MakeDecodeImagePreferenceEttNS0_24VideoDecoderOutputFormatENS0_15ImageTilingModeE"));
    CHECK(!s2a_codec_entry("_ZN2nn5codec21InitializeOpusDecoderEPNS0_15OpusDecoderTypeEiiPvm"));
    // nn::vi::GetDisplayVsyncEvent（金刚 / raiders，11-04）：nvn2.c 的 vi 表弱引用到本文件实现；挂到游戏 SystemEvent（托管、自动清除），宿主线程按 60 Hz 触发
    {
        void *nvn2_vi_entry(const char *name);
        uint32_t (*vs)(void *, void *) = (uint32_t (*)(void *, void *))nvn2_vi_entry("_ZN2nn2vi20GetDisplayVsyncEventEPNS_2os15SystemEventTypeEPNS0_7DisplayE");
        static fake_sev vsev; int e0 = g_nev;
        CHECK(vs && vs(&vsev, NULL) == 0 && vsev.handle == 0x100u + (uint32_t)e0 && vsev.mode == 1);
        atomic_store(&g_ev[e0].sig, 0);
        struct timespec ts = {0, 100000000}; nanosleep(&ts, NULL);
        CHECK(atomic_load(&g_ev[e0].sig) == 1);   // 100 ms 内至少被触发过一次
        // 审计 P1-80：线程随会话走。期望手写：起后活着 1 条；会话代号加一（进程内重启）后 100 ms 内退出（活着 0 条）、放掉自己那份事件引用（2 → 1），
        //   之后不再触发（清掉标志再等 100 ms 仍是 0）。旧实现线程永不退出：活着仍 1 条、引用仍 2、标志又被置 1
        int nvn2_vi_vsync_live(void);
        CHECK(nvn2_vi_vsync_live() == 1);
        atomic_fetch_add(&g_gen, 1); nanosleep(&ts, NULL);
        printf("vsync 线程：会话结束后活着 %d 条（期望 0）、事件引用 %d（期望 1）\n", nvn2_vi_vsync_live(), g_ev[e0].refs);
        CHECK(nvn2_vi_vsync_live() == 0 && g_ev[e0].refs == 1);
        atomic_store(&g_ev[e0].sig, 0); nanosleep(&ts, NULL); CHECK(atomic_load(&g_ev[e0].sig) == 0);
    }
    // SDK 20（金刚）的旧版初始化名字：与 SDK 22 新版（带输出模式）接到同一个实现（名字照游戏导入表原样抄，期望不跑被测实现就能写出）
    {
        static const char *pairs[][2] = {
            {"_ZN2nn5codec20InitializeVp9DecoderEPNS0_14Vp9DecoderTypeEPvmmttjNS0_23VideoDecoderInputFormatENS0_24VideoDecoderOutputFormatE",
             "_ZN2nn5codec36InitializeVp9DecoderByTransferMemoryEPNS0_14Vp9DecoderTypeEPvmmttjNS0_23VideoDecoderInputFormatENS0_24VideoDecoderOutputFormatENS0_22VideoDecoderOutputModeE"},
            {"_ZN2nn5codec20InitializeVp9DecoderEPNS0_14Vp9DecoderTypeEmttjNS0_23VideoDecoderInputFormatENS0_24VideoDecoderOutputFormatE",
             "_ZN2nn5codec34InitializeVp9DecoderByRemoteMemoryEPNS0_14Vp9DecoderTypeEmttjNS0_23VideoDecoderInputFormatENS0_24VideoDecoderOutputFormatENS0_22VideoDecoderOutputModeE"},
            {"_ZN2nn5codec20InitializeVp8DecoderEPNS0_14Vp8DecoderTypeEPvmmttjNS0_23VideoDecoderInputFormatENS0_24VideoDecoderOutputFormatE",
             "_ZN2nn5codec36InitializeVp8DecoderByTransferMemoryEPNS0_14Vp8DecoderTypeEPvmmttjNS0_23VideoDecoderInputFormatENS0_24VideoDecoderOutputFormatENS0_22VideoDecoderOutputModeE"},
            {"_ZN2nn5codec20InitializeAv1DecoderEPNS0_14Av1DecoderTypeEmttjNS0_23VideoDecoderInputFormatENS0_24VideoDecoderOutputFormatE",
             "_ZN2nn5codec34InitializeAv1DecoderByRemoteMemoryEPNS0_14Av1DecoderTypeEmttjNS0_23VideoDecoderInputFormatENS0_24VideoDecoderOutputFormatENS0_22VideoDecoderOutputModeE"},
            {"_ZN2nn5codec21InitializeH264DecoderEPNS0_15H264DecoderTypeEPvmmttjNS0_23VideoDecoderInputFormatENS0_24VideoDecoderOutputFormatEPKvm",
             "_ZN2nn5codec37InitializeH264DecoderByTransferMemoryEPNS0_15H264DecoderTypeEPvmmttjNS0_23VideoDecoderInputFormatENS0_24VideoDecoderOutputFormatENS0_22VideoDecoderOutputModeEPKvm"},
            {"_ZN2nn5codec21InitializeH264DecoderEPNS0_15H264DecoderTypeEmttjNS0_23VideoDecoderInputFormatENS0_24VideoDecoderOutputFormatEPKvm",
             "_ZN2nn5codec35InitializeH264DecoderByRemoteMemoryEPNS0_15H264DecoderTypeEmttjNS0_23VideoDecoderInputFormatENS0_24VideoDecoderOutputFormatENS0_22VideoDecoderOutputModeEPKvm"},
            {"_ZN2nn5codec26InitializeDecoderImagePoolEPNS0_25VideoDecoderImagePoolTypeEPvmRKNS0_27VideoDecoderImagePreferenceEjNS0_9CodecModeE",
             "_ZN2nn5codec26InitializeDecoderImagePoolEPNS0_25VideoDecoderImagePoolTypeEPvmRKNS0_27VideoDecoderImagePreferenceEj"},
        };
        for (unsigned i = 0; i < sizeof pairs / sizeof *pairs; i++) { void *o = s2a_codec_entry(pairs[i][0]); CHECK(o && o == s2a_codec_entry(pairs[i][1])); }
        // 旧版可提交事件：出参写回对象 +8（新版返回值同一处）；工作缓冲大小 4 KB / 4 KB 对齐
        _Alignas(16) uint8_t obj[64]; void *ev = NULL;
        Result (*ro)(void **, void *) = (Result (*)(void **, void *))s2a_codec_entry("_ZN2nn5codec33GetVp9DecoderSubmissionReadyEventEPPNS_2os15SystemEventTypeEPNS0_14Vp9DecoderTypeE");
        CHECK(ro && ro(&ev, obj) == 0 && ev == obj + 8);
        CHECK(s2a_codec_entry("_ZN2nn5codec34GetH264DecoderSubmissionReadyEventEPPNS_2os15SystemEventTypeEPNS0_15H264DecoderTypeE") == (void *)ro);
        uint64_t wsz = 0, wal = 0; Result (*ws)(uint64_t *, uint64_t *, uint64_t, uint32_t, uint32_t) = (Result (*)(uint64_t *, uint64_t *, uint64_t, uint32_t, uint32_t))s2a_codec_entry("_ZN2nn5codec29CalculateAv1DecoderWorkBufferEPmS1_mtt");
        CHECK(ws && ws(&wsz, &wal, 0, 1920, 1080) == 0 && wsz == 0x1000 && wal == 0x1000);
        CHECK(s2a_codec_entry("_ZN2nn5codec30CalculateH264DecoderWorkBufferEPmS1_mtt") == (void *)ws && s2a_codec_entry("_ZN2nn5codec29CalculateVp8DecoderWorkBufferEPmS1_mtt") == (void *)ws);
    }
    CHECK(!s2a_codec_entry("_ZN5movie10VideoFrame20GetNativeImageHandleEPN2nn2gs17NativeImageHandleE"));

    // ---------- 同步句柄比较 ----------
    f_gstw tw = (f_gstw)E(GS_TRYWAIT);
    sync_h zero = {0, 0, 0}, alien = {~77u, 1, 5};
    CHECK(tw(&zero) && tw(&alien));

    // ---------- 同步点事件 ----------
    uint32_t spev = 0; int h0 = g_holders; uint8_t holder[0x40];
    CHECK(((f_spc)E(SP_CREATE))(&spev) == 0);
    ((f_sph)E(SP_HOLDER))(holder, &spev); CHECK(g_holders == h0 + 1);

    // ---------- VP9（libvpx，无损）：两帧红，按登记次序填 ----------
    {
        rig r; rig_up(&r, &VP9, 64, 64);
        uint64_t id = 0;
        CHECK(((f_sub)E(VP9.sub))(&id, r.obj, red_vp9_0, sizeof red_vp9_0, 33333000, 0) == 0 && id == 1);
        CHECK(((f_sub)E(VP9.sub))(&id, r.obj, red_vp9_1, sizeof red_vp9_1, 66666999, 0) == 0 && id == 2);
        sync_h h1, h2; uint32_t i1 = take(&r, &VP9, &spev, &h1), i2 = take(&r, &VP9, &spev, &h2);
        CHECK(i1 == 0 && i2 == 1 && h2.value == h1.value + 1 && h1.id_inv == h2.id_inv);
        uint16_t w, h, w2, h2_; int64_t pts; uint8_t eos;
        CHECK(((f_props)E(VP9.props))(&w, &h, &w2, &h2_, &pts, &eos, r.obj, i1) == 0 && w == 64 && h == 64 && w2 == 64 && h2_ == 64 && pts == 33333000 && !eos);
        CHECK(((f_props)E(VP9.props))(&w, &h, &w2, &h2_, &pts, &eos, r.obj, i2) == 0 && pts == 66666000 && !eos);
        uint8_t p[4];
        for (uint32_t k = 0; k < 2; k++) { px(&r, k, p); printf("VP9 第 %u 帧像素 (%u,%u,%u,%u)\n", k, p[0], p[1], p[2], p[3]); CHECK(p[0] >= 253 && p[1] <= 1 && p[2] <= 1 && p[3] == 255); }
        // 释放后再出一帧（流结束：上一帧再给一次带标记）：句柄接着往后
        ((f_rel)E(VP9.rel))(r.obj, i1, 0, 0);
        CHECK(((f_sub)E(VP9.sub))(&id, r.obj, NULL, 0, 100000000, 1) == 0);
        sync_h h3; uint32_t i3 = take(&r, &VP9, &spev, &h3);
        CHECK(i3 == i1 && h3.value == h2.value + 1);
        CHECK(((f_props)E(VP9.props))(&w, &h, &w2, &h2_, &pts, &eos, r.obj, i3) == 0 && eos == 1 && w == 64);
        rig_down(&r, &VP9);
    }

    // ---------- 11-04 接口面全量：BGRA 读法（SDK 20）、退登记、宿主句柄的阻塞 / 限时等待（gs 与 syncpt 同一实现）----------
    //   期望：红帧 RGBA (254,0,0,255)（上面手算）按 B G R A 存 → (0,0,254,255)；退登记的缓冲不再被 Acquire 给出（环空回 0x1c286f「还没有」），再退回失败，重登记后又给出；
    //   宿主计数器未到的句柄限时 10 ms 等不到（0）、已达到的立即 1
    {
        rig r; rig_up(&r, &VP9, 64, 64);
        uint64_t id = 0;
        CHECK(((f_sub)E(VP9.sub))(&id, r.obj, red_vp9_0, sizeof red_vp9_0, 0, 0) == 0);
        sync_h h1; uint32_t i1 = take(&r, &VP9, &spev, &h1);
        uint8_t bg[4] = {9, 9, 9, 9};
        CHECK(((f_rgba)E("_ZN2nn5codec26ReadDecoderOutputImageBgraEPKNS0_25VideoDecoderImagePoolTypeEjttttPvmm"))(r.pool[i1], 0, 3, 5, 1, 1, bg, 4, 4) == 0);
        printf("BGRA 读法像素 (%u,%u,%u,%u)\n", bg[0], bg[1], bg[2], bg[3]);
        CHECK(bg[0] <= 1 && bg[1] <= 1 && bg[2] >= 253 && bg[3] == 255);
        Result (*unreg)(void *, uint32_t) = (Result (*)(void *, uint32_t))E("_ZN2nn5codec26UnregisterVp9DecoderBufferEPNS0_14Vp9DecoderTypeEj");
        CHECK(E("_ZN2nn5codec27UnregisterH264DecoderBufferEPNS0_15H264DecoderTypeEj") == (void *)unreg && E("_ZN2nn5codec26UnregisterAv1DecoderBufferEPNS0_14Av1DecoderTypeEj") == (void *)unreg);
        uint32_t other = 1 - i1, idx = 99; sync_h hx;
        CHECK(unreg(r.obj, other) == 0 && ((f_acq)E(VP9.acq))(&idx, &hx, r.obj) == 0x1c286f && unreg(r.obj, other) != 0);
        CHECK(((f_reg)E(VP9.reg))(r.obj, other, r.pool[other], 0) == 0 && ((f_acq)E(VP9.acq))(&idx, &hx, r.obj) == 0 && idx == other);
        int (*tw2)(const sync_h *, int64_t) = (int (*)(const sync_h *, int64_t))E("_ZN2nn2gs19TimedWaitNativeSyncERKNS0_16NativeSyncHandleENS_8TimeSpanE");
        CHECK(E("_ZN2nn6syncpt3sdk18TimedWaitSyncPointERKNS1_15SyncPointHandleENS_8TimeSpanE") == (void *)tw2 && E("_ZN2nn6syncpt3sdk16TryWaitSyncPointERKNS1_15SyncPointHandleE") == E(GS_TRYWAIT)
              && E("_ZN2nn2gs14WaitNativeSyncERKNS0_16NativeSyncHandleE") == E("_ZN2nn6syncpt3sdk13WaitSyncPointERKNS1_15SyncPointHandleE"));
        sync_h far = {h1.id_inv, 1, h1.value + 100};
        uint64_t t0 = now_ns(); int got = tw2(&far, 10000000); uint64_t dt = now_ns() - t0;
        CHECK(!got && dt >= 9000000 && tw2(&h1, 0) == 1);
        ((void (*)(const sync_h *))E("_ZN2nn2gs14WaitNativeSyncERKNS0_16NativeSyncHandleE"))(&h1);   // 已达到：立即返回
        rig_down(&r, &VP9);
    }
    // ---------- 读档自中止（11-06 时之笛 Switch 2：subsdk0 movie 库 0x4480 取帧 TryWait 未达到 → AbortImpl，sdk+0x1a5560 Break）----------
    //   movie 的事件管理器线程只在同步点事件触发后取环头帧，环头的同步句柄必须已达到，否则中止。游戏 Flush 时另一条线程直接取环头
    //   （TryWaitNativeSync 达到就弹出，再 Cancel + Request 下一帧的句柄）。期望：解码线程「达到 h1」的触发与这次取消 + 请求 h2 无论怎么交错，
    //   事件只要是触发态，h2 就必须已达到（h2 的帧还没提交，绝不会达到 → 事件必须是清掉的）
    {
        rig r; rig_up(&r, &VP9, 64, 64);
        uint32_t i1 = 99, i2 = 99; sync_h h1, h2;
        CHECK(((f_acq)E(VP9.acq))(&i1, &h1, r.obj) == 0 && ((f_acq)E(VP9.acq))(&i2, &h2, r.obj) == 0 && h2.value == h1.value + 1);
        g_hook_fn = race_flush_side; g_race_spev = &spev; g_race_h1 = h1; g_race_h2 = h2;
        ((f_spr)E(SP_REQUEST))(&spev, &h1);
        uint64_t sev = (uint64_t)(((fake_sev *)g_sp_sev)->handle - 0x100) + 1;
        CHECK(atomic_load(&g_ev[sev - 1].sig) == 0);
        atomic_store(&g_hook_done, 0); atomic_store(&g_hook_fired, 0); atomic_store(&g_hook_ev, sev);
        uint64_t id = 0;
        CHECK(((f_sub)E(VP9.sub))(&id, r.obj, red_vp9_0, sizeof red_vp9_0, 0, 0) == 0);
        for (int t = 0; t < 3000 && !(atomic_load(&g_hook_fired) && atomic_load(&g_hook_done)); t++) usleep(1000);
        CHECK(atomic_load(&g_hook_fired) && atomic_load(&g_hook_done) && g_race_saw_h1);
        int sig = atomic_load(&g_ev[sev - 1].sig), h2_ok = ((f_gstw)E(GS_TRYWAIT))(&h2);
        printf("读档自中止竞态：解码线程触发与取消 + 请求下一帧交错后，事件 %s、下一帧句柄 %s（期望：事件清着、句柄未达到）\n", sig ? "触发着" : "清着", h2_ok ? "已达到" : "未达到");
        CHECK(!sig || h2_ok);
        ((f_spv)E("_ZN2nn6syncpt3sdk20CancelSyncPointEventEPNS1_18SyncPointEventTypeE"))(&spev);
        rig_down(&r, &VP9);
    }
    // ---------- nn::gs 启动 / 检查 / 分配器（与 nv:: 同一份状态）：没启动时 Check 照 sdk 语义中止，BootGraphicsSystem 后放行 ----------
    {
        void *chk = E("_ZN2nn2gs3sdk30CheckGraphicsSystemInitializedEPKcm");
        CHECK(!nvn2_gs_booted() && dies1(chk, (uintptr_t)"t", 1));
        static uint8_t gpool[256];
        CHECK(((Result (*)(void *, uint64_t))E("_ZN2nn2gs3sdk18BootGraphicsSystemEPvm"))(gpool, sizeof gpool) == 0 && nvn2_gs_booted() && !dies1(chk, (uintptr_t)"t", 1));
        int A, F, R, U; void *a = 0, *f = 0, *rr = 0;
        ((void (*)(void *, void *, void *, void *))E("_ZN2nn2gs3sdk27InitializeGraphicsAllocatorEPFPvmmS2_EPFvS2_S2_EPFS2_S2_mS2_ES2_"))(&A, &F, &R, &U);
        ((void (*)(void **, void **, void **))E("_ZN2nn2gs3sdk20GetGraphicsAllocatorEPPFPvmmS2_EPPFvS2_S2_EPPFS2_S2_mS2_E"))(&a, &f, &rr);
        void *na = 0, *nf = 0, *nr = 0, *nu = 0;
        ((void (*)(void **, void **, void **, void **))s2a_nv_entry("_ZN2nv20GetGraphicsAllocatorEPPFPvmmS0_EPPFvS0_S0_EPPFS0_S0_mS0_EPS0_"))(&na, &nf, &nr, &nu);
        CHECK(a == &A && f == &F && rr == &R && na == &A && nu == &U);
        ((void (*)(void))E("_ZN2nn2gs8FinalizeEv"))(); CHECK(!nvn2_gs_booted());
    }
    // ---------- 族内宿主做不到的：红桩（装载打红行，调用即中止点名）；族内纯函数 / 数据符号 / 族外：照原路径 ----------
    {
        // 红桩只给有实证的：gs 未启动模拟执行进了 gsv 会话（编码器图像池、别名池、gsv 视频服务会话）或经 syncpt 库表跳空（库表转发、NvRm 栅栏转同步句柄）
        static const char *const red[] = {
            "_ZN2nn5codec26InitializeEncoderImagePoolEPNS0_25VideoEncoderImagePoolTypeEPvmRKNS0_27VideoEncoderImagePreferenceEj",   // Pokopia subsdk0 导入
            "_ZN2nn5codec31InitializeDecoderAliasImagePoolEPNS0_25VideoDecoderImagePoolTypeENS_2gs17NativeImageHandleEj",
            "_ZN2nn6syncpt3sdk19MakeSyncPointHandleENS1_13SyncCounterIdEmNS1_13SyncValueModeE",
            "_ZN2nn6syncpt3sdk21CreateDebugSyncDeviceEPNS1_19DebugSyncDeviceTypeE",
            "_ZN2nn2gs8external32GetNativeSyncHandleFromNvRmFenceERKNS1_12NvRmFenceRecE",   // Pokopia subsdk0 导入
            "_ZN2nn5codec5video6detail17ShimLibraryGlobal10InitializeEv",
        };
        static const char *const why[] = { "编码", "别名", "库表", "调试", "NvRm", "gsv" };
        for (unsigned i = 0; i < sizeof red / sizeof *red; i++) { void *f = s2a_codec_entry(red[i]); CHECK(f && nvn2_red_of(f) && strstr(nvn2_red_of(f), why[i])); }
        // 族内没接、但没有原路径必中止实证的：照原路径（H.264 编码器初始化 / 加密输入 / 原生窗口 / nvnSync 由原生同步句柄初始化）
        CHECK(!s2a_codec_entry("_ZN2nn5codec21InitializeH264EncoderEPmPNS0_15H264EncoderTypeEPvmttiNS_5movie11BitRateModeENS4_12EncoderLevelENS0_23VideoEncoderInputFormatE")
              && !s2a_codec_entry("_ZN2nn5codec36SubmitEncryptedVp9DecoderInputBufferEPmPNS0_14Vp9DecoderTypeEPKNS0_18EncryptionPropertyEPKvmNS_8TimeSpanEb")
              && !s2a_codec_entry("_ZN2nn2gs3sdk19ConnectNativeWindowEPvPKcNS1_21NativeWindowAttributeE")
              && !s2a_codec_entry("_Z37nvnSyncInitializeFromNativeSyncHandleP7NVNsyncP9NVNdeviceN2nn2gs16NativeSyncHandleE"));
        CHECK(dies1(s2a_codec_entry(red[0]), 0, 0));
        static const char *const pass[] = {
            "_ZN2nn2gs3sdk17ReadUserImageRgbaEPvmmRKNS_3gsv7imgdesc4impl4user5ounce22CpuUserImageDescriptorEPKvtttt", "_ZN2nn2gs21EmptyNativeSyncHandleE",
            "_ZN2nn6syncpt3sdk39MakeSyncPointHandleFromNativeSyncHandleERKNS_2gs16NativeSyncHandleE", "_ZN2nn5codec25MakeEncodeImagePreferenceEtt",
            "_ZN2nn2gs35InstallIpcResultCheckForApplicationEv", "_ZN3nvn11NativeImageaSERKS0_", "_ZN2nn5codec4OpusEv" };
        for (unsigned i = 0; i < sizeof pass / sizeof *pass; i++) CHECK(!s2a_codec_entry(pass[i]));
        // NVN2 原生图像的 C++ 包装（this 在前）：与 C 版同一实现；InitializeTexture 参数次序反过来，单独一个
        CHECK(E("_ZN3nvn11NativeImage10InitializeEPKNS_18NativeImageBuilderE") == E("_Z24nvnNativeImageInitializeP14NVNnativeImagePK21NVNnativeImageBuilder"));
        CHECK(E("_ZNK3nvn18NativeImageBuilder9GetFormatEv") == E("_Z30nvnNativeImageBuilderGetFormatPK21NVNnativeImageBuilder"));
        void *it = E("_ZN3nvn11NativeImage17InitializeTextureEPNS_7TextureE"); CHECK(!nvn2_red_of(it) && it != E("_Z35nvnTextureInitializeFromNativeImageP10NVNtextureP14NVNnativeImage"));
    }

    // ---------- H.264 宿主没接：初始化回失败 ----------
    {
        _Alignas(16) uint8_t obj[0x400];
        CHECK(((f_init_tm)E(H264.init))(obj, NULL, 0, 0, 32, 16, 0, 0, 2, 0) != 0);
    }

    // ---------- dav1d 垫片：逐帧 MD5 对 ffmpeg（libdav1d）参考 ----------
    {
        static const char *const want8[6] = { "7c445a3a2221f0a538414ba5fd2f2c41", "c259b2a6a3fe2b087a65f5056fe8f933", "446a8cdca368be75186776b8d24a3382",
                                              "6952b325b88908a2c5791874e0b5bd6f", "89ed6182b091a0c67511110af40fea1f", "88025e2b2d8ababb79a6c030aa34ec3c" };
        static const char *const want10 = "d3f13f6f8df70f77a54df0f91ef79a41";
        void *h = s2a_av1_open(2); CHECK(h);
        int same = 0; char md[33];
        for (int i = 0; i < 6; i++) {
            uint8_t *pl[3]; int32_t st[3], info[6];
            CHECK(s2a_av1_decode(h, ts_av1[i], (uint32_t)ts_av1_n[i], pl, st, info) == 0 && info[0] == 96 && info[1] == 64 && info[2] == 8 && info[3] == 1);
            md5_420(pl, st, 96, 64, 1, md); same += !strcmp(md, want8[i]);
        }
        s2a_av1_close(h);
        printf("dav1d 8 位：6 帧里 MD5 对上 %d 帧\n", same); CHECK(same == 6);
        h = s2a_av1_open(1); CHECK(h); same = 0;
        for (int i = 0; i < 2; i++) {
            uint8_t *pl[3]; int32_t st[3], info[6];
            CHECK(s2a_av1_decode(h, red10_av1[i], (uint32_t)red10_av1_n[i], pl, st, info) == 0 && info[0] == 64 && info[2] == 10);
            md5_420(pl, st, 64, 64, 2, md); same += !strcmp(md, want10);
        }
        s2a_av1_close(h);
        printf("dav1d 10 位：2 帧里 MD5 对上 %d 帧\n", same); CHECK(same == 2);
        uint8_t junk[16] = {0x32, 0x0e, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14}; uint8_t *pl[3]; int32_t st[3], info[6];
        h = s2a_av1_open(1); CHECK(s2a_av1_decode(h, junk, sizeof junk, pl, st, info) != 0); s2a_av1_close(h);
    }

    // ---------- AV1 强制软解（S2A_AV1_SOFT=1）走整条接管路径：8 位、10 位红 ----------
    setenv("S2A_AV1_SOFT", "1", 1);
    {
        const uint8_t *const *fr[2] = { (const uint8_t *const[]){ red_av1_0, red_av1_1 }, red10_av1 };
        const size_t n8[2] = { sizeof red_av1_0, sizeof red_av1_1 };
        for (int pass = 0; pass < 2; pass++) {
            rig r; rig_up(&r, &AV1, 64, 64); uint64_t id;
            for (int i = 0; i < 2; i++) CHECK(((f_sub)E(AV1.sub))(&id, r.obj, fr[pass][i], pass ? red10_av1_n[i] : n8[i], (int64_t)i * 33333000, 0) == 0);
            sync_h a, b; take(&r, &AV1, &spev, &a); take(&r, &AV1, &spev, &b);
            uint8_t p[4];
            for (uint32_t k = 0; k < 2; k++) { px(&r, k, p); printf("AV1 软解 %d 位 第 %u 帧像素 (%u,%u,%u,%u)\n", pass ? 10 : 8, k, p[0], p[1], p[2], p[3]); CHECK(p[0] >= 251 && p[1] <= 3 && p[2] <= 3 && p[3] == 255); }
            rig_down(&r, &AV1);
        }
    }
    // 整条路径写出的 RGBA 逐像素对「同一帧的 YUV（经垫片另解一份）+ BT.601 视频范围公式（双精度）」，±1：核 NEON 与逐像素两段转换
    {
        void *h = s2a_av1_open(1); uint8_t *pl[3]; int32_t st[3], info[6];
        CHECK(s2a_av1_decode(h, ts_av1[0], (uint32_t)ts_av1_n[0], pl, st, info) == 0);
        rig r; rig_up(&r, &AV1, 96, 64); uint64_t id; sync_h a;
        CHECK(((f_sub)E(AV1.sub))(&id, r.obj, ts_av1[0], ts_av1_n[0], 0, 0) == 0);
        uint32_t idx = take(&r, &AV1, &spev, &a);
        static uint8_t got[96 * 64 * 4];
        CHECK(((f_rgba)E(READ_RGBA))(r.pool[idx], 0, 0, 0, 96, 64, got, 96 * 4, sizeof got) == 0);
        int bad = 0, maxd = 0;
        for (int y = 0; y < 64; y++) for (int x = 0; x < 96; x++) {
            double Y = (pl[0][y * st[0] + x] - 16) * 255.0 / 219.0, U = (pl[1][(y / 2) * st[1] + x / 2] - 128) * 255.0 / 224.0, V = (pl[2][(y / 2) * st[1] + x / 2] - 128) * 255.0 / 224.0;
            double want[3] = { Y + 1.402 * V, Y - 0.3441 * U - 0.7141 * V, Y + 1.772 * U };
            for (int c = 0; c < 3; c++) { int w = (int)(want[c] < 0 ? 0 : want[c] > 255 ? 255 : want[c] + 0.5), d = abs(w - got[(y * 96 + x) * 4 + c]); if (d > maxd) maxd = d; bad += d > 1; }
            bad += got[(y * 96 + x) * 4 + 3] != 255;
        }
        printf("AV1 软解整条路径 96x64：逐像素对公式最大差 %d、超 ±1 的 %d 个分量\n", maxd, bad); CHECK(bad == 0);
        s2a_av1_close(h); rig_down(&r, &AV1);
    }
    unsetenv("S2A_AV1_SOFT");

    // ---------- AV1（VideoToolbox 硬件解码；没有 AV1 硬件解码的机器上这段跳过并说明）----------
    if (VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)) {
        rig r; rig_up(&r, &AV1, 64, 64);
        uint64_t id;
        CHECK(((f_sub)E(AV1.sub))(&id, r.obj, red_av1_0, sizeof red_av1_0, 0, 0) == 0);
        CHECK(((f_sub)E(AV1.sub))(&id, r.obj, red_av1_1, sizeof red_av1_1, 33333000, 0) == 0);
        sync_h a, b; take(&r, &AV1, &spev, &a); take(&r, &AV1, &spev, &b);
        uint8_t p[4];
        for (uint32_t k = 0; k < 2; k++) { px(&r, k, p); printf("AV1 第 %u 帧像素 (%u,%u,%u,%u)\n", k, p[0], p[1], p[2], p[3]); CHECK(p[0] >= 230 && p[1] <= 25 && p[2] <= 25 && p[3] == 255); }
        rig_down(&r, &AV1);
    } else printf("AV1：本机没有 AV1 硬件解码（VTIsHardwareDecodeSupported = 否），跳过这段\n");

    // ---------- NVN2 原生图像 → 线性纹理（零拷贝在解码图像内存上）----------
    {
        _Alignas(16) uint8_t pool[0x20], b[0x100], ni[0x200], tx[0x80], *mem; uint64_t size, align;
        uint32_t pref[16] = {0, 5, (1280 - 1) | (720 - 1) << 16}, prefnv[16] = {0, 4, (64 - 1) | (64 - 1) << 16};
        CHECK(((f_psize)E(POOL_SIZE))(&size, &align, pref, 1) == 0);
        CHECK(!posix_memalign((void **)&mem, (size_t)align, (size_t)size));
        CHECK(((f_pinit)E(POOL_INIT))(pool, mem, size, pref, 1) == 0);
        uint32_t hd = ((f_phandle)E(POOL_HANDLE))(pool, 0);
        void (*setdev)(void *, void *) = E("_Z30nvnNativeImageBuilderSetDeviceP21NVNnativeImageBuilderP9NVNdevice");
        void (*setdef)(void *) = E("_Z32nvnNativeImageBuilderSetDefaultsP21NVNnativeImageBuilder");
        void (*seth)(void *, uint32_t) = E("_Z41nvnNativeImageBuilderSetNativeImageHandleP21NVNnativeImageBuilderN2nn2gs17NativeImageHandleE");
        void (*setf)(void *, int) = E("_Z30nvnNativeImageBuilderSetFormatP21NVNnativeImageBuilder9NVNformat");
        void *(*getdev)(const void *) = E("_Z30nvnNativeImageBuilderGetDevicePK21NVNnativeImageBuilder");
        int (*niinit)(void *, const void *) = E("_Z24nvnNativeImageInitializeP14NVNnativeImagePK21NVNnativeImageBuilder");
        int (*tinit)(void *, const void *) = E("_Z35nvnTextureInitializeFromNativeImageP10NVNtextureP14NVNnativeImage");
        void *dev = (void *)0x1234;
        setdev(b, dev); setdef(b); seth(b, hd); setf(b, 0x38);
        CHECK(getdev(b) == dev);
        CHECK(niinit(ni, b) == 1);
        int a0 = g_pool_adds, t0 = g_tex_inits;
        CHECK(tinit(tx, ni) == 1 && tinit(tx, ni) == 1);
        const tex_t *t = (const tex_t *)tx;
        // 行距 1280×4 = 5120（已是 256 的倍数）；线性、2D、存储就是解码图像的内存；同一个池只登记一次
        CHECK(t->d.flags == NVN_TEXTURE_FLAGS_LINEAR && t->d.target == NVN_TEXTURE_TARGET_2D && t->d.width == 1280 && t->d.height == 720 && t->d.stride == 5120 && t->d.format == 0x38);
        CHECK(t->mem == mem && t->pool && t->pool->mem == mem && t->off == 0 && t->serial);
        CHECK(g_pool_adds == a0 + 1 && g_tex_inits == t0 + 2);
        // 不是宿主发的句柄（马车世界 1.8.0 开机从摄像头 / GameChat 句柄 0 建三张纹理，失败就中止 main+0xd32438）：初始化成功，纹理是宿主的 16x16 空纹理；
        //   两张共用同一块全零池，池只登记一次；格式不是四字节一像素时换 RGBA8
        {
            _Alignas(16) uint8_t ni0[0x200], tx0[0x80], tx1[0x80];
            int a1 = g_pool_adds, t1 = g_tex_inits;
            seth(b, 0); CHECK(niinit(ni0, b) == 1);
            CHECK(tinit(tx0, ni0) == 1);
            const tex_t *e0 = (const tex_t *)tx0;
            CHECK(e0->d.width == 16 && e0->d.height == 16 && e0->d.flags == NVN_TEXTURE_FLAGS_LINEAR && e0->d.target == NVN_TEXTURE_TARGET_2D && e0->d.format == 0x38 && e0->d.stride == 256);
            CHECK(e0->mem && e0->pool && e0->pool->mem == e0->mem && e0->pool->size >= 256u * 16 && e0->serial);
            int zero = 1; for (int i = 0; i < 256 * 16; i++) zero &= !e0->mem[i];
            CHECK(zero);
            seth(b, 0xfff0); setf(b, 0x3); CHECK(niinit(ni0, b) == 1 && tinit(tx1, ni0) == 1);
            const tex_t *e1 = (const tex_t *)tx1;
            CHECK(e1->pool == e0->pool && e1->d.format == NVN_FORMAT_RGBA8 && e1->serial != e0->serial);
            CHECK(g_pool_adds == a1 + 1 && g_tex_inits == t1 + 2);
            setf(b, 0x38);
        }
        // NV12 图像不能按四字节格式建纹理
        _Alignas(16) uint8_t pool2[0x20], ni2[0x200]; uint8_t *mem2; uint64_t s2;
        CHECK(((f_psize)E(POOL_SIZE))(&s2, &align, prefnv, 1) == 0 && !posix_memalign((void **)&mem2, (size_t)align, (size_t)s2));
        CHECK(((f_pinit)E(POOL_INIT))(pool2, mem2, s2, prefnv, 1) == 0);
        seth(b, ((f_phandle)E(POOL_HANDLE))(pool2, 0)); CHECK(niinit(ni2, b) == 1 && tinit(tx, ni2) == 0);
        int d0 = g_pool_dels, dr0 = g_alias_drops;
        const void *nv0 = ((const tex_t *)tx)->pool;   // 建纹理时的 pool_t 地址
        ((f_pfini)E(POOL_FINI))(pool); CHECK(g_pool_dels == d0 + 1 && g_alias_drops == dr0 + 1 && g_alias_drop_last == nv0);
        ((f_pfini)E(POOL_FINI))(pool2); CHECK(g_pool_dels == d0 + 1);   // pool2 没建过 NVN 纹理，不登记、不调 alias_drop
        free(mem); free(mem2);
    }

    // ---------- 句柄复用：建池 → 建纹理 → 释放池 → 新池复用同句柄 → 纹理指向新内存 ----------
    // 复现花屏根因：释放池未清 g_alias，新池同 pool_t 地址命中旧 MTLTexture 条目
    {
        f_psize  psz  = (f_psize)E(POOL_SIZE);
        f_pinit  pini = (f_pinit)E(POOL_INIT);
        f_pfini  pfin = (f_pfini)E(POOL_FINI);
        f_phandle phd = (f_phandle)E(POOL_HANDLE);
        int (*niinit)(void *, const void *) = E("_Z24nvnNativeImageInitializeP14NVNnativeImagePK21NVNnativeImageBuilder");
        int (*tinit)(void *, const void *)  = E("_Z35nvnTextureInitializeFromNativeImageP10NVNtextureP14NVNnativeImage");
        void (*setdev)(void *, void *) = E("_Z30nvnNativeImageBuilderSetDeviceP21NVNnativeImageBuilderP9NVNdevice");
        void (*setdef)(void *)         = E("_Z32nvnNativeImageBuilderSetDefaultsP21NVNnativeImageBuilder");
        void (*seth)(void *, uint32_t) = E("_Z41nvnNativeImageBuilderSetNativeImageHandleP21NVNnativeImageBuilderN2nn2gs17NativeImageHandleE");
        void (*setf)(void *, int)      = E("_Z30nvnNativeImageBuilderSetFormatP21NVNnativeImageBuilder9NVNformat");
        uint32_t pref[16] = {0, 5, (64 - 1) | (64 - 1) << 16};
        uint64_t sz = 0, al = 0;
        CHECK(psz(&sz, &al, pref, 1) == 0);

        // 第一个池：建池 → 原生图像 → 建纹理 → 记下内存地址
        _Alignas(16) uint8_t poolA[0x20], bA[0x100], niA[0x200], txA[0x80]; uint8_t *memA;
        CHECK(!posix_memalign((void **)&memA, (size_t)al, (size_t)sz));
        CHECK(pini(poolA, memA, sz, pref, 1) == 0);
        setdev(bA, (void *)0x1); setdef(bA); seth(bA, phd(poolA, 0)); setf(bA, 0x38);
        CHECK(niinit(niA, bA) == 1 && tinit(txA, niA) == 1);
        const tex_t *tA = (const tex_t *)txA;
        const void *pool_t_a = tA->pool;   // pool_t 地址（g_cvp 槽内嵌）

        // 释放第一个池：alias_drop_pool 必须被调用，pool_t 地址相同
        int dr1 = g_alias_drops;
        pfin(poolA);
        CHECK(g_alias_drops == dr1 + 1 && g_alias_drop_last == pool_t_a);

        // 第二个池：分配不同内存，建同尺寸池；g_cvp 槽被复用 → pool_t 地址与 pool_t_a 相同
        _Alignas(16) uint8_t poolB[0x20], bB[0x100], niB[0x200], txB[0x80]; uint8_t *memB;
        CHECK(!posix_memalign((void **)&memB, (size_t)al, (size_t)sz));
        CHECK(memB != memA);   // 两块不同内存
        CHECK(pini(poolB, memB, sz, pref, 1) == 0);
        setdev(bB, (void *)0x1); setdef(bB); seth(bB, phd(poolB, 0)); setf(bB, 0x38);
        CHECK(niinit(niB, bB) == 1 && tinit(txB, niB) == 1);
        const tex_t *tB = (const tex_t *)txB;

        // 核心断言：新纹理的内存指针必须是新池的内存，不能是旧池的
        // 期望：tB->mem == memB；旧代码（漏 alias_drop_pool）下 g_alias 命中旧条目，tB->mem 仍为 memA → 花屏
        CHECK(tB->mem == memB && tB->mem != memA);
        CHECK(tB->pool && tB->pool->mem == memB);   // pool_t 的 mem 字段也已更新

        pfin(poolB); free(memA); free(memB);
    }

    // ---------- 硬件 Opus（11-10 Orbitals：GetHardwareOpusDecoderManagerWorkBufferSize 进 sdk hwacod，hwopus 命令 100 没有，对空会话调虚函数 SIGSEGV）----------
    {
        int nvn2_opus_live(void);
        #define OPN(x) "_ZN2nn5codec" x
        typedef uint64_t (*f_mws)(int, int, int64_t, int, int);
        typedef uint32_t (*f_minit)(void *, void *, int, int, int64_t, int, int, void *, uint64_t);
        typedef uint32_t (*f_dinit)(void *, int, int, int64_t, void *);
        typedef int (*f_cnt)(const void *);
        typedef uint32_t (*f_enq)(void *, uint64_t *, const void *, uint64_t);
        typedef uint32_t (*f_deq)(void *, int *, int16_t *, uint64_t);
        typedef uint32_t (*f_res)(void *);
        typedef void (*f_v)(void *);
        // 入口：Orbitals 导入的 34 个 Opus 名字里硬件那族全由宿主接（宿主实现、不是红桩）；软件解码器与多流管理器形态照原路径
        static const char *const hw[] = {
            OPN("43GetHardwareOpusDecoderManagerWorkBufferSizeEiiNS_8TimeSpanEii"),
            OPN("36InitializeHardwareOpusDecoderManagerEPNS0_30HardwareOpusDecoderManagerTypeEPNS_2os15SystemEventTypeEiiNS_8TimeSpanEiiPvm"),
            OPN("34FinalizeHardwareOpusDecoderManagerEPNS0_30HardwareOpusDecoderManagerTypeE"),
            OPN("46GetHardwareOpusDecoderManagerFreeIoBufferCountEPKNS0_30HardwareOpusDecoderManagerTypeE"),
            OPN("29InitializeHardwareOpusDecoderEPNS0_23HardwareOpusDecoderTypeEiiNS_8TimeSpanEPNS0_30HardwareOpusDecoderManagerTypeE"),
            OPN("29InitializeHardwareOpusDecoderEPNS0_23HardwareOpusDecoderTypeEiiPvmi"),
            OPN("36EnqueueOpusDataToHardwareOpusDecoderEPNS0_23HardwareOpusDecoderTypeEPmPKvm"),
            OPN("34ExecuteHardwareOpusDecoderDecodingEPNS0_30HardwareOpusDecoderManagerTypeE"),
            OPN("48DequeuePcmInterleavedDataFromHardwareOpusDecoderEPNS0_23HardwareOpusDecoderTypeEPiPsm"),
            OPN("47GetHardwareOpusDecoderWaitingDecodeRequestCountEPKNS0_23HardwareOpusDecoderTypeE"),
            OPN("49GetHardwareOpusDecoderExecutingDecodeRequestCountEPKNS0_23HardwareOpusDecoderTypeE"),
            OPN("49GetHardwareOpusDecoderCompletedDecodeRequestCountEPKNS0_23HardwareOpusDecoderTypeE"),
            OPN("27FinalizeHardwareOpusDecoderEPNS0_23HardwareOpusDecoderTypeE"),
            OPN("24ResetHardwareOpusDecoderEPNS0_23HardwareOpusDecoderTypeE"),
            OPN("32GetHardwareOpusDecoderSampleRateEPKNS0_23HardwareOpusDecoderTypeE"),
            OPN("34GetHardwareOpusDecoderChannelCountEPKNS0_23HardwareOpusDecoderTypeE"),
            OPN("33DecodeOpusInterleavedWithHardwareEPNS0_23HardwareOpusDecoderTypeEPmPiPsmPKvm"),
            OPN("36GetHardwareOpusDecoderWorkBufferSizeEiii"),
        };
        for (unsigned i = 0; i < sizeof hw / sizeof *hw; i++) { void *f = s2a_codec_entry(hw[i]); CHECK(f && !nvn2_red_of(f)); }
        CHECK(!s2a_codec_entry(OPN("28GetOpusDecoderWorkBufferSizeEii")) && !s2a_codec_entry(OPN("21DecodeOpusInterleavedEPNS0_15OpusDecoderTypeEPmPiPsmPKvm")));
        CHECK(!s2a_codec_entry(OPN("47InitializeHardwareOpusMultiStreamDecoderManagerEPNS0_39HardwareOpusMultiStreamDecoderManagerTypeEPNS_2os15SystemEventTypeEiiiiNS_8TimeSpanEiiPvm")));
        // 崩溃那一步：Orbitals main+0x6a46ea4 的参数（48 kHz、128 个解码器、255 个 I/O 缓冲）——宿主答，不进 sdk（替身 guest_sym 没有 hwacod 名字，进了就中止）
        CHECK(((f_mws)E(hw[0]))(48000, 1, 0x2d00, 0x80, 0xff) > 0);
        int live0 = nvn2_opus_live();

        // 老的 C 接口：工作缓冲按软件解码器给、原样转交；采样率 / 声道 / 解码 / Reset / Finalize 都到软件解码器
        {
            _Alignas(16) uint8_t gd[0x40] = {0}; uint64_t ws = ((uint64_t (*)(int, int, int))E(hw[17]))(48000, 2, 0);
            CHECK(ws == 0x100 + 2 * 0x40);
            void *work = malloc(ws);
            CHECK(((uint32_t (*)(void *, int, int, void *, uint64_t, int))E(hw[5]))(gd, 48000, 2, work, ws, 0) == 0);
            CHECK(((f_cnt)E(hw[14]))(gd) == 48000 && ((f_cnt)E(hw[15]))(gd) == 2 && nvn2_opus_live() == live0 + 1);
            uint8_t pkt[8 + 3] = {0, 0, 0, 3, 0, 0, 0, 0, 7, 1, 2}; static int16_t pcm[960 * 2]; uint64_t used = 0; int smp = 0;
            CHECK(((uint32_t (*)(void *, uint64_t *, int *, int16_t *, uint64_t, const void *, uint64_t))E(hw[16]))(gd, &used, &smp, pcm, sizeof pcm, pkt, sizeof pkt) == 0);
            CHECK(used == sizeof pkt && smp == 960 && pcm[0] == 7 && pcm[960 * 2 - 1] == 7);
            int r0 = g_opus_reset, f0 = g_opus_fini;
            ((f_v)E(hw[13]))(gd); CHECK(g_opus_reset == r0 + 1);
            ((f_v)E(hw[12]))(gd); CHECK(g_opus_fini == f0 + 1 && nvn2_opus_live() == live0);
            ((f_v)E(hw[12]))(gd); CHECK(g_opus_fini == f0 + 1);   // 二次 Finalize 不再放
            free(work);
        }

        // SDK 21 管理器：4 个 I/O 缓冲、2 个解码器（单声道 + 双声道）
        _Alignas(16) uint8_t gm[0x18] = {0}; _Alignas(16) uint8_t sev[0x40] = {0}; uint8_t mbuf[0x1000];
        int nev0 = g_nev;
        CHECK(((f_minit)E(hw[1]))(gm, sev, 48000, 2, 20000000, 2, 4, mbuf, sizeof mbuf) == 0);
        CHECK(*(void **)gm != NULL && g_nev == nev0 + 1 && ((fake_sev *)sev)->handle >= 0x100 && ((fake_sev *)sev)->mode == 1);   // 游戏凭第一个字认已初始化；事件挂上、自动清除
        CHECK(((f_cnt)E(hw[3]))(gm) == 4 && ((f_cnt)E(OPN("47GetHardwareOpusDecoderManagerTotalIoBufferCountEPKNS0_30HardwareOpusDecoderManagerTypeE")))(gm) == 4);
        typedef int (*f_val)(const void *, int, int, int64_t);
        f_val val = (f_val)E(OPN("49ValidateHardwareOpusDecoderManagerDecoderResourceEPKNS0_30HardwareOpusDecoderManagerTypeEiiNS_8TimeSpanE"));
        _Alignas(16) uint8_t da[0x30] = {0}, db[0x30] = {0};
        CHECK(val(gm, 48000, 1, 20000000) == 1);
        CHECK(((f_dinit)E(hw[4]))(da, 48000, 1, 20000000, gm) == 0 && ((f_dinit)E(hw[4]))(db, 48000, 2, 20000000, gm) == 0);
        CHECK(val(gm, 48000, 1, 20000000) == 0);   // 两个都用了
        _Alignas(16) uint8_t dc[0x30] = {0};
        CHECK(((f_dinit)E(hw[4]))(dc, 48000, 6, 20000000, gm) != 0);   // 软件解码器拒的声道数：初始化原样回失败，不登记
        CHECK(nvn2_opus_live() == live0 + 2);
        CHECK(((void *(*)(void *))E(OPN("29GetHardwareOpusDecoderManagerEPNS0_23HardwareOpusDecoderTypeE")))(da) == gm);
        CHECK(((int64_t (*)(const void *))E(OPN("35GetHardwareOpusDecoderFrameDurationEPKNS0_23HardwareOpusDecoderTypeE")))(db) == 20000000);
        CHECK(((f_cnt)E(hw[14]))(da) == 48000 && ((f_cnt)E(hw[15]))(db) == 2);   // 共用的采样率 / 声道数读管理器形态的解码器
        uint8_t p1[8 + 2] = {0, 0, 0, 2, 0, 0, 0, 0, 0x11, 0}, p2[8 + 2] = {0, 0, 0, 2, 0, 0, 0, 0, 0xEE, 0}, p3[8 + 2] = {0, 0, 0, 2, 0, 0, 0, 0, 0x22, 0};
        uint64_t used = 99;
        CHECK(((f_enq)E(hw[6]))(da, &used, p1, sizeof p1) == 0 && used == sizeof p1);
        CHECK(((f_enq)E(hw[6]))(da, &used, p2, sizeof p2) == 0);
        CHECK(((f_enq)E(hw[6]))(db, &used, p3, sizeof p3) == 0);
        CHECK(((f_enq)E(hw[6]))(db, &used, p1, 7) != 0 && used == 0);   // 不到 8 字节头：拒，不占缓冲
        CHECK(((f_cnt)E(hw[9]))(da) == 2 && ((f_cnt)E(hw[9]))(db) == 1 && ((f_cnt)E(hw[10]))(da) == 0 && ((f_cnt)E(hw[11]))(da) == 0 && ((f_cnt)E(hw[3]))(gm) == 1);
        CHECK(((f_enq)E(hw[6]))(db, &used, p3, sizeof p3) == 0 && ((f_cnt)E(hw[3]))(gm) == 0);
        CHECK(((f_enq)E(hw[6]))(db, &used, p3, sizeof p3) != 0);   // 没有空 I/O 缓冲
        CHECK(!g_trywait(sev));   // Execute 之前不触发
        int dc0 = g_opus_dec_calls;
        CHECK(((f_res)E(hw[7]))(gm) == 0);
        CHECK(g_opus_dec_calls == dc0 + 4 && g_trywait(sev) && !g_trywait(sev));   // 四个包都在 Execute 里解完；事件触发一次、自动清除
        CHECK(((f_cnt)E(hw[9]))(da) == 0 && ((f_cnt)E(hw[11]))(da) == 2 && ((f_cnt)E(hw[11]))(db) == 2 && ((f_cnt)E(hw[3]))(gm) == 0);
        static int16_t out[960 * 2]; int smp = 0;
        CHECK(((f_deq)E(hw[8]))(da, &smp, out, 100) != 0 && smp == 0 && ((f_cnt)E(hw[11]))(da) == 2);   // 缓冲太小：拒，帧留着
        CHECK(((f_deq)E(hw[8]))(da, &smp, out, sizeof out) == 0 && smp == 960 && out[0] == 0x11 && out[959] == 0x11);
        memset(out, 0x55, sizeof out);
        CHECK(((f_deq)E(hw[8]))(da, &smp, out, sizeof out) == 0 && smp == 960 && out[0] == 0 && out[959] == 0 && out[960] == 0x5555);   // 坏包 = 20 ms 静音，只写一帧单声道
        CHECK(((f_deq)E(hw[8]))(da, &smp, out, sizeof out) != 0);   // 取完了
        CHECK(((f_deq)E(hw[8]))(db, &smp, out, sizeof out) == 0 && smp == 960 && out[0] == 0x22 && out[960 * 2 - 1] == 0x22);
        CHECK(((f_cnt)E(hw[3]))(gm) == 3 && ((f_cnt)E(OPN("47GetHardwareOpusDecoderManagerUsingIoBufferCountEPKNS0_30HardwareOpusDecoderManagerTypeE")))(gm) == 1);
        // Reset（共用名）丢掉管理器形态解码器的请求、缓冲还池
        int r0 = g_opus_reset;
        ((f_v)E(hw[13]))(db); CHECK(g_opus_reset == r0 + 1 && ((f_cnt)E(hw[11]))(db) == 0 && ((f_cnt)E(hw[3]))(gm) == 4);
        // 管理器先结束：解码器之后的 Enqueue / Dequeue 回失败、计数回 0；事件引用放掉；Finalize（共用名）照常放解码器
        int refs0 = g_ev[g_nev - 1].refs;
        ((f_v)E(hw[2]))(gm);
        CHECK(*(void **)gm == NULL && g_ev[g_nev - 1].refs == refs0 - 1);
        CHECK(((f_enq)E(hw[6]))(da, &used, p1, sizeof p1) != 0 && ((f_deq)E(hw[8]))(da, &smp, out, sizeof out) != 0 && ((f_cnt)E(hw[9]))(da) == 0);
        int f0 = g_opus_fini;
        ((f_v)E(hw[12]))(da); ((f_v)E(hw[12]))(db);
        CHECK(g_opus_fini == f0 + 2 && nvn2_opus_live() == live0);
        ((f_v)E(hw[2]))(gm);   // 二次结束：第一个字已清，什么都不做
        #undef OPN
    }

    ((f_spv)E(SP_DESTROY))(&spev);
    printf("✓ t_nvn2_codec：%u 项检查全过\n", checks);
    return 0;
}
