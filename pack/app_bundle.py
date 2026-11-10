#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Cross-host post-build iOS App assembly. See APP_BUNDLE.md for ownership and limits."""
from __future__ import annotations

import argparse
import io
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import sys
import tempfile
import warnings
import zipfile

if __package__ in (None, ''):
    # A normal script launch adds pack/ to sys.path: its pack.py would shadow
    # the repository's namespace package. Isolated (-I) launches omit it.
    if sys.path and Path(sys.path[0]).resolve() == Path(__file__).resolve().parent:
        sys.path.pop(0)
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from pack.shell.manifest import validate_download_paths


class BundleError(ValueError):
    """App input or output does not satisfy the assembly contract."""


def _plain(path):
    info = path.lstat()
    if (stat.S_ISLNK(info.st_mode) or getattr(info, 'st_file_attributes', 0) & 0x400
            or not (stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode))):
        raise BundleError(f'拒绝链接、重解析点或特殊文件：{path}')
    return info


def _tree(app, *, unsigned=False):
    app = Path(app)
    if not stat.S_ISDIR(_plain(app).st_mode):
        raise BundleError(f'不是 App 目录：{app}')
    app = app.resolve()
    entries, seen = [], set()

    def walk(folder):
        for path in sorted(folder.iterdir()):
            info = _plain(path)  # Check before recursing; never follow a directory link.
            rel = path.relative_to(app).as_posix()
            validate_download_paths([{'path': rel}])
            if rel.casefold() in seen:
                raise BundleError(f'App 路径大小写冲突：{rel}')
            seen.add(rel.casefold())
            if unsigned and path.name in ('_CodeSignature', 'embedded.mobileprovision'):
                raise BundleError(f'组装模板须未签名，发现签名残留：{rel}')
            directory = stat.S_ISDIR(info.st_mode)
            entries.append((path, rel, directory))
            if directory:
                walk(path)
    walk(app)
    return app, entries


def _plist(path):
    if not stat.S_ISREG(_plain(path).st_mode):
        raise BundleError(f'不是普通 plist 文件：{path}')
    try:
        result = plistlib.loads(path.read_bytes())
    except (ValueError, TypeError, OverflowError) as error:
        raise BundleError(f'plist 读不了：{path.name}：{error}') from error
    if not isinstance(result, dict):
        raise BundleError(f'plist 根必须是字典：{path.name}')
    return result


def _executable(info, folder):
    name = info.get('CFBundleExecutable')
    if (not isinstance(name, str) or not name or '/' in name or '\\' in name
            or name in ('.', '..')):
        raise BundleError('CFBundleExecutable 必须是当前 bundle 内的单个文件名')
    validate_download_paths([{'path': name}])
    path = folder / name
    try:
        regular = stat.S_ISREG(_plain(path).st_mode)
    except FileNotFoundError as error:
        raise BundleError(f'缺主程序文件：{name}') from error
    if not regular:
        raise BundleError(f'主程序不是普通文件：{name}')
    return path


def _info(app):
    info = _plist(app / 'Info.plist')
    _executable(info, app)
    return info


def _executable_paths(app, entries):
    result = {_executable(_info(app), app).relative_to(app).as_posix()}
    for path, rel, directory in entries:
        if not directory and path.suffix == '.dylib':
            result.add(rel)
        if directory and path.parent == app / 'Frameworks' and path.suffix == '.framework':
            result.add(_executable(_plist(path / 'Info.plist'), path).relative_to(app).as_posix())
    return result


