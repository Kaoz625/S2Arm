#!/usr/bin/env python3
"""iOS 宿主界面本地化（#316）单测：宿主玩家看得到的文字走 S2AL(@"键")（ios/s2a_l10n.h），
字符串表 ios/l10n/<语言>.lproj/S2ArmHost.strings（en / zh-Hans / zh-Hant，按目录自动认）；与游戏进程 / Mac 共用的 C 宏文案（runtime/include 四个头文件）走 S2APICK 取 <宏>_EN；
iOS「设置」App 的 S2Arm 页 Root.plist 原文英文、zh-Hans.lproj/Root.strings 译中文；Info.plist 权限说明主值英文、<语言>.lproj/InfoPlist.strings 译文。
期望按规则手写，不跑被测代码：
  ① SRCS 里的 .m，除注释与日志调用（NSLog / LOG / s2a_log / fprintf / printf）外，不再有含中文的 @"…" 字面量；
     不上屏的串（与别的代码比对的标识串、只进诊断包 / 日志 / 崩溃原因的串、真实路径名）列在 IDENT 里，逐条写明理由，且必须真的还在
  ② 代码里每个 S2AL 的参数都是 @"键" 字面量；每个键在各语言表都有；每种语言与 en 键集合相同（任何一种缺键即红）、无重复键；表里没有代码不用的孤儿键
  ③ 同一个键两表的格式占位符（%@ %d %.1f %1$@ …，按位置归一）一致
  ④ Root.plist 显示文字（Title / FooterText / Titles）无中文；含字母的每条在 Root.strings 里都有翻译，Root.strings 没有多余键
  ⑤ 两张 S2ArmHost.strings、两张 InfoPlist.strings 与 Root.strings（连同 Root.plist）过 plutil -lint
  ⑥ SRCS 里含中文的 C 字面量 "…"（不带 @）只许出现在日志调用或本文件登记的「只进日志 / 诊断」的函数参数里（C_SINKS，按文件逐个写理由），
     或逐条登记在 IDENT_C；其余一律算漏翻（例如直接递给 s2a_ios_show_notice 的中文）
  ⑦ runtime/include 四个头文件（横幅 / 初启失败页 / 自检提示页 / 直连安全网）的每个文案宏都有 <宏>_EN；SRCS 里用到这些宏的地方只许经 S2APICK / S2APICKC
     或 app.m host_text 的 {宏, 宏_EN} 对照表；C 层递字符串上来的那几组（自检提示页全部、初启失败页的原因句与下一步）必须都在对照表里
  ⑧ en 表的值不含中文，除了 EN_CJK 登记的键（照写真实的「<游戏名>资源包」文件夹名）与 ENDONYM（界面语言选项里的语言自称，各表同值）
  ⑨ InfoPlist.strings 两表键集合相同、都非空，且每个键都是 runtime/build.mk 写进 Info.plist 的键（主值英文、不含中文）
  ⑩ 跨平台 C 层递给宿主显示的文字（runtime/include/s2a_ui_text.h）：每个 S2A_UI_* 文案宏都有 _EN、_EN 不含中文（照写的「资源包」除外）、
     都被用到；用到的地方只许经 S2A_UI(…)；用 S2A_UI 的 .c 各带一份 s2a_ui_zh 弱缺省，iOS / Mac 各有一份强定义；
     显示路径（DISPLAY_CALLS 的调用参数、DISPLAY_FUNCS 的函数体）里不许再有中文 C 字面量
  ⑪ 存档服务层（services/S2A.Services/SaveTransfer*.cs）玩家看得到的说明：除 stderr 日志外，每个中文字面量都是 T("中文", "English") 的第一参，
     英文非空、不含中文；同一句中文全仓只对应一句英文
  ⑫ iOS 游戏库 / iCloud 同步页（shell/Sources/S2ArmShellHost/*.swift，我方代码）：除日志（NSLog / print）与 SHELL_IDENT 登记的串外，没有中文字面量；
     代码里 shellText("…") 的键（字符串插值按 %@ 算）与设置行标签（S2ArmGameSettings 的 title / label / note / SettingOption 标签，ShellUI 按英文原文查表）
     在 ShellUI 的 Localizable.xcstrings 里都有非空的 en 与 zh-Hans、en 就是键本身、两种语言占位符一致、zh-Hans 里有中文；
     共享 SaveSync（launchers/shared/SaveSync）源码不带中文句子；Mac 启动器 s2arm.cloud.error.* 三个键中英都有、{n} 占位一致、代码都用到
"""
import json, os, pathlib, plistlib, re, shutil, subprocess, sys

H = pathlib.Path(__file__).resolve().parents[1]
SRCS = ['ios/diagzip.m', 'ios/ea_rumble.m', 'ios/extdisplay.m', 'ios/input_config.m', 'ios/play_layout.m', 'ios/prov_expiry.m', 'ios/root_ready.m',   # 11-13 补登：原先没扫，扫过无中文显示串
        'ios/vpad.m', 'ios/vpad_settings.m', 'ios/vpad_layout.m', 'ios/vpad_cheats.m', 'ios/cheats_parse.m', 'ios/vpad_shell.m', 'ios/cpatch_settings.m', 'ios/cpatch_model.m',
        'ios/app.m', 'ios/app_settings.m', 'ios/controller.m', 'ios/diag.m', 'ios/diagredact.m', 'ios/dprompt.m', 'ios/hud.m', 'ios/iml_probe.m',
        'ios/lan_permission.m', 'ios/ldn_lan.m', 'ios/loadpage.m', 'ios/notice.m', 'ios/phone_motion.m', 'ios/save_transfer.m', 'ios/settings.m',
        'ios/textinput.m', 'ios/touch_config.m', 'ios/game_options.m', 'ios/sgrade_style.m', 'ios/sgrade_line.m',
        'ios/ota_download.m', 'ios/ota_place.m']   # blz fork：OTA 下载 / 随包资源包
