"""随包资源包（单款游戏 App：包里 Games/<游戏号>/ota/ = tools/ota_pack.py export 原样输出）落点单测：编真 ios/ota_place.m + runtime/src/pack_apply.c，
在合成的小资源包上核 s2a_ota_place_bundled（ios/ota_download.m s2a_ota_bundled_install 首启调它）。期望按 ios/ota_place.h 的契约手写：
  ① 包 → Documents/games/<号>/资源包：每个文件按 ota.json 的 dest 落地、与导出逐字节相同；同卷 APFS 上全程克隆；再跑真导入闸门 → 就绪、解开后逐字节 = 资源包
  ② 重跑：放好之后（闸门导入前）再跑一次全部跳过、落点 inode 不变；导入就绪之后再跑直接返回、不动资源包
  ③ 放到一半被杀（第 N 个文件前退出，另塞一个半截落点与残留临时文件）：manifest.json 不在、库判不在机上、闸门不导入；下次启动重跑 → 放齐、导入就绪、逐字节一致
  ④ 包里的文件被改坏（大小不对）报失败、不留 manifest.json；ota.json 游戏号不对报失败"""
import json, os, shutil, subprocess, sys, tempfile, unittest
from pathlib import Path
R = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(R / "tools")); sys.path.insert(0, str(R / "tests"))
import ota_pack
import push_pack as push
import ota_pack_test as opt   # 只借合成资源包与小工具，不把它的用例收进来
TID, tree = opt.TID, opt.tree

PACK = "资源包"


