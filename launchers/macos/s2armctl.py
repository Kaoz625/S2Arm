#!/usr/bin/env python3
# S2Arm Mac 前端的控制客户端（用户体验线 10-23）：前端照常开窗口给人看，脚本 / AI 经本机控制口操作它（见 ControlServer.swift）。
# 玩家用法：S2Arm「设置 → 允许 AI 操作 S2Arm」打开后，AI 运行 /Applications/S2Arm.app/Contents/Resources/s2armctl（App 自带 Python，不用另装）。
#   流程、排查与底线见 App 里的操作手册 skill/s2arm-operator/SKILL.md（仓库 launchers/macos/skill/s2arm-operator/SKILL.md）。
# 用法：
#   s2armctl help                                本工具和 App 接口能做什么
#   s2armctl start [App 路径]                    App 没开就打开它，等控制口就绪（已开着就直接用）
#   s2armctl state [--full|--json]               当前界面状态（缺省摘要；--json 给程序读）
#   s2armctl targets                             打 iPhone 包的目标设备：当前目标、连着的设备、可选机型和系统
#   s2armctl errors [游戏号]                     最近失败任务的错误码、原因、恢复建议、日志位置和日志末尾
#   s2armctl diag [export [输出.zip]] | diag pull   导出 Mac 诊断包（不给路径就放桌面）/ 拉回 iPhone 诊断
#   s2armctl snapshot <输出.png> [--app]      主窗口截图：缺省系统截图（与屏幕一致，要屏幕录制权限），不行或 --app 时 App 自绘
#   s2armctl keys <prod.keys>                 导入密钥（等同拖进来）
#   s2armctl fonts <目录|"">                  原版字体目录（空串 = 清掉）
#   s2armctl games <路径>...                  添加游戏（引导页上就走引导页的入口）
#   s2armctl prepare|ipa|launch <游戏号>      编译（Mac）/ 打 iPhone 包 / 启动
#   s2armctl target probe | target <机型号> <系统大版本>   重新检测连接的设备 / 选打 iPhone 包的目标机型（state 里 iphoneTarget 是当前目标）
#   s2armctl cancel|retry <任务号>
#   s2armctl select <页面> [游戏号]           切侧栏页（library / tasks / settings …）
#   s2armctl onboarding open|finish|defer|step <n>
#   s2armctl env | refresh | dismiss          环境检查 / 刷新游戏库 / 关掉提示
#   s2armctl wait <游戏号> [--op build] [--timeout 秒]   等该游戏的任务结束，逐条打里程碑和进度，结尾打每个里程碑的耗时；失败退出 1
# 公共参数：--data-root <目录>（与 App 的 --data-root 一致；缺省 ~/Library/Application Support/S2Arm，Windows 是 %LOCALAPPDATA%\S2Arm\WindowsLauncher）
# Windows（11-08 启动器线）：协议和命令同一份，启动器自带 s2armctl.cmd；Windows 只出 iPhone / iPad 包，Mac 专属命令由启动器回 409。
import argparse
import glob, json, os, subprocess, sys, time, urllib.request, urllib.error

USAGE = """s2armctl —— 让 AI 助手操作 S2Arm（每条命令 = 玩家点了对应按钮，屏幕上看得到）

  help                              本说明 + App 接口表
  start                             连上 S2Arm（没开就打开）；打印连上的是哪个数据目录
  state [--json]                    当前状态：环境、密钥、游戏（游戏号 / 能否编译 / 缺什么）、任务进度；--json 给程序读
  keys <prod.keys>                  放密钥，等导入完成再返回
  games <文件或文件夹>...            放游戏（本体、更新、DLC 放一个文件夹传文件夹即可；多个更新自动用最新版本），等导入完成再返回
  prepare <游戏号>                   Mac 编译（排队）
  ipa <游戏号> [--space-override]    打 iPhone 包（出 IPA + 资源包）；--space-override 同界面「仍然继续」，磁盘预检不够也照出（先征得玩家同意）
  build <游戏号> [ios|mac|android|harmony] [--space-override]   出包，按目标：ios = iPhone / iPad（缺省）、mac = Mac；安卓、鸿蒙即将上线
  install-check <游戏号> [--json]    装到 iPhone 前的清单：iPhone 版做好没有、Xcode 登录 Apple ID、连上、信任、开发者模式；没好的写谁做什么
  customize <游戏号> [--name 名字] [--cover 图片] [--reset-name] [--reset-cover]   改显示名 / 封面（JPG、PNG），下次装到 iPhone 时带上
  delete <游戏号>                    删除这款游戏（IPA / 资源包 / 中间产物 / 缓存；存档与原始游戏文件保留），等删完再返回
  wait <游戏号> [--op build|ipa] [--timeout 秒]
                                    等该游戏的任务结束：build = Mac 编译（缺省），ipa = iPhone 包；逐段打印进度，失败退出码 1
  targets [--models|--json]         打 iPhone 包的目标设备：当前目标、连着的设备（含设备名）、可选系统；--models 列可选机型
  target probe | target <机型号> <系统大版本>   重新检测连着的设备 / 没连时选机型
  update [restart|retry]            新版后台下载的状态；restart = 重启并换上已下载好的新版，retry = 重试下载（出包中不能重启）
  library <目录> [--move]            换游戏库位置（外接盘也行）；--move 把现有游戏、成品、缓存和存档一起搬到这个空文件夹
  display <游戏号> [--fps60 on|off] [--widen on|off] [--metalfx on|off]   看 / 改这款的画面设置，下次启动生效
  errors [游戏号]                    最近失败任务的错误码、原因、建议、日志位置和日志末尾
  retry <任务号> | cancel <任务号>    重试 / 取消任务
  launch <游戏号>                    在 Mac 上启动游戏
  diag [export [输出.zip]] | diag pull  导出 Mac 诊断包（不给路径就放桌面）/ 拉回 iPhone 诊断
  snapshot <输出.png>                截主窗口
  env | refresh | dismiss           重新检查环境 / 刷新游戏库 / 关掉提示框
  fonts <目录|"">                    换成原版字体（空串 = 用应用自带）
  next [游戏号] [--target mac|ios] [--json]   AI 代操作入口（缺省 ios）：现在走到哪一步、下一步做什么、由谁做（ai 自己做 / ask 问玩家要输入 /
                                    human 只能玩家本人做 / confirm 先征得玩家同意）、为什么；出错时带错误码、原因和处理办法
  logs <任务号|游戏号> [--lines N]    读这条任务（或这款游戏最近一条任务）的日志末尾（缺省 40 行）
  install <游戏号> [--team 团队号] [--device UDID或设备名]   装到 iPhone（签名 + 装 App + 推资源包）；连着多台时用 --device 指定（同网配对的也行）
  device <游戏号>                    iPhone 连没连、这款游戏的 App 装没装（装机要玩家用 AltStore 登录 Apple ID，AI 不代做）
  push-pack <游戏号>                 App 装好后把资源包拷进 iPhone（同在访达里把「资源包」文件夹拖到 App 上），拷完逐文件核对

公共参数：--data-root <目录>：S2Arm 数据目录不是缺省位置时，每条命令都要带（玩家复制给你的说明里会写）
"""

WINDOWS = os.name == 'nt'

