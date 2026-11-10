#!/usr/bin/env python3
"""iOS 宿主界面本地化（#316）单测：游戏内菜单 / 触屏布局 / 金手指 / 社区补丁页的文字走 S2AL(@"键")（ios/s2a_l10n.h），
字符串表 ios/l10n/{en,zh-Hans}.lproj/S2ArmHost.strings；iOS「设置」App 的 S2Arm 页 Root.plist 原文英文、zh-Hans.lproj/Root.strings 译中文。
期望按规则手写，不跑被测代码：
  ① ios/ 下全部 .m（11-10 起，原先只扫 7 个）里，除注释与日志调用（NSLog / LOG / s2a_log / fprintf / printf）外，不再有含中文的 @"…" 字面量；
     与别的代码比对的标识串（金手指条目名 / 状态值是与服务层 Cheats.cs 约定的串、切换原因只进日志）列在 IDENT 里，逐条写明理由，且必须真的还在
  ② 代码里每个 S2AL 的参数都是 @"键" 字面量；每个键在 en / zh-Hans 两表都有；两表键集合相同、无重复键；表里没有代码不用的孤儿键
  ③ 同一个键两表的格式占位符（%@ %d %.1f %1$@ …，按位置归一）一致
  ④ Root.plist 显示文字（Title / FooterText / Titles）无中文；含字母的每条在 Root.strings 里都有翻译，Root.strings 没有多余键
  ⑤ 两张 S2ArmHost.strings 与 Root.strings（连同 Root.plist）过 plutil -lint
"""
import os, pathlib, plistlib, re, shutil, subprocess, sys

H = pathlib.Path(__file__).resolve().parents[1]
# 11-10 英文默认（维护者：英文设备上看到中文）：扫 ios/ 下全部 .m（输入工作台 ios/lab/ 是开发自用，不在内）
SRCS = sorted(str(p.relative_to(H)) for p in H.glob('ios/*.m'))
KEY_ONLY = []
TABLES = {'en': 'ios/l10n/en.lproj/S2ArmHost.strings', 'zh-Hans': 'ios/l10n/zh-Hans.lproj/S2ArmHost.strings'}
ROOT_PLIST, ROOT_STRINGS = 'ios/Settings.bundle/Root.plist', 'ios/Settings.bundle/zh-Hans.lproj/Root.strings'
LOG_CALLS = {'NSLog', 'LOG', 's2a_log', 'fprintf', 'printf'}
CHEATS_CS = '与服务层 Cheats.cs 约定的串（status.txt 状态值 / 条目名，比对与开关键照原样用），显示经 cheat_status_text / cheats.unnamed 换语言'
IDENT = {   # 文件 → {字面量: 不改的理由}
    'ios/vpad.m': {'提示条': 'setTouchOnly:why: 的原因串，只进日志「触屏布局：切到…」', '未注明': 's2a_vpad_set_touch_only 的原因缺省值，只进日志'},
    'ios/ota_download.m': {'资源包': '设备侧资源包目录名（推送契约 tools/push_pack.py / runtime/src/pack_apply.c 同名路径段），不显示'},
    'ios/ota_place.m': {'资源包': '设备侧资源包目录名（推送契约 tools/push_pack.py / runtime/src/pack_apply.c 同名路径段），不显示'},
    'ios/diag.m': {'资源包': '设备侧资源包目录名（推送契约 tools/push_pack.py / runtime/src/pack_apply.c 同名路径段），不显示', '<设备名>': '诊断包里替换设备名的占位，写进诊断文件、不上屏', '\\n…截掉 %lu 字节…\\n': '截断日志时写进诊断文件的标记，不上屏'},
    'ios/loadpage.m': {'Documents/资源包': '资源包目录路径（同上），不显示'},
    'ios/notice.m': {'%@资源包': '拼出设备上真实的资源包目录名（Mac 启动器导出的「<App 名>资源包」），作为参数填进译好的句子'},
    'ios/diagredact.m': {'/Users/<用户>': '诊断脱敏替换串，写进诊断文件', '[^\\\\s\\"\'<>:=,;{}\\\\[\\\\]，。]+的(iPhone|iPad)': '脱敏正则（匹配中文设备名「某某的 iPhone」）', '[DEVICE_NAME]的$1': '脱敏替换串，写进诊断文件'},
    'ios/settings.m': {'读取画面设置 %s 失败：%s': 'NSException 原因，只进崩溃 / 诊断', '重读画面设置 %@ 失败：%s': 'NSException 原因，只进崩溃 / 诊断'},
    'ios/vpad_cheats.m': {s: CHEATS_CS for s in ('未命名', '主代码', '生效中', '地址未就绪', '执行出错', '改代码，不支持', '格式不对', '版本不符', '关', '游戏未装载', '指令有误')},
}
CJK = re.compile('[㐀-䶿一-鿿　-〿！（），：；？]')
PH = re.compile(r"%%|%(?:(\d+)\$)?([-+ #0']*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|h|ll|l|q|L|z|j|t)?[@dDuUxXoOfeEgGcCsSpaAF])")