# 语言按目录自己找（11-13 加繁中 zh-Hant，维护者「任何一种语言缺键就报红」）：ios/l10n/<语言>.lproj 每一种都要有两张表；en 是基准（开发区域），别的语言逐项与 en 比
LANGS = sorted(d.name[:-len('.lproj')] for d in (H / 'ios/l10n').glob('*.lproj'))
TABLES = {l: f'ios/l10n/{l}.lproj/S2ArmHost.strings' for l in LANGS}
INFOPLIST = {l: f'ios/l10n/{l}.lproj/InfoPlist.strings' for l in LANGS}
ZH_LANGS = [l for l in LANGS if l.startswith('zh')]   # 中文表：值要是中文译文
BUILD_MK = 'runtime/build.mk'
MACRO_HEADERS = ['runtime/include/s2a_direct_prompt.h', 'runtime/include/s2a_init_fail.h', 'runtime/include/s2a_selfcheck_page.h', 'runtime/include/s2a_dguard.h']
HOST_TEXT_FILE = 'ios/app.m'   # host_text：C 层递上来的规格文案按 App 语言换 <宏>_EN 的对照表
ROOT_PLIST = 'ios/Settings.bundle/Root.plist'
ROOT_STRINGS_ALL = {l: f'ios/Settings.bundle/{l}.lproj/Root.strings' for l in LANGS if l != 'en'}   # en 就是 Root.plist 原文，别的语言每种一张译文
LOG_CALLS = {'NSLog', 'LOG', 's2a_log', 'fprintf', 'printf'}
CHEATS_CS = '与服务层 Cheats.cs 约定的串（status.txt 状态值 / 条目名，比对与开关键照原样用），显示经 cheat_status_text / cheats.unnamed 换语言'
REDACT = '诊断包脱敏（diag.m redact / diagredact.m）的匹配式与替换占位，只进诊断包给开发者看，不上屏'
IDENT = {   # 文件 → {字面量（源码里的原样，含转义）: 不改的理由}
    'ios/vpad.m': {'提示条': 'setTouchOnly:why: 的原因串，只进日志「触屏布局：切到…」', '未注明': 's2a_vpad_set_touch_only 的原因缺省值，只进日志'},
    'ios/cheats_parse.m': {s: CHEATS_CS for s in ('未命名', '主代码')},
    'ios/vpad_cheats.m': {s: CHEATS_CS for s in ('未命名', '生效中', '生效中（编进游戏）', '地址未就绪', '执行出错', '改代码，不支持', '格式不对', '版本不符', '关', '游戏未装载', '指令有误')},
    'ios/diag.m': {'资源包': '单款包资源目录的真实文件夹名 Documents/资源包（pack_root 拼路径，launchctx / pack_apply 同一个名字）',
                   '<设备名>': REDACT, '\\n…截掉 %lu 字节…\\n': '诊断包里大日志截断处的标记行，只进诊断包'},
    'ios/diagredact.m': {'/Users/<用户>': REDACT, r'[^\\s\"' + "'" + r'<>:=,;{}\\[\\]，。]+的(iPhone|iPad)': REDACT, '[DEVICE_NAME]的$1': REDACT},
    'ios/loadpage.m': {'Documents/资源包': '单款包资源目录的真实路径（读 ctl/control.nacp 取游戏名）'},
    'ios/settings.m': {'Documents/资源包': '单款包资源目录的真实路径（读 ctl/control.nacp 的支持语言标志，同 loadpage.m）', **{s: 'NSException 原因串（启动环境写不进去即抛，进崩溃报告 / 日志），不是界面文字' for s in ('读取画面设置 %s 失败：%s', '重读画面设置 %@ 失败：%s')},
                       '强信号': '能力清单 s2a_caps.tsv 原因列的匹配字样（tools/caps_policy.py 写的「强信号：…」），判满屏改不改得动，不上屏'},
    'ios/game_options.m': {'未命名': CHEATS_CS, **{s: '社区补丁实际结果表 cpatch_status.tsv 的状态值（runtime/src/cpatch.c 写，比对用，显示走 S2AL）' for s in ('不配套', '表不认', '开')}},
}
# ⑥ C 字面量：只进日志 / 诊断的函数（按文件登记，理由写清楚去向）
C_SINKS = {
    'ios/app.m': {'s2a_ios_suspend_enqueue': '前后台切换原因串，只进 host.log「iOS 壳：<原因> → …」与 GPU 闸门日志', 'snprintf': '内存分区 / 客体窗口账的日志行拼接（mem_split_line 与 10 秒心跳行），只进 host.log',
                  'mem_split_line': '内存跳变日志行的标签', 's2a_dump_threads': '线程现场转储的原因，只进 host.log', 's2a_dguard_evidence': '直连安全网失败记录的原因，只进诊断信息（不上屏）',
                  's2a_host_shutdown': '收局原因，只进 host.log', 's2a_boot_rebase': '起局计时日志', 'BOOT_MARK': '起局计时日志', 'die': 'LOG("FATAL …") 后退出（runtime/src/native.h）'},
    'ios/controller.m': {'system_fail_on_queue': '系统手柄震动失败的步骤名，只进日志「系统手柄震动：…」'},
    'ios/ldn_lan.m': {'s2a_lan_permission_failed': '联机失败的步骤名 what，lan_permission.m 只写进日志，弹窗文字走 S2AL'},
    'ios/save_transfer.m': {'s2a_host_shutdown': '收局原因，只进 host.log'},
    'ios/touch_config.m': {'s2a_vpad_set_touch_only': '切方案原因串，只进日志「触屏布局：切到…」'},
}
IDENT_C = {
    'ios/hud.m': {s: '开发浮层（S2A_HUD，设置页「开发」组）的发热档名，拼进 runtime/src/hud.c 整份中文诊断文字，开发者看的诊断' for s in ('正常', '偏热', '热', '过热', '无')},
    'ios/iml_probe.m': {s: '地址档名，只拼进 [IML] 首启复核日志行' for s in ('地址上限读不到', '大地址档', '小地址档')},
}
UI_TEXT_H = 'runtime/include/s2a_ui_text.h'
UI_USERS = ['runtime/src/pack_apply.c', 'runtime/src/ap_host.c', 'runtime/src/hud.c']
UI_STRONG = {'ios/app.m': 's2a_l10n_zh()', 'macos/front_mac.m': 'NSLocale.preferredLanguages'}   # iOS 按 App 本地化；Mac 宿主不带 .lproj，按系统首选语言
DISPLAY_CALLS = {'runtime/src/pack_apply.c': {'s2a_ios_show_notice', 's2a_ios_show_pack_help'}}
DISPLAY_FUNCS = {'runtime/src/pack_apply.c': ['s2a_pack_help_detail', 'help_title', 'gate_show'], 'runtime/src/ap_host.c': ['stall_note'], 'runtime/src/hud.c': ['s2a_hud_brief']}
SAVE_CS = 'services/S2A.Services'
SHELL_DIR = 'shell/Sources/S2ArmShellHost'
SHELL_XCSTRINGS = 'shell/Sources/ShellUI/Resources/Localizable.xcstrings'
SHELL_LOG_CALLS = {'NSLog', 'print'}
SHELL_IDENT = {   # 文件 → {中文字面量开头: 不改的理由}
    'Catalogue.swift': {s: 'Catalogue.problems：清单读不了 / 坏了的原因，只进 NSLog（S2ArmShellHostModel 打日志，shell/UPSTREAM.md「问题只进日志」）'
                        for s in ('清单读不了：', '清单 JSON 坏了：', '清单 schema ', '重复的 title_id ', 'title_id \\"')},
    'S2ArmShellHostModel.swift': {'资源包': '机上目录名 Documents/games/<游戏号>/资源包（runtime/src/pack_apply.c 同名），不是显示文字'},
}
SAVESYNC_DIR = 'launchers/shared/SaveSync/Sources/SaveSync'
MAC_L10N = {'zh': 'launchers/macos/frontend/l10n/zh.json', 'en': 'launchers/macos/frontend/l10n/en.json'}
MAC_CLOUD_SRC = 'launchers/macos/frontend/Sources/NX2Apple/S2ArmLauncherModel+CloudSaves.swift'
EN_CJK = {}   # 原先「<游戏名>资源包」文件夹名照写的三条已随访达拷文件夹那条路删掉（iOS 装机剃刀 #28，11-11）
ENDONYM = {'settings.language.zhHans', 'settings.language.zhHant', 'settings.language.ja', 'settings.language.es', 'settings.language.fr', 'settings.gameLanguage.ja'}   # 界面语言 / 游戏语言选项里语言的自称（简体中文 / 繁體中文 / 日本語）：每种语言表里都照写同一个自称，玩家不认识当前界面语言也认得出自己的语言
CJK = re.compile('[㐀-䶿一-鿿　-〿！（），：；？]')
PH = re.compile(r"%%|%(?:(\d+)\$)?([-+ #0']*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|h|ll|l|q|L|z|j|t)?[@dDuUxXoOfeEgGcCsSpaAF])")