def root():
    if '--data-root' in sys.argv:
        i = sys.argv.index('--data-root'); r = sys.argv[i + 1]; del sys.argv[i:i + 2]; return r, True
    if WINDOWS: return os.path.join(os.environ.get('LOCALAPPDATA') or os.path.expanduser('~'), 'S2Arm', 'WindowsLauncher'), False
    return os.path.expanduser('~/Library/Application Support/S2Arm'), False
ROOT, CUSTOM_ROOT = root()

def info():
    p = os.path.join(ROOT, 'control.json')
    try: return json.load(open(p))
    except Exception: sys.exit(f'连不上 S2Arm：{p} 不存在。请玩家在 S2Arm 的「设置 → 让 AI 帮你操作」打开「允许 AI 操作 S2Arm」，或运行 s2armctl start')

LOCAL = urllib.request.build_opener(urllib.request.ProxyHandler({}))   # 只连本机：系统代理（Windows 上常开）不能接管 127.0.0.1

def call(method, path, body=None, raw=False, timeout=30, soft=False):
    # soft=True：超时 / 连不上返回 None，不退出（wait 用：控制口不应答时改按作业记录判，10-26 Spare-host 内存吃紧启动器失联、作业照跑却被判失败）
    c = info()
    req = urllib.request.Request(f'http://127.0.0.1:{c["port"]}{path}', method=method,
                                 data=None if body is None else json.dumps(body).encode(),
                                 headers={'X-S2Arm-Token': c['token'], 'Content-Type': 'application/json'})
    try:
        with LOCAL.open(req, timeout=timeout) as r: d = r.read()
    except urllib.error.HTTPError as e: sys.exit(f'{e.code}：{e.read().decode(errors="replace")}')
    except OSError as e:
        if soft: return None
        if 'timed out' in str(e):
            sys.exit('S2Arm 没在规定时间内回应：多半在等屏幕上的系统框（比如「想访问“下载”文件夹」），请玩家看一下屏幕并点允许，然后重试这条命令')
        sys.exit(f'连不上 S2Arm（App 可能退出了，s2armctl start 重开）：{e}')
    return d if raw else json.loads(d)

def alive(pid):
    if WINDOWS:   # Windows 的 os.kill(pid, 0) 是发 Ctrl-C，不是探测
        import ctypes
        k = ctypes.WinDLL('kernel32', use_last_error=True); k.OpenProcess.restype = ctypes.c_void_p
        h = k.OpenProcess(0x1000, False, int(pid))   # PROCESS_QUERY_LIMITED_INFORMATION
        if not h: return ctypes.get_last_error() == 5   # 拒绝访问 = 进程在
        try:
            code = ctypes.c_ulong(); k.GetExitCodeProcess.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ulong)]
            return bool(k.GetExitCodeProcess(h, ctypes.byref(code))) and code.value == 259   # STILL_ACTIVE
        finally:
            k.CloseHandle.argtypes = [ctypes.c_void_p]; k.CloseHandle(h)
    try: os.kill(pid, 0); return True
    except OSError: return False

def default_app():
    # 在 App 里运行（Contents/Resources/s2armctl.py）就用这个 App；否则 /Applications，再退到 ~/Applications
    here = os.path.abspath(__file__)
    if WINDOWS: return os.path.join(os.path.dirname(here), 'S2Arm.exe')
    if '/Contents/Resources/' in here: return here.split('/Contents/Resources/')[0]
    for a in ('/Applications/S2Arm.app', os.path.expanduser('~/Applications/S2Arm.app')):
        if os.path.isdir(a): return a
    return '/Applications/S2Arm.app'

def launch_args(app, root=None, custom=None):
    # 数据目录用整体写法 --data-root=<目录>：分开写时 macOS 把落单的 <目录> 当成要打开的文件交给 App，App 就不建窗口（11-02 坑记录）
    root, custom = (ROOT if root is None else root), (CUSTOM_ROOT if custom is None else custom)
    if WINDOWS: return [app, '--control'] + ([f'--data-root={root}'] if custom else [])
    return ['open', app, '--args', '--control'] + ([f'--data-root={root}'] if custom else [])

def start_failure(path, since):
    # App 起不来控制口时把原因写在这里；只认这次启动之后写的
    try:
        if os.path.getmtime(path) <= since: return ''
        with open(path, encoding='utf-8') as f: why = f.read().strip()
    except OSError: return ''
    if why.startswith('Private job root'):   # Windows 只接受 S2Arm 自己建的数据目录（权限不继承上级）
        why += '（这个数据目录不是 S2Arm 自己建的：请把 --data-root 换成一个还不存在的路径，S2Arm 会自己建）'
    return why

def start(app):
    cj = os.path.join(ROOT, 'control.json')
    err = os.path.join(ROOT, 'control.error')
    try:
        if alive(info()['pid']): call('GET', '/state', timeout=3); print(f'控制口已就绪：127.0.0.1:{info()["port"]}（pid {info()["pid"]}，数据目录 {ROOT}）'); return
    except SystemExit: pass
    old = os.path.getmtime(cj) if os.path.exists(cj) else 0
    old_err = os.path.getmtime(err) if os.path.exists(err) else 0
    # 不加 -n：玩家的 S2Arm 已经开着就不再开第二个（已开着但没打开 AI 开关时，--control 不会生效，下面超时会提示）
    args = launch_args(app)
    if WINDOWS: subprocess.Popen(args, cwd=os.path.dirname(app), creationflags=0x00000008 | 0x00000200, close_fds=True)   # DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP：窗口不随本命令退出
    else: subprocess.run(args, check=True)
    t = time.time()
    while time.time() - t < 60:
        if os.path.exists(cj) and os.path.getmtime(cj) > old and alive(info()['pid']):
            try: call('GET', '/state', timeout=3); print(f'控制口就绪：127.0.0.1:{info()["port"]}（pid {info()["pid"]}，数据目录 {ROOT}）'); return
            except SystemExit: pass
        why = start_failure(err, old_err)
        if why: sys.exit(f'控制口没起来：{why}')
        time.sleep(0.5)
    sys.exit('60 秒内控制口没就绪：如果 S2Arm 已经开着，请在它的「设置 → 让 AI 帮你操作」打开「允许 AI 操作 S2Arm」')

def brief(s):
    out = [f'页面 {s["selection"]}；引导页 {"开（第 %d 步）" % s["onboardingStep"] if s["showOnboarding"] else "关"}；密钥 {s["keyStatus"]}；环境 {"齐" if s["environmentReady"] else "未齐"}{"（检查中）" if s["checkingEnvironment"] else ""}']
    bad = [c for c in s['checks'] if not c['ok']]
    if bad: out.append('环境缺：' + '；'.join(f'{c["name"]}：{c["message"]}' for c in bad))
    if s.get('waitingForAccess'): out.append(f'在等系统授权：S2Arm 要读「{s["waitingForAccess"]}」，请玩家在屏幕上的系统框里点「允许」')
    for g in s['games']:
        if s.get('platform') == 'windows': st = 'iPhone 包已出好' if g['ready'] else ('可以出包' if g['buildable'] else '不能出包：' + '、'.join(g['missing']))
        else: st = '已编译，可启动' if g['ready'] else ('未编译，可以编译' if g['buildable'] else '不能编译：' + '、'.join(g['missing']))
        out.append(f'游戏号 {g["id"]}  {g["name"]}（版本 {g["display"]}）  {st}')
    for t in s['tasks'][-8:]:
        pr = f' {t.get("done", 0):.0f}/{t.get("total", 0):.0f}' if t.get('total') else ''
        out.append(f'任务 {t["id"]}  {t["operation"]}  {t["state"]}  {t.get("milestone") or t.get("stage") or ""}{pr}  {t.get("message") or ""}'.rstrip())
    if s['notice']: out.append('提示：' + s['notice'])
    if s['error']: out.append('错误：' + s['error'])
    return '\n'.join(out)