class Bundled(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.bd = tempfile.TemporaryDirectory(); b = Path(cls.bd.name)
        if not shutil.which("cc"): raise unittest.SkipTest("没有 C 编译器")
        flags = subprocess.run([sys.executable, str(R / "tools/weak_link_decl.py"), "flags", "host"], capture_output=True, text=True).stdout.split()
        inc = ["-I" + str(R / "runtime/include"), "-I" + str(R / "runtime/src"), "-DS2A_UNIT_TEST"]
        cls.gate_bin, cls.place_bin = b / "gate", b / "place"
        for out, srcs, extra in ((cls.gate_bin, ["tests/ota_gate/driver.c", "runtime/src/pack_apply.c"], []),
                                 (cls.place_bin, ["tests/ota_gate/bundled.m", "ios/ota_place.m", "runtime/src/pack_apply.c"], ["-fobjc-arc", "-framework", "Foundation"])):
            r = subprocess.run(["cc", "-O1", *inc, "-o", str(out), *[str(R / s) for s in srcs], *extra, *flags], capture_output=True, text=True)
            assert r.returncode == 0, r.stderr[-1500:]

    @classmethod
    def tearDownClass(cls): cls.bd.cleanup()

    def setUp(self):
        self.td = tempfile.TemporaryDirectory(); d = Path(self.td.name)
        self.lim0 = push.LIM; push.LIM = 4096
        mk = opt.OtaExport(); mk.pk = d / "pack"   # 借导出单测的合成资源包（同一份数据形状）
        self.data = mk.make()
        self.ota_dir = d / "S2Arm.app" / "Games" / TID / "ota"   # 单款游戏 App 包里的位置
        self.ota = ota_pack.export(mk.pk, self.ota_dir, TID, say=lambda m: None)
        self.docs = d / "Documents"; self.root = self.docs / "games" / TID / PACK

    def tearDown(self):
        push.LIM = self.lim0; self.td.cleanup()

    def run_place(self, *extra, ota_dir=None):
        r = subprocess.run([str(self.place_bin), str(ota_dir or self.ota_dir), str(self.docs), TID, *extra], capture_output=True, text=True)
        out = dict(l.split("=", 1) for l in r.stdout.splitlines() if "=" in l)
        return r.returncode, out

    def gate(self, *extra):
        r = subprocess.run([str(self.gate_bin), str(self.docs), TID, *extra], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        return dict(l.split("=", 1) for l in r.stdout.splitlines() if "=" in l)

    def assert_placed(self):
        for f in self.ota["files"]:
            self.assertEqual((self.root / f["dest"]).read_bytes(), (self.ota_dir / f["name"]).read_bytes(), f["dest"])
        self.assertFalse((self.docs / "games" / TID / ".ota-bundled").exists())   # 临时目录收掉

    def assert_imports(self):
        g = self.gate("apply")
        self.assertEqual(g["on_device"], "1")
        self.assertEqual(g["gate"].split(",")[1], "1")   # S2A_GATE_IMPORT
        self.assertEqual((g["apply"], g["state"], g["quick"]), ("0", "0", "0"))
        self.assertFalse(list((self.root / ".incoming").glob("*.tar")))
        for k, v in self.data.items(): self.assertEqual((self.root / k).read_bytes(), v, k)

    def test_place_then_gate_ready(self):
        before = tree(self.ota_dir)
        rc, o = self.run_place()
        self.assertEqual((rc, o["rc"]), (0, "0"), o)
        self.assertEqual(o["cloned"], "1")   # 同卷 APFS：全程 clonefile
        self.assert_placed()
        self.assertFalse((self.root / ".applied").exists())   # 清过的空 .applied 放完收掉（新装待解开的样子）
        self.assert_imports()
        self.assertEqual(tree(self.ota_dir), before)   # 包里的不动（克隆是写时复制，闸门删 tar 不碰包）

    def test_rerun_is_idempotent(self):
        self.assertEqual(self.run_place()[1]["rc"], "0")
        ino = {f["dest"]: (self.root / f["dest"]).stat().st_ino for f in self.ota["files"] if f["dest"] != "manifest.json"}
        self.assertEqual(self.run_place()[1]["rc"], "0")
        self.assertEqual({k: (self.root / k).stat().st_ino for k in ino}, ino)   # 已放好的跳过，不重放
        self.assert_placed()
        self.assert_imports()
        snap = tree(self.root)
        rc, o = self.run_place()   # 已导入就绪：直接返回，不再放（tar 不回来、清单不动）
        self.assertEqual((o["rc"], o["calls"]), ("0", "0"))
        self.assertEqual(tree(self.root), snap)

    def test_interrupted_recovers(self):
        n = len(self.ota["files"])
        rc, o = self.run_place(str(n - 2))   # 杀在 index.tsv 之前：镜像与 tar 已放，清单没到
        self.assertEqual((rc, o.get("killed_at")), (9, str(n - 2)))
        self.assertFalse((self.root / "manifest.json").exists())
        mid = self.gate()
        self.assertEqual(mid["on_device"], "0")
        self.assertEqual(mid["gate"], "3,3")   # S2A_GATE_WAIT：清单没到，不导入
        tars = [f for f in self.ota["files"] if f["dest"].startswith(".incoming/")]
        (self.root / tars[-1]["dest"]).write_bytes(b"half")   # 半截落点（大小不对）
        tmp = self.docs / "games" / TID / ".ota-bundled"; tmp.mkdir(exist_ok=True); (tmp / "placing.tmp").write_bytes(b"junk")
        (self.root / "manifest.json").write_bytes(b'{"stale": true}')   # 上一版留下的旧清单：开头要先拿掉
        rc, o = self.run_place("1")   # 再被杀一次（刚开头）
        self.assertEqual(rc, 9); self.assertFalse((self.root / "manifest.json").exists())
        rc, o = self.run_place()
        self.assertEqual((rc, o["rc"]), (0, "0"), o)
        self.assert_placed()
        self.assert_imports()

    def test_reapply_over_old_install_clears_applied(self):
        self.assertEqual(self.run_place()[1]["rc"], "0"); self.assert_imports()
        (self.root / "exefs/main.npdm").unlink()   # 资源包被弄坏：库判不在，单款 App 首启会再放一次
        rc, o = self.run_place()
        self.assertEqual(o["rc"], "0", o)
        self.assertFalse((self.root / ".applied").exists())
        self.assert_imports()

    def test_corrupt_bundle_and_wrong_id_fail(self):
        img = self.ota_dir / "img/romfs.img"; img.chmod(0o644); img.write_bytes(b"short")
        rc, o = self.run_place()
        self.assertEqual(o["rc"], "1"); self.assertIn("size", o["why"])
        self.assertFalse((self.root / "manifest.json").exists())
        j = json.loads((self.ota_dir / "ota.json").read_text()); j["title_id"] = "0100000000000000"
        (self.ota_dir / "ota.json").write_text(json.dumps(j))
        rc, o = self.run_place()
        self.assertEqual(o["rc"], "1"); self.assertIn("title id", o["why"])


if __name__ == "__main__":
    unittest.main()
