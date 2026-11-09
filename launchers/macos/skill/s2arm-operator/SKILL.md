---
name: s2arm-operator
description: 替玩家操作 S2Arm（把玩家自己的 Switch 游戏导出成 iPhone / iPad 或 Mac 能玩的版本、装到手机上的启动器）：从下载启动器、导入密钥和游戏、导出、装到 iPhone，到排查每一步出的问题。玩家说「用 S2Arm 帮我把 XX 装到 iPhone」「S2Arm 出包失败了」「帮我看看 S2Arm 卡在哪」「手机上打不开」时用。
---

# S2Arm 操作手册（给替玩家操作的 AI）

S2Arm 把玩家**自己的** Switch 游戏导出成能在 iPhone / iPad（同一个包）或这台 Mac 上玩的版本，再装到手机上。你通过命令行工具 `s2armctl` 操作 S2Arm 的窗口：每条命令都等于玩家点了对应按钮，**玩家在屏幕上看得到你做的每一步**，不要在后台另起无界面的进程代替它。

工具位置：玩家复制给你的提示词里写着（缺省是 `/Applications/S2Arm.app/Contents/Resources/s2armctl`）。提示词里的命令带 `--data-root` 时，每条命令都要带上。下文写作 `s2armctl`。

## 底线

- 只在这台 Mac 上操作。不上传、不拷到别处、不打印 prod.keys、游戏文件（NSP / XCI / NCA）和资源包的内容。
- 密钥和游戏只用玩家给的路径；不去网上找、下载或生成。
- **只有玩家本人能做的事，停下来告诉他怎么做，等他说做完**：点 macOS 的系统授权框、输开机密码、装 / 打开 Xcode、在 Xcode 里登录 Apple ID、在 iPhone 上点「信任」/ 打开开发者模式 / 重启、用 AltStore 登录 Apple ID。
- 删除游戏、清理磁盘这类有破坏性的操作，先问玩家同意。
- 同一个错误按下面的办法处理后重试一次还不行，就生成诊断包交给玩家反馈（见最后一节），不要反复试、不要猜着改文件。

## 玩家用的是 Windows

命令和主流程相同，差别只有这些：

- 工具是启动器目录里的 `s2armctl.cmd`，用 `s2armctl.cmd start` 打开窗口并接上。也可以请玩家在「环境检查」页打开「允许 AI 操作 S2Arm」。
- Windows 只出 iPhone / iPad 包：`prepare`、`launch`、`build <游戏号> mac`、`target`、`targets` 会被拒绝，不要用。
- 装到手机走 Impactor：Apple ID 只能玩家本人在 Impactor 里登录，`install-check` 里没打勾的项照它说的请玩家做。`install` 已包含拷资源包，不用 `device` 和 `push-pack`。
- 还没有的功能：`delete`、`diag pull`。`diag export <输出.zip>` 可用。排查用 `errors` 和 `logs`。
- 下文里的 Xcode、App Store、macOS 授权框只适用于 Mac。

## 更新

启动器发现新版会在后台下载，玩家数据不受影响。`s2armctl update` 看状态，下好后（state = ready）先问玩家，同意了再 `s2armctl update restart`。出包、装机进行中不能重启。

## 还没装 S2Arm：从 GitHub 开始

1. 从 GitHub Releases 下最新版 `S2Arm-mac-arm64.dmg`：`gh release download --repo jhaizhou-ops/S2Arm --pattern S2Arm-mac-arm64.dmg`（没有 `gh` 就让玩家打开 https://github.com/jhaizhou-ops/S2Arm/releases/latest 下载）。Windows 玩家不走这份手册。
2. 打开 dmg，把 `S2Arm.app` 拖进「应用程序」（`/Applications`）。已经有旧版就先问玩家是否替换。已公证，不用手动放行。
3. 运行 `/Applications/S2Arm.app/Contents/Resources/s2armctl start`：它会**打开 S2Arm 窗口**并接上控制口，玩家能看到启动器启动。
4. 接着按下面的主流程做。

## 主流程：反复问「下一步」，照做

```bash
s2armctl start          # 连上 S2Arm（没开就打开窗口）
s2armctl next           # 现在走到哪一步、下一步做什么、谁来做、为什么
s2armctl next --json    # 同上，给程序读：{step, who, do, why, game, task, code, suggestion, log, ipa, others, note}
```

