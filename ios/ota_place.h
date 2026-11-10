// OTA 资源包落点（ios/ota_place.m）：下载（ota_download.m）与随包资源包（包里 Games/<游戏号>/ota/，单款游戏 App）共用的「按 ota.json 把文件放进
//   Documents/games/<游戏号>/资源包」。只用 Foundation（不连 UIKit），Mac 上单测直接编（tests/ota_bundled_test.py）。
//   落点契约同推送（tools/push_pack.py 文件头、docs/OTA_DOWNLOAD.md）：tar → 资源包/.incoming/<名>.tar，直写镜像 → 资源包/<路径>（写前把 .applied 清空），
//   index.tsv、manifest.json 最后。每个文件先放到旁边的临时名、核过大小才改名到落点：闸门（runtime/src/pack_apply.c）永远看不到半截文件。
#import <Foundation/Foundation.h>

// ota.json 核对（格式 / 游戏号 / 安全相对路径 / tar 落点 / index.tsv、manifest.json 最后）：对返回 nil，不对返回原因（英文，进日志）
NSString *s2a_ota_check(NSDictionary *ota, NSString *gid);
// dest 是不是直写镜像（不是 tar、不是 index.tsv / manifest.json）：落第一个直写镜像前要清空 .applied
BOOL s2a_ota_is_direct(NSString *dest);
// 资源包/.applied 在就清空（同 push_pack.send：镜像写到一半时库里不能判成就绪）
void s2a_ota_clear_applied(NSString *pack_root);
// 文件 sha256（小写十六进制）；读不了返回 nil
NSString *s2a_ota_sha256(NSString *path);
// 把 src 放到 <pack_root>/<dest>：clone = YES 时 src 不动（clonefile → copyfile CLONE → 普通拷贝，先放 tmp_dir 里的临时名、核大小再改名）；
//   clone = NO 时直接改名过去（下载的 .part）。size ≥ 0 时核大小。成功返回 nil，失败返回原因；*cloned 回报这次是不是 APFS 克隆（可传 NULL）
NSString *s2a_ota_place_file(NSString *src, NSString *pack_root, NSString *dest, long long size, BOOL clone, NSString *tmp_dir, BOOL *cloned);

// ---- 随包资源包（单款游戏 App：包里 Games/<游戏号>/ota/ = tools/ota_pack.py export 的原样输出）----
// 包里这款有没有随包资源包（<bundle>/Games/<游戏号>/ota/ota.json 在）；有就返回 ota 目录，没有返回 nil
NSString *s2a_ota_bundled_dir(NSString *bundle_dir, NSString *gid);
// 进度回调（在调用线程上同步调）：已放字节 / 总字节、当前第 i 个（从 0 起）/ 共 n 个
typedef void (^s2a_ota_place_progress)(long long done, long long total, NSUInteger i, NSUInteger n);
// 把 ota_dir 里的资源包按 ota.json 放进 <game_docs>/资源包（game_docs = Documents/games/<游戏号>）：
//   开头先删落点上的 manifest.json（上次放到一半被杀时，它不能让库误判「已传完」）、按 clear_applied 清 .applied；
//   逐个文件：落点已是同样大小（≤ 64 MB 的再核 sha256）就跳过，否则克隆过去；≤ 64 MB 的放完核 sha256，大的只核大小（首启要快，
//   内容由解包后的 index.tsv 逐文件核对兜底）；index.tsv、manifest.json 最后。可重入：中途被杀，下次启动再调接着放。
//   free_bytes：克隆不成、要真拷时用来核剩余空间（返回 -1 = 读不到，照拷）。成功返回 nil，失败返回原因；*cloned_all 回报是不是全程克隆
NSString *s2a_ota_place_bundled(NSString *ota_dir, NSString *game_docs, NSString *gid, long long (^free_bytes)(void),
                                s2a_ota_place_progress progress, BOOL *cloned_all);
