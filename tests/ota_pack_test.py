"""OTA 资源包导出（tools/ota_pack.py）单测：小的合成资源包上核输出。期望按 tools/ota_pack.py / push_pack.py 文件头的契约手写：
  ① 非镜像文件全进 tar（设备侧 .incoming/<时刻>_<三位序号>.tar），解开后逐字节等于资源包；每批 ≤ LIM（单个超限的自成一批）；tar 是完整的（512 整倍、末尾 1024 字节全零）
  ② romfs.img 不进 tar、按 img/<路径> 直写，clear_applied = 真；没有镜像时 clear_applied = 假
  ③ ota.json 每个文件 size / sha256 与输出目录里的实物一致，order 连续，index.tsv、manifest.json 排最后且与输入逐字节相同
  ④ 输入目录不被改动；输出目录非空 / 游戏号不对报失败"""
import hashlib, io, json, re, shutil, subprocess, sys, tarfile, tempfile, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import ota_pack
import push_pack as push

TID = "0100ABCD12340000"


def sha(b): return hashlib.sha256(b).hexdigest()


def tree(d):
    return {p.relative_to(d).as_posix(): p.read_bytes() for p in sorted(Path(d).rglob("*")) if p.is_file()}


class OtaExport(unittest.TestCase):
    def setUp(self):
        self.td = tempfile.TemporaryDirectory(); d = Path(self.td.name)
        self.pk = d / "pack"; self.out = d / "out"
        self.lim0 = push.LIM; push.LIM = 4096   # 小包也能分出几批
        self.log = []

    def tearDown(self):
        push.LIM = self.lim0; self.td.cleanup()

    def make(self, img=True):
        data = {"exefs/main.npdm": b"N" * 300, "ctl/control.nacp": b"C" * 1500, "shaders/a.bin": b"S" * 3000,
                "shaders/b.bin": bytes(range(256)) * 20, "big.bin": b"B" * 9000, "zero.bin": b""}
        if img: data["romfs.img"] = b"R" * 5000
        for k, v in data.items():
            p = self.pk / k; p.parent.mkdir(parents=True, exist_ok=True); p.write_bytes(v)
        (self.pk / "index.tsv").write_text("".join(f"{k}\t{len(v)}\t{sha(v)}\n" for k, v in data.items()), encoding="utf-8")
        idx_sha = sha((self.pk / "index.tsv").read_bytes())
        (self.pk / "manifest.json").write_text(json.dumps({"version": 2, "files": len(data), "total": sum(map(len, data.values())), "index_sha256": idx_sha}), encoding="utf-8")
        return data

    def run_export(self):
        return ota_pack.export(self.pk, self.out, TID, say=self.log.append)

    def test_tars_hold_every_non_image_file(self):
        data = self.make(); before = tree(self.pk)
        ota = self.run_export()
        tars = [f for f in ota["files"] if f["dest"].startswith(".incoming/")]
        self.assertGreaterEqual(len(tars), 3)
        got = {}
        for f in tars:
            self.assertRegex(f["dest"], r"^\.incoming/\d+_\d{3}\.tar$")
            self.assertEqual(f["name"], "tars/" + f["dest"].split("/", 1)[1])
            raw = (self.out / f["name"]).read_bytes()
            self.assertEqual(len(raw) % 512, 0); self.assertEqual(raw[-1024:], b"\0" * 1024)   # pack_apply.c tar_done
            with tarfile.open(fileobj=io.BytesIO(raw)) as t:
                members = [m for m in t.getmembers() if m.isfile()]
                body = sum(m.size for m in members)
                self.assertTrue(body <= push.LIM or len(members) == 1, f"{f['name']} 超批上限：{body}")
                for m in members:
                    self.assertTrue(m.uid == 0 and m.gid == 0)
                    got[m.name] = t.extractfile(m).read()
        self.assertEqual(got, {k: v for k, v in data.items() if k != "romfs.img"})
        names = [f["dest"] for f in tars]; self.assertEqual(names, sorted(names))   # 设备按名字序解
        self.assertEqual(tree(self.pk), before)   # 输入只读

    def test_image_direct_and_order(self):
        data = self.make()
        ota = self.run_export()
        self.assertTrue(ota["clear_applied"])
        img = [f for f in ota["files"] if f["dest"] == "romfs.img"]
        self.assertEqual(len(img), 1); self.assertEqual(img[0]["name"], "img/romfs.img")
        self.assertEqual((self.out / "img/romfs.img").read_bytes(), data["romfs.img"])
        self.assertEqual([f["dest"] for f in ota["files"][-2:]], ["index.tsv", "manifest.json"])
        self.assertEqual([f["order"] for f in ota["files"]], list(range(len(ota["files"]))))
        for f in ("index.tsv", "manifest.json"):
            self.assertEqual((self.out / f).read_bytes(), (self.pk / f).read_bytes())

    def test_ota_json_matches_files(self):
        self.make()
        ota = self.run_export()
        disk = json.loads((self.out / "ota.json").read_text(encoding="utf-8"))
        self.assertEqual(disk, ota)
        self.assertEqual((disk["format"], disk["version"], disk["title_id"]), ("s2arm-ota", 1, TID))
        self.assertEqual(disk["index_sha256"], sha((self.pk / "index.tsv").read_bytes()))
        for f in disk["files"]:
            b = (self.out / f["name"]).read_bytes()
            self.assertEqual((f["size"], f["sha256"]), (len(b), sha(b)))
            self.assertFalse(f["name"].startswith("/") or ".." in f["name"].split("/"))
        self.assertEqual(disk["total"], sum(f["size"] for f in disk["files"]))
        listed = {f["name"] for f in disk["files"]} | {"ota.json"}
        self.assertEqual(set(tree(self.out)), listed)   # 输出目录里没有多余文件（.pushed、临时 tar）

    def test_no_image_no_clear(self):
        self.make(img=False)
        ota = self.run_export()
        self.assertFalse(ota["clear_applied"])
        self.assertFalse([f for f in ota["files"] if f["name"].startswith("img/")])

    def test_refuses_bad_input(self):
        self.make()
        with self.assertRaises(push.Fail): ota_pack.export(self.pk, self.out, "xyz", say=self.log.append)
        self.out.mkdir(); (self.out / "keep").write_text("x")
        with self.assertRaises(push.Fail): self.run_export()
        self.assertEqual((self.out / "keep").read_text(), "x")
        with self.assertRaises(push.Fail): ota_pack.export(Path(self.td.name) / "nope", Path(self.td.name) / "o2", TID, say=self.log.append)

    def test_device_layout_imports_through_real_gate(self):
        """⑤ 端到端契约：按 ota.json 的 dest 把文件摆进 Documents/games/<号>/资源包（ios/ota_download.m 落地的样子），
        跑真 runtime/src/pack_apply.c：只到了 tar（清单没到）时库里不算在机上、闸门等；全到后库里可开始、闸门导入、解开后逐字节 = 资源包"""
        cc = shutil.which("cc")
        if not cc: self.skipTest("没有 C 编译器")
        R = Path(__file__).resolve().parents[1]
        drv = Path(self.td.name) / "drv"
        flags = subprocess.run([sys.executable, str(R / "tools/weak_link_decl.py"), "flags", "host"], capture_output=True, text=True).stdout.split()
        b = subprocess.run([cc, "-O1", "-I" + str(R / "runtime/include"), "-DS2A_UNIT_TEST", "-o", str(drv), str(R / "tests/ota_gate/driver.c"), str(R / "runtime/src/pack_apply.c"), *flags], capture_output=True, text=True)
        self.assertEqual(b.returncode, 0, b.stderr[-800:])
        data = self.make(); ota = self.run_export()
        docs = Path(self.td.name) / "Documents"; root = docs / "games" / TID / "资源包"

        def land(f):
            d = root / f["dest"]; d.parent.mkdir(parents=True, exist_ok=True); shutil.copyfile(self.out / f["name"], d)

        def drive(*extra):
            r = subprocess.run([str(drv), str(docs), TID, *extra], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            return dict(l.split("=", 1) for l in r.stdout.splitlines() if "=" in l)
        for f in ota["files"][:-2]: land(f)   # 下到一半：tar 与镜像落地，index.tsv / manifest.json 还没到
        mid = drive()
        self.assertEqual(mid["on_device"], "0")
        self.assertEqual(mid["gate"], "3,3")   # S2A_GATE_WAIT：清单没到，闸门等、不导入
        for f in ota["files"][-2:]: land(f)
        r = drive("apply")
        self.assertEqual(r["on_device"], "1")
        self.assertEqual(r["gate"].split(",")[1], "1")   # S2A_GATE_IMPORT（首轮 SETTLE，稳住后导入）
        self.assertEqual((r["apply"], r["state"], r["quick"]), ("0", "0", "0"))   # 解包成功、就绪、库快判就绪
        self.assertFalse(list((root / ".incoming").glob("*.tar")))   # 解完即删
        for k, v in data.items(): self.assertEqual((root / k).read_bytes(), v, k)

    def test_cli(self):
        self.make()
        rc = ota_pack.main(["export", str(self.pk), str(self.out), "--title-id", TID.lower()])
        self.assertEqual(rc, 0)
        self.assertEqual(json.loads((self.out / "ota.json").read_text())["title_id"], TID)


if __name__ == "__main__":
    unittest.main()