results = []
def ck(name, ok, detail=''):
    results.append(ok)
    print(f'{"通" if ok else "不通"} {name}' + (f'：{detail}' if detail and not ok else ''))

def objc_literals(text):
    """跳过注释，返回 (@字面量内容, 行号, 外层调用名集合)。调用名取每个未闭合「(」前紧挨的标识符。"""
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
            if at: out.append((''.join(buf), line, {s for s in stack if s}))
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
for rel in SRCS + KEY_ONLY:
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
en, zh = tables['en'], tables['zh-Hans']
ck('② en / zh-Hans 两表键集合相同', en.keys() == zh.keys(), f'只在 en：{sorted(en.keys() - zh.keys())[:5]} 只在 zh-Hans：{sorted(zh.keys() - en.keys())[:5]}')
orphan = sorted((en.keys() | zh.keys()) - used)
ck('② 表里没有代码不用的孤儿键', not orphan, ' '.join(orphan[:10]))
empty = sorted(k for t in tables.values() for k, v in t.items() if not v.strip())
ck('② 两表没有空值', not empty, ' '.join(empty[:10]))

# ③ 占位符一致
diff = [f'{k}: en {placeholders(en[k])} / zh {placeholders(zh[k])}' for k in sorted(en.keys() & zh.keys()) if placeholders(en[k]) != placeholders(zh[k])]
nfmt = sum(1 for k in en.keys() & zh.keys() if placeholders(en[k]))
ck(f'③ 两表同键格式占位符一致（{len(en.keys() & zh.keys())} 个键，其中 {nfmt} 个含占位符）', not diff, '；'.join(diff[:5]))

# ④ Settings.bundle
specs = plistlib.loads((H / ROOT_PLIST).read_bytes())['PreferenceSpecifiers']
texts = []
for s in specs:
    texts += [s[f] for f in ('Title', 'FooterText') if f in s] + list(s.get('Titles', []))
cjk = [t[:20] for t in texts if CJK.search(t)]
ck(f'④ Root.plist 显示文字 {len(texts)} 条无中文（原文英文）', not cjk, '；'.join(cjk[:5]))
rpairs, rerr = parse_strings(H / ROOT_STRINGS); root = dict(rpairs)
need = {t for t in texts if re.search('[A-Za-z]', t)}
miss, extra = sorted(need - root.keys()), sorted(root.keys() - set(texts))
ck(f'④ Root.plist 含字母的 {len(need)} 条在 Root.strings 都有翻译', rerr is None and not miss, rerr or '；'.join(m[:30] for m in miss[:5]))
ck(f'④ Root.strings {len(root)} 条没有多余键、无重复', rerr is None and not extra and len(rpairs) == len(root), '；'.join(e[:30] for e in extra[:5]) or ('有重复键' if len(rpairs) != len(root) else ''))

# ⑤ plutil -lint
lint = [TABLES['en'], TABLES['zh-Hans'], ROOT_STRINGS, ROOT_PLIST]
if shutil.which('plutil') and sys.platform == 'darwin':
    r = subprocess.run(['plutil', '-lint', *lint], cwd=H, capture_output=True, text=True)
    ck(f'⑤ plutil -lint {len(lint)} 个文件', r.returncode == 0, (r.stdout + r.stderr).strip().replace('\n', '；') if r.returncode else '')
else:
    print(f'跳过 ⑤ plutil -lint（本机不是 macOS，没有 plutil）')

fails = results.count(False)
print(f'{"✓" if not fails else "✗"} ios_l10n：{len(results)} 项断言，{fails} 项不通（扫 {len(SRCS)} 个 .m、代码用 {len(used)} 个键、设置页 {len(texts)} 条文字）')
sys.exit(1 if fails else 0)
