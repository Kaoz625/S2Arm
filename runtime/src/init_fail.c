// 初启失败的出口：决策与诊断文本（契约与分支见 runtime/include/s2a_init_fail.h）。只用 libc，单测 runtime/tests/t_init_fail.c 直接链本文件。
#include "s2a_init_fail.h"
#include "s2a_ui_lang.h"   // 上屏话术英文默认（S2A_TR）
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

int s2a_init_fail_action(int is_ios, int unattended) {
    // 只有 iOS 上有人看着的局停在提示页；其余照旧失败退出（退出码 1）
    return is_ios && !unattended ? S2A_INIT_FAIL_PAGE : S2A_INIT_FAIL_EXIT;
}

int s2a_init_fail_service_code(const char *game_data) {
    char p[2048]; struct stat st;
    if (!game_data || !*game_data) return S2A_INIT_FAIL_E_SERVICE_INIT;
    snprintf(p, sizeof p, "%s/exefs/main.npdm", game_data);
    return stat(p, &st) || !S_ISREG(st.st_mode) ? S2A_INIT_FAIL_E_GAME_FILES : S2A_INIT_FAIL_E_SERVICE_INIT;
}

// 码表（头文件 S2A_INIT_FAIL_CODES 展开）：下标 = 错误码，0 = 码表外
static const struct { const char *id, *summary, *msg, *msg_en; } g_codes[S2A_INIT_FAIL_E_COUNT] = {   // msg_en：<话术宏>_EN（11-10 英文默认）
    [S2A_INIT_FAIL_E_UNKNOWN] = {"unknown", "未登记的初启失败", S2A_INIT_FAIL_MSG_GENERIC, S2A_INIT_FAIL_MSG_GENERIC_EN},
#define S2A_INIT_FAIL_ROW_(e, i, sum, m) [e] = {i, sum, m, m##_EN},
    S2A_INIT_FAIL_CODES(S2A_INIT_FAIL_ROW_)
#undef S2A_INIT_FAIL_ROW_
};
static int known(int code) { return code > S2A_INIT_FAIL_E_UNKNOWN && code < S2A_INIT_FAIL_E_COUNT ? code : S2A_INIT_FAIL_E_UNKNOWN; }
const char *s2a_init_fail_code_id(int code) { return g_codes[known(code)].id; }
const char *s2a_init_fail_summary(int code) { return g_codes[known(code)].summary; }

struct sbuf { char *p; size_t n, len; };
static void put(struct sbuf *b, const char *s, size_t k) {
    if (!b->n) return;
    size_t room = b->n - 1 - b->len; if (k > room) k = room;
    memcpy(b->p + b->len, s, k); b->len += k; b->p[b->len] = 0;
}
static void putf(struct sbuf *b, const char *fmt, ...) {
    char t[1024]; va_list ap; va_start(ap, fmt); int k = vsnprintf(t, sizeof t, fmt, ap); va_end(ap);
    if (k > 0) put(b, t, (size_t)k < sizeof t ? (size_t)k : sizeof t - 1);
}
static int has_red(const char *s, size_t k) {
    static const char red[] = "【红】"; size_t r = sizeof red - 1;
    for (size_t i = 0; i + r <= k; i++) if (!memcmp(s + i, red, r)) return 1;
    return 0;
}

// 提示页正文只取玩家话术：内部摘要不上屏（11-02 维护者）
size_t s2a_init_fail_screen(char *out, size_t n, int code) {
    struct sbuf b = {out, n, 0}; if (n) out[0] = 0;
    putf(&b, "%s\n%s", S2A_TR(g_codes[known(code)].msg_en, g_codes[known(code)].msg), S2A_TR(S2A_INIT_FAIL_NEXT_EN, S2A_INIT_FAIL_NEXT));
    return b.len;
}

size_t s2a_init_fail_diag(char *out, size_t n, int code, const char *build_id, const char *chain, const char *log, size_t len) {
    struct sbuf b = {out, n, 0}; if (n) out[0] = 0;
    putf(&b, "S2Arm 初启失败\n失败摘要：%s\n错误码：%s\n主程序构建号：%s\n翻译链：%s\n", s2a_init_fail_summary(code), s2a_init_fail_code_id(code),
         build_id && *build_id ? build_id : "-", chain && *chain ? chain : "-");
    // 最近 S2A_INIT_FAIL_RED_LINES 条红行：一遍扫出全部红行的起止，环形只留最后几条
    const char *ls[S2A_INIT_FAIL_RED_LINES]; size_t lk[S2A_INIT_FAIL_RED_LINES]; size_t cnt = 0;
    for (size_t i = 0; log && i < len;) {
        const char *e = memchr(log + i, '\n', len - i); size_t k = e ? (size_t)(e - (log + i)) : len - i;
        if (has_red(log + i, k)) { ls[cnt % S2A_INIT_FAIL_RED_LINES] = log + i; lk[cnt % S2A_INIT_FAIL_RED_LINES] = k; cnt++; }
        i += k + 1;
    }
    if (!cnt) { putf(&b, "最近的红行：无\n"); return b.len; }
    size_t keep = cnt < S2A_INIT_FAIL_RED_LINES ? cnt : S2A_INIT_FAIL_RED_LINES;
    putf(&b, "最近的红行（host.log，%zu 条）：\n", keep);
    for (size_t j = cnt - keep; j < cnt; j++) { put(&b, ls[j % S2A_INIT_FAIL_RED_LINES], lk[j % S2A_INIT_FAIL_RED_LINES]); put(&b, "\n", 1); }
    return b.len;
}

size_t s2a_init_fail_diag_file(char *out, size_t n, int code, const char *build_id, const char *chain, const char *path) {
    char *buf = NULL; size_t got = 0; int fd = path ? open(path, O_RDONLY) : -1; struct stat st;
    if (fd >= 0 && !fstat(fd, &st) && st.st_size > 0 && (buf = malloc(S2A_INIT_FAIL_LOG_TAIL))) {
        off_t from = st.st_size > S2A_INIT_FAIL_LOG_TAIL ? st.st_size - S2A_INIT_FAIL_LOG_TAIL : 0;
        ssize_t r = pread(fd, buf, S2A_INIT_FAIL_LOG_TAIL, from); got = r > 0 ? (size_t)r : 0;
        if (from > 0) {   // 从中间截开：第一行不完整，丢到第一个换行之后
            char *nl = memchr(buf, '\n', got); size_t skip = nl ? (size_t)(nl - buf) + 1 : got;
            memmove(buf, buf + skip, got - skip); got -= skip;
        }
    }
    if (fd >= 0) close(fd);
    size_t r = s2a_init_fail_diag(out, n, code, build_id, chain, buf, got);
    free(buf); return r;
}