# ---------------- AI 代操作（10-26 维护者：导入 → 出包 → 签名装机 → 拷资源包 → 进游戏整条链路让玩家自己的 AI 能接手）----------------
# 错误码 → AI 下一步：who = ai（自己做）/ ask（问玩家要一个输入再做）/ human（只能玩家本人做：Apple ID、系统授权、密码、装 Xcode）/ confirm（有破坏性，先征得同意）
AI_NEXT = {
    'keys_missing': ('ask', '问玩家自己导出的 prod.keys 放在哪，然后 s2armctl keys <路径>'),
    'keys_invalid': ('ask', 'prod.keys 文件不完整：请玩家重新导出一份，然后 s2armctl keys <路径>'),
    'content_unreadable': ('human', '请玩家核对源文件和票据是否完整'),
    'ticket_missing': ('human', '请玩家核对源文件是否含有所需票据'),
    'content_truncated': ('human', '请玩家从原始位置重新复制完整的游戏文件'),
    'keys_outdated': ('human', '请玩家用系统版本更新的 Switch 重新导出 prod.keys，再 s2armctl keys <路径>'),
    'input_base_missing': ('ask', '只放了更新或 DLC：问玩家这款游戏本体（NSP / XCI）在哪，s2armctl games <本体所在文件夹>'),
    'input_empty': ('ask', '这个文件夹里没有 NSP / XCI：问玩家游戏文件在哪，s2armctl games <文件夹>'),
    'input_type_unsupported': ('ask', '不是 NSP / XCI：问玩家游戏文件在哪，s2armctl games <文件夹>'),
    'input_missing': ('ask', '游戏文件找不到了（磁盘没接上或被挪走）：请玩家接上磁盘或告诉你新位置，s2armctl games <文件夹>'),
    'content_invalid': ('ask', '游戏文件损坏或被改过：请玩家换一份完整的原版文件，s2armctl games <文件夹>'),
    'guest_isa_unsupported': ('human', '这款游戏是 32 位程序，S2Arm 暂不支持：告诉玩家换一款游戏'),
    'library_not_apfs': ('confirm', '游戏库（导出时的工作数据）放在了 exFAT 等非 APFS 格式的磁盘上，导出会失败；游戏原件放哪都行、不用挪：征得玩家同意后请他在 S2Arm「设置 → 游戏库与玩家数据」改用这台 Mac 上的默认位置（或选一块 APFS 外接盘），然后 s2armctl env'),
    'disk_full': ('confirm', '磁盘不够：s2armctl state --json 看各游戏 bytes，征得玩家同意后 s2armctl delete <不要的游戏号> 腾空间，或请玩家清理磁盘，然后 s2armctl retry <任务号>'),
    'permission_denied': ('human', '系统不让读这个位置：请玩家在屏幕上的系统框里点「允许」，或把游戏文件挪到不受保护的文件夹（不要放在「下载」「桌面」「文稿」），然后重试'),
    'architecture_unsupported': ('human', '需要 Apple 芯片的 Mac：告诉玩家这台 Mac 跑不了'),
    'os_unsupported': ('human', '需要更新的 macOS：请玩家升级系统'),
    'xcode_unavailable': ('human', '没装 Xcode：请玩家去 App Store 安装（要 Apple ID），装好打开一次，然后 s2armctl env'),
    'xcode_setup_required': ('human', 'Xcode 还没完成首次设置：请玩家打开 Xcode 同意许可（可能要输开机密码），然后 s2armctl env'),
    'xcode_sdk_too_old': ('human', 'Xcode 太旧：请玩家在 App Store 更新 Xcode，然后 s2armctl env'),
    'metal_unavailable': ('human', '缺 Metal 编译组件：请玩家在 S2Arm 环境检查里点「一键下载」，然后 s2armctl env'),
    'dotnet_sdk_missing': ('human', '缺 .NET SDK：请玩家在 S2Arm 环境检查里点安装，然后 s2armctl env'),
    'target_unsupported': ('human', '这台 iPhone 芯片太老或系统太旧（要 A14 及以上、iOS 18 及以上）：告诉玩家原因，升级系统或换设备'),
    'xcode_account_missing': ('human', 'Xcode 里没登录 Apple ID：请玩家打开 Xcode →「设置」→「账户」点「+」登录（免费的就行，要输 Apple ID 密码，AI 不代做），然后 s2armctl install <游戏号>；玩家不想登录 Xcode 就改用 AltStore（装机步骤页第二部分）'),
    'device_not_connected': ('ask', '没连 iPhone 或连了不止一台：请玩家用数据线只连要装的那台、解锁、在手机上点「信任」（第一次还要打开开发者模式），连好后 s2armctl install <游戏号>'),
    'device_locked': ('human', 'iPhone 锁屏了：请玩家解锁手机、停在主屏幕，然后重试 s2armctl install'),
    'free_app_limit': ('human', '免费 Apple ID 的自签 App 名额满了（同时 3 个、每周 10 个包名）：请玩家在 iPhone 上删掉一个不玩的自签 App 再试，或改用付费 Apple 开发者账号（AltStore 同样受这个上限）'),
    'signing_failed': ('ai', 's2armctl logs <任务号> 看签名哪一步报错；偶发的 s2armctl retry <任务号> 一次，再不行请玩家改用 AltStore（装机步骤页第二部分）'),
    'stage_timeout': ('ai', 's2armctl logs <任务号> 看卡在哪；s2armctl retry <任务号> 重试一次，还超时就 s2armctl diag export <输出.zip> 交给玩家反馈'),
}
DEFAULT_NEXT = ('ai', 's2armctl logs <任务号> 看原因，按日志末尾的提示处理；明确是偶发的就 s2armctl retry <任务号> 重试一次，再失败 s2armctl diag export <输出.zip> 交给玩家反馈')

def task_log(task_id):
    d = os.path.join(ROOT, 'logs')
    # Mac 构建各阶段写 logs/<任务>/，起游戏等作业写 logs/<任务>-*.log；两种布局都查。
    prefix = os.path.join(glob.escape(d), glob.escape(task_id))
    fs = glob.glob(prefix + '*.log') + glob.glob(os.path.join(prefix, '*.log'))
    fs = [f for f in fs if os.path.isfile(f)]
    return max(fs, key=os.path.getmtime) if fs else None

def logs(ref, n):
    s = call('GET', '/state'); ts = [t for t in s['tasks'] if t['id'] == ref or t.get('gameId') == ref]
    if not ts: sys.exit(f'没有任务号或游戏号 {ref} 的任务')
    t = max(ts, key=lambda t: t.get('started') or 0); f = task_log(t['id'])
    if not f: sys.exit(f'任务 {t["id"]}（{t["operation"]}）没有日志文件')
    print(f'== 任务 {t["id"]}  {t["operation"]}  {t["state"]}  日志 {f}')
    with open(f, 'rb') as h:
        h.seek(max(0, os.path.getsize(f) - 64000)); print('\n'.join(h.read().decode(errors='replace').splitlines()[-n:]))