results = []
def ck(name, ok, detail=''):
    results.append(ok)
    print(f'{"通" if ok else "不通"} {name}' + (f'：{detail}' if detail and not ok else ''))

def objc_literals(text, objc=True):
    """跳过注释，返回 (@字面量内容, 行号, 外层调用名集合)；objc=False 改为返回不带 @ 的 C 字面量。调用名取每个未闭合「(」前紧挨的标识符。"""
    out, stack, i, n, line = [], [], 0, len(text), 1
    while i < n:
        c = text[i]
        if c == '\n': line += 1; i += 1
        elif text.startswith('//', i): i = text.find('\n', i) if '\n' in text[i:] else n
        elif text.startswith('/*', i):
            j = text.find('*/', i + 2); j = n if j < 0 else j + 2; line += text.count('\n', i, j); i = j
        elif c == '"' or (c == '@' and i + 1 < n and text[i + 1] == '"'):
            at = c == '@'; j = i + (2 if at else 1); buf = []
            while j < n and text[j] != '"':
                if text[j] == '\\': buf.append(text[j:j + 2]); j += 2
                else: buf.append(text[j]); j += 1
            if at == objc: out.append((''.join(buf), line, {s for s in stack if s}))
            i = j + 1
        elif c == "'":
            j = i + 1
            while j < n and text[j] != "'": j += 2 if text[j] == '\\' else 1
            i = j + 1
        elif c == '(':
            m = re.search(r'([A-Za-z_]\w*)\s*$', text[max(0, i - 64):i]); stack.append(m.group(1) if m else ''); i += 1
        elif c == ')':
            if stack: stack.pop()
            i += 1
        else: i += 1
    return out