def _atomic_write(path, data):
    fd, temp = tempfile.mkstemp(prefix='.app-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
        os.chmod(temp, 0o644)
        os.replace(temp, path)
    finally:
        Path(temp).unlink(missing_ok=True)


def _metadata(info, values):
    if not isinstance(values, dict):
        raise BundleError('元数据必须是键值字典')
    updated = dict(info)
    for key, value in values.items():
        if (not isinstance(key, str) or not key or any(ord(c) < 32 for c in key)
                or not (value is None or isinstance(value, str))):
            raise BundleError('元数据键须非空字符串，值只认字符串或 None')
        if value in (None, ''):
            updated.pop(key, None)
        else:
            updated[key] = value
    # Serialize before touching the old plist, including illegal XML characters.
    try:
        return plistlib.dumps(updated, fmt=plistlib.FMT_XML, sort_keys=False)
    except (ValueError, TypeError, OverflowError) as error:
        raise BundleError(f'元数据不能写成 XML plist：{error}') from error


def update_metadata(app_dir, values):
    """Update string keys (empty/None deletes); caller owns an unsigned new build."""
    app, _ = _tree(app_dir, unsigned=True)
    data = _metadata(_info(app), values)
    _executable(plistlib.loads(data), app)
    _atomic_write(app / 'Info.plist', data)


def write_icons(icon_path, app_dir):
    """Write 120/180 PNGs and CFBundleIcons. Missing/empty icon leaves App unchanged."""
    icon = Path(icon_path)
    if not icon.exists() and not icon.is_symlink():
        print(f'【黄】没有图标 {icon}：不加 AppIcon，沿用系统缺省图标')
        return False
    icon_stat = _plain(icon)
    if not stat.S_ISREG(icon_stat.st_mode):
        raise BundleError(f'图标不是普通文件：{icon}')
    if icon_stat.st_size == 0:
        print(f'【黄】空图标 {icon}：不加 AppIcon，沿用系统缺省图标')
        return False
    app, _ = _tree(app_dir, unsigned=True)
    info = _info(app)
    try:
        from PIL import Image
    except ImportError as error:
        raise BundleError('缺 Pillow：请在出包环境手动安装 launchers/macos/requirements-runtime.txt；不会自动下载') from error
    try:
        # Turn Pillow's oversized-input warning into a failure, not a silent huge allocation.
        with warnings.catch_warnings():
            warnings.simplefilter('error', Image.DecompressionBombWarning)
            with Image.open(icon) as image:
                image.load()
                image = image.convert('RGB')
                rendered = []
                for scale, size in ((2, 120), (3, 180)):
                    data = io.BytesIO()
                    image.resize((size, size), Image.Resampling.LANCZOS).save(data, format='PNG')
                    rendered.append((app / f'AppIcon60x60@{scale}x.png', data.getvalue()))
    except (OSError, ValueError, Image.DecompressionBombError, Image.DecompressionBombWarning) as error:
        raise BundleError(f'图标打不开或缩放失败：{icon.name}：{error}') from error
    info['CFBundleIcons'] = {'CFBundlePrimaryIcon': {'CFBundleIconFiles': ['AppIcon60x60']}}
    plist_data = plistlib.dumps(info, fmt=plistlib.FMT_XML, sort_keys=False)
    for path, data in rendered:
        _atomic_write(path, data)
    _atomic_write(app / 'Info.plist', plist_data)
    return True


def _destination(path, app):
    path = Path(path)
    if os.path.lexists(path):
        raise BundleError(f'不覆盖已有目标：{path}')
    dest = path.resolve()
    if dest.is_relative_to(app) or app.is_relative_to(dest):
        raise BundleError('输出不能和源 App 重叠')
    dest.parent.mkdir(parents=True, exist_ok=True)
    return dest


def assemble(template_app, output_app, *, bundle_id, display_name, icon, metadata=None, localized_names=None):
    """Copy a read-only, previously verified unsigned template; atomically publish a new App."""
    if (not isinstance(bundle_id, str)
            or not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', bundle_id)):
        raise BundleError('包名须为显式的反向域名形式')
    if not isinstance(display_name, str) or not display_name.strip():
        raise BundleError('显示名须为非空字符串')
    if not display_name.isascii():   # 侧载工具（AltServer 等）拿 CFBundleDisplayName 建 App ID，苹果只收 ASCII；本地化名走 localized_names
        raise BundleError(f'Info.plist 的显示名须为 ASCII（中文名放 localized_names）：{display_name}')
    if Path(output_app).name != 'S2Arm.app':
        raise BundleError('输出目录名必须是 S2Arm.app，显示名由 plist 决定')
    source, entries = _tree(template_app, unsigned=True)
    _info(source)
    values = dict(metadata or {})
    values.update(CFBundleIdentifier=bundle_id, CFBundleDisplayName=display_name)
    _metadata(_info(source), values)  # Validate before copying or publishing.
    dest = _destination(output_app, source)
    temp = Path(tempfile.mkdtemp(prefix='.assemble-', dir=dest.parent))
    try:
        for path, rel, directory in entries:
            target = temp / rel
            if directory:
                target.mkdir()
            else:
                before = _plain(path)
                shutil.copyfile(path, target)
                after = _plain(path)
                if ((before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns)
                        or target.stat().st_size != before.st_size):
                    raise BundleError(f'复制期间模板文件变了：{rel}')
        update_metadata(temp, values)
        for lang, name in sorted((localized_names or {}).items()):   # 本地化显示名：<语言>.lproj/InfoPlist.strings（手机按系统语言显示，Info.plist 本体保持 ASCII）
            if not re.fullmatch(r'[A-Za-z]{2,3}(?:[-_][A-Za-z0-9]+)*', lang) or not isinstance(name, str) or not name.strip():
                raise BundleError(f'本地化显示名不合法：{lang}={name!r}')
            esc = name.replace('\\', '\\\\').replace('"', '\\"')
            d = temp / f'{lang}.lproj'; d.mkdir(exist_ok=True)   # 模板壳自带同语言 .lproj（宿主界面字符串表 S2ArmHost.strings，#316）：并进去，不覆盖原表
            (d / 'InfoPlist.strings').write_text(f'"CFBundleDisplayName" = "{esc}";\n', encoding='utf-8', newline='\n')
        write_icons(icon, temp)
        _, copied = _tree(temp, unsigned=True)
        executable = _executable_paths(temp, copied)
        for path, rel, directory in copied:
            path.chmod(0o755 if directory or rel in executable else 0o644)
        temp.chmod(0o755)
        if os.path.lexists(dest):
            raise BundleError(f'不覆盖已有目标：{dest}')
        temp.rename(dest)
        return dest
    finally:
        if temp.exists():
            shutil.rmtree(temp)


def _zip_entry(name, directory, executable=False):
    entry = zipfile.ZipInfo(name)
    entry.create_system = 3
    mode = 0o755 if directory or executable else 0o644
    kind = stat.S_IFDIR if directory else stat.S_IFREG
    entry.external_attr = ((kind | mode) << 16) | (0x10 if directory else 0)
    entry.compress_type = zipfile.ZIP_STORED if directory else zipfile.ZIP_DEFLATED
    return entry


# 非 zip64 归档的物理上限（条目数 / 字节数）：侧载工具不认 zip64（见下面的注释），超了 zipfile 在写条目 / 收尾时才抛
#   LargeZipFile——它不是 OSError，调用方（pack/ipa_tail.py 的「打 ipa」步）原先把整段原因丢掉，玩家的错误码只能落到
#   package_failed「原因没认出来」（#11：9.78 GB 的 PERSONA4 The GOLDEN 停在出包 2/5）。那单的具体原因是哪一条以红行原文为准，
#   这里只负责：真撞到上限时给一条读得懂的红行，不落成裸 traceback。
ZIP32_MAX = zipfile.ZIP64_LIMIT              # 单条 / 整份字节上限（2 GiB − 1）
ZIP32_ENTRIES = zipfile.ZIP_FILECOUNT_LIMIT  # 条目数上限（65535）


def _zip32_budget(entries):
    """归档前的体积账（只 lstat，不读内容）：→ (条目数, 文件总字节, 最大的那个文件 (相对路径, 字节))。
    条目数与单文件上限能提前判死；整份的字节上限取决于压缩后大小，写的时候才知道（见 write_ipa 的 LargeZipFile 分支）。"""
    count, total, biggest = 0, 0, ('', 0)
    for path, rel, directory in entries:
        count += 1
        if directory:
            continue
        size = _plain(path).st_size
        total += size
        if size > biggest[1]:
            biggest = (rel, size)
    return count, total, biggest


BIG = 64 * 1024 * 1024   # zip64 模式下这么大以上的文件先抽样试压：压不下去（游戏镜像多半已压缩）就原样存，省掉几十 GB 的无用 deflate


def _deflate_pays(path, size, samples=8, chunk=4 * 1024 * 1024, ratio=0.97):
    """大文件抽 samples 段、每段 chunk 字节，zlib 1 级试压；整体能压到 ratio 以下才值得 deflate"""
    import zlib
    raw = packed = 0
    with path.open('rb') as f:
        for i in range(samples):
            f.seek(size * i // samples)
            b = f.read(chunk)
            raw += len(b)
            packed += len(zlib.compress(b, 1))
    return raw > 0 and packed < raw * ratio


def write_ipa(signed_app, output_ipa, *, zip64=False):
    """Archive only: never mutate signed bytes. Permissions derive from bundle metadata.
    zip64=True：单款游戏 App 包里带着整份资源包（6–30 GB，tools/single_game_app.py），超过 zip 32 位上限只能 zip64（iOS 安装与 Xcode 导出的大 IPA 同格式）；
      大文件抽样试压、压不下去就原样存（ZIP_STORED），能压的用 1 级 deflate。缺省 False 保持原样：不写 zip64（侧载工具 AltServer for Windows 不认，见下）"""
    app, entries = _tree(signed_app)
    executable = _executable_paths(app, entries)
    count, total, (biggest, biggest_size) = _zip32_budget(entries)
    if count > ZIP32_ENTRIES and not zip64:
        raise BundleError(f'App 有 {count} 个条目，超过非 zip64 归档的 {ZIP32_ENTRIES} 个上限（侧载工具读不了 zip64）')
    dest = _destination(output_ipa, app)
    fd, name = tempfile.mkstemp(prefix='.ipa-', dir=dest.parent)
    temp = Path(name)
    try:
        try:
            with os.fdopen(fd, 'w+b') as stream, zipfile.ZipFile(stream, 'w', allowZip64=zip64) as archive:
                prefix = 'Payload/S2Arm.app/'
                archive.writestr(_zip_entry('Payload/', True), b'')
                archive.writestr(_zip_entry(prefix, True), b'')
                for path, rel, directory in entries:
                    entry = _zip_entry(prefix + rel + ('/' if directory else ''), directory, rel in executable)
                    if directory:
                        archive.writestr(entry, b'')
                    else:
                        before = _plain(path)
                        # 不写 zip64（11-04 S0-5）：AltServer for Windows 1.8.1 自带 minizip 1.01e 不认 zip64，强制 zip64 时本地头写占位大小、与中央目录不一致，
                        #   打开条目即 UNZ_BADZIPFILE，侧载报「An unknown error occured while reading the file」。单个文件到 zip 32 位上限就报红，不静默改写格式
                        if before.st_size > ZIP32_MAX and not zip64:
                            raise BundleError(f'单个文件超过 zip 32 位上限、侧载工具读不了：{rel}（{before.st_size} 字节）')
                        big = zip64 and before.st_size >= BIG
                        if big:
                            entry.file_size = before.st_size
                            if _deflate_pays(path, before.st_size):
                                try:
                                    entry.compress_level = 1   # Python ≥ 3.13
                                except AttributeError:
                                    entry._compresslevel = 1   # 3.12 及更早的属性名
                            else:
                                entry.compress_type = zipfile.ZIP_STORED
                        with path.open('rb') as source, archive.open(entry, 'w', force_zip64=zip64 and before.st_size > 0x7FFF0000) as target:
                            shutil.copyfileobj(source, target, length=(16 if big else 1) * 1024 * 1024)
                        after = _plain(path)
                        if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
                            raise BundleError(f'归档期间文件变了：{rel}')
        except zipfile.LargeZipFile as error:   # 压缩后装不下：给一条带体积账的红行，别让它变成裸 traceback（父进程只看得到退出码）
            raise BundleError(f'非 zip64 的 IPA 装不下这份 App：{count} 个条目、文件合计 {total} 字节、最大 {biggest} {biggest_size} 字节；'
                              f'zipfile 报「{error}」') from error
        # Atomic no-replace publication on both hosts; no fallback that overwrites an existing IPA.
        os.link(temp, dest)
        return dest
    finally:
        temp.unlink(missing_ok=True)


def _values(arguments):
    values = {}
    for item in arguments:
        key, separator, value = item.partition('=')
        if not separator or key in values:
            raise BundleError('--set 须为不重复的 KEY=VALUE，空值删键')
        values[key] = value
    return values


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    icons = commands.add_parser('write_icons')
    icons.add_argument('icon')
    icons.add_argument('app')
    metadata = commands.add_parser('update_metadata')
    metadata.add_argument('app')
    metadata.add_argument('--set', action='append', default=[])
    build = commands.add_parser('assemble')
    build.add_argument('template')
    build.add_argument('output')
    build.add_argument('--bundle-id', required=True)
    build.add_argument('--display-name', required=True)
    build.add_argument('--icon', required=True)
    build.add_argument('--set', action='append', default=[])
    ipa = commands.add_parser('write_ipa')
    ipa.add_argument('app')
    ipa.add_argument('output')
    args = parser.parse_args(argv)
    try:
        if args.command == 'write_icons':
            write_icons(args.icon, args.app)
        elif args.command == 'update_metadata':
            update_metadata(args.app, _values(args.set))
        elif args.command == 'assemble':
            print(assemble(args.template, args.output, bundle_id=args.bundle_id,
                           display_name=args.display_name, icon=args.icon, metadata=_values(args.set)))
        else:
            print(write_ipa(args.app, args.output))
    except (OSError, ValueError, RuntimeError, zipfile.LargeZipFile) as error:
        # LargeZipFile 不是 OSError（zipfile 自己的异常类型）：write_ipa 里已转成带体积账的 BundleError，
        #   这里再兜一层，任何一条路都不许落成裸 traceback——父进程只拿得到退出码，原因就断了。
        print(f'【红】App 组装：{error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8')
    sys.stderr.reconfigure(encoding='utf-8')
    raise SystemExit(main())