def main_game(s, gid=None):
    gs = [g for g in s['games']]
    if gid: return next((g for g in gs if g['id'] == gid), None), []
    if not gs: return None, []
    gs = sorted(gs, key=lambda g: -(g.get('baseBytes') or 0)); return gs[0], gs[1:]

def ipa_of(s, gid):
    ts = [t for t in s['tasks'] if t.get('gameId') == gid and t['operation'] == 'ipa' and t['state'] == 'completed' and t.get('ipaPath')]
    return max(ts, key=lambda t: t.get('ended') or 0)['ipaPath'] if ts else None

def next_step(s, gid=None, target='ios'):
    """从 /state 推下一步：{step, who, do, why, game?, task?, code?}"""
    mac = target == 'mac'
    target_arg = ' --target mac' if mac else ''
    next_command = 's2armctl next' + (f' {gid}' if mac and gid else '') + target_arg
    if s.get('waitingForAccess'):
        return dict(step='授权', who='human', do=f'请玩家看屏幕，在系统框里点「允许」（S2Arm 要读「{s["waitingForAccess"]}」），然后 {next_command}', why='系统隐私授权只能玩家本人点')
    g, others = main_game(s, gid)
    mac_ready = mac and g and g['ready'] and not g.get('needsPreparation')
    # 已准备好的 Mac 游戏只需要运行环境，准备阶段仍需完整构建环境。
    environment_ready = s.get('runtimeReady', s['environmentReady']) if mac_ready else s['environmentReady']
    # 还没有任何检查结果也算在查：刚拉起窗口那一刻检查还没开始，不能报「环境缺东西、玩家去处理」却列不出缺什么（11-02 beta.3 走查）
    if s['checkingEnvironment'] or (not environment_ready and not s['checks']):
        return dict(step='环境检查', who='ai', do=f'等几秒再 {next_command}；一分钟后还是这一步，就 s2armctl env 发起一次检查', why='S2Arm 正在检查本机环境')
    if not environment_ready:
        bad = [c for c in s['checks'] if not c['ok']]
        return dict(step='环境', who='human', do='；'.join(f'{c["name"]}：{c["message"]}' for c in bad) + '（按提示装好后 s2armctl env）', why='本机缺组件，要玩家本人按提示安装' if s.get('platform') == 'windows' else '本机缺组件，多数要玩家本人在 App Store / 系统里操作')
    # 解包好的游戏不要密钥：空库先问游戏，NSP / XCI 没密钥时导入会报 keys_missing 再问
    if not mac_ready and not s.get('hasImportedKeys') and any(g.get('needsKeys', True) for g in s['games']):
        return dict(step='密钥', who='ask', do='问玩家自己从 Switch 导出的 prod.keys 放在哪，然后 s2armctl keys <路径>', why='S2Arm 不提供密钥，只能用玩家自己的')
    if not s['games']:
        return dict(step='导入', who='ask', do='问玩家游戏文件（NSP / XCI，本体 + 更新 + DLC 放一个文件夹）在哪，然后 s2armctl games <文件夹>', why='游戏库是空的')
    if not g: return dict(step='导入', who='ask', do=f'游戏库里没有 {gid}：s2armctl state 看游戏号，或 s2armctl games <文件夹> 导入', why='游戏号不在库里')
    extra = {'game': g['id'], 'name': g['name']}
    if others and not gid:
        extra['others'] = [f'{o["id"]} {o["name"]}（{(o.get("baseBytes") or 0) / 1e9:.2f} GB）' for o in others]
        extra['note'] = f'库里不止一款：按本体大小认 {g["name"]} 是主游戏，其余多半是同系列小工具；要出别的就 s2armctl next <游戏号>{target_arg}'
    mine = sorted([t for t in s['tasks'] if t.get('gameId') == g['id']], key=lambda t: t.get('started') or 0)
    if mac:
        mine = [t for t in mine if t['operation'] == 'build']
    act = [t for t in mine if t['state'] in ('running', 'queued', 'cancelling')]
    if act:
        t = act[-1]; op = t['operation'] if t['operation'] in ('ipa', 'install') else 'build'
        return dict(step='等待', who='ai', do=f's2armctl wait {g["id"]} --op {op}（或隔一会儿 {next_command}）', why=f'{t["operation"]} 正在进行：{t.get("milestone") or t.get("stage") or ""} {t.get("message") or ""}'.strip(), task=t['id'], **extra)
    if mac and g['id'] in s.get('queue', []):
        return dict(step='等待', who='ai', do=f's2armctl wait {g["id"]} --op build（或隔一会儿 {next_command}）', why='这款的 Mac 准备任务正在排队', **extra)
    if mac_ready:
        execution_task = s.get('executionTask')
        if execution_task and any(
            t['id'] == execution_task and t['operation'] == 'launch'
            and t.get('gameId') == g['id'] and t['state'] == 'running'
            for t in s['tasks']
        ):
            return dict(step='运行中', who='human', do='请玩家查看 Mac 上的游戏窗口',
                        why='这款游戏正在启动或运行', task=execution_task, **extra)
        if execution_task or s.get('queue'):
            return dict(step='等待', who='ai', do=f'等当前任务结束后再 {next_command}', why='构建与游戏运行互斥', **extra)
        return dict(step='启动', who='ai', do=f's2armctl launch {g["id"]}', why='这款游戏的 Mac 版已准备好', **extra)

    ipa = None if mac else ipa_of(s, g['id'])
    last = mine[-1] if mine else None
    if last and last['state'] in ('failed', 'interrupted') and (mac or last['operation'] == 'install' or (last['operation'] == 'ipa' and not ipa)):
        d = (last.get('diagnostics') or [{}])[0]; code = d.get('code') or 'job_failed'
        who, do = AI_NEXT.get(code, DEFAULT_NEXT)
        step = {'build': '准备失败', 'install': '装机失败', 'ipa': '出包失败'}[last['operation']]
        return dict(step=step, who=who, do=do.replace('<任务号>', last['id']), why=d.get('summary') or last.get('message') or '', code=code, suggestion=d.get('suggestion'), task=last['id'], log=d.get('logPath'), **extra)
    if not g['buildable'] and (mac or not g['ready']):
        return dict(step='导入', who='ask', do='这款游戏缺：' + '、'.join(g.get('missing') or []) + '；问玩家要缺的文件，s2armctl games <文件夹>', why='游戏文件不全', **extra)
    if mac:
        return dict(step='准备', who='ai', do=f's2armctl build {g["id"]} mac，然后 s2armctl wait {g["id"]} --op build', why='还需要准备这款游戏的 Mac 版', **extra)
    if not ipa:
        # 一包通用（10-30）：iPhone 包与机型无关，不用先选目标设备——11-02 beta.3 走查发现这里还在多问一步
        return dict(step='出包', who='ai', do=f's2armctl build {g["id"]} ios，然后 s2armctl wait {g["id"]} --op ipa --timeout 7200', why='还没出 iPhone 版（大游戏第一次要几十分钟到一个多小时，请玩家插上电源、别让%s睡眠）' % ('电脑' if s.get('platform') == 'windows' else ' Mac '), **extra)
    if s.get('platform') == 'windows':
        if [t for t in mine if t['operation'] == 'install' and t['state'] == 'completed']:
            return dict(step='打开游戏', who='human', do='已装到 iPhone：请玩家打开这款游戏，第一次会先导入游戏资源（几分钟），保持前台别锁屏', why='装机完成，剩下只有玩家本人在手机上打开', ipa=ipa, **extra)
        return dict(step='装机', who='ai', do=f's2armctl install-check {g["id"]}，没打勾的项按它说的请玩家做（Apple ID 只能玩家本人在 Impactor 里登录）；然后 s2armctl install {g["id"]}，然后 s2armctl wait {g["id"]} --op install --timeout 3600',
                    why='iPhone 包已出好：用玩家在 Impactor 登录的 Apple ID 签名，数据线装上并拷资源包', ipa=ipa, **extra)
    # 装机主路（10-26 维护者 定）：用玩家在 Xcode 登录的 Apple ID 签名、数据线装、自动拷资源包；Xcode 没登录 / 没连设备由 install 报错码，再按 AI_NEXT 处理
    done = [t for t in mine if t['operation'] == 'install' and t['state'] == 'completed' and (t.get('ended') or 0) >= max((x.get('ended') or 0) for x in mine if x['operation'] == 'ipa' and x['state'] == 'completed')]
    if done:
        return dict(step='打开游戏', who='human', do=f'已装到 iPhone{("「" + done[-1]["device"] + "」") if done[-1].get("device") else ""}、资源包已拷好并核对：请玩家打开这款游戏，第一次会先导入游戏资源（几分钟），保持前台别锁屏，导入完会自动进入游戏。免费 Apple ID 签的 App 7 天过期，到时连上再 s2armctl install {g["id"]}',
                    why='装机完成，剩下只有玩家本人在手机上打开', ipa=ipa, **extra)
    return dict(step='装机', who='ai', do=f's2armctl install-check {g["id"]}，没打勾的项按它说的请玩家做；然后 s2armctl install {g["id"]}，然后 s2armctl wait {g["id"]} --op install --timeout 3600',
                why='iPhone 包已出好：用玩家在 Xcode 登录的 Apple ID 签名，数据线装上并拷资源包。玩家不想登录 Xcode 就改用 AltStore（装机步骤页第二部分）', ipa=ipa, **extra)