def parse_strings(path):
    """解析 "键" = "值"; 的 .strings（含 /* */ 与 // 注释），返回 (有序键值列表, 错误)。"""
    text, i, pairs = path.read_text(encoding='utf-8'), 0, []
    def ws(i):
        while i < len(text):
            if text[i].isspace(): i += 1
            elif text.startswith('/*', i): i = text.index('*/', i) + 2
            elif text.startswith('//', i): i = text.find('\n', i) if '\n' in text[i:] else len(text)
            else: break
        return i
    def qstr(i):
        if text[i] != '"': raise ValueError(f'第 {text.count(chr(10), 0, i) + 1} 行要引号')
        j, buf = i + 1, []
        while text[j] != '"':
            if text[j] == '\\':
                e = text[j + 1]; buf.append({'n': '\n', 't': '\t', '"': '"', '\\': '\\'}.get(e, '\\' + e)); j += 2
            else: buf.append(text[j]); j += 1
        return ''.join(buf), j + 1
    try:
        while True:
            i = ws(i)
            if i >= len(text): break
            k, i = qstr(i); i = ws(i)
            if text[i] != '=': raise ValueError(f'键 {k} 后要 =')
            i = ws(i + 1); v, i = qstr(i); i = ws(i)
            if text[i] != ';': raise ValueError(f'键 {k} 后要 ;')
            pairs.append((k, v)); i += 1
    except (ValueError, IndexError) as e:
        return pairs, str(e) or '格式坏'
    return pairs, None

def placeholders(s):
    seq, out = 0, []
    for m in PH.finditer(s):
        if m.group(0) == '%%': continue
        if m.group(1): pos = int(m.group(1))
        else: seq += 1; pos = seq
        out.append((pos, m.group(2)))
    return sorted(out)

# ① 范围内 .m 无中文 @"…"（注释 / 日志 / 标识串除外）
bad, seen_ident = [], set()
for rel in SRCS:
    for lit, line, calls in objc_literals((H / rel).read_text(encoding='utf-8')):
        if not CJK.search(lit) or calls & LOG_CALLS: continue
        if lit in IDENT.get(rel, {}): seen_ident.add((rel, lit)); continue
        bad.append(f'{rel}:{line} @"{lit[:30]}"')
ck(f'① {len(SRCS)} 个 .m 无显示用中文 @"…" 字面量', not bad, '；'.join(bad[:8]) + (f' 等 {len(bad)} 处' if len(bad) > 8 else ''))
stale = [f'{rel} @"{lit}"' for rel, d in IDENT.items() for lit in d if (rel, lit) not in seen_ident]
ck(f'① 标识串清单 {sum(map(len, IDENT.values()))} 条都还在代码里（没有过期豁免）', not stale, '；'.join(stale))

# ② 代码键 ⊆ 两表、两表同集、无孤儿、无重复
used, nonlit = set(), []
for rel in SRCS:
    t = (H / rel).read_text(encoding='utf-8')
    for m in re.finditer(r'\bS2AL\(\s*(@"([^"\\]+)")?', t):
        if m.group(2): used.add(m.group(2))
        else: nonlit.append(f'{rel}:{t.count(chr(10), 0, m.start()) + 1}')
ck(f'② 每个 S2AL 的参数都是 @"键" 字面量（{len(used)} 个键）', not nonlit and bool(used), '；'.join(nonlit) or ('一个都没找到' if not used else ''))
tables = {}
for lang, rel in TABLES.items():
    pairs, err = parse_strings(H / rel)
    keys = [k for k, _ in pairs]; dup = sorted({k for k in keys if keys.count(k) > 1})
    ck(f'② {lang} 表可解析、无重复键（{len(pairs)} 条）', err is None and not dup, err or '重复：' + ' '.join(dup))
    tables[lang] = dict(pairs)
for lang, t in tables.items():
    miss = sorted(used - t.keys())
    ck(f'② 代码用到的键在 {lang} 表都有', not miss, ' '.join(miss[:10]))
ck(f'② 语言表齐全：{" / ".join(LANGS)}（至少 en 与 zh-Hans）', {'en', 'zh-Hans'} <= set(LANGS), '')
en = tables['en']
for lang, t in tables.items():
    if lang == 'en': continue
    ck(f'② en / {lang} 两表键集合相同（缺键即红）', en.keys() == t.keys(), f'{lang} 缺：{sorted(en.keys() - t.keys())[:5]} {lang} 多：{sorted(t.keys() - en.keys())[:5]}')
orphan = sorted(set().union(*(t.keys() for t in tables.values())) - used)
ck('② 表里没有代码不用的孤儿键', not orphan, ' '.join(orphan[:10]))
empty = sorted(k for t in tables.values() for k, v in t.items() if not v.strip())
ck('② 各表没有空值', not empty, ' '.join(empty[:10]))

# ③ 占位符一致
for lang, t in tables.items():
    if lang == 'en': continue
    diff = [f'{k}: en {placeholders(en[k])} / {lang} {placeholders(t[k])}' for k in sorted(en.keys() & t.keys()) if placeholders(en[k]) != placeholders(t[k])]
    nfmt = sum(1 for k in en.keys() & t.keys() if placeholders(en[k]))
    ck(f'③ en / {lang} 同键格式占位符一致（{len(en.keys() & t.keys())} 个键，其中 {nfmt} 个含占位符）', not diff, '；'.join(diff[:5]))
for lang in ZH_LANGS:
    notzh = sorted(k for k, v in tables[lang].items() if not CJK.search(v) and CJK.search(tables['zh-Hans'].get(k, '')))
    ck(f'③ {lang} 表在简中是中文的条目也都是中文译文', not notzh, ' '.join(notzh[:8]))

