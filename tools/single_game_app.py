#!/usr/bin/env python3
"""单款游戏 App（一个游戏一个 iOS App，游戏资源装在 App 里）：预编壳 + 一款产物根 + 这款的 OTA 导出 → 一个 .ipa。
装上后点开直接进这款（ios/app.m solo_game_id）；首次打开把包里 Games/<游戏号>/ota/ 按下载同一套落点克隆进 Documents/games/<游戏号>/资源包
（ios/ota_place.m，同卷 APFS 克隆、几乎不占空间），再由导入闸门照常解开。引擎就是 S2Arm 的宿主（软件 BC 解码，A16 iPad 能跑）。

  python3 tools/single_game_app.py --shell <壳目录> --kit <产物根> --ota <OTA 导出目录> --out <输出.ipa>
          [--display-name <主屏名>] [--icon <图标>] [--bundle-id <包名>] [--sign none|adhoc] [--keep-app <目录>]

  --kit      产物根（如 ~/S2Arm/games/<号>/image/ios/kit，只读）：改写产物、main.npdm、ctl/control.nacp、icon.jpg
  --ota      tools/ota_pack.py export 的输出（ota.json、img/、tars/、index.tsv、manifest.json，只读）：原样克隆进包里 Games/<号>/ota/
  主屏名     缺省用游戏自带英文名；Info.plist 只放 ASCII（侧载 / 签名工具拿它建 App ID），原样的名字（含 ' : 等）进各语言 InfoPlist.strings，
             中日韩系统显示游戏自带的那种语言名
  包名       缺省 io.s2arm.games.<游戏号小写>：每款一个包名，几款游戏 App 并存
  图标       缺省产物根 icon.jpg（游戏自带图标）
  签名       none（缺省，交给发布脚本统一签）/ adhoc（本机 ad-hoc，codesign 要把几十 GB 全哈希一遍，慢）
  IPA        zip64（单个镜像 6–30 GB 超 zip 32 位上限）；大文件抽样试压，压不下去就原样存
  写前核：OTA 导出与产物根是同一款（ota.json title_id = main.npdm 程序号）、导出里每个文件在且大小对、≤ 64 MB 的 sha256 对；
          输出所在盘剩余 ≥ 估算 IPA 大小 + 5 GB。App 先在输出旁的临时目录组装（同卷才能克隆），打完 IPA 删掉（--keep-app 留一份）
退出码：0 成功；1 失败（末行【红】）；2 用法
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "tools")); sys.path.insert(0, str(REPO))   # 仓库根在最前：pack/pack.py 不能顶掉 pack 包
from pack import app_bundle  # noqa: E402
from pack.display_name import NoTitle, _ascii, localized_names, title  # noqa: E402
from pack import xcode_keys  # noqa: E402

SMALL = 64 << 20
MARGIN = 5 << 30
BRAND = " S2Arm"


class Fail(Exception):
    pass


def npdm_gid(npdm):
    b = Path(npdm).read_bytes()
    if len(b) < 0x80 or b[:4] != b"META":
        raise Fail(f"{npdm} 不是 NPDM")
    aci = int.from_bytes(b[0x70:0x74], "little")
    if b[aci:aci + 4] != b"ACI0":
        raise Fail(f"{npdm} 没有 ACI0")
    return f"{int.from_bytes(b[aci + 0x10:aci + 0x18], 'little'):016X}"


def sha256(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(8 << 20), b""):
            h.update(b)
    return h.hexdigest()


def check_export(ota_dir, gid):
    """OTA 导出 → ota.json（核格式、同一款、每个文件在且大小对、小文件 sha256 对、index.tsv / manifest.json 最后）"""
    ota_dir = Path(ota_dir)
    try:
        o = json.loads((ota_dir / "ota.json").read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        raise Fail(f"读不了 {ota_dir}/ota.json：{e}")
    if o.get("format") != "s2arm-ota" or o.get("version") != 1:
        raise Fail(f"{ota_dir}/ota.json 不是 s2arm-ota v1")
    if str(o.get("title_id", "")).upper() != gid:
        raise Fail(f"OTA 导出是 {o.get('title_id')}，产物根是 {gid}：不是同一款")
    fs = o.get("files") or []
    if [f.get("dest") for f in fs[-2:]] != ["index.tsv", "manifest.json"]:
        raise Fail("ota.json 里 index.tsv / manifest.json 不在最后")
    for f in fs:
        n = f.get("name", "")
        if not n or n.startswith("/") or ".." in n.split("/") or "\\" in n:
            raise Fail(f"ota.json 里文件名不安全：{n!r}")
        p = ota_dir / n
        if not p.is_file() or p.stat().st_size != f["size"]:
            raise Fail(f"导出里 {n} 不在或大小不对（要 {f['size']}）")
        if f["size"] <= SMALL and sha256(p) != f["sha256"].lower():
            raise Fail(f"导出里 {n} 的 sha256 不对")
    return o


def clone(src, dst):
    """APFS 克隆（cp -c，写时复制、不占第二份空间）；不行退回普通拷贝"""
    dst.parent.mkdir(parents=True, exist_ok=True)
    if sys.platform == "darwin" and subprocess.run(["/bin/cp", "-c", str(src), str(dst)], capture_output=True).returncode == 0:
        return True
    shutil.copyfile(src, dst)
    return False


def place_export(ota_dir, ota, dest):
    """导出里 ota.json 列的文件 + ota.json 原样放进 dest（包里 Games/<号>/ota/）；→ 克隆的个数"""
    n = 0
    for f in ota["files"]:
        n += clone(Path(ota_dir) / f["name"], dest / f["name"])
    n += clone(Path(ota_dir) / "ota.json", dest / "ota.json")
    return n


def names_for(kit, display):
    """→ (Info.plist 的 ASCII 名, {语言: 主屏名})：游戏自带各语言名去掉品牌后缀；给了 display 时拉丁文字的那几种语言换成它"""
    try:
        loc = {k: v[:-len(BRAND)] if v.endswith(BRAND) else v for k, v in localized_names(str(kit), "").items()}
    except NoTitle as e:
        raise Fail(f"取不到游戏名：{e}")
    en = loc.get("en")
    if display:
        loc = {k: display if v == en or not en else v for k, v in loc.items()}
        loc.setdefault("en", display)
    plain = _ascii(re.sub(r"['’]", "", display or en or title(str(kit))))   # Link's → Links（撇号去掉不留空格）
    if not plain:
        raise Fail("主屏名去掉非 ASCII 字符后为空：请给 --display-name")
    return plain, loc


def write_lproj(app, loc):
    for lang, name in sorted(loc.items()):
        if not re.fullmatch(r"[A-Za-z]{2,3}(?:[-_][A-Za-z0-9]+)*", lang):
            continue
        esc = name.replace("\\", "\\\\").replace('"', '\\"')
        d = app / f"{lang}.lproj"; d.mkdir(exist_ok=True)
        (d / "InfoPlist.strings").write_text(f'"CFBundleDisplayName" = "{esc}";\n', encoding="utf-8", newline="\n")


def free_bytes(path):
    st = os.statvfs(path)
    return st.f_bavail * st.f_frsize


def verify_ipa(ipa, gid, ota):
    """IPA 里有 Games/<号>/ota/ota.json 与导出列的每个文件（大小一致），且有主程序与清单"""
    pre = f"Payload/S2Arm.app/Games/{gid}/ota/"
    with zipfile.ZipFile(ipa) as z:
        got = {i.filename: i.file_size for i in z.infolist()}
        cat = json.loads(z.read("Payload/S2Arm.app/s2a_catalogue.json"))
    miss = [pre + f["name"] for f in ota["files"] if got.get(pre + f["name"]) != f["size"]]
    if pre + "ota.json" not in got:
        miss.append(pre + "ota.json")
    if miss:
        raise Fail(f"IPA 里缺 / 大小不对：{miss[:5]}")
    if not cat.get("solo") or [g["title_id"] for g in cat["games"]] != [gid]:
        raise Fail("IPA 里的 s2a_catalogue.json 不是只装这一款的 solo 清单")
    return got


def build(a):
    kit, ota_dir, out = Path(a.kit), Path(a.ota), Path(a.out).expanduser()
    gid = npdm_gid(kit / "main.npdm")
    ota = check_export(ota_dir, gid)
    if os.path.lexists(out):
        raise Fail(f"不覆盖已有输出：{out}")
    out.parent.mkdir(parents=True, exist_ok=True)
    total = ota["total"] + sum(p.stat().st_size for p in kit.rglob("*") if p.is_file())
    fr = free_bytes(out.parent)
    if fr < total + MARGIN:
        raise Fail(f"{out.parent} 所在盘剩 {fr >> 30} GB，打这个 IPA 最多要 {total >> 30} GB + 留 {MARGIN >> 30} GB")
    bundle_id = a.bundle_id or f"io.s2arm.games.{gid.lower()}"
    plain, loc = names_for(kit, a.display_name)
    icon = Path(a.icon) if a.icon else kit / "icon.jpg"
    m = re.search(r"^HOST_ABI = (\d+)", (REPO / "pack/jobs/host_update.py").read_text(encoding="utf-8"), re.M)   # 宿主读产物约定号（同启动器出容器时给的）
    if not m:
        raise Fail("pack/jobs/host_update.py 里找不到 HOST_ABI")
    HOST_ABI = int(m[1])
    work = Path(tempfile.mkdtemp(prefix=f".single-{gid}-", dir=out.parent))
    try:
        app = work / "S2Arm.app"
        r = subprocess.run([sys.executable, str(REPO / "pack/ship_ext.py"), "container", "--shell", str(a.shell), "--out", str(app), "--game", str(kit),
                            "--bundle-id", bundle_id, "--icon", str(icon), "--display-name", plain, "--host-abi", str(HOST_ABI), "--solo", "--sign", "none"],
                           capture_output=True, text=True)
        if r.returncode:
            raise Fail(f"组装容器失败：{(r.stderr or r.stdout).strip().splitlines()[-1:]}")
        print(r.stdout.strip().splitlines()[-1])
        nc = place_export(ota_dir, ota, app / "Games" / gid / "ota")
        write_lproj(app, loc)
        stamped = xcode_keys.stamp(app)
        if a.sign == "adhoc":
            from pack import ship_ext
            ship_ext.sign_app(app, "adhoc", bundle_id, "")
        app_bundle.write_ipa(app, out, zip64=True)
        got = verify_ipa(out, gid, ota)
        if a.keep_app:
            keep = Path(a.keep_app).expanduser()
            if os.path.lexists(keep):
                raise Fail(f"不覆盖已有 --keep-app：{keep}")
            os.replace(app, keep)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    img = [f for f in ota["files"] if not f["dest"].startswith(".incoming/") and f["dest"] not in ("index.tsv", "manifest.json")]
    print(f"🟢 单款游戏 App {out}（{out.stat().st_size} 字节，{len(got)} 个条目）：游戏 {gid}，包名 {bundle_id}，主屏名 {plain!r}（{loc.get('en', plain)!r}），"
          f"签名 {a.sign}；包里资源包 {len(ota['files'])} 个文件 {ota['total']} 字节（克隆 {nc} 个；直写镜像 {', '.join(f['dest'] for f in img) or '无'}）；构建环境键写进 {', '.join(stamped)}")
    return dict(ipa=str(out), size=out.stat().st_size, bundle_id=bundle_id, display_name=plain, localized=loc, title_id=gid)


def main(argv=None):
    for s in (sys.stdout, sys.stderr):
        if hasattr(s, "reconfigure"): s.reconfigure(encoding="utf-8")
    ap = argparse.ArgumentParser(description="单款游戏 App（游戏资源装在 App 里）")
    ap.add_argument("--shell", required=True); ap.add_argument("--kit", required=True); ap.add_argument("--ota", required=True); ap.add_argument("--out", required=True)
    ap.add_argument("--display-name"); ap.add_argument("--icon"); ap.add_argument("--bundle-id")
    ap.add_argument("--sign", choices=("none", "adhoc"), default="none"); ap.add_argument("--keep-app")
    a = ap.parse_args(argv)
    try:
        build(a); return 0
    except (Fail, app_bundle.BundleError, RuntimeError, OSError) as e:
        print(f"【红】{e}"); return 1


if __name__ == "__main__":
    sys.exit(main())