def show_next(gid, as_json, target='ios'):
    n = next_step(call('GET', '/state'), gid, target)
    if as_json: print(json.dumps(n, ensure_ascii=False, indent=1)); return
    who = {'ai': 'AI 自己做', 'ask': '先问玩家要输入', 'human': '只能玩家本人做（AI 停下来提示玩家）', 'confirm': '有破坏性，先征得玩家同意'}[n['who']]
    print(f'下一步：{n["step"]}（{who}）\n  做什么：{n["do"]}\n  为什么：{n["why"]}')
    for k in ('code', 'suggestion', 'log', 'note'):
        if n.get(k): print(f'  {k}：{n[k]}')
    for o in n.get('others', []): print(f'  库里另有：{o}')

DEVICECTL = '/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/Resources/bin/devicectl'   # 直接调，不走 xcrun 包装（包装脚本版本不符时会弹装组件的密码框）

def dctl(args, timeout=90):
    exe = DEVICECTL if os.path.exists(DEVICECTL) else 'xcrun'
    full = ([exe] if exe == DEVICECTL else ['xcrun', 'devicectl']) + args
    return subprocess.run(full, capture_output=True, text=True, timeout=timeout)

def game_bundle(gid):
    s = call('GET', '/state'); ipa = ipa_of(s, gid)
    if not ipa: sys.exit(f'{gid} 还没出 iPhone 包：s2armctl next {gid}')
    import zipfile, plistlib
    with zipfile.ZipFile(ipa) as z:
        pl = next(n for n in z.namelist() if n.count('/') == 2 and n.endswith('.app/Info.plist'))
        return ipa, plistlib.loads(z.read(pl))['CFBundleIdentifier']

def iphone():
    import tempfile
    with tempfile.NamedTemporaryFile(suffix='.json') as f:
        r = dctl(['list', 'devices', '--json-output', f.name])
        try: ds = json.load(open(f.name))['result']['devices']
        except Exception: sys.exit(f'读不了设备列表（devicectl 退出 {r.returncode}）：{(r.stderr or r.stdout).strip()[-300:]}')
    ds = [d for d in ds if d.get('hardwareProperties', {}).get('reality') == 'physical' and (d.get('connectionProperties', {}).get('tunnelState') in ('connected', None)
          or d.get('connectionProperties', {}).get('transportType') == 'wired' and d.get('connectionProperties', {}).get('pairingState') == 'paired')
          and d.get('hardwareProperties', {}).get('platform') == 'iOS']
    return ds

def device(gid):
    ipa, bid = game_bundle(gid); ds = iphone()
    if not ds: print(f'没连 iPhone：请玩家用数据线连上并解锁、在手机上点「信任」。包 {ipa}（应用身份 {bid}）'); sys.exit(2)
    for d in ds:
        u = d['hardwareProperties']['udid']; name = d.get('deviceProperties', {}).get('name', u)
        import tempfile
        with tempfile.NamedTemporaryFile(suffix='.json') as f:
            dctl(['device', 'info', 'apps', '--device', u, '--bundle-id', bid, '--json-output', f.name])
            try: apps = json.load(open(f.name))['result']['apps']
            except Exception: apps = []
        print(f'iPhone「{name}」（{u}）：{"已装" if apps else "没装"} {bid}' + ('' if apps else '——请玩家用 AltStore 装（要登录 Apple ID，AI 不代做）'))
    sys.exit(0)

def engine_root():   # 引擎目录：App 里是 Contents/Resources/Engine（bundle_engine 冻结的快照），仓库里是仓库根
    here = os.path.abspath(__file__)
    if '/Contents/Resources/' in here: return os.path.join(here.split('/Contents/Resources/')[0], 'Contents/Resources/Engine')
    return os.path.dirname(os.path.dirname(os.path.dirname(here)))

def push_pack(gid):
    """只推游戏资源（App 已由玩家装好、资源不全时）：调 Mac / Windows 共用的 tools/push_pack.py（同启动器装机、dev_run）——
    按 sha256 只推机上没有 / 变了的文件、残留批按完整性处理、推完起一次 App 只解包并等解完（--apply）。原先这里整个资源包目录 devicectl 拷进 Documents，
    每次全量、不认机上已有（11-06 第三条推包路径收编）"""
    ipa, bid = game_bundle(gid); pack = next((os.path.join(os.path.dirname(ipa), f) for f in os.listdir(os.path.dirname(ipa)) if f.endswith('资源包')), None)
    if not pack: sys.exit(f'{os.path.dirname(ipa)} 里没有「资源包」文件夹：重新出包 s2armctl ipa {gid}')
    ds = iphone()
    if len(ds) != 1: sys.exit('要恰好连着一台 iPhone（现在 %d 台）：请玩家只连要装的那台' % len(ds))
    u = ds[0]['hardwareProperties']['udid']; tool = os.path.join(engine_root(), 'tools', 'push_pack.py')
    if not os.path.isfile(tool): sys.exit(f'找不到推包工具 {tool}：App 不完整，请重新下载 S2Arm')
    env = dict(os.environ, S2A_DEVICECTL=DEVICECTL if os.path.exists(DEVICECTL) else 'xcrun devicectl', S2A_PUSH_UDID=u)
    if '/Contents/Resources/' in os.path.abspath(__file__): env.setdefault('S2A_PREBUILT_TOOLS', os.path.join(engine_root(), 'Binaries', 'Prepare'))   # App 内置 s2a-devpush → 流式写
    print(f'推 {pack} → iPhone 上 {bid}：只推机上没有 / 变了的文件，推完起一次 App 解开（大包要几分钟）…', flush=True)
    r = subprocess.run([sys.executable, '-B', tool, 'run', u, bid, pack, '--via', 'devicectl', '--udid', u, '--apply'], env=env)
    if r.returncode:
        sys.exit('资源包没推完（上面最后一行【红】是原因）：手机要解锁、保持连接；App 还没装的话请玩家先用 AltStore / Impactor 装好再试')
    print('🟢 资源包已推进 iPhone 并解开。请玩家打开这款游戏：第一次会先导入游戏资源（几分钟），保持前台别锁屏，导入完会自动进入游戏')