# ④ Settings.bundle
specs = plistlib.loads((H / ROOT_PLIST).read_bytes())['PreferenceSpecifiers']
texts = []
for s in specs:
    texts += [s[f] for f in ('Title', 'FooterText') if f in s] + list(s.get('Titles', []))
cjk = [t[:20] for t in texts if CJK.search(t)]
ck(f'④ Root.plist 显示文字 {len(texts)} 条无中文（原文英文）', not cjk, '；'.join(cjk[:5]))
need = {t for t in texts if re.search('[A-Za-z]', t)}
for lang, rel in ROOT_STRINGS_ALL.items():
    rpairs, rerr = parse_strings(H / rel); root = dict(rpairs)
    miss, extra = sorted(need - root.keys()), sorted(root.keys() - set(texts))
    ck(f'④ Root.plist 含字母的 {len(need)} 条在 {lang} Root.strings 都有翻译', rerr is None and not miss, rerr or '；'.join(m[:30] for m in miss[:5]))
    ck(f'④ {lang} Root.strings {len(root)} 条没有多余键、无重复', rerr is None and not extra and len(rpairs) == len(root), '；'.join(e[:30] for e in extra[:5]) or ('有重复键' if len(rpairs) != len(root) else ''))

# ⑤ plutil -lint
lint = [*TABLES.values(), *INFOPLIST.values(), *ROOT_STRINGS_ALL.values(), ROOT_PLIST]
if shutil.which('plutil') and sys.platform == 'darwin':
    r = subprocess.run(['plutil', '-lint', *lint], cwd=H, capture_output=True, text=True)
    ck(f'⑤ plutil -lint {len(lint)} 个文件', r.returncode == 0, (r.stdout + r.stderr).strip().replace('\n', '；') if r.returncode else '')
else:
    print(f'跳过 ⑤ plutil -lint（本机不是 macOS，没有 plutil）')

# ⑥ 中文 C 字面量只许进日志 / 登记过的只进日志的函数
cbad, seen_c, seen_sink = [], set(), set()
for rel in SRCS:
    sinks = C_SINKS.get(rel, {})
    for lit, line, calls in objc_literals((H / rel).read_text(encoding='utf-8'), objc=False):
        if not CJK.search(lit) or calls & LOG_CALLS: continue
        hit = calls & sinks.keys()
        if hit: seen_sink |= {(rel, s) for s in hit}; continue
        if lit in IDENT_C.get(rel, {}): seen_c.add((rel, lit)); continue
        cbad.append(f'{rel}:{line} "{lit[:30]}"')
ck(f'⑥ {len(SRCS)} 个 .m 的中文 C 字面量都只进日志 / 诊断', not cbad, '；'.join(cbad[:8]) + (f' 等 {len(cbad)} 处' if len(cbad) > 8 else ''))
cstale = [f'{rel} {s}()' for rel, d in C_SINKS.items() for s in d if (rel, s) not in seen_sink]
cstale += [f'{rel} "{lit}"' for rel, d in IDENT_C.items() for lit in d if (rel, lit) not in seen_c]
ck(f'⑥ 只进日志的函数 {sum(map(len, C_SINKS.values()))} 个、C 豁免串 {sum(map(len, IDENT_C.values()))} 条都还在用（没有过期豁免）', not cstale, '；'.join(cstale))

# ⑦ C 宏文案：都有 <宏>_EN；宿主只经 S2APICK / S2APICKC / host_text 对照表用
hmacros = {}
for rel in MACRO_HEADERS:
    for name, _ in re.findall(r'#define\s+(S2A_[A-Z0-9_]+)\s+"((?:[^"\\]|\\.)*)"', (H / rel).read_text(encoding='utf-8')):
        hmacros[name] = rel
texts_m = {n for n in hmacros if not n.endswith('_EN')}
noen = sorted(n for n in texts_m if n + '_EN' not in hmacros)
ck(f'⑦ {len(MACRO_HEADERS)} 个头文件的 {len(texts_m)} 个文案宏都有 <宏>_EN', not noen and bool(texts_m), ' '.join(noen))
mbad, nuse = [], 0
for rel in SRCS:
    src = re.sub(r'//[^\n]*|/\*.*?\*/', '', (H / rel).read_text(encoding='utf-8'), flags=re.S)
    for m in re.finditer(r'\b(S2A_[A-Z0-9_]+)\b', src):
        name = m.group(1)
        if name not in texts_m: continue
        nuse += 1
        before, after = src[max(0, m.start() - 9):m.start()], src[m.end():m.end() + len(name) + 8]
        if re.search(r'S2APICKC?\($', before) or re.match(r'\s*,\s*' + name + r'_EN\s*\}', after): continue
        mbad.append(f'{rel}:{src.count(chr(10), 0, m.start()) + 1} {name}')
ck(f'⑦ 宿主用到文案宏的 {nuse} 处都经 S2APICK / S2APICKC / 对照表', not mbad and nuse > 0, '；'.join(mbad[:8]))
pairs_ht = set(re.findall(r'\{(S2A_[A-Z0-9_]+),\s*\1_EN\}', (H / HOST_TEXT_FILE).read_text(encoding='utf-8')))
need_ht = {n for n in texts_m if n.startswith('S2A_SELFCHECK_') or n.startswith('S2A_INIT_FAIL_MSG_') or n == 'S2A_INIT_FAIL_NEXT'}
ck(f'⑦ C 层递上来的 {len(need_ht)} 句（自检提示页、初启失败页原因与下一步）都在 host_text 对照表', need_ht <= pairs_ht, ' '.join(sorted(need_ht - pairs_ht)))

