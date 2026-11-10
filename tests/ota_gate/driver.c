// OTA 落点 × 导入闸门契约驱动（tests/ota_pack_test.py 编它）：按 ota.json 的 dest 摆好的 Documents/games/<号>，跑真 runtime/src/pack_apply.c 的
//   库判据（s2a_game_on_device）、闸门两轮（s2a_import_decide，隔 4 秒）、解包（s2a_pack_apply）、解后状态，逐行打 键=值 给 Python 核。
//   用法：driver <进程级 Documents> <游戏号> [apply]
#include "../../runtime/src/native.h"
#include <stdio.h>
int s2a_pack_apply(const char *docs); int s2a_import_state(const char *docs);
int s2a_game_on_device(const char *proc_docs, const char *gid); int s2a_import_state_game_quick(const char *proc_docs, const char *gid);
struct s2a_gate_watch { int n, moved; uint64_t fp; time_t changed; };   // 同 pack_apply.c
int s2a_import_decide(const char *docs, struct s2a_gate_watch *w, time_t now, char *why, size_t n);
uint64_t now_ns(void) { return 0; }
int main(int argc, char **argv) {
    if (argc < 3) return 2;
    char docs[2048], why[600]; snprintf(docs, sizeof docs, "%s/games/%s", argv[1], argv[2]);
    struct s2a_gate_watch w = {0};
    printf("on_device=%d\n", s2a_game_on_device(argv[1], argv[2]));
    int a0 = s2a_import_decide(docs, &w, 1000, why, sizeof why), a1 = s2a_import_decide(docs, &w, 1004, why, sizeof why);
    printf("gate=%d,%d\n", a0, a1);
    if (argc > 3) { printf("apply=%d\n", s2a_pack_apply(docs)); printf("state=%d\n", s2a_import_state(docs)); printf("quick=%d\n", s2a_import_state_game_quick(argv[1], argv[2])); }
    return 0;
}