| who | 你怎么做 |
|---|---|
| `ai` | 照 `do` 里的命令执行 |
| `ask` | 先问玩家要一个输入（prod.keys 或游戏文件夹在哪），拿到后执行 `do` |
| `human` | 只能玩家本人做：把 `do` 用大白话告诉玩家，等他说做完再 `next` |
| `confirm` | 有破坏性：先说明要做什么、问玩家同意，同意了再执行 |

默认目标是 iOS，流程依次是检查环境、导入密钥和游戏、导出、装到 iPhone、请玩家打开游戏。每做完一步就再运行 `next`。库里有多款游戏时，`next` 按本体大小选主游戏，其余列在 `others`。可以用 `next <游戏号>` 指定另一款。

如果玩家要在这台 Mac 上玩，每次运行 `s2armctl next <游戏号> --target mac`（也可加 `--json`）。未准备的游戏会提示 `s2armctl build <游戏号> mac`，用 `s2armctl wait <游戏号> --op build` 等待。准备好后，按提示运行 `s2armctl launch <游戏号>`。如果返回「运行中」，请玩家查看游戏窗口即可。Windows 只支持 `--target ios`。

`next` 收到无法识别的选项或多余的位置参数时，会打印用法并以状态码 `2` 退出。

## 各步命令

```bash
s2armctl keys <prod.keys 路径>              # 放密钥，等导入完成才返回
s2armctl games <游戏文件夹>                  # 放游戏：本体、更新、DLC 放同一个文件夹；等导入完成才返回
s2armctl build <游戏号> ios                  # 导出 iPhone / iPad 版（同一个包）；mac = 这台 Mac；android / harmony 即将上线
s2armctl customize <游戏号> --name 名字 --cover 图片  # 改游戏显示名 / 封面；--reset-name、--reset-cover 恢复默认；下次装到 iPhone 时带上
s2armctl wait <游戏号> --op ipa --timeout 7200   # 等导出结束：逐段打进度，结尾打每段耗时；失败退出码 1
s2armctl install-check <游戏号>              # 装机前清单：iPhone 版、Xcode 登录 Apple ID、数据线连上、信任、开发者模式
s2armctl install <游戏号>                    # 装到 iPhone：签名 → 数据线安装 → 拷游戏资源、逐文件核对
s2armctl wait <游戏号> --op install --timeout 3600
s2armctl device <游戏号>                     # iPhone 连没连、这款游戏装没装
s2armctl push-pack <游戏号>                  # 只拷游戏资源（App 已装好、资源不全时）
s2armctl state | errors [游戏号] | logs <任务号|游戏号> [--lines N]
```

`s2armctl help` 打出的是最新全表，以它为准。

## 遇到问题怎么办

先看 `s2armctl next`（出错时带 `code` 和处理办法）和 `s2armctl errors <游戏号>`（原因、建议、日志位置和日志末尾；每条诊断附 failureSummary：失败阶段、退出码、最后几行原文）。按下面对号处理。

### 环境（这台 Mac）

| 现象 / 错误码 | 谁 | 怎么办 |
|---|---|---|
| `xcode_unavailable` 没装 Xcode | human | 请玩家在 App Store 装 Xcode（免费，体积大，要一段时间），装好后打开一次、同意许可，然后 `s2armctl env` |
| `xcode_setup_required` | human | 请玩家打开 Xcode 同意许可、等组件装完（可能要输开机密码），然后 `s2armctl env` |
| `xcode_sdk_too_old` | human | 请玩家在 App Store 更新 Xcode，然后 `s2armctl env` |
| `metal_unavailable` 缺 Metal 编译组件 | human | 请玩家在 S2Arm「设置 → 运行与构建环境」点「一键下载」，然后 `s2armctl env` |
| `ios_platform_missing` 缺 Xcode 的 iOS 平台组件 | human | 请玩家在 S2Arm「设置 → 运行与构建环境」的「iOS 平台组件」点「一键下载」（约 8 GB），然后 `s2armctl env`；只在 Mac 上玩不需要 |
| `dotnet_sdk_missing` | human | 请玩家在同一处点安装，然后 `s2armctl env` |
| 等系统授权（`next` 说 S2Arm 要读某个文件夹） | human | 请玩家在屏幕上的系统框里点「允许」 |
| `architecture_unsupported` / `os_unsupported` | human | 告诉玩家：需要 Apple 芯片的 Mac / 更新的 macOS，这台跑不了或要先升级 |

### 密钥与游戏文件

