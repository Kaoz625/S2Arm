#!/usr/bin/env python3
"""Xcode 导出 iOS App 时写进 Info.plist 的构建环境键（DT* 等）：从本机 xcodebuild / xcrun / sw_vers 读真值，写进 App 与内嵌 framework。
make ios 出的壳（runtime/build.mk）没有这些键；Xcode 的 Organizer / 部分签名与分发工具（含 xcodebuild -exportArchive）按它们认「这是 iphoneos 的 App」，
NS2Pro.framework 缺它们时导出报错（11-09 单款游戏 App 线）。只在 Mac 上跑。

  xcode_keys.py <App>        打印读到的值并写进 <App>/Info.plist 与 <App>/Frameworks/*.framework/Info.plist
"""
import plistlib
import re
import subprocess
import sys
from pathlib import Path


def _run(*cmd):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode or not r.stdout.strip():
        raise RuntimeError(f"{' '.join(cmd)} 失败：{(r.stderr or r.stdout).strip()[-200:]}")
    return r.stdout.strip()


def read_keys():
    """→ 本机 Xcode / iOS SDK / macOS 的构建环境键（值全是字符串，LSRequiresIPhoneOS 为真）"""
    xv = _run("xcodebuild", "-version")
    m = re.search(r"Xcode (\d+)(?:\.(\d+))?(?:\.(\d+))?", xv); b = re.search(r"Build version (\S+)", xv)
    if not m or not b:
        raise RuntimeError(f"认不出 xcodebuild -version：{xv!r}")
    major, minor, patch = int(m[1]), int(m[2] or 0), int(m[3] or 0)
    sdk = _run("xcrun", "--sdk", "iphoneos", "--show-sdk-version")
    sdk_build = _run("xcrun", "--sdk", "iphoneos", "--show-sdk-build-version")
    return {
        "BuildMachineOSBuild": _run("sw_vers", "-buildVersion"),
        "DTCompiler": "com.apple.compilers.llvm.clang.1_0",
        "DTPlatformBuild": sdk_build,
        "DTPlatformName": "iphoneos",
        "DTPlatformVersion": sdk,
        "DTSDKBuild": sdk_build,
        "DTSDKName": f"iphoneos{sdk}",
        "DTXcode": f"{major:02d}{minor}{patch}",   # Xcode 26.1 → 2610，同 Xcode 自己写的格式
        "DTXcodeBuild": b[1],
        "LSRequiresIPhoneOS": True,
    }


def stamp(app, keys=None):
    """把键写进 App 与 Frameworks/*.framework 的 Info.plist（原格式写回）；→ 改了的 plist 相对路径"""
    app = Path(app); keys = keys or read_keys(); done = []
    for p in [app / "Info.plist", *sorted((app / "Frameworks").glob("*.framework/Info.plist"))]:
        raw = p.read_bytes()
        fmt = plistlib.FMT_BINARY if raw.startswith(b"bplist") else plistlib.FMT_XML
        info = plistlib.loads(raw); info.update(keys)
        p.write_bytes(plistlib.dumps(info, fmt=fmt, sort_keys=False))
        done.append(p.relative_to(app).as_posix())
    return done


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__); sys.exit(2)
    k = read_keys()
    for n, v in k.items(): print(f"{n}\t{v}")
    print("写进：" + " ".join(stamp(sys.argv[1], k)))
