// OTA 资源包下载（ios/ota_download.m；无线装机：离家时从私有 HTTPS 地址下载一款游戏的资源包，不用数据线）。
//   服务端布局由 tools/ota_pack.py export 出（见 docs/OTA_DOWNLOAD.md）；下载只把文件按推送契约放进 Documents/games/<游戏号>/资源包
//   （tar → .incoming/，index.tsv、manifest.json 最后），解包仍由点 Play 后的导入闸门做（runtime/src/pack_apply.c），这里不解包。
//   以下函数都在主线程调。
#import <UIKit/UIKit.h>

// 游戏库界面出现时调：读缓存的下载目录、后台刷新一次；接上系统后台会话里还在跑的下载并显示进度
void s2a_ota_library_appeared(void);
// 缺资源包的提示框（app.m library_pack_help）：配置了下载目录且（目录里有这款 / 目录还没取到）时加一个「下载」按钮
void s2a_ota_add_download_action(UIAlertController *alert, NSString *gid);
// 开始 / 接着下载这一款（有没下完的同款任务就接着下）
void s2a_ota_start(NSString *gid);
// s2arm://download?catalog=<url>[&key=<值>][&game=<游戏号>]：记下目录地址（与可选的 X-Blazing-Key），取目录；
//   带 game 直接下这款，不带就列出目录里本机还没有的款让玩家选。认得这个地址返回 YES
BOOL s2a_ota_open_url(NSURL *url);
// App 代理 application:handleEventsForBackgroundURLSession:completionHandler: 转过来（系统在后台下完一段后唤醒 App）
BOOL s2a_ota_background_events(NSString *identifier, void (^completion)(void));
// app.m 实现：让游戏库重判各款资源包（下载完后刷新「需要游戏数据」→ 可开始）
void s2a_ota_library_refresh(void);
