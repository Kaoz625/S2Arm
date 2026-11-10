#!/usr/bin/env python3
"""共享体验规格自检（launchers/shared/experience.v1.json）。

四端都读同一份规格，所以规格本身的错要在合入前就抓到：
1. 结构：状态 / 动作 / 转换 / 错误码互相引用必须成立，不允许悬空 id；
2. 覆盖：issue #187 要求的状态机六态 + 失败 / 恢复分支必须在；
3. 唯一来源：errors 的码集合 == pack/jobs/errors.py 的 RECOVERY 键集合（外加 artifact_invalid），
   「下一步」只写来源指针，不写第二份文案；
4. 一致性：prompts 的横幅文案与 runtime/include/s2a_direct_prompt.h 的宏**逐字**相同；条目带 en 时头文件要有 <宏>_EN 且与 en 逐字相同（游戏内中英同屏的文案）；
5. 一致性：stage_labels 的键与 pack/contracts/protocol.py 的 STAGES 右值集合相同；
6. 一致性：出包画面模式两句与 ios/settings.m 逐字相同；Mac 消费共享标签与资源，
   Localizable.json 不再复制共享文本；
7. 一致性：init_fail_page（iOS 初启失败页）的文案与 runtime/include/s2a_init_fail.h 的宏逐字相同、
   codes 与头文件 S2A_INIT_FAIL_CODES 一一对应（码 id、枚举名、话术归类），每句带中英文且不进 Localizable.json；
8. 一致性：selfcheck_page（iOS 起局自检不过的提示页）的文案与 runtime/include/s2a_selfcheck_page.h 的宏逐字相同、
   宏集合一一对应，每句带中英文且不进 Localizable.json。

所有比对都从源文件读，不在本脚本里手抄字符串。

用法：python3 launchers/shared/check_experience.py [-v]
退出码 0 = 全过；1 = 有断言失败。
"""
from __future__ import annotations

import importlib.util
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = Path(__file__).resolve().parent / "experience.v1.json"
HEADER = ROOT / "runtime" / "include" / "s2a_direct_prompt.h"
INIT_FAIL_H = ROOT / "runtime" / "include" / "s2a_init_fail.h"
SELFCHECK_H = ROOT / "runtime" / "include" / "s2a_selfcheck_page.h"
PROTOCOL = ROOT / "pack" / "contracts" / "protocol.py"
ERRORS_PY = ROOT / "pack" / "jobs" / "errors.py"
IOS_SETTINGS_M = ROOT / "ios" / "settings.m"
MAC_PACK_MODE_SWIFT = ROOT / "launchers" / "macos" / "Sources" / "S2ArmLauncher" / "PackMode.swift"
ADAPTER = ROOT / "launchers" / "macos" / "adapter"
LOCALIZABLE = ADAPTER / "Sources" / "S2ArmAppleAdapter" / "Resources" / "Localizable.json"

REQUIRED_STATES = ["idle", "keys_missing", "importing", "preparing", "ready", "running", "failed", "recovering"]
REQUIRED_LANGS = ["zh-Hans", "en"]
ERROR_KEYS = {"code", "title", "detail", "severity", "retryable", "recoverable", "next_action"}
# 不是 RECOVERY 的键，但确实是出包链抛出的码（pack/targets/ios/adapter.py），恢复口径在 pack/contracts/README.md
EXTRA_CODES = {"artifact_invalid"}
EXTRA_CODE_SOURCES = {"artifact_invalid": "pack/contracts/README.md"}
# 终态不是错误码（job.succeeded / job.cancelled），归 event_map.terminal_results
TERMINAL_CODES = {"job.succeeded", "job.cancelled"}

fails: list[str] = []
checks = 0


def ok(cond: bool, msg: str) -> None:
    global checks
    checks += 1
    if not cond:
        fails.append(msg)


def text_field(node: dict, where: str, keys=("title", "detail")) -> None:
    """一条文案要么是 {zh-Hans, en} 双语，要么是只有源语言的字符串。"""
    for key in keys:
        if key not in node:
            continue
        value = node[key]
        if isinstance(value, str):
            ok(value.strip() != "", f"{where}: {key} 是空串")
            continue
        for lang in REQUIRED_LANGS:
            ok(lang in value and str(value[lang]).strip() != "", f"{where}: {key} 缺 {lang}")


def load_recovery() -> dict:
    """直接 import pack/jobs/errors.py 取 RECOVERY，不手抄码表。"""
    spec = importlib.util.spec_from_file_location("s2a_jobs_errors", ERRORS_PY)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return dict(module.RECOVERY)