# ⑧ en 表不含中文（真实文件夹名除外）
encjk = sorted(k for k, v in en.items() if k not in ENDONYM and CJK.search(v.replace('资源包', '') if k in EN_CJK else v))
ck(f'⑧ en 表 {len(en)} 条不含中文（{len(EN_CJK)} 条照写「…资源包」文件夹名）', not encjk, ' '.join(encjk[:10]))
stale_en = sorted(k for k in EN_CJK if k not in en or '资源包' not in en[k])
endo = sorted(k for k in ENDONYM if len({t.get(k) for t in tables.values()}) != 1 or k not in en)
ck(f'⑧ 语言自称 {len(ENDONYM)} 条在各语言表照写同一个值', not endo, ' '.join(endo))
ck('⑧ 文件夹名豁免键都还在、且确实含「资源包」', not stale_en, ' '.join(stale_en))

# ⑨ InfoPlist.strings：两表同键、键都是 build.mk 写进 Info.plist 的、主值英文
ip = {}
for lang, rel in INFOPLIST.items():
    pairs, err = parse_strings(H / rel)
    ck(f'⑨ {lang} InfoPlist.strings 可解析、非空、无重复（{len(pairs)} 条）', err is None and pairs and len(pairs) == len(dict(pairs)), err or '空或有重复键')
    ip[lang] = dict(pairs)
for lang in LANGS:
    if lang == 'en': continue
    ck(f'⑨ InfoPlist.strings en / {lang} 键集合相同', ip['en'].keys() == ip[lang].keys(), f"只在 en：{sorted(ip['en'].keys() - ip[lang].keys())} 只在 {lang}：{sorted(ip[lang].keys() - ip['en'].keys())}")
mk = (H / BUILD_MK).read_text(encoding='utf-8')
main = dict(re.findall(r'plutil -insert (NS\w+UsageDescription) -string "([^"]*)"', mk))
ck(f'⑨ InfoPlist.strings 的键都是 build.mk 写进 Info.plist 的权限说明（{len(main)} 个）', set(ip['en']) == set(main),
   f"表多：{sorted(set(ip['en']) - set(main))} build.mk 多：{sorted(set(main) - set(ip['en']))}")
ck('⑨ Info.plist 权限说明主值英文、与 en 表逐字一致', all(not CJK.search(v) and ip['en'].get(k) == v for k, v in main.items()),
   '；'.join(f'{k}={v[:30]}' for k, v in main.items() if CJK.search(v) or ip['en'].get(k) != v))
for lang in ZH_LANGS:
    cjk_ip = sorted(k for k, v in ip[lang].items() if not CJK.search(v))
    ck(f'⑨ {lang} InfoPlist.strings 每条都是中文译文', not cjk_ip, ' '.join(cjk_ip))

# ⑩ C 层显示文字：s2a_ui_text.h 中英配对、只经 S2A_UI 取、显示路径无中文字面量
uih = (H / UI_TEXT_H).read_text(encoding='utf-8')
ui = dict((n, re.sub(r'\\(.)', r'\1', v)) for n, v in re.findall(r'#define\s+(S2A_UI_[A-Z0-9_]+)\s+"((?:[^"\\]|\\.)*)"', uih))
ui_text = sorted(n for n in ui if not n.endswith('_EN'))
ck(f'⑩ s2a_ui_text.h 的 {len(ui_text)} 个文案宏都有 _EN', bool(ui_text) and all(n + '_EN' in ui for n in ui_text), ' '.join(n for n in ui_text if n + '_EN' not in ui))
ck('⑩ _EN 不含中文（照写的「资源包」除外）、中文原宏含中文', all(not CJK.search(ui[n + '_EN'].replace('资源包', '')) and CJK.search(ui[n]) for n in ui_text if n + '_EN' in ui),
   ' '.join(n for n in ui_text if n + '_EN' in ui and (CJK.search(ui[n + '_EN'].replace('资源包', '')) or not CJK.search(ui[n]))))
ck('⑩ 中英两份格式占位符一致', all(placeholders(ui[n]) == placeholders(ui[n + '_EN']) for n in ui_text if n + '_EN' in ui),
   ' '.join(n for n in ui_text if n + '_EN' in ui and placeholders(ui[n]) != placeholders(ui[n + '_EN'])))
strip_c = lambda s: re.sub(r'//[^\n]*|/\*.*?\*/', '', s, flags=re.S)
uses, ubad = {}, []
for rel in UI_USERS + [f for f in SRCS]:
    src = strip_c((H / rel).read_text(encoding='utf-8'))
    for m in re.finditer(r'\b(S2A_UI_[A-Z0-9_]+?)(_EN)?\b', src):
        if m.group(2) or m.group(1) not in ui: continue   # 只认 s2a_ui_text.h 定义的文案宏（环境变量名 S2A_UI_LANGUAGE 这类同前缀的字串不算）
        uses[m.group(1)] = uses.get(m.group(1), 0) + 1
        if not re.search(r'S2A_UI\($', src[max(0, m.start() - 7):m.start()]): ubad.append(f'{rel}:{src.count(chr(10), 0, m.start()) + 1} {m.group(1)}')