# 作业记录（pack/jobs/core.py 写的 <数据目录>/jobs/<任务>.json：state / stage / milestone / done / total / pid / pidStart …）：
#   控制口不应答或给的快照太旧时，wait 按它判。作业是独立进程，启动器卡住（内存吃紧、主线程忙）不等于作业停了
def journal_task(game, op, tid, since):
    best = None
    for p in glob.glob(os.path.join(ROOT, 'jobs', '*.json')):
        if p.endswith('.request.json'): continue
        try: j = json.load(open(p, encoding='utf-8'))
        except Exception: continue
        if not isinstance(j, dict) or (tid and j.get('id') != tid): continue
        if not tid and (j.get('gameId') != game or j.get('operation') != op): continue
        if not tid and j.get('state') not in ('running', 'cancelling') and (j.get('ended') or j.get('started') or 0) < since: continue   # 等之前就结束的旧作业
        if best is None or (j.get('started') or 0) > (best.get('started') or 0): best = j
    return best

def job_alive(j):
    """True：同一作业仍活着；False：已退出 / PID 已复用；None：身份无法确认。"""
    pid = j.get('pid')
    if not pid or not alive(int(pid)): return False
    if WINDOWS: return True   # 没有 ps；这条只在控制口失联时用，进程号在作业存续期内不会复用
    # 僵尸（已退出、父进程还没收尸——启动器卡住时正是这样）算没了；进程号被别的进程复用（起始时刻对不上）也算没了
    try:
        r = subprocess.run(['/bin/ps', '-o', 'stat=', '-o', 'lstart=', '-p', str(int(pid))], capture_output=True, text=True)
    except OSError:
        return None
    if r.returncode: return None
    st, _, start = r.stdout.strip().partition(' ')
    if st.startswith('Z'): return False
    identity = j.get('pidStart')
    if not st or not start.strip() or not isinstance(identity, str) or not identity.strip(): return None
    return start.strip() == identity

def wait(game, op, limit):
    t0 = time.time(); last = None; tid = None
    before_queue = None; queue_started = None; said_lost = False
    while time.time() - t0 < limit:
        s = call('GET', '/state', soft=True, timeout=float(os.environ.get('S2ARMCTL_STATE_TIMEOUT', '15')))   # 单测调短
        if s is None or time.time() - (s.get('cachedAt') or time.time()) > 20:   # 控制口不应答 / 快照停在 20 秒前（主线程卡住）
            j = journal_task(game, op, tid, t0 - 5)
            if not said_lost:
                print(f'[{time.time() - t0:6.0f}s] 启动器控制口{"没应答" if s is None else "的状态停住了"}，改按作业记录判（作业是独立进程，需核对身份）', flush=True); said_lost = True
            if j:
                tid = j['id']
                if j.get('state') in ('running', 'cancelling'):
                    living = job_alive(j)
                    if living is None:
                        print(f'无法确认作业进程身份（任务 {tid}）：作业记录缺起始时刻或进程查询不可用；请待控制口恢复后核对，勿据此重复启动'); sys.exit(1)
                    if living is False:
                        print(f'作业进程已不在（任务 {tid}，停在 {j.get("stage") or "?"}）：可在 S2Arm 里重试，已完成的阶段会验证后跳过'); sys.exit(1)
                last = show_task(j, t0, last)
            time.sleep(2); continue
        if said_lost: print(f'[{time.time() - t0:6.0f}s] 控制口恢复', flush=True); said_lost = False
        ts = [t for t in s['tasks'] if t.get('gameId') == game and t['operation'] == op]
        queued = op == 'build' and game in s.get('queue', [])
        # queue 先于 jobs 刷新到 tasks；此时不能拿历史构建结果提前结束等待。
        if queued:
            if before_queue is None: before_queue = {t['id'] for t in ts if t['state'] != 'queued'}
            ts = [t for t in ts if t['state'] == 'queued']
            if ts: queue_started = max(t.get('started') or 0 for t in ts)
        elif before_queue is not None:
            # 出队时 App 同步插入 worker；取消时则直接删除排队记录，不保证留下 cancelled。
            ts = [t for t in ts if t['id'] not in before_queue
                  and (queue_started is None or (t.get('started') or 0) >= queue_started)]
            if not ts: print('排队已取消'); sys.exit(1)
        if ts:
            t = max(ts, key=lambda t: t.get('started') or 0); tid = t['id']
            last = show_task(t, t0, last)
        elif s['error'] and not queued: print('错误：' + s['error']); sys.exit(1)
        time.sleep(2)
    sys.exit(f'{limit} 秒内没结束（任务 {tid}）')

