# 原生层（runtime/）构建片段：被顶层 Makefile 包含。
# Mach-O 跨对象的构造函数按链接顺序执行，不能只靠 constructor(99)。
# envfile 必须排在其他宿主源码前面；Mac 与 IOS_SRCS 共用这份顺序。
# 自动发现（10-30 列车线：每加一张随包表 / 一个弱符号就改这里的单行，近 5 天是列车冲突头号文件）：由使用方在自己的源文件里声明，这里只收集
#   随包表：读表的源文件写一行「// 随包表：<表名或通配>」→ make ios 从产物根拷进 App（存在才拷）
#   弱链接：引用方写一行「// 弱链接[<场合,…>]：<符号>」，场合 = host（Mac 宿主）/ ios（iOS 主程序）/ nvntest（NVN 单测）/ autoplay（自动玩家库与单测）/ lab（iOS 输入工作台）/ touchtest（触屏快照对拍）→ 对应链接行放行未定义
S2A_DECL_SRCS := $(sort $(wildcard runtime/src/*.c ios/*.m graphics/nvn/gfx/*/*.m graphics/nvn/gfx/*/*.c tests/autoplay/*.c))   # 不含安卓目录（11-05 架构方案 2-1 / H6：iOS 出壳读安卓源码，安卓每加一个 .c 出壳就红）   # 直连层（libnvn）弱引用的宿主符号也在这里声明
S2A_APP_TABLES := $(shell python3 pack/pkg_srcs.py app-tables)   # 随包表清单唯一实现在 pack/pkg_srcs.py（扫 S2A_DECL_SRCS 同一组源码的「随包表：」声明；出包包键与 Windows 编排共用）
.PHONY: print-app-tables
print-app-tables: ; @echo $(S2A_APP_TABLES)   # 出包包键（pack/ipa_key.sh）按这份清单取产物根里随包表的内容，与下面 ios 目标拷进 App 的同一份
s2a_comma := ,
# 弱链接放行参数与 tools/weak_link_decl.py 读同一份解析结果（11-05：原先这里用 sed 按子串收场合「[^]]*host[^]]*」，Python 侧按逗号拆开整词比，
#   安卓登记 android_draw_host 被 make 误收进 host，c4d0a36e4 合入后 weak_link_decl_test「两侧 host 放行参数同一份」红）
S2A_WEAK_U = $(shell python3 tools/weak_link_decl.py flags $(1))
NATIVE_SRCS := runtime/src/envfile.c $(filter-out runtime/src/envfile.c,$(sort $(wildcard runtime/src/*.c runtime/src/*.S)))
APPLE_PLAT_SRCS := platform/apple/plat_apple.c
HOST_SRCS   := $(NATIVE_SRCS) $(APPLE_PLAT_SRCS) $(HOST_SRCS)
NATIVE_INC  := -Iruntime/include
# 宿主弱符号放行参数的唯一来源（11-01 合入线：原先 5 个单测 mk、gfxmode 单测替身、Mac 图形 Python 测试各抄一份，加一个弱符号要改 7 处、漏一处就红）。
#   Mac 宿主、原生单测、单测探针的链接行都用它；（原 Mac 图形 Python 测试已随通用模式切换入口删掉）。
#   登记一致性由 tools/weak_link_decl.py 核（tests/weak_link_decl_test.sh）：runtime/src 里每个 weak_import 都要有「弱链接[host]」登记
ifeq ($(shell uname -s),Darwin)
S2A_HOST_WEAK := $(call S2A_WEAK_U,host)   # 立即求值一次：几十条链接行都引用它，别每次都起一次 python3
# Mac 宿主热状态 / 低电量（runtime/src/host_main.c dm_thermal_now，经 objc 运行时读 NSProcessInfo，审计 P1-80）：原生层单独构建（runtime/gate.sh）不带 graphics/build.mk 的 Foundation，这里自己链
HOST_LIBS += -framework Foundation
endif

# 依赖（全部 HOST_SRCS、头文件、构建配置戳）由顶层 Makefile 在读完所有 build.mk 之后统一写，这里只写配方（配方延迟展开，链的是完整 HOST_SRCS）
# 先链到同目录临时文件再 rename 原子替换：原地写 build/s2arm-host 时，同树正在 exec 的局读到半个二进制被 SIGKILL（10-21 帧率能耗线九款回归暗黑3 rc=137、host.log 空）；
# rename 后在跑 / 正起的进程拿到的是旧或新的完整文件。链接失败删掉临时文件、不动原宿主
# 地址窗口护栏（macos/vaguard.c）：Mac 宿主弱链接，放在可执行文件同目录（缺了照常起，只是 macOS 27 上窗口会被 malloc 占走）
VAGUARD := $(BUILD)/libs2a_vaguard.dylib
$(VAGUARD): macos/vaguard.c
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -dynamiclib -install_name @executable_path/libs2a_vaguard.dylib -o $@ $<
$(BUILD)/s2arm-host: platform/plat.h platform/plat_asm.h $(VAGUARD)
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(NATIVE_INC) -o $@.tmp.$$$$ $(HOST_SRCS) $(HOST_LIBS) -Wl,-weak_library,$(VAGUARD) $(S2A_HOST_WEAK) && mv -f $@.tmp.$$$$ $@ && { [ ! -d $@.tmp.$$$$.dSYM ] || { rm -rf $@.dSYM && mv $@.tmp.$$$$.dSYM $@.dSYM; }; } || { rm -rf $@.tmp.$$$$ $@.tmp.$$$$.dSYM; exit 1; }   # 弱引用：链了就取，没链为空指针

# 单测：runtime/tests/t_<名>.c 编成一个可执行文件，只链被测的 runtime/src/<名>.c，跑一遍。
# 逐个展开成显式规则（make 3.81 不对 .PHONY 目标找模式规则：写成模式规则时 `make test` 什么都不跑却报通过）
NATIVE_TEST_NAMES := $(patsubst runtime/tests/t_%.c,%,$(sort $(wildcard runtime/tests/t_*.c)))
define NATIVE_TEST_RULE
.PHONY: native-test-$(1)
native-test-$(1):
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -DS2A_UNIT_TEST -o $(BUILD)/tests/t_$(1) runtime/tests/t_$(1).c runtime/src/$(1).c $(S2A_HOST_WEAK)
	$(BUILD)/tests/t_$(1)
endef

ifeq ($(shell uname -s),Darwin)
# 和 Mac 宿主一样弱链接地址护栏；macOS 27 的 malloc 会在构造函数前占窗。
# 护栏库的安装名是 @executable_path/libs2a_vaguard.dylib：测试程序在 $(BUILD)/tests/，库得拷到它旁边，否则弱链接找不到、静默不装护栏
#   （10-24 gate-host 门禁 t_ios_prewarm 红：窗口按真实空洞选址后，没装上护栏的进程里 malloc 预留的 24 GB 让 2^39 以下最大空洞只剩 26–29 GB）
TEST_VAGUARD := $(BUILD)/tests/libs2a_vaguard.dylib
$(TEST_VAGUARD): $(VAGUARD)
	@mkdir -p $(BUILD)/tests && cp -f $(VAGUARD) $@

endif

# 地址窗口护栏（Mac）：假 malloc 库 + vawin.c，带护栏 / 不带护栏各编一份；带护栏那份打 ✓ t_vaguard，不带的是反证（应占不到窗口）。
#   另两份按 #100 作者的场景：NORESERVE 时护栏也放行；窗口 mmap 失败时日志打的是 mmap 当时的 errno（测试库让之后的 write 改 errno）

# Apple plat.h smoke test: the test source is in runtime/tests so gate.sh counts
# it in "want", but the implementation lives under platform/apple, so it needs
# a custom link rule instead of runtime/src/<name>.c.

# t_thread variant with the real Apple plat implementation.  The wrapper file
# lives in runtime/tests so gate.sh counts it in "want"; both this target and the
# normal t_thread print "✓ t_thread", so "got" also counts it.  Excluded from
# the generic runtime/src/<name>.c rule above.

# C03③ shared input parsing is auto-discovered in NATIVE_SRCS (Mac/iOS).
# Its portable C test uses the generic rule; this adapter test deliberately exits
# before creating an AppKit window or Metal layer and never accesses devices.
ifeq ($(shell uname -s),Darwin)
.PHONY: native-test-input_config_apple
native-test-input_config_apple:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -Iios -fobjc-arc -o $(BUILD)/tests/t_input_config_apple runtime/tests/t_input_config_apple.m runtime/src/input_config.c runtime/src/pad.c ios/input_config.m -framework AppKit -framework CoreGraphics -framework GameController -framework CoreHaptics -framework QuartzCore
	$(BUILD)/tests/t_input_config_apple
TEST_TARGETS += native-test-input_config_apple
endif

# ---------- iOS 壳：make ios [IOS_BUNDLE=<包名>] ----------
# 产物 build/ios/S2Arm.app（未签名）= 与游戏无关的预编壳：主程序不含任何游戏镜像（11-04 阶段 0 全外置，维护者 定为 Mac / Windows 出 iOS 包的唯一路径）。
#   按款的东西（游戏镜像包 Frameworks/S2AImages.dylib、随行表 .fixups/.gates/.widen.tsv、main.npdm、随包表）由 pack/ship_ext.py build 从产物根组装进壳的副本
#   （纯 Python，Windows / Mac 同一份；镜像包 ios/embed.py，运行时 runtime/src/imgpack.c 映射，见 docs/接口_原生层.md「外置镜像包」）。
#   出壳（含渲染器内部辅助库、主程序 ad-hoc 签名带内存权限、壳清单）走 pack/shell_build.sh。各目录在自己的 build.mk 里往 IOS_SRCS / IOS_LIBS 追加（C# 静态库、渲染器等）。
IOS_SRCS   += $(HOST_SRCS) $(sort $(wildcard ios/*.m))
# 桌面显示名（pack/ipa.sh 传「<游戏自带名> S2Arm[ 后缀]」，取名见 pack/display_name.py；注释单独成行：make 会把值后到 # 前的空格算进值）
IOS_DISPLAY ?= S2Arm
ifneq ($(origin IOS_VAMM_LAYOUT),undefined)
$(error IOS_VAMM_LAYOUT 已停用；请使用自动地址需求表重新出包)
endif
IOS_LIBS   += -framework GameController -framework UniformTypeIdentifiers
# 手机自身当掌机（ios/phone_motion.m）：陀螺仪 / 加速度当六轴、Core Haptics 当震动马达
IOS_LIBS   += -framework CoreMotion -framework CoreHaptics
# 诊断包（ios/diag.m）：MetricKit 收崩溃 / 卡顿诊断
IOS_LIBS   += -framework MetricKit
# 诊断包自己写 zip（文件放根目录、文件名带 UTF-8 标记；系统「为上传而读」会多套一层文件夹、中文名按 cp437 解成乱码）：deflate 用系统 zlib
IOS_LIBS   += -lz
IOS_BUNDLE ?= local.s2arm.app
IOS_SDK     = $(shell DEVELOPER_DIR=$(DEVELOPER_DIR) xcrun --sdk iphoneos --show-sdk-path)
IOS_CC      = DEVELOPER_DIR=$(DEVELOPER_DIR) xcrun --sdk iphoneos clang -target arm64-apple-ios$(IPHONEOS_DEPLOYMENT_TARGET) -isysroot $(IOS_SDK)
IOS_APP     = $(BUILD)/ios/S2Arm.app
NS2_CODECS := $(sort $(wildcard runtime/ns2pro/*.c))
NS2_SRCS := $(NS2_CODECS) $(sort $(wildcard runtime/ns2pro/*.m))
NS2_FRAMEWORK := $(BUILD)/ios/NS2Pro.framework
# 可复现编译（10-24 #190 统一出包新旧入口对照：同一输入出两次 NS2Pro / S2Arm 不逐字节一致）：原先 clang 一步编链，.o 落在 $TMPDIR 的随机名下，
#   调试映射（N_OSO）记着随机名和 .o 时间戳，UUID 跟着变。改成：每个源编到 $(BUILD) 下固定名的 .o（-fdebug-prefix-map 去掉源码树绝对路径）→
#   链接时 ZERO_AR_DATE=1（时间戳记 0）、-oso_prefix 去掉 $(BUILD) 绝对路径 → 两个不同目录、隔开时间各编一次逐字节一致（UUID 同）。
#   对象名也不能带 $(BUILD)（构建期生成的源在 $(BUILD) 下）：链接器按对象路径排 ObjC 选择子桩（__objc_stubs），对象名一变桩序就变（实测 808 字节差）。
IOS_BUILD_ABS = $(abspath $(BUILD))
ios_objlist = $(foreach s,$(2),$(1)/$(subst /,_,$(patsubst $(BUILD)/%,%,$(s))).o)
# 宿主每个提交只编一次（10-31 出包线，出包管线深修 ②：原先每款出包都在自己的产物根里把全部宿主源文件从头编一遍，马车8 只改宿主出包 make ios 48 秒）：
#   源码树里的源文件编进共用缓存 $(IOS_OBJ_CACHE)/<编译参数摘要>/（缺省在 $(BUILD) 下，出包 pack/ipa.sh 指到引擎树的 build/ 下、各款共用），
#   clang -MD 记依赖，.o 比源文件和它 include 的头都新就不再编；写临时名再改名（两单同时编同一个源，产物逐字节相同，谁后改名都对）。
#   编完把 .o 克隆（APFS cp -c，不占空间）到本次的对象目录再链接：对象路径与原先一致，链接产物逐字节不变（上面「可复现编译」）。
#   $(BUILD) 下生成的源照旧每次在本次对象目录里编。
#   ios_objs_cached <对象目录> <额外编译参数> <源…>
IOS_OBJ_CACHE ?= $(BUILD)/ios/objcache
ios_objkey = $(shell printf '%s' '$(IOS_CC) $(CFLAGS) $(1) $(CURDIR)' | shasum -a 256 | cut -c1-16)
ios_objs_cached = c=$(IOS_OBJ_CACHE)/$(call ios_objkey,$(2)); mkdir -p $(1) $$c && for s in $(3); do n=$$(echo "$$s" | sed 's|^$(BUILD)/||' | tr / _).o; \
	  case "$$s" in $(BUILD)/*) $(IOS_CC) $(CFLAGS) -fdebug-prefix-map="$(CURDIR)"=. $(2) -c "$$s" -o "$(1)/$$n" || exit 1; continue;; esac; \
	  o=$$c/$$n; fresh=; if [ -f "$$o" ] && [ -f "$$o.d" ]; then fresh=1; for d in $$(sed -e '1s/^[^:]*://' -e 's/\\$$//' "$$o.d"); do [ -e "$$d" ] && [ ! "$$d" -nt "$$o" ] || { fresh=; break; }; done; fi; \
	  [ -n "$$fresh" ] || { t=$$o.tmp.$$$$; $(IOS_CC) $(CFLAGS) -fdebug-prefix-map="$(CURDIR)"=. $(2) -MD -MF $$t.d -c "$$s" -o $$t && mv -f $$t.d $$o.d && mv -f $$t $$o || { rm -f $$t $$t.d; exit 1; }; }; \
	  rm -f "$(1)/$$n" && cp -c "$$o" "$(1)/$$n" || exit 1; done
IOS_LD_REPRO = ZERO_AR_DATE=1
# 主程序 ObjC 桩用小桩（10-25 #190 剩余差异定因：同一批 .o 原样链 6 次出两种结果，__objc_stubs 每桩差 1 字节、__stubs 差 1 字节、UUID 跟着变）：
#   静态库（libnxgal / System.Native 等）直接引用 _objc_msgSend，链接器合成的快速 objc 桩又另建一格 GOT → GOT 里有两格 _objc_msgSend，
#   多线程合成桩时随机挑一格。小桩直接跳 __stubs 里那一个 objc_msgSend 桩、不自建 GOT（只剩一格）→ 6/6 一致；主程序小约 16 KB，每次消息发送多一次跳转。
#   -Wl,-reproducible 试过无效（6 次 1:5）
IOS_LD_DET = -Wl,-objc_stubs_small
# iOS 游戏库界面（shell：上游 ShellUI / ShellControllers + 我方 S2ArmShellHost，见该目录 UPSTREAM.md；11-07 启动器线 P2 单款启动门）：
#   S2A_SHELLUI=1 才编进主程序（多款容器的库界面，ios/app.m 弱链接取 s2a_shell_library_vc / s2a_shell_set_play_handler）；缺省 0 = 壳不带、整个 make 不读该目录。
#   xcodebuild 出 4 个目标文件 + 资源包（本地化 + 字体）；Swift 运行时按 iOS 18 下限全取系统 /usr/lib/swift，不随包；资源包拷到 App 根（SwiftPM 的 Bundle.module 在主包根找）。
#   壳编号：出壳（pack/shell_build.sh）不收外部开关，按壳输入表 pack/stage_inputs/shell.tsv 有没有「入 shell」行定 S2A_SHELLUI——
#   表本身与表里的目录都进壳编号，开关和库界面源码一变壳编号必变，同一编号不会对应两种壳
S2A_SHELLUI ?= 0
ifeq ($(S2A_SHELLUI),1)
SHELLUI_DD = $(abspath $(BUILD))/ios/shellui
SHELLUI_PRODUCTS = $(SHELLUI_DD)/Build/Products/Release-iphoneos
IOS_SHELLUI_LINK = $(addprefix $(SHELLUI_PRODUCTS)/,S2ArmShellHost.o S2ArmShellBridge.o ShellUI.o ShellControllers.o SaveSync.o) \
  -L$(shell DEVELOPER_DIR=$(DEVELOPER_DIR) xcrun --sdk iphoneos --find swiftc | sed 's|/bin/swiftc$$||')/lib/swift/iphoneos -L$(IOS_SDK)/usr/lib/swift -framework SwiftUI
.PHONY: ios-shellui
ios-shellui:
	@mkdir -p $(SHELLUI_DD)
	cd shell && DEVELOPER_DIR=$(DEVELOPER_DIR) xcodebuild -quiet -scheme S2ArmShellHost -destination 'generic/platform=iOS' -configuration Release \
	  -derivedDataPath $(SHELLUI_DD) IPHONEOS_DEPLOYMENT_TARGET=$(IPHONEOS_DEPLOYMENT_TARGET) build > $(SHELLUI_DD)/xcodebuild.log 2>&1 || { tail -30 $(SHELLUI_DD)/xcodebuild.log; echo "🔴 游戏库界面（S2A_SHELLUI=1）编不过，日志 $(SHELLUI_DD)/xcodebuild.log"; exit 1; }
ios: ios-shellui
endif
.PHONY: ios ios-ns2pro ns2pro-test native-test-ns2pro native-test-touch_compat
ios-ns2pro:
	@mkdir -p $(NS2_FRAMEWORK)
	@$(call ios_objs_cached,$(BUILD)/ios/obj_ns2pro,-fobjc-arc -fvisibility=hidden -Iruntime/ns2pro/include,$(NS2_SRCS))
	$(IOS_LD_REPRO) $(IOS_CC) -fobjc-arc -dynamiclib -Wl,-oso_prefix,$(IOS_BUILD_ABS)/ \
	  -install_name @rpath/NS2Pro.framework/NS2Pro -Wl,-exported_symbol,_ns2_module_api \
	  -o $(NS2_FRAMEWORK)/NS2Pro $(call ios_objlist,$(BUILD)/ios/obj_ns2pro,$(NS2_SRCS)) -framework CoreBluetooth -framework Foundation
	@rm -rf $(BUILD)/ios/NS2Pro.dSYM; DEVELOPER_DIR=$(DEVELOPER_DIR) xcrun dsymutil --oso-prepend-path=$(IOS_BUILD_ABS) $(NS2_FRAMEWORK)/NS2Pro -o $(BUILD)/ios/NS2Pro.dSYM   # 调试符号包（不进包）：分开编链后 clang 不再自动出，按相对对象路径补
	@rm -f $(NS2_FRAMEWORK)/Info.plist.tmp
	@/usr/bin/plutil -create xml1 $(NS2_FRAMEWORK)/Info.plist.tmp && for kv in CFBundleIdentifier=dev.s2arm.NS2Pro CFBundleExecutable=NS2Pro CFBundleName=NS2Pro CFBundlePackageType=FMWK CFBundleShortVersionString=1.0 CFBundleVersion=1 MinimumOSVersion=$(IPHONEOS_DEPLOYMENT_TARGET); do /usr/bin/plutil -insert $${kv%%=*} -string "$${kv#*=}" $(NS2_FRAMEWORK)/Info.plist.tmp; done
	@/usr/bin/plutil -insert CFBundleSupportedPlatforms -xml '<array><string>iPhoneOS</string></array>' $(NS2_FRAMEWORK)/Info.plist.tmp
	@mv -f $(NS2_FRAMEWORK)/Info.plist.tmp $(NS2_FRAMEWORK)/Info.plist
	@cp runtime/ns2pro/LICENSE $(NS2_FRAMEWORK)/LICENSE
ns2pro-test: native-test-ns2pro
ios: ios-ns2pro
	@[ -z "$(IOS_MODS)" ] || { echo "🔴 make ios 只出与游戏无关的壳（11-04 全外置）：不再收 IOS_MODS；按款组装用 pack/ship_ext.py build"; exit 1; }
	@rm -rf $(IOS_APP) && mkdir -p $(IOS_APP) $(BUILD)/ios
	@mkdir -p $(IOS_APP)/Frameworks && cp -R $(NS2_FRAMEWORK) $(IOS_APP)/Frameworks/
	@cp -R ios/Settings.bundle $(IOS_APP)/Settings.bundle
	@cp -R ios/l10n/*.lproj $(IOS_APP)/   # 宿主界面字符串表（游戏内菜单 / 触屏布局 / 金手指 / 社区补丁，ios/s2a_l10n.h S2AL）：<语言>.lproj/S2ArmHost.strings 放主 bundle（#316）
	@$(call ios_objs_cached,$(BUILD)/ios/obj_app,-fobjc-arc $(NATIVE_INC) -Iruntime/src -Iruntime/ns2pro/include,$(IOS_SRCS))
	$(IOS_LD_REPRO) $(IOS_CC) -fobjc-arc $(IOS_LD_DET) -Wl,-oso_prefix,$(IOS_BUILD_ABS)/ -o $(IOS_APP)/S2Arm $(call ios_objlist,$(BUILD)/ios/obj_app,$(IOS_SRCS)) $(IOS_LIBS) \
	  -framework UIKit -framework Foundation -framework CoreGraphics $(IOS_SHELLUI_LINK) $(call S2A_WEAK_U,ios) -Wl,-S
	@rm -rf $(BUILD)/ios/S2Arm.dSYM $(IOS_APP)/S2Arm.dSYM   # 主程序链接带 -Wl,-S（不留调试映射），没有调试符号包可出；函数符号表照留，atos / 宿主 dladdr 照常符号化
	@[ "$(S2A_SHELLUI)" != 1 ] || cp -R $(SHELLUI_PRODUCTS)/S2ArmShellUI_ShellUI.bundle $(IOS_APP)/   # 游戏库界面资源包（本地化 + 字体）
	@/usr/bin/plutil -create xml1 $(IOS_APP)/Info.plist && for kv in CFBundleIdentifier=$(IOS_BUNDLE) CFBundleExecutable=S2Arm CFBundleName=S2Arm CFBundlePackageType=APPL \
	  CFBundleShortVersionString=0.1 CFBundleVersion=1 MinimumOSVersion=$(IPHONEOS_DEPLOYMENT_TARGET) UILaunchStoryboardName=; do /usr/bin/plutil -insert $${kv%%=*} -string "$${kv#*=}" $(IOS_APP)/Info.plist; done; \
	  /usr/bin/plutil -insert UIRequiredDeviceCapabilities -xml '<array><string>arm64</string></array>' $(IOS_APP)/Info.plist; \
	  /usr/bin/plutil -insert CFBundleDisplayName -string "$(IOS_DISPLAY)" $(IOS_APP)/Info.plist; \
	  /usr/bin/plutil -insert S2ACommit -string "$$(git rev-parse HEAD 2> /dev/null || echo unknown)" $(IOS_APP)/Info.plist; \
	  /usr/bin/plutil -insert CFBundleSupportedPlatforms -xml '<array><string>iPhoneOS</string></array>' $(IOS_APP)/Info.plist; \
	  /usr/bin/plutil -insert UIDeviceFamily -xml '<array><integer>1</integer><integer>2</integer></array>' $(IOS_APP)/Info.plist; \
	  /usr/bin/plutil -insert UIFileSharingEnabled -bool YES $(IOS_APP)/Info.plist; \
	  /usr/bin/plutil -insert LSSupportsOpeningDocumentsInPlace -bool YES $(IOS_APP)/Info.plist; \
	  /usr/bin/plutil -insert UIApplicationShortcutItems -json "$$(cat ios/shortcuts.json)" $(IOS_APP)/Info.plist; \
	  /usr/bin/plutil -insert CFBundleLocalizations -json '["en","zh-Hans","ja","de","fr","it","sv"]' $(IOS_APP)/Info.plist; \
	  /usr/bin/plutil -insert CFBundleDevelopmentRegion -string en $(IOS_APP)/Info.plist; \
	  for k in UISupportedInterfaceOrientations UISupportedInterfaceOrientations~ipad; do /usr/bin/plutil -insert $$k -xml '<array><string>UIInterfaceOrientationLandscapeRight</string><string>UIInterfaceOrientationLandscapeLeft</string></array>' $(IOS_APP)/Info.plist; done; \
	  /usr/bin/plutil -insert UIRequiresFullScreen -bool YES $(IOS_APP)/Info.plist; /usr/bin/plutil -insert UIStatusBarHidden -bool YES $(IOS_APP)/Info.plist   # 只许横屏、全屏、无状态栏
	@/usr/bin/plutil -insert LSSupportsGameMode -bool YES $(IOS_APP)/Info.plist   # 声明支持系统游戏模式（10-20 维护者二分：动森整机 5.88 → 3.37 W、30 帧不变，性能核 3.9 → 2.2 GHz；旧 S2A 包有此键、S2Arm 漏了）
	@/usr/bin/plutil -insert LSApplicationCategoryType -string public.app-category.games $(IOS_APP)/Info.plist   # 系统靠类别认出是游戏才进游戏模式（11-01 调研：LSSupportsGameMode 之外还要类别键）
	@/usr/bin/plutil -insert GCSupportsGameMode -bool YES $(IOS_APP)/Info.plist   # 部署目标 iOS 18.0 < 18.6：LSSupportsGameMode 18.6 起才认，18.0–18.5 靠旧键
	@/usr/bin/plutil -insert NSLocalNetworkUsageDescription -string "本地联机：与同一 Wi-Fi 下的其他设备互相发现、进同一个房间。" $(IOS_APP)/Info.plist; /usr/bin/plutil -insert NSBonjourServices -json '["_s2arm-ldn._tcp"]' $(IOS_APP)/Info.plist   # ldn_lan.m
	@/usr/bin/plutil -insert NSBluetoothAlwaysUsageDescription -string "Connect a Switch 2 Pro Controller when enabled in Settings." $(IOS_APP)/Info.plist
	@/usr/bin/plutil -insert CFBundleURLTypes -json '[{"CFBundleURLName":"dev.s2arm.ota","CFBundleURLSchemes":["s2arm"]}]' $(IOS_APP)/Info.plist   # s2arm://download?catalog=…：OTA 资源包下载（ios/ota_download.m、docs/OTA_DOWNLOAD.md）
	@/usr/bin/plutil -insert UIApplicationSceneManifest -json '{"UIApplicationSupportsMultipleScenes":false,"UISceneConfigurations":{"UIWindowSceneSessionRoleApplication":[{"UISceneConfigurationName":"Default","UISceneDelegateClassName":"S2ASceneDelegate"}]}}' $(IOS_APP)/Info.plist   # iOS 27 场景生命周期（27.1 SDK 强制 UIScene adoption，否则启动即崩）：指向 app.m 的 S2ASceneDelegate
	@echo "iOS App：$(IOS_APP)（$$(du -sh $(IOS_APP) | cut -f1)，包名 $(IOS_BUNDLE)，未签名）"

# NVN 查询测试共用完整生产 bootstrap / swnvn / NVN 跳板；保留签名检查，不提供测试替身。
# 只需原生宿主、直连库和真实宽屏核心，不构建服务层 / Ryujinx / 通用渲染器。
# 宿主目前一步编链，测试把同一份生产源码缓存成对象，排除提供 main 的 host_main.c。
# 工具链继续用 S2A_DEVELOPER_DIR；NativeAOT 的本机依赖搜索沿用 LIBRARY_PATH。
ifeq ($(shell uname -s),Darwin)
NVN_TEST_DIR := $(BUILD)/tests/nvn
# 包含了生产 nvn_mtl.m 的单测目标都依赖这一组（11-05 nvn_rec_cover 时红时绿：目标只写 nvn_mtl.m，改了它包含的 .inc / .h 时增量构建不重编，
#   红绿取决于旧对象是哪一版；列车 gate-host 复用检出，批与批之间就这样漂）
NVN_MTL_DEPS := graphics/nvn/gfx/nvn/nvn_mtl.m $(wildcard graphics/nvn/gfx/nvn/*.inc graphics/nvn/gfx/nvn/*.h graphics/nvn/*.inc graphics/nvn/host/*.h)
NVN_TEST_HOST_SRCS := $(filter-out runtime/src/host_main.c,$(NATIVE_SRCS)) $(APPLE_PLAT_SRCS) graphics/track/track.c graphics/track/glue.c
NVN_TEST_HOST_OBJS := $(addprefix $(NVN_TEST_DIR)/host/,$(addsuffix .o,$(NVN_TEST_HOST_SRCS)))
NVN_TEST_LIB := $(NVN_TEST_DIR)/nvn/mac/libnvn.a
NVN_TEST_WIDEN := $(NVN_TEST_DIR)/widen/S2Arm.Gfx.Widen.dylib
# Tests that include nvn_mtl.m use the same generated AA headers as their
# production library prerequisite, including when BUILD selects another tree.
$(BUILD)/tests/t_nvn_%: CFLAGS += -I$(abspath $(NVN_TEST_DIR)/nvn/gen)
# NVN 单测不链原生层 / 渲染器：libnvn 里弱引用的宿主符号在链接行一律放行（新单测照用这个变量，别逐行抄标志——10-25 t_nvn_a / t_nvn_event 两次漏 _s2a_autoplay_on 链接失败）
# Switch 2 视频解码接管（graphics/nvn/gfx/nvn/nvn2_codec.c，在 libnvn.a 里）用 VideoToolbox / CoreMedia / CoreVideo：系统框架，NVN 单测链 libnvn.a 时一起带上（同 graphics/build.mk HOST_LIBS）
NVN_TEST_WEAK := $(call S2A_WEAK_U,nvntest) -framework VideoToolbox -framework CoreMedia -framework CoreVideo
$(NVN_TEST_DIR)/host/%.o: % runtime/src/native.h $(wildcard runtime/include/*.h) platform/plat.h platform/plat_asm.h graphics/track/s2a_track.h $(BUILD)/.host_cfg
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) $(NATIVE_INC) -c $< -o $@
$(NVN_TEST_LIB): $(if $(NVN_TEST_PREBUILT),,FORCE)
	$(MAKE) -C graphics/nvn mac OUT=$(abspath $(NVN_TEST_DIR)/nvn)
$(NVN_TEST_WIDEN): $(if $(NVN_TEST_PREBUILT),,FORCE)
	dotnet publish graphics/widen/S2Arm.Gfx.Widen.csproj -c Release -r osx-arm64 -nodeReuse:false -p:UseSharedCompilation=false \
	  --artifacts-path $(abspath $(NVN_TEST_DIR)/widen-artifacts) \
	  -o $(abspath $(NVN_TEST_DIR)/widen) -p:PublishAot=true -p:NativeLib=Shared -p:InvariantGlobalization=true
# runtime/gate.sh 并行跑组前先建一次 NVN 组共用的前置（10-28 门禁提速）；之后各组带 NVN_TEST_PREBUILT=1，上面两个 FORCE 不再生效、不会多组同时重写同一个库
.PHONY: native-test-prereq
native-test-prereq: $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
endif

# B组复用A组真实生产对象/libnvn/Widen；只单独编译查询用例和最终可执行文件。

# E 组（延迟纹理绑定保留描述符池偏移，#315）：复用共享的生产对象 / libnvn / 宽屏核心

# 单测分片（10-26 根治同一处追加互撞：refl-nb / cps-fail / pair-guard 都要往这里加一行）：每个有自己构建规则的单测一个 runtime/tests/mk/<名>.mk，
#   分片里先 NATIVE_TEST_OWN += <名>（不走下面的通用规则）、再写规则和 TEST_TARGETS += native-test-<名>；平台限定的规则在分片里自带 ifeq。
#   放在末尾收：分片里要用上面的 TEST_VAGUARD / NVN_TEST_* / NS2_CODECS 等变量
NATIVE_TEST_OWN :=
include $(sort $(wildcard runtime/tests/mk/*.mk))
# 其余 runtime/tests/t_<名>.c 走通用规则：只链 runtime/src/<名>.c
$(foreach t,$(filter-out $(NATIVE_TEST_OWN),$(NATIVE_TEST_NAMES)),$(eval $(call NATIVE_TEST_RULE,$(t))))
TEST_TARGETS += $(addprefix native-test-,$(filter-out $(NATIVE_TEST_OWN),$(NATIVE_TEST_NAMES)))