ck(f'⑩ 文案宏 {len(ui_text)} 个都被用到', set(ui_text) <= set(uses), ' '.join(sorted(set(ui_text) - set(uses))))
ck(f'⑩ 用到的 {sum(uses.values())} 处都经 S2A_UI(…)', not ubad and bool(uses), '；'.join(ubad[:8]))
weak = r'__attribute__\(\(weak\)\)\s*int\s+s2a_ui_zh\(void\)\s*\{\s*return 1;\s*\}'
nweak = [rel for rel in UI_USERS if 'S2A_UI(' in (H / rel).read_text(encoding='utf-8') and not re.search(weak, (H / rel).read_text(encoding='utf-8'))]
ck(f'⑩ 用 S2A_UI 的 {len(UI_USERS)} 个 .c 各带 s2a_ui_zh 弱缺省（返回 1 = 中文）', not nweak, ' '.join(nweak))
nstrong = [rel for rel, how in UI_STRONG.items() if not re.search(r'^int s2a_ui_zh\(void\) \{[^\n]*' + re.escape(how), (H / rel).read_text(encoding='utf-8'), re.M)]
ck('⑩ iOS（ios/app.m，App 语言）与 Mac（macos/front_mac.m，系统首选语言）各有 s2a_ui_zh 强定义', not nstrong, ' '.join(nstrong))
dbad = []
for rel, calls in DISPLAY_CALLS.items():
    for lit, line, cs in objc_literals((H / rel).read_text(encoding='utf-8'), objc=False):
        if CJK.search(lit) and cs & calls: dbad.append(f'{rel}:{line} "{lit[:24]}"')
for rel, funcs in DISPLAY_FUNCS.items():
    src = (H / rel).read_text(encoding='utf-8')
    for fn in funcs:
        m = re.search(r'^[^\n;]*\b' + fn + r'\([^)]*\)\s*\{', src, re.M)
        if not m: dbad.append(f'{rel} 找不到函数 {fn}'); continue
        depth, i = 0, m.end() - 1
        while True:
            depth += {'{': 1, '}': -1}.get(src[i], 0); i += 1
            if depth == 0: break
        for lit, line, cs in objc_literals(src[m.start():i], objc=False):
            if CJK.search(lit) and not cs & LOG_CALLS: dbad.append(f'{rel} {fn}() "{lit[:24]}"')
ck(f'⑩ 显示路径（{sum(map(len, DISPLAY_CALLS.values()))} 个调用、{sum(map(len, DISPLAY_FUNCS.values()))} 个函数）没有中文 C 字面量', not dbad, '；'.join(dbad[:8]))

# ⑪ 服务层存档说明：中文都在 T("中文", "English") 里
cs_bad, cs_pairs = [], {}
for f in sorted((H / SAVE_CS).glob('SaveTransfer*.cs')):
    for i, line in enumerate(f.read_text(encoding='utf-8').split('\n'), 1):
        if line.lstrip().startswith('//') or 'Console.' in line: continue
        for zh_s, en_s in re.findall(r'\bT\("((?:[^"\\]|\\.)*)", "((?:[^"\\]|\\.)*)"\)', line):
            cs_pairs.setdefault(zh_s, set()).add(en_s)
            if not CJK.search(zh_s) or not en_s.strip() or CJK.search(en_s): cs_bad.append(f'{f.name}:{i} T("{zh_s[:16]}", "{en_s[:16]}")')
        code = re.sub(r'\bT\("(?:[^"\\]|\\.)*", "(?:[^"\\]|\\.)*"\)', 'T()', line)
        cm = re.search(r'\s//', code)
        if cm and code[:cm.start()].count('"') % 2 == 0: code = code[:cm.start()]
        if '\\"ok\\"' in code and 'save_internal' in code: continue   # 桥接失败的整段 JSON 字面量：按 SaveTransfer.English 二选一，下面单独核
        if CJK.search(code): cs_bad.append(f'{f.name}:{i} {code.strip()[:40]}')
exp = (H / SAVE_CS / 'SaveTransferExports.cs').read_text(encoding='utf-8')
bridge = re.findall(r'save_internal\\",\\"message\\":\\"((?:[^"\\]|\\.)*?)\\"', exp)
ck(f'⑪ 存档服务层 {sum(len(v) for v in cs_pairs.values())} 句说明都经 T(中文, 英文)、英文无中文（stderr 日志除外）', not cs_bad and len(cs_pairs) > 50, '；'.join(cs_bad[:6]))
ck('⑪ 同一句中文只对应一句英文', all(len(v) == 1 for v in cs_pairs.values()), '；'.join(k[:16] for k, v in cs_pairs.items() if len(v) > 1))
ck('⑪ 桥接失败兜底 JSON 中英各一份（按 SaveTransfer.English 选）', len(bridge) == 2 and CJK.search(bridge[1]) and not CJK.search(bridge[0]) and 'SaveTransfer.English ?' in exp, str(bridge))

# ⑫ 游戏库 / iCloud 同步页（Swift）
def swift_literals(text):
    """跳过注释，返回 (字面量原文, 行号, 外层调用名集合)；插值 \\( … ) 里的嵌套字面量不单列（整句算一条）"""
    out, stack, i, n, line = [], [], 0, len(text), 1
    while i < n:
        c = text[i]
        if c == '\n': line += 1; i += 1
        elif text.startswith('//', i): i = text.find('\n', i) if '\n' in text[i:] else n
        elif text.startswith('/*', i): j = text.find('*/', i + 2); j = n if j < 0 else j + 2; line += text.count('\n', i, j); i = j
        elif c == '"':
            j, depth = i + 1, 0
            while j < n:
                if text.startswith('\\(', j): depth += 1; j += 2; continue
                if depth and text[j] == '(': depth += 1
                elif depth and text[j] == ')': depth -= 1
                elif text[j] == '\\': j += 2; continue
                elif text[j] == '"' and not depth: break
                j += 1
            out.append((text[i + 1:j], line, {s for s in stack if s})); i = j + 1
        elif c == '(':
            m = re.search(r'([A-Za-z_]\w*)\s*$', text[max(0, i - 64):i]); stack.append(m.group(1) if m else ''); i += 1
        elif c == ')':
            if stack: stack.pop()
            i += 1
        else: i += 1
    return out