| 现象 / 错误码 | 谁 | 怎么办 |
|---|---|---|
| `keys_missing` / `keys_invalid` | ask | 问玩家自己的 prod.keys 在哪，`keys <路径>`；文件不完整就请他换一份完整的 |
| `content_unreadable` 无法读取 | human | 核对源文件和票据是否完整 |
| `ticket_missing` 缺少票据 | human | 核对源文件是否含有所需票据 |
| `content_truncated` 文件不完整 | human | 从原始位置重新复制完整的游戏文件 |
| `keys_outdated` 密钥版本不足 | human | 请玩家换一份版本更新的、自己的 prod.keys，再 `keys <路径>` |
| `input_base_missing` | ask | 只放了更新或 DLC：问玩家游戏本体在哪，`games <本体所在文件夹>` |
| `input_empty` / `input_type_unsupported` | ask | 文件夹里没有 NSP / XCI / NSZ / XCZ：问玩家游戏文件到底在哪 |
| `input_missing` / `content_invalid` | ask | 文件找不到（外接盘没接）或损坏：请玩家接上磁盘或换一份完整的原版文件 |
| `input_permission` / `permission_denied` | human | 系统不让读：请玩家在系统框点「允许」，或把文件挪出「下载 / 桌面 / 文稿」到普通文件夹 |
| `guest_isa_unsupported` | human | 这款是 32 位程序，暂不支持：告诉玩家换一款 |

### 导出（出包）

- **要多久**：大游戏第一次导出几十分钟到一个多小时，中小游戏几分钟。请玩家插上电源、别让 Mac 睡眠。用 `wait` 看进度，**进度在动就别取消**。
- **像是卡住了**：`wait` 超过 15 分钟没有任何变化时，`s2armctl logs <游戏号> --lines 60` 看日志末尾：末行还在更新 = 还在做（着色器编译阶段日志可能很久才写一行），继续等；日志停了很久 = 卡住，`s2armctl cancel <任务号>` 后 `retry` 一次。
- 错误码：

| 错误码 | 谁 | 怎么办 |
|---|---|---|
| `library_not_apfs` 游戏库所在磁盘格式不支持 | confirm | 游戏原件放哪块盘都行（S2Arm 原地只读、不复制）；导出时的工作数据（游戏库）要放在 APFS 格式的磁盘上（Mac 内置盘就是）：问玩家同意后，请他在「设置 → 游戏库与玩家数据」改用这台 Mac 上的默认位置，或选一块 APFS 外接盘（「磁盘工具」里另分一个 APFS 分区，盘上要有空闲空间、原有数据不动），然后 `s2armctl env`；游戏原件不用挪 |
| `disk_full` | confirm | 磁盘不够：`state --json` 看各游戏 `bytes`，征得同意后 `delete <不要的游戏号>`，或请玩家清理磁盘；然后 `retry <任务号>`。磁盘预检偏保守时，玩家同意后可以 `build <游戏号> <平台> --space-override`（同界面「仍然继续」，真写满会停下报错） |
| `stage_timeout` | ai | `logs` 看卡在哪；`retry <任务号>` 一次 |
| `configuration_failed` / `shader_extract_failed` / `rewrite_failed` / `compilation_failed` | ai | 不是玩家的问题：`retry` 一次；还失败就 `s2armctl diag export ~/Desktop/S2Arm-诊断.zip` 导出诊断包、帮玩家反馈（见「反馈问题」） |
| `aoc_missing`（警告） | ai | 本体照常装；告诉玩家有追加内容没进包，生成诊断包反馈 |
| `target_unsupported` | human | 手机芯片太老或系统太旧（要 A14 及以上、iOS 18 及以上）：告诉玩家 |
| 其他 | ai | `logs <任务号>` 看原因；偶发的 `retry` 一次，再失败生成诊断包 |

### 装到 iPhone

先 `install-check <游戏号>`，没打勾的项原样告诉玩家，玩家做完再查；全齐了再 `install`。启动器出的包是自签的，要用玩家自己在 Xcode 里登录的 Apple ID（免费的就行）重签，`install` 会自动完成。

`install` 是把这款加进同一个 S2Arm App（所有游戏共用一个 App，覆盖安装不丢其他款的数据）。装机要求电脑只连一台 iPhone。单款 App 路径（旧版一款一个包）已没有。

要从 iPhone 删一款游戏用 `uninstall <游戏号>`：删之前自动备份这款的存档到电脑，然后更新 S2Arm App（其余游戏不动），再清掉手机上这款的文档数据。

