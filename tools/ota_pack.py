#!/usr/bin/env python3
"""OTA 资源包导出（无线装机，玩家离家时从私有 HTTPS 地址下载资源包）：把一款游戏的资源包目录变成
「首次装机时 tools/push_pack.py 会推上机的那几样文件」+ 一份 ota.json，放到任意静态 HTTPS 服务上，容器 App 按 ota.json 逐个下载（ios/ota_download.m）。

不另写格式：批次、tar 写法、推送顺序全部借 push_pack.py——本工具给 push_pack.plan(full=True) / send() 一个「本地目录设备」，
send() 往设备上 put 的每个文件（除推送记账 .pushed）原样落到 <out_dir>，按 put 的先后排顺序：
  ① 直写镜像（romfs.img；push 先把机上 .applied 清空再写它，ota.json 记 clear_applied）
  ② 各批 tar（≤1 GB，设备侧放 资源包/.incoming/<时刻>_<序号>.tar）
  ③ index.tsv、④ manifest.json（最后：App 的导入闸门见到 manifest 才认「传完了」，runtime/src/pack_apply.c s2a_import_transferring）
设备侧在下载完后不解包：下次点 Play 时现有的导入闸门（s2a_import_gate）照推送的口径解开。

用法：python3 tools/ota_pack.py export <资源包目录> <输出目录> --title-id <16 位游戏号>
输出目录（不存在才建；已存在且非空报红，不覆盖）：
  ota.json                 {"format":"s2arm-ota","version":1,"title_id":…,"index_sha256":…,"total":…,"clear_applied":bool,
                            "files":[{"name","dest","size","sha256","order"}…]}
  <name>                   每个文件按 name（相对 ota.json 所在目录的 URL 路径）放：tar 在 tars/，直写镜像在 img/<资源包内路径>，index.tsv / manifest.json 在顶层
dest = 设备上相对「资源包」目录的落点（tar 是 .incoming/<名>）。
退出码：0 成功；1 失败（末行【红】说明）；2 用法"""
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
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import push_pack as push   # noqa: E402  批次 / tar / 顺序全用它的

FORMAT, VERSION = "s2arm-ota", 1
DOCS = "OTA"   # 本地目录设备的「文档根」名，只用来认 send() 给的设备路径前缀
TID = re.compile(r"[0-9A-Fa-f]{16}")


def sha256_file(p, bs=8 << 20):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(bs), b""):
            h.update(b)
    return h.hexdigest()


def clone(src, dst):
    """拷大文件：APFS 上 cp -c 是写时复制（不占第二份空间、秒完）；不行退回普通拷贝。输入目录只读，不硬链（共 inode，改输出会改输入）"""
    dst.parent.mkdir(parents=True, exist_ok=True)
    if sys.platform == "darwin":
        try:
            if subprocess.run(["/bin/cp", "-c", str(src), str(dst)], capture_output=True).returncode == 0:
                return
        except OSError:
            pass
    shutil.copyfile(src, dst)


class LocalDev:
    """push_pack 的设备接口落到本地目录：只收 send() 用到的 put / put_big / put_tar / nospc / why。
    put_tar 直接借 push_pack.Devicectl.put_tar 的退路（tarfile PAX、uid/gid 0、按 push.lst 顺序），与推到手机上的 tar 同一段代码"""
    kind = "ota"; docs = DOCS; ctx = None; why = "OTA 导出（本地目录）"; dp = None
    put_tar = push.Devicectl.put_tar
    say = staticmethod(lambda m: None)

    def __init__(self, out, work):
        self.out, self.work = Path(out), Path(work)
        self.puts = []   # [(设备侧相对资源包的路径, 本地文件)]，按 put 的先后
        self.clear_applied = False

    def _rel(self, rel):
        pre = push.rp(self) + "/"
        if not rel.startswith(pre):
            raise push.Fail(f"设备路径不在资源包下：{rel}")
        return rel[len(pre):]

    def put(self, src, rel):
        r = self._rel(rel)
        if r == ".pushed":   # 推送记账（中断续推用），OTA 端自己记进度，不下发
            return
        if r == ".applied":   # send() 写直写镜像前把 .applied 清空：设备侧照做
            self.clear_applied = True; return
        if r.startswith(".incoming/"):
            name = "tars/" + r[len(".incoming/"):]
        elif r in ("index.tsv", "manifest.json"):
            name = r
        else:
            name = "img/" + r
        dst = self.out / name
        dst.parent.mkdir(parents=True, exist_ok=True)
        if Path(src).parent == self.work:   # send() 在 work 里现打的 tar：挪过去（之后它 unlink(missing_ok)）
            os.replace(src, dst)
        else:
            clone(Path(src), dst)
        self.puts.append((r, name))

    put_big = put

    def nospc(self):
        return False


def export(pack, out, title_id, say=print):
    pack, out = Path(pack), Path(out)
    if not TID.fullmatch(title_id or ""):
        raise push.Fail(f"游戏号要 16 位十六进制：{title_id}")
    if not (pack / "index.tsv").is_file() or not (pack / "manifest.json").is_file():
        raise push.Fail(f"资源包目录不在或不是 v2（缺 index.tsv / manifest.json）：{pack}")
    if out.exists() and any(out.iterdir()):
        raise push.Fail(f"输出目录已存在且非空，不覆盖：{out}")
    out.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=os.environ.get("S2A_PUSH_TMP")) as w:
        work = Path(w); dev = LocalDev(out, work)
        nb, nt, nbytes = push.plan(dev, pack, work, full=True, say=say)   # 首次装机 = 整包
        push.send(dev, pack, work, say=say)
    man = json.loads((pack / "manifest.json").read_text(encoding="utf-8"))
    files = []
    for i, (dest, name) in enumerate(dev.puts):
        p = out / name
        files.append({"name": name, "dest": dest, "size": p.stat().st_size, "sha256": sha256_file(p), "order": i})
    if [f["dest"] for f in files[-2:]] != ["index.tsv", "manifest.json"]:
        raise push.Fail("推送顺序变了：index.tsv / manifest.json 不在最后（tools/push_pack.py send）")
    ota = {"format": FORMAT, "version": VERSION, "title_id": title_id.upper(), "index_sha256": man.get("index_sha256"),
           "total": sum(f["size"] for f in files), "clear_applied": dev.clear_applied, "files": files}
    (out / "ota.json").write_text(json.dumps(ota, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    ntar = sum(f["dest"].startswith(".incoming/") for f in files)
    say(f"OTA 导出：{nt} 个文件 {nbytes >> 20} MB → {ntar} 个 tar + {len(files) - ntar - 2} 个直写镜像 + index.tsv + manifest.json，共 {ota['total'] >> 20} MB（{out}/ota.json）")
    return ota


def main(argv=None):
    for s in (sys.stdout, sys.stderr):
        if hasattr(s, "reconfigure"): s.reconfigure(encoding="utf-8")
    ap = argparse.ArgumentParser(description="OTA 资源包导出（无线装机）")
    ap.add_argument("op", choices=("export",)); ap.add_argument("pack"); ap.add_argument("out")
    ap.add_argument("--title-id", required=True)
    a = ap.parse_args(argv)
    try:
        export(a.pack, a.out, a.title_id)
        return 0
    except push.Fail as e:
        print(f"【红】{e}"); return 1


if __name__ == "__main__":
    sys.exit(main())
