"""单款游戏 App 出包（tools/single_game_app.py、pack/app_bundle.py write_ipa zip64、pack/xcode_keys.py）单测：合成小件，不读游戏文件、不调 Xcode。
  ① 导出核对：同一款才收；文件缺 / 大小不对 / 小文件 sha256 不对 / 清单不在最后报失败
  ② 导出放进包里 Games/<号>/ota/：只放 ota.json 列的文件 + ota.json，逐字节相同（APFS 上是克隆）
  ③ 主屏名：Info.plist 是 ASCII（撇号去掉），各语言 InfoPlist.strings 是原样名；给了主屏名时拉丁文字语言换成它、中日韩保留游戏自带名
  ④ write_ipa zip64：大文件抽样试压——压不下去的原样存（STORED）、能压的 deflate；归档逐字节可读；缺省（非 zip64）行为不变
  ⑤ 构建环境键写进 App 与内嵌 framework 的 Info.plist（二进制 / XML 原格式写回）"""
import hashlib, json, os, plistlib, sys, tempfile, unittest, zipfile
from pathlib import Path
R = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(R / "tools")); sys.path.insert(0, str(R))
import single_game_app as sga
from pack import app_bundle, xcode_keys

GID = "0100ABCD12340000"


def sha(b): return hashlib.sha256(b).hexdigest()


class SingleGame(unittest.TestCase):
    def setUp(self):
        self.td = tempfile.TemporaryDirectory(); self.d = Path(self.td.name)

    def tearDown(self): self.td.cleanup()

    def export(self):
        e = self.d / "ota"; files = {"img/romfs.img": os.urandom(3000), "tars/1_000.tar": b"T" * 1024, "index.tsv": b"i\n", "manifest.json": b"{}"}
        dests = {"img/romfs.img": "romfs.img", "tars/1_000.tar": ".incoming/1_000.tar", "index.tsv": "index.tsv", "manifest.json": "manifest.json"}
        fl = []
        for i, (n, b) in enumerate(files.items()):
            (e / n).parent.mkdir(parents=True, exist_ok=True); (e / n).write_bytes(b)
            fl.append(dict(name=n, dest=dests[n], size=len(b), sha256=sha(b), order=i))
        (e / "stray.txt").write_text("not listed")
        o = dict(format="s2arm-ota", version=1, title_id=GID, total=sum(map(len, files.values())), clear_applied=True, files=fl)
        (e / "ota.json").write_text(json.dumps(o)); return e, o, files

    def test_check_export(self):
        e, o, _ = self.export()
        self.assertEqual(sga.check_export(e, GID)["title_id"], GID)
        with self.assertRaises(sga.Fail): sga.check_export(e, "0100000000000000")
        (e / "tars/1_000.tar").write_bytes(b"T" * 1023)
        with self.assertRaises(sga.Fail): sga.check_export(e, GID)
        (e / "tars/1_000.tar").write_bytes(b"X" * 1024)   # 同大小、内容不对：小文件核 sha256
        with self.assertRaises(sga.Fail): sga.check_export(e, GID)

    def test_place_export(self):
        e, o, files = self.export()
        dest = self.d / "S2Arm.app/Games" / GID / "ota"
        sga.place_export(e, o, dest)
        got = {p.relative_to(dest).as_posix(): p.read_bytes() for p in dest.rglob("*") if p.is_file()}
        self.assertEqual(got, dict(files, **{"ota.json": (e / "ota.json").read_bytes()}))   # stray.txt 不进包

    def test_names(self):
        kit = self.d / "kit/ctl"; kit.mkdir(parents=True)
        nacp = bytearray(0x4000)
        for lang, name in ((0, "The Legend of Zelda: Link's Awakening"), (1, "The Legend of Zelda: Link's Awakening"), (14, "塞尔达传说 织梦岛")):
            b = name.encode(); nacp[lang * 0x300:lang * 0x300 + len(b)] = b
        (kit / "control.nacp").write_bytes(bytes(nacp))
        plain, loc = sga.names_for(kit.parent, None)
        self.assertEqual(plain, "The Legend of Zelda Links Awakening")
        self.assertEqual(loc["en"], "The Legend of Zelda: Link's Awakening")
        plain, loc = sga.names_for(kit.parent, "Link's Awakening")
        self.assertEqual((plain, loc["en"], loc["zh-Hans"]), ("Links Awakening", "Link's Awakening", "塞尔达传说 织梦岛"))
        app = self.d / "A.app"; app.mkdir(); sga.write_lproj(app, loc)
        self.assertEqual((app / "en.lproj/InfoPlist.strings").read_text(encoding="utf-8"), '"CFBundleDisplayName" = "Link\'s Awakening";\n')

    def fake_app(self):
        app = self.d / "S2Arm.app"; (app / "Frameworks/X.framework").mkdir(parents=True)
        (app / "S2Arm").write_bytes(b"\xcf\xfa\xed\xfe" + b"\0" * 60)
        (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "S2Arm", "CFBundleIdentifier": "a.b"}))
        (app / "Frameworks/X.framework/X").write_bytes(b"x")
        (app / "Frameworks/X.framework/Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "X"}, fmt=plistlib.FMT_BINARY))
        return app

    def test_write_ipa_zip64(self):
        app = self.fake_app(); g = app / "Games" / GID / "ota"; g.mkdir(parents=True)
        rnd, zer = os.urandom(200_000), b"\0" * 200_000
        (g / "img.bin").write_bytes(rnd); (g / "zero.bin").write_bytes(zer)
        big0 = app_bundle.BIG; app_bundle.BIG = 100_000
        try:
            ipa = app_bundle.write_ipa(app, self.d / "x.ipa", zip64=True)
        finally:
            app_bundle.BIG = big0
        with zipfile.ZipFile(ipa) as z:
            pre = f"Payload/S2Arm.app/Games/{GID}/ota/"
            self.assertEqual(z.getinfo(pre + "img.bin").compress_type, zipfile.ZIP_STORED)
            self.assertEqual(z.getinfo(pre + "zero.bin").compress_type, zipfile.ZIP_DEFLATED)
            self.assertEqual((z.read(pre + "img.bin"), z.read(pre + "zero.bin")), (rnd, zer))
            self.assertIsNone(z.testzip())
        ipa2 = app_bundle.write_ipa(app, self.d / "y.ipa")   # 缺省：不写 zip64、照旧全 deflate
        with zipfile.ZipFile(ipa2) as z:
            self.assertTrue(all(i.compress_type == zipfile.ZIP_DEFLATED for i in z.infolist() if not i.is_dir()))

    def test_xcode_keys_stamp(self):
        app = self.fake_app()
        keys = {"DTPlatformName": "iphoneos", "DTSDKName": "iphoneos27.2", "DTXcode": "2720", "LSRequiresIPhoneOS": True}
        done = xcode_keys.stamp(app, keys)
        self.assertEqual(done, ["Info.plist", "Frameworks/X.framework/Info.plist"])
        for p in done:
            info = plistlib.loads((app / p).read_bytes())
            for k, v in keys.items(): self.assertEqual(info[k], v, (p, k))
        self.assertTrue((app / done[1]).read_bytes().startswith(b"bplist"))   # 原格式写回
        self.assertEqual(plistlib.loads((app / "Info.plist").read_bytes())["CFBundleIdentifier"], "a.b")


if __name__ == "__main__":
    unittest.main()