| 现象 / 错误码 | 谁 | 怎么办 |
|---|---|---|
| 第一次装机卡在签名 | human | Mac 弹了钥匙串授权框：请玩家输入 Mac 登录密码，点「始终允许」（不点会 10 分钟超时）。开发证书和描述文件由 Xcode 自动建，不用手动建 |
| `xcode_team_pending` | human | Apple ID 登录了但这台 Mac 没有签名团队：`s2armctl signing-project` 打开引导项目，请玩家在 Xcode 选 Personal Team，连手机点运行一次；已知 Team ID 时可用 `install <游戏号> --team <10 位>` |
| `signing_certificate_missing` | human | 请玩家在 Apple Accounts 里选中账号 → Manage Certificates → + → Apple Development |
| `xcode_account_missing` | human | 请玩家打开 Xcode →「设置」→「账户」，点「+」登录 Apple ID（要输密码，你不代做） |
| `device_not_connected` / 连着不止一台 | ask | 请玩家用数据线只连要装的那台、解锁、在手机上点「信任」 |
| `device_pairing_required` | human | 请玩家拔掉重插、解锁，在手机上重新点「信任此电脑」 |
| `developer_mode_required` | human | 请玩家在 iPhone「设置 → 隐私与安全性 → 开发者模式」打开，按提示重启，重启后解锁 |
| `device_locked` | human | 请玩家解锁手机、停在主屏幕，装的过程中别锁屏 |
| `free_app_limit` | human | 免费 Apple ID 同时最多 3 个自签 App、每 7 天最多 10 个新包名：请玩家删掉不玩的自签 App，或过几天再装 |
| `provisioning_expired` / `signing_failed` | ai | 再 `install` 一次（会重新申请）；还不行 `logs` 看签名哪步报错，必要时改用 AltStore（启动器「装到 iPhone」页底部有步骤，玩家本人登录） |
| `manual_unpack_required`（警告） | human | 资源包已传完，电脑拉不起手机上的 App：让玩家在 iPhone 上打开这款游戏、保持前台等导入完，不要重推 |
| `usb_slow`（警告） | human | 数据线是 USB 2：换 USB 3 的 USB-C 线、直插 Mac 会快很多（只有 iPhone 15 Pro 及更新的 Pro 机型支持 USB 3） |
| `shell_sdk_old`（警告） | human | 包是旧版 Xcode 出的、iPhone 系统更新：iPhone Duo 等新机型上 App 缩小居中。请玩家更新 Xcode（不低于 iPhone 系统大版本）、启动器里选它后重新打 iPhone 包 |
| `resource_transfer_failed` / `pack_missing` | ai | 资源没拷完：`push-pack <游戏号>`；提示没有资源包就重新导出 iPhone 版 |

### 玩家在 iPhone 上打开游戏之后

| 手机上看到的 | 怎么办 |
|---|---|
| 「正在导入游戏资源」 | 第一次要几分钟：请玩家保持 App 在前台、别锁屏，导入完会自动进入游戏 |
| 「还缺游戏资源」/「游戏资源传到一半停住了」 | 连上手机，`push-pack <游戏号>` |
| 「首次启动，正在为你的设备做一次性准备」 | 正常的一次性优化，有剩余时间；8 秒后可以先开始玩 |
| 「安装少了一项必要权限」/「这次安装丢了提高内存上限权限」 | 用 `install` 重新装（Xcode 签名会带上这项权限）；用 AltStore 的要 AltStore Classic 2.2 或更新，不要用 SideStore 0.7.0 |
| 「这台手机暂时玩不了这款游戏」 | 机型内存不够，重装也没用：告诉玩家换内存更大的设备 |
| 「签名快到期了」/ App 打不开（7 天到期） | 连上手机再 `install` 一次，存档和已拷的资源都还在 |
| 「这款游戏最近几次都没能启动」/ 反复闪退 / 画面卡住 | `s2armctl diag pull` 拉回手机诊断、`s2armctl diag export ~/Desktop/S2Arm-诊断.zip` 导出诊断包，帮玩家反馈（见「反馈问题」） |

## 反馈问题

解决不了时帮玩家整理反馈：

- `s2armctl diag export ~/Desktop/S2Arm-诊断.zip`：导出 Mac 端诊断包（只写 `s2armctl diag` 也行，默认放桌面、文件名带时刻）；
- `s2armctl diag pull`：手机用数据线连着时，拉回手机上的诊断；
- 请玩家在 https://github.com/jhaizhou-ops/S2Arm/issues 选「问题回报（内测）」模板提交，附上错误码、包号（导出完成页可复制）和诊断包。诊断包里不含密钥、游戏文件和存档。