def swift_key(lit):   # shellText 的键：插值按 %@，转义还原
    s = re.sub(r'\\\((?:[^()]|\([^()]*\))*\)', '%@', lit)
    return re.sub(r'\\(.)', r'\1', s)
xc = json.loads((H / SHELL_XCSTRINGS).read_text(encoding='utf-8'))['strings']
def xval(k, lang): return ((xc.get(k) or {}).get('localizations', {}).get(lang) or {}).get('stringUnit', {}).get('value', '')
shbad, shkeys, seen_sh = [], set(), set()
for f in sorted((H / SHELL_DIR).glob('*.swift')):
    src = f.read_text(encoding='utf-8')
    for lit, line, calls in swift_literals(src):
        if 'shellText' in calls and not calls & SHELL_LOG_CALLS and re.search(r'shellText\(\s*"' + re.escape(lit) + '"', src): shkeys.add(swift_key(lit))
        if not CJK.search(lit) or calls & SHELL_LOG_CALLS: continue
        hit = [p for p in SHELL_IDENT.get(f.name, {}) if lit.startswith(p)]
        if hit: seen_sh |= {(f.name, p) for p in hit}; continue
        shbad.append(f'{f.name}:{line} "{lit[:24]}"')
gs = (H / SHELL_DIR / 'S2ArmGameSettings.swift').read_text(encoding='utf-8')
setting_keys = set(re.findall(r'\b(?:title|label|note): "([^"\\]+)"', gs)) | set(re.findall(r'SettingOption\([^,()]+, "([^"\\]+)"\)', gs))
for pair in re.findall(r'SettingOption\("[^"]+", [^()"]*\? "([^"\\]+)" : "([^"\\]+)"\)', gs): setting_keys |= set(pair)   # SettingOption("current", 已自定义 ? "…" : "…")
ck(f'⑫ 游戏库 Swift（{len(list((H / SHELL_DIR).glob("*.swift")))} 个文件）没有显示用中文字面量', not shbad, '；'.join(shbad[:8]))
shstale = [f'{fn} "{p}"' for fn, d in SHELL_IDENT.items() for p in d if (fn, p) not in seen_sh]
ck(f'⑫ 游戏库豁免 {sum(map(len, SHELL_IDENT.values()))} 条都还在代码里', not shstale, '；'.join(shstale))
allk = shkeys | setting_keys
miss = sorted(k for k in allk if not (xval(k, 'en') and xval(k, 'zh-Hans')))
ck(f'⑫ 用到的 {len(shkeys)} 个 shellText 键、{len(setting_keys)} 个设置行标签在 xcstrings 里都有 en 与 zh-Hans', bool(shkeys) and bool(setting_keys) and not miss, ' | '.join(miss[:6]))
bad_en = sorted(k for k in allk if xval(k, 'en') and xval(k, 'en') != k)
ck('⑫ 这些键的 en 值就是键本身（键 = 英文原文）', not bad_en, ' | '.join(bad_en[:6]))
bad_ph = sorted(k for k in allk if xval(k, 'zh-Hans') and placeholders(xval(k, 'en')) != placeholders(xval(k, 'zh-Hans')))
ck('⑫ 中英格式占位符一致', not bad_ph, ' | '.join(bad_ph[:6]))
bad_zh = sorted(k for k in allk if xval(k, 'zh-Hans') and not CJK.search(xval(k, 'zh-Hans')) and k not in ('60 FPS',))
ck('⑫ zh-Hans 值是中文译文', not bad_zh, ' | '.join(bad_zh[:6]))
ss = [f'{f.name}:{line}' for f in sorted((H / SAVESYNC_DIR).glob('*.swift')) for lit, line, calls in swift_literals(f.read_text(encoding='utf-8')) if CJK.search(lit) and not calls & SHELL_LOG_CALLS]
ck('⑫ 共享 SaveSync 源码不带中文句子（文字归显示端）', not ss, ' '.join(ss))
mac = {lang: json.loads((H / rel).read_text(encoding='utf-8')) for lang, rel in MAC_L10N.items()}
mk_keys = ['s2arm.cloud.error.notDownloaded', 's2arm.cloud.error.corrupt', 's2arm.cloud.error.writeBack']
msrc = (H / MAC_CLOUD_SRC).read_text(encoding='utf-8')
ck('⑫ Mac s2arm.cloud.error.* 中英都有、{n} 占位一致、代码都用到', all(k in mac['zh'] and k in mac['en'] and sorted(re.findall(r'\{\d\}', mac['zh'][k])) == sorted(re.findall(r'\{\d\}', mac['en'][k]))
   and CJK.search(mac['zh'][k]) and not CJK.search(mac['en'][k]) and f'"{k}"' in msrc for k in mk_keys), ' '.join(k for k in mk_keys if k not in mac['zh'] or k not in mac['en'] or f'"{k}"' not in msrc))

fails = results.count(False)
print(f'{"✓" if not fails else "✗"} ios_l10n：{len(results)} 项断言，{fails} 项不通（扫 {len(SRCS)} 个 .m、代码用 {len(used)} 个键、设置页 {len(texts)} 条文字）')
sys.exit(1 if fails else 0)