def show_task(t, t0, last):
    """打一行进度（状态 / 里程碑 / 每 5% 变一次才打）；终态打各里程碑用时后按结果退出。返回新的 last"""
    cur = (t['state'], t.get('milestone'), int(t.get('done') or 0) // max(1, int((t.get('total') or 1) // 20)))
    if cur != last:
        last = cur; pr = f' {t.get("done") or 0:.0f}/{t.get("total") or 0:.0f}{t.get("unit") or ""}' if t.get('total') else ''
        print(f'[{time.time() - t0:6.0f}s] {t["state"]}  {t.get("milestone") or t.get("stage") or ""}{pr}  {t.get("message") or ""}'.rstrip(), flush=True)
    if t['state'] not in ('running', 'queued', 'cancelling'):
        ms = t.get('milestoneStarted') or {}; order = [m['id'] for m in (t.get('milestones') or []) if m['id'] in ms]
        end = t.get('ended') or time.time()
        for i, m in enumerate(order):
            nxt = ms[order[i + 1]] if i + 1 < len(order) else end
            print(f'  里程碑 {m}：{nxt - ms[m]:.0f} 秒')
        if t.get('started'): print(f'  合计 {end - t["started"]:.0f} 秒')
        sys.exit(0 if t['state'] == 'completed' else 1)
    return last

def wait_op(op, before, limit=1800):
    # 等「放密钥 / 放游戏」这类不属于某款游戏的任务结束（取发命令之后出现的最新一个），打结果；失败给出 errors 同样的信息
    t0 = time.time(); said = None; stage = None; n0 = len(call('GET', '/state')['games'])
    while time.time() - t0 < limit:
        s = call('GET', '/state')
        for t in s['tasks']:
            # 放密钥时会顺带建游戏库（一分钟上下）、放游戏要校验：阶段一变就打一行，免得像卡住
            if t['id'] not in before and t['state'] == 'running' and t.get('stage') and (t['id'], t['stage']) != stage:
                stage = (t['id'], t['stage']); print(f'[{time.time() - t0:5.0f}s] {t["operation"]}：{t["stage"]}', flush=True)
        if s.get('waitingForAccess') and said != 'access':
            print(f'在等系统授权：请玩家在屏幕上的系统框里点「允许」（S2Arm 要读「{s["waitingForAccess"]}」）', flush=True); said = 'access'
        ts = [t for t in s['tasks'] if t['operation'] == op and t['id'] not in before]
        if ts:
            t = max(ts, key=lambda t: t.get('started') or 0)
            if t['state'] not in ('running', 'queued', 'cancelling'):
                print(f'{t["state"]}：{t.get("message") or ""}')
                if t['state'] != 'completed': errors(); sys.exit(1)
                # 作业记录写完时启动器还在收尾（刷新游戏库等）：等它空闲再返回，否则紧接着的下一条命令会被 409 挡回来
                for _ in range(40):
                    if not call('GET', '/state').get('busy'): break
                    time.sleep(0.5)
                # 导入完成后游戏库异步刷新：等到游戏出现在列表里（最多 10 秒）再打状态，好拿游戏号
                for _ in range(20):
                    s = call('GET', '/state')
                    if op != 'import' or len(s['games']) > n0: break
                    time.sleep(0.5)
                print(brief(s)); return
        elif s.get('error') and not s.get('waitingForAccess'): print('错误：' + s['error']); sys.exit(1)
        time.sleep(1)
    sys.exit(f'{limit} 秒内 {op} 没结束')

def errors(game=None):
    # 最近一个失败任务（可按游戏号筛）：错误码、原因、建议、日志位置 + 日志末尾 40 行（日志本来就在这台 Mac 上）
    s = call('GET', '/state')
    bad = [t for t in s['tasks'] if t['state'] in ('failed', 'interrupted') and (not game or t.get('gameId') == game)]
    if not bad:
        print('没有失败的任务。' + ('当前提示：' + s['error'] if s.get('error') else '')); return
    t = max(bad, key=lambda t: t.get('started') or 0)
    print(f'任务 {t["id"]}  {t["operation"]}  游戏 {t.get("gameId") or "-"}  {t["state"]}  {t.get("message") or ""}')
    for d in t.get('diagnostics') or []:
        print(f'- 错误码 {d.get("code")}  阶段 {d.get("stage") or "-"}\n  原因：{d.get("summary")}\n  建议：{d.get("suggestion")}\n  日志：{d.get("logPath") or "-"}')
        if d.get('failureSummary'):
            print('  ' + d['failureSummary'].replace('\n', '\n  '))
    logs = [d['logPath'] for d in t.get('diagnostics') or [] if d.get('logPath') and os.path.isfile(d['logPath'])]
    if logs:
        print(f'--- {logs[-1]} 末尾 ---'); print(''.join(open(logs[-1], errors='replace').readlines()[-40:]).rstrip())

def install_check(gid, as_json, limit=40):
    """POST /installCheck 后等 /state 里出现这款的 installReadiness（启动器后台查，几秒）"""
    call('POST', '/installCheck', {'gameId': gid}); t0 = time.time()
    while time.time() - t0 < limit:
        rd = call('GET', '/state').get('installReadiness')
        if rd and rd.get('gameId') == gid:
            if as_json: print(json.dumps(rd, ensure_ascii=False, indent=1)); return
            for i in rd['items']:
                mark = '✓' if i['ok'] else ('…' if i['waiting'] else '✗')
                print(f'{mark} {i["title"]}' + (f'\n    {"玩家本人做" if i["who"] == "human" else "启动器做"}：{i["detail"]}' if not i['ok'] and not i['waiting'] else ''))
            if rd.get('signing'): print('Xcode 签名：' + rd['signing'])
            print('可以装：s2armctl install ' + gid + '（✗ 的项先告诉玩家；失败时按错误提示处理）' if rd['ready'] else '这款的 iPhone 版还没做好：先出包，再 s2armctl install-check ' + gid)
            sys.exit(0 if rd['ready'] else 2)
        time.sleep(1)
    sys.exit(f'{limit} 秒内没查完（读手机信息很慢时会这样），再试一次')

def diag_body(rest, now=None):
    """diag 的请求体。只写 diag（或 diag export 不给路径）= 导出 Mac 诊断包到桌面（没有桌面就当前目录），文件名带时刻；
    原先只认 diag pull / diag export <路径>，只敲 diag 直接 IndexError 的 traceback（#94：维护方让玩家跑 s2armctl diag，玩家拿到的是报错）。
    认不出的写法返回 None，由调用方打用法、退出 2"""
    if rest[:1] == ['pull'] and len(rest) == 1: return {'action': 'pull'}
    if rest[:1] == ['export'] and len(rest) == 2: return {'action': 'export', 'path': os.path.abspath(os.path.expanduser(rest[1]))}
    if rest and rest != ['export']: return None
    desk = os.path.expanduser('~/Desktop'); base = desk if os.path.isdir(desk) else os.getcwd()
    return {'action': 'export', 'path': os.path.join(base, time.strftime('S2Arm-诊断-%Y%m%d-%H%M%S.zip', time.localtime(now)))}

def main():
    a = sys.argv[1:]
    if not a or a[0] in ('help', '-h', '--help'):
        print(USAGE)
        try:
            h = call('GET', '/help', timeout=3)
            print(f'\nApp 接口（S2Arm {h["version"]}）：'); [print(f'  {e["call"]:52} {e["what"]}') for e in h['endpoints']]
        except SystemExit: print('\n（App 的控制口没开：先 s2armctl start，或在 S2Arm 设置里打开「允许 AI 操作 S2Arm」）')
        return
    cmd, rest = a[0], a[1:]
    if cmd == 'start': start(rest[0] if rest else default_app()); return
    if cmd == 'state':
        s = call('GET', '/state'); print(json.dumps(s, ensure_ascii=False, indent=None if '--json' in rest else 1) if ('--full' in rest or '--json' in rest) else brief(s)); return
    if cmd in ('keys', 'games'):
        op = 'keys' if cmd == 'keys' else 'import'
        before = {t['id'] for t in call('GET', '/state')['tasks']}
        body = {'path': os.path.abspath(os.path.expanduser(rest[0]))} if cmd == 'keys' else {'paths': [os.path.abspath(os.path.expanduser(x)) for x in rest]}
        call('POST', '/keys' if cmd == 'keys' else '/games', body); wait_op(op, before); return
    if cmd == 'next':
        parser = argparse.ArgumentParser(prog='s2armctl next', allow_abbrev=False)
        parser.add_argument('game', metavar='游戏号', nargs='?')
        parser.add_argument('--target', choices=('mac', 'ios'), default='ios', help='默认 ios')
        parser.add_argument('--json', action='store_true', help='以 JSON 输出')
        args = parser.parse_args(rest)
        if WINDOWS and args.target == 'mac':
            parser.error('Windows 只支持 iOS，不能使用 --target mac')
        show_next(args.game, args.json, args.target)
        return
    if cmd == 'logs': logs(rest[0], int(rest[rest.index('--lines') + 1]) if '--lines' in rest else 40); return
    if WINDOWS and cmd in ('device', 'push-pack'):
        sys.exit('Windows 上用 s2armctl install-check <游戏号> 看手机状态；s2armctl install <游戏号> 会装 App 并拷资源包')
    if cmd == 'device': device(rest[0]); return
    if cmd == 'push-pack': push_pack(rest[0]); return
    if cmd == 'customize':
        def value(flag): return rest[rest.index(flag) + 1] if flag in rest else None
        body = {'gameId': rest[0]}
        if value('--name') is not None: body['name'] = value('--name')
        if value('--cover') is not None: body['coverPath'] = os.path.abspath(value('--cover'))
        if '--reset-name' in rest: body['name'] = ''
        if '--reset-cover' in rest: body['coverPath'] = ''
        if len(body) == 1: sys.exit('要给 --name、--cover、--reset-name 或 --reset-cover')
        print(json.dumps(call('POST', '/customize', body), ensure_ascii=False)); return
    if cmd == 'signing-project':
        print(json.dumps(call('POST', '/signingProject', {}), ensure_ascii=False)); return
    if cmd == 'delete':
        before = {t['id'] for t in call('GET', '/state')['tasks']}
        call('POST', '/delete', {'gameId': rest[0]}); wait_op('delete', before); return
    if cmd == 'targets':
        t = call('GET', '/targets')
        if '--json' in rest: print(json.dumps(t, ensure_ascii=False, indent=1)); return
        lab = lambda d: f'{d["model"]}（{d["productType"]}，{d["gpuArch"]}）· iOS {d.get("os") or "?"}' + (f'，设备名「{d["deviceName"]}」' if d.get('deviceName') else '')
        print('当前目标：' + (lab(t['current']) + ('（已连接，自动选的）' if t['current'].get('connected') else '（玩家选的）') if t['current'] else '没有（连上设备，或用 target <机型号> <系统大版本> 选）'))
        print(f'连着的设备 {len(t["connected"])} 台' + ''.join('\n  - ' + lab(d) for d in t['connected']))
        print('可选系统大版本：' + '、'.join(map(str, t['osChoices'])) + f'；可选机型 {len(t["models"])} 种' + ('：' if '--models' in rest else '（加 --models 列全）'))
        if '--models' in rest: [print(f'  {m["productType"]:12} {m["model"]}（{m["gpuArch"]}）') for m in t['models']]
        return
    if cmd == 'update':
        if rest: print(json.dumps(call('POST', '/update', {'action': rest[0]}), ensure_ascii=False))
        else: print(json.dumps(call('GET', '/state').get('update'), ensure_ascii=False))
        return
    if cmd == 'display':
        names = {'--fps60': 'fps60', '--widen': 'widenForce', '--metalfx': 'metalfx'}
        body = {'gameId': rest[0]}
        for flag, key in names.items():
            if flag in rest: body[key] = rest[rest.index(flag) + 1] == 'on'
        print(json.dumps(call('POST', '/display', body), ensure_ascii=False, indent=1)); return
    if cmd == 'library':
        before = {t['id'] for t in call('GET', '/state')['tasks']}
        call('POST', '/library', {'path': os.path.abspath(os.path.expanduser(rest[0])), 'move': '--move' in rest}); wait_op('setup', before); return
    if cmd == 'errors': errors(rest[0] if rest else None); return
    if cmd == 'install-check': install_check(rest[0], '--json' in rest); return
    if cmd == 'build':
        args = [a for a in rest if a != '--space-override']
        target = args[1] if len(args) > 1 else 'ios'
        if target in ('android', 'harmony'): print('即将上线，敬请期待'); sys.exit(2)
        print(json.dumps(call('POST', '/build', {'gameId': args[0], 'target': target, **space_flag(rest)}), ensure_ascii=False)); return
    if cmd == 'diag':
        body = diag_body(rest)
        if body is None: print('用法：s2armctl diag [export [输出.zip]] | diag pull', file=sys.stderr); sys.exit(2)
        print(json.dumps(call('POST', '/diagnostics', body), ensure_ascii=False)); return
    if cmd == 'snapshot':
        out = rest[0]
        # 优先系统截图按主窗口区域截（与屏幕所见一致，含弹出层 / 毛玻璃；需要调用方有屏幕录制权限）；不行再让 App 自己画
        if '--app' not in rest and not WINDOWS:
            ws = [w for w in call('GET', '/state')['windows'] if not w['sheet'] and w['rect'][2] > 200]
            if ws:
                x, y, w, h = ws[0]['rect']
                # 10 秒上限：缺屏幕录制权限时系统会弹授权框、screencapture 一直等
                try: r = subprocess.run(['screencapture', '-x', '-R', f'{x:.0f},{y:.0f},{w:.0f},{h:.0f}', out], capture_output=True, text=True, timeout=10)
                except subprocess.TimeoutExpired: r = subprocess.CompletedProcess([], 124, '', '10 秒没截出来（多半在等屏幕录制授权）')
                if r.returncode == 0 and os.path.exists(out) and os.path.getsize(out) > 0: print(out, '（系统截图）'); return
                print(f'系统截图不行（{(r.stderr or r.stdout).strip()}），改用 App 自绘（不含弹出层、毛玻璃）', file=sys.stderr)
        open(out, 'wb').write(call('GET', '/snapshot', raw=True)); print(out, '（App 自绘）')
        # 有弹出层开着而 App 只能自绘时，App 在截图口径里写「截不全」：照实说、退出码 3，别把缺了弹出层的图当证据
        how = call('GET', '/state').get('lastSnapshotPath', '')
        if '截不全' in how: print('⚠️ ' + how[how.index('截不全'):], file=sys.stderr); sys.exit(3)
        return
    if cmd == 'wait':
        op = rest[rest.index('--op') + 1] if '--op' in rest else 'build'
        lim = float(rest[rest.index('--timeout') + 1]) if '--timeout' in rest else 14400
        wait(rest[0], op, lim); return
    simple = {
              'fonts': ('/fonts', lambda r: {'path': os.path.abspath(r[0]) if r and r[0] else ''}),
              'prepare': ('/prepare', lambda r: {'gameId': r[0], **space_flag(r)}), 'ipa': ('/ipa', lambda r: {'gameId': r[0], **space_flag(r)}), 'install': ('/install', lambda r: {'gameId': r[0], **({'teamId': r[r.index('--team') + 1]} if '--team' in r else {}), **({'device': r[r.index('--device') + 1]} if '--device' in r else {})}), 'uninstall': ('/uninstall', lambda r: {'gameId': r[0]}), 'launch': ('/launch', lambda r: {'gameId': r[0]}),
              'cancel': ('/cancel', lambda r: {'taskId': r[0]}), 'retry': ('/retry', lambda r: {'taskId': r[0]}),
              'select': ('/select', lambda r: {'selection': r[0], **({'gameId': r[1]} if len(r) > 1 else {})}),
              'onboarding': ('/onboarding', lambda r: {'action': r[0], **({'step': int(r[1])} if len(r) > 1 else {})}),
              'target': ('/target', lambda r: {'action': 'probe'} if r[:1] == ['probe'] else {'productType': r[0], 'os': int(r[1])}),
              'env': ('/environment', lambda r: {}), 'refresh': ('/refresh', lambda r: {}), 'dismiss': ('/dismiss', lambda r: {})}
    if cmd not in simple: sys.exit(f'不认识 {cmd}')
    path, mk = simple[cmd]; print(json.dumps(call('POST', path, mk(rest)), ensure_ascii=False))

def space_flag(args): return {'spaceOverride': True} if '--space-override' in args else {}

if __name__ == '__main__': main()