IOS_STRINGS = {lang: ROOT / "ios" / "l10n" / f"{lang}.lproj" / "S2ArmHost.strings" for lang in ("zh-Hans", "en")}


def ios_strings(lang: str) -> dict:
    """iOS 宿主字符串表（ios/l10n/<语言>.lproj/S2ArmHost.strings，#316）：键 → 值"""
    text = IOS_STRINGS[lang].read_text(encoding="utf-8")
    return {k: v.replace('\\"', '"') for k, v in re.findall(r'^"([^"]+)"\s*=\s*"((?:[^"\\]|\\.)*)";', text, re.M)}


def ios_pack_labels(src: str) -> dict:
    """从 s2a_ios_publish_bundle_info 里按分支结构取两句的本地化键（S2AL，#316），再到中英两张字符串表取值，不做字面匹配。"""
    body = re.search(r"void\s+s2a_ios_publish_bundle_info\s*\([^)]*\)\s*\{(.*?)\n\}", src, re.S)
    assert body is not None, "ios/settings.m 里找不到 s2a_ios_publish_bundle_info"
    fn = body.group(1)
    direct = re.search(r'isEqual:@"direct"\]\)\s*text\s*=\s*S2AL\(@"([^"]+)"\)', fn)
    unknown = re.search(r'\belse\s+text\s*=\s*S2AL\(@"([^"]+)"\)', fn)
    assert direct and unknown, "settings.m 出包画面模式的分支结构变了，自检要跟着改"
    tables = {lang: ios_strings(lang) for lang in IOS_STRINGS}
    return {lid: {lang: tables[lang].get(m.group(1)) for lang in tables} for lid, m in (("direct", direct), ("unknown", unknown))}


def main() -> int:
    spec = json.loads(SPEC.read_text(encoding="utf-8"))
    ok(spec.get("schema") == 1, "schema 必须是 1")
    ok(spec.get("contract") == "s2a.experience.v1", "contract 必须是 s2a.experience.v1")
    ok(isinstance(spec.get("revision"), int) and spec["revision"] >= 1, "revision 必须是 >=1 的整数")
    ok(spec.get("source_language") == "zh-Hans", "source_language 必须是 zh-Hans")
    ok(spec.get("languages") == REQUIRED_LANGS, f"languages 必须是 {REQUIRED_LANGS}")

    states = {s["id"]: s for s in spec["states"]}
    ok(len(states) == len(spec["states"]), "states 里有重复 id")
    for sid in REQUIRED_STATES:
        ok(sid in states, f"缺必需状态 {sid}")
    for sid, s in states.items():
        text_field(s, f"state {sid}")
        ok(s.get("tone") in {"neutral", "busy", "ok", "warn", "error"}, f"state {sid}: tone 不认识（{s.get('tone')}）")

    actions = {a["id"] for a in spec["actions"]}
    for sid, s in states.items():
        action = s.get("primary_action")
        ok(action in actions, f"state {sid}: primary_action {action} 不在 actions 里")

    for t in spec["transitions"]:
        ok(t["from"] in states, f"transition: from {t['from']} 不是已知状态")
        ok(t["to"] in states, f"transition: to {t['to']} 不是已知状态")
        ok(str(t.get("when", "")).strip() != "", f"transition {t['from']}->{t['to']}: 缺 when")

    reachable = {"idle"}
    changed = True
    while changed:
        changed = False
        for t in spec["transitions"]:
            if t["from"] in reachable and t["to"] not in reachable:
                reachable.add(t["to"])
                changed = True
    for sid in REQUIRED_STATES:
        ok(sid in reachable, f"状态 {sid} 从 idle 走不到")

    # ---------- 错误码：RECOVERY 是唯一来源 ----------
    recovery = load_recovery()
    ok(len(recovery) > 0, "pack/jobs/errors.py 的 RECOVERY 读出来是空的")
    for code, text in recovery.items():
        ok(str(text).strip() != "", f"errors.py RECOVERY[{code}] 没有恢复文案")

    errors_block = spec["errors"]
    ok(errors_block.get("code_source") == "pack/jobs/errors.py#RECOVERY",
       "errors.code_source 必须指向 pack/jobs/errors.py#RECOVERY")
    items = errors_block["items"]
    codes = [e["code"] for e in items]
    ok(len(codes) == len(set(codes)), "errors 里有重复 code")
    ok(set(codes) == set(recovery) | EXTRA_CODES,
       "errors 的码集合与 RECOVERY 不一致\n  只在规格: %s\n  只在 errors.py: %s"
       % (sorted(set(codes) - set(recovery) - EXTRA_CODES), sorted(set(recovery) - set(codes))))
    for code in TERMINAL_CODES:
        ok(code not in codes, f"{code} 是任务终态，不是错误码，应放 event_map.terminal_results")

    for e in items:
        code = e["code"]
        ok(set(e) == ERROR_KEYS, f"error {code}: 字段只能是 {sorted(ERROR_KEYS)}，实际 {sorted(e)}")
        ok(re.fullmatch(r"[A-Za-z][A-Za-z0-9_.-]*", code) is not None, f"错误码格式不对：{code}")
        text_field(e, f"error {code}")
        ok(e.get("severity") in {"info", "warn", "error"}, f"error {code}: severity 不认识")
        ok(isinstance(e.get("retryable"), bool), f"error {code}: retryable 必须是布尔")
        ok(isinstance(e.get("recoverable"), bool), f"error {code}: recoverable 必须是布尔")
        # 下一步只放来源指针，不放文案（第二份来源正是要收掉的东西）
        nxt = e.get("next_action")
        ok(isinstance(nxt, dict) and set(nxt) == {"from"},
           f"error {code}: next_action 只能是 {{\"from\": ...}} 来源指针")
        if isinstance(nxt, dict) and "from" in nxt:
            src = nxt["from"]
            ok(isinstance(src, str) and not any("\u4e00" <= ch <= "\u9fff" for ch in src),
               f"error {code}: next_action.from 必须是源文件路径，不能是文案")
            ok((ROOT / str(src)).exists(), f"error {code}: next_action.from {src} 不存在")
            if code in recovery:
                ok(src == "pack/jobs/errors.py", f"error {code}: 下一步来源必须是 pack/jobs/errors.py")
            elif code in EXTRA_CODE_SOURCES:
                ok(src == EXTRA_CODE_SOURCES[code], f"error {code}: 下一步来源应是 {EXTRA_CODE_SOURCES[code]}")
                ok(code in (ROOT / src).read_text(encoding="utf-8"),
                   f"{src} 里没写 {code} 的恢复口径")

    # ---------- 终态（job.succeeded / job.cancelled）不是错误码 ----------
    terminal = spec["event_map"]["terminal_results"]
    ok(set(terminal) - {"note"} == TERMINAL_CODES,
       f"terminal_results 必须正好是 {sorted(TERMINAL_CODES)}")
    for code in TERMINAL_CODES:
        node = terminal[code]
        ok(node.get("state") in states, f"terminal_results {code}: state 不是已知状态")
        text_field(node, f"terminal_results {code}")

    for rule in spec["event_map"]["rules"]:
        ok(rule.get("state") in states or rule.get("state") == "keep",
           f"event_map 规则 {rule.get('match')}: state {rule.get('state')} 不是已知状态")

    # ---------- Mac 的共享文本只能来自规格，不复制进本地字符串表 ----------
    localizable = {e["source"]: e.get("en") for e in json.loads(LOCALIZABLE.read_text(encoding="utf-8"))}
    shared_texts = ([s["title"] for s in spec["states"] if s["id"] in {"running", "failed"}]
                    + [spec["event_map"]["terminal_results"][code]["title"] for code in TERMINAL_CODES]
                    + list(spec["pack_graphics_mode"]["labels"].values())
                    + list(spec["stage_labels"].values()))
    for text in shared_texts:
        ok(text["zh-Hans"] not in localizable, f"Localizable.json 重复共享文本：{text['zh-Hans']}")
    # 作业层文字的翻译（新旧 Mac 前端共用）在适配层 BackendText：L() 改调它，它从规格取这些源串。
    mac_sources = MAC_PACK_MODE_SWIFT.parent
    localization_src = (mac_sources / "Localization.swift").read_text(encoding="utf-8")
    ok("BackendText.translate" in localization_src, "L() 没有接入适配层的共享翻译（BackendText）")
    backend_src = (ADAPTER / "Sources" / "S2ArmAppleAdapter" / "BackendText.swift").read_text(encoding="utf-8")
    ok("sharedEntries(Data(contentsOf: experienceURL()))" in backend_src, "BackendText 没有并入共享规格的中英文")
    for resource in (mac_sources / "Resources" / "experience.v1.json", LOCALIZABLE.parent / "experience.v1.json"):
        ok(not resource.exists() and not resource.is_symlink(), f"源码资源目录不应复制或软链共享规格：{resource.relative_to(ROOT)}")
    package = (ADAPTER / "Package.swift").read_text(encoding="utf-8")
    plugin = (ADAPTER / "Plugins/SharedExperienceResource/plugin.swift").read_text(encoding="utf-8")
    ok('plugins: [.plugin(name: "SharedExperienceResource")]' in package,
       "适配层目标必须使用共享资源构建插件")
    ok('shared/experience.v1.json' in plugin and 'inputFiles: [source], outputFiles: [resource]' in plugin,
       "共享资源插件必须声明真实原件输入与生成资源输出")
    ok("SharedExperience.specification" in (mac_sources / "App.swift").read_text(encoding="utf-8"),
       "App 启动时必须校验共享规格")

    # ---------- 出包画面模式：#389 iOS 与 #387 Mac 同源于 IPA Info.plist ----------
    pack = spec["pack_graphics_mode"]
    settings_src = IOS_SETTINGS_M.read_text(encoding="utf-8")
    swift_src = MAC_PACK_MODE_SWIFT.read_text(encoding="utf-8")
    ios_labels = ios_pack_labels(settings_src)
    mac_labels = set(re.findall(r'SharedExperience\.packLabel\("([^"]+)"', swift_src))
    ok(mac_labels == set(pack["labels"]), "PackMode.swift 必须消费全部共享标签且不另造标签")
    for key in ("S2AGraphicsMode", "S2ADirectLibVersion", "S2APackTime", "S2ABuildID"):
        ok(key in pack["keys"], f"pack_graphics_mode.keys 缺 {key}")
        ok(key in settings_src, f"settings.m 里没有 {key}")
        ok(key in swift_src, f"PackMode.swift 里没有 {key}")
    ok(len(pack["keys"]) == 4, f"pack_graphics_mode.keys 应正好 4 个，实际 {len(pack['keys'])}")
    ok(set(pack["values"]) == {"direct"}, "pack_graphics_mode.values 应只有 direct（包只出直连）")
    swift_values = set(re.findall(r'case "([a-z_]+)":', swift_src))
    ok(set(pack["values"].values()) == swift_values,
       f"pack_graphics_mode.values 与 PackMode.swift 的取值不一致：{sorted(swift_values)}")
    ok(set(ios_labels) == set(pack["labels"]), "pack_graphics_mode.labels 的键应是 direct / unknown")
    for lid, label in pack["labels"].items():
        for lang in ("zh-Hans", "en"):   # iOS 取自字符串表（#316）：中英两种都要和规格逐字一致
            got = (ios_labels.get(lid) or {}).get(lang)
            ok(got == label[lang],
               f"pack_graphics_mode.{lid}（{lang}）与 iOS 字符串表不一致\n  S2ArmHost.strings: {got}\n  规格:              {label[lang]}")

    # ---------- 横幅文案：C 头文件逐字 ----------
    header = HEADER.read_text(encoding="utf-8")
    macros = dict(re.findall(r'#define\s+(S2A_DPROMPT_[A-Z0-9_]+)\s+"([^"]*)"', header))
    spec_macros = set()
    for item in spec["prompts"]["items"]:
        macro = item["macro"]
        spec_macros.add(macro)
        ok(macro in macros, f"prompts: 头文件里没有宏 {macro}")
        if macro in macros:
            ok(macros[macro] == item["zh-Hans"],
               f"prompts: {macro} 与头文件不一致\n  头文件: {macros[macro]}\n  规格:   {item['zh-Hans']}")
        if "en" in item:   # 游戏内中英同屏的文案：英文宏 <宏>_EN 是实现来源，与规格 en 逐字一致
            en = macro + "_EN"
            spec_macros.add(en)
            ok(macros.get(en) == item["en"], f"prompts: {en} 与规格 en 不一致（或头文件缺）\n  头文件: {macros.get(en)}\n  规格:   {item['en']}")
    ok(spec_macros == set(macros),
       "prompts.items 与头文件的宏不是一一对应\n  只在头文件: %s\n  只在规格: %s"
       % (sorted(set(macros) - spec_macros), sorted(spec_macros - set(macros))))

    # ---------- 初启失败页：C 头文件逐字 + 错误码归类一一对应 ----------
    ifp = spec["init_fail_page"]
    ok(ifp.get("source") == "runtime/include/s2a_init_fail.h", "init_fail_page.source 应指向 runtime/include/s2a_init_fail.h")
    ih = INIT_FAIL_H.read_text(encoding="utf-8")
    imacros = dict(re.findall(r'#define\s+(S2A_INIT_FAIL_[A-Z0-9_]+)\s+"([^"]*)"', ih))
    by_id = {}
    for item in ifp["items"]:
        macro = item["macro"]
        by_id[item["id"]] = item
        ok(macro in imacros, f"init_fail_page: 头文件里没有宏 {macro}")
        if macro in imacros:
            ok(imacros[macro] == item["zh-Hans"],
               f"init_fail_page: {macro} 与头文件不一致\n  头文件: {imacros[macro]}\n  规格:   {item['zh-Hans']}")
        ok(bool(item.get("en", "").strip()), f"init_fail_page {item['id']}: 缺英文")
        # 11-10 英文默认：iOS 按界面语言取 <宏>_EN（runtime/include/s2a_ui_lang.h S2A_TR），与规格 en 逐字一致
        ok(imacros.get(macro + "_EN") == item.get("en"), f"init_fail_page: {macro}_EN 与规格 en 不一致（或头文件缺）\n  头文件: {imacros.get(macro + '_EN')}\n  规格:   {item.get('en')}")
        ok(item["zh-Hans"] not in localizable, f"Localizable.json 重复共享文本：{item['zh-Hans']}")
    spec_imacros = {i["macro"] for i in ifp["items"]} | {i["macro"] + "_EN" for i in ifp["items"]}
    ok(spec_imacros == set(imacros),
       "init_fail_page.items 与头文件的文案宏不是一一对应\n  只在头文件: %s\n  只在规格: %s"
       % (sorted(set(imacros) - spec_imacros), sorted(spec_imacros - set(imacros))))
    # 头文件码表：X(枚举名, "码 id", "内部摘要", 话术宏)；unknown（码表外）不在 X 表里，固定用通用句
    hcodes = {(e, cid, msg) for e, cid, msg in
              re.findall(r'X\((S2A_INIT_FAIL_E_[A-Z0-9_]+),\s*"([a-z0-9_]+)",\s*"[^"]*",\s*(S2A_INIT_FAIL_MSG_[A-Z0-9_]+)\)', ih)}
    ok(len(hcodes) > 0, "s2a_init_fail.h 里找不到 S2A_INIT_FAIL_CODES 码表")
    scodes = set()
    for c in ifp["codes"]:
        msg = by_id.get(c["message"])
        ok(msg is not None and msg["macro"].startswith("S2A_INIT_FAIL_MSG_"),
           f"init_fail_page.codes {c['id']}: message {c['message']} 不是一句原因话术")
        if c["id"] == "unknown":
            ok(c["enum"] == "S2A_INIT_FAIL_E_UNKNOWN" and c["message"] == "msg_generic", "init_fail_page.codes unknown 应是 S2A_INIT_FAIL_E_UNKNOWN + msg_generic")
        elif msg is not None:
            scodes.add((c["enum"], c["id"], msg["macro"]))
    ok(scodes == hcodes,
       "init_fail_page.codes 与头文件 S2A_INIT_FAIL_CODES 不一致\n  只在头文件: %s\n  只在规格: %s"
       % (sorted(hcodes - scodes), sorted(scodes - hcodes)))

    # ---------- 起局自检提示页：C 头文件逐字、宏集合一一对应 ----------
    scp = spec["selfcheck_page"]
    ok(scp.get("source") == "runtime/include/s2a_selfcheck_page.h", "selfcheck_page.source 应指向 runtime/include/s2a_selfcheck_page.h")
    smacros = dict(re.findall(r'#define\s+(S2A_SELFCHECK_[A-Z0-9_]+)\s+"([^"]*)"', SELFCHECK_H.read_text(encoding="utf-8")))
    ok(len(smacros) > 0, "s2a_selfcheck_page.h 里找不到 S2A_SELFCHECK_* 文案宏")
    for item in scp["items"]:
        macro = item["macro"]
        ok(macro in smacros, f"selfcheck_page: 头文件里没有宏 {macro}")
        if macro in smacros:
            ok(smacros[macro] == item["zh-Hans"],
               f"selfcheck_page: {macro} 与头文件不一致\n  头文件: {smacros[macro]}\n  规格:   {item['zh-Hans']}")
        ok(bool(item.get("en", "").strip()), f"selfcheck_page {item['id']}: 缺英文")
        ok(smacros.get(macro + "_EN") == item.get("en"), f"selfcheck_page: {macro}_EN 与规格 en 不一致（或头文件缺）\n  头文件: {smacros.get(macro + '_EN')}\n  规格:   {item.get('en')}")
        ok(item["zh-Hans"] not in localizable, f"Localizable.json 重复共享文本：{item['zh-Hans']}")
    spec_smacros = {i["macro"] for i in scp["items"]} | {i["macro"] + "_EN" for i in scp["items"]}
    ok(spec_smacros == set(smacros),
       "selfcheck_page.items 与头文件的文案宏不是一一对应\n  只在头文件: %s\n  只在规格: %s"
       % (sorted(set(smacros) - spec_smacros), sorted(spec_smacros - set(smacros))))

    # ---------- 阶段名必须与出包契约的 stageId 集合一致 ----------
    proto = PROTOCOL.read_text(encoding="utf-8")
    block = re.search(r"STAGES\s*=\s*\{(.*?)\}", proto, re.S)
    ok(block is not None, "在 pack/contracts/protocol.py 里找不到 STAGES")
    if block:
        # STAGES 是 {里程碑键: stageId}，右值才是事件里的 stageId
        stage_ids = set(re.findall(r':\s*"([a-z][a-z0-9_.-]*)"', block.group(1)))
        # 兜底 stageId 不在 STAGES 里：event_fields 的 STAGES.get(milestone, <兜底>) 表达式——「检查游戏输入」阶段给 input.validate、其余认不出的给 job
        #   （11-07 出包去掉原件重算的 verify 里程碑后，input.validate 只剩这条兜底在发）
        fb = re.search(r"STAGES\.get\(milestone,(.*?)\)\s*,", proto)
        ok(fb is not None, "在 pack/contracts/protocol.py 里找不到 STAGES.get(milestone, …) 兜底")
        allowed = stage_ids | set(re.findall(r'"([a-z][a-z0-9_.-]*)"', fb.group(1) if fb else ""))
        labels = set(spec["stage_labels"])
        ok(labels == allowed,
           "stage_labels 与 STAGES 不一致\n  只在规格: %s\n  只在契约: %s"
           % (sorted(labels - allowed), sorted(allowed - labels)))
        for sid, label in spec["stage_labels"].items():
            text_field({"title": label}, f"stage {sid}")

    # 启动器客户端界面文案（launcher 段）：键唯一、键名形状、两种语言都非空；环境检查六种状态都有文案（同 pack/jobs/winenv.py 的状态集合）
    launcher = spec.get("launcher") or {}
    litems = launcher.get("items") or []
    ok(bool(litems), "launcher.items 为空")
    lids = [it.get("id") for it in litems]
    ok(len(lids) == len(set(lids)), "launcher 里有重复 id")
    for it in litems:
        ok(set(it) == {"id", *REQUIRED_LANGS}, f"launcher {it.get('id')}: 字段只能是 id + {REQUIRED_LANGS}")
        ok(re.fullmatch(r"[a-z][a-z0-9_]*(\.[A-Za-z0-9_-]+)+", str(it.get("id"))) is not None, f"launcher 键名形状不对：{it.get('id')}")
        for lang in REQUIRED_LANGS:
            ok(str(it.get(lang, "")).strip() != "", f"launcher {it.get('id')}: 缺 {lang}")
    for st in ("ok", "missing", "mismatch", "unverified", "error", "user-selected"):
        ok(f"environment.status.{st}" in lids, f"launcher 缺环境检查状态 environment.status.{st}")

    if fails:
        print(f"失败：{len(fails)} / 断言 {checks}")
        for f in fails:
            print("  ✗ " + f)
        return 1
    print(f"通过：{checks} / {checks} 项断言")
    print(f"  状态 {len(states)} 个、转换 {len(spec['transitions'])} 条、错误码 {len(codes)} 个、"
          f"阶段名 {len(spec['stage_labels'])} 个、横幅文案 {len(spec['prompts']['items'])} 条、"
          f"初启失败页文案 {len(spec['init_fail_page']['items'])} 条 / 错误码 {len(spec['init_fail_page']['codes'])} 个、"
          f"自检提示页文案 {len(spec['selfcheck_page']['items'])} 条、"
          f"出包画面模式 {len(pack['labels'])} 句、启动器界面文案 {len(litems)} 条")
    return 0


if __name__ == "__main__":
    sys.exit(main())
