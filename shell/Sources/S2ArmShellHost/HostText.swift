import Foundation
// 11-10 英文默认（维护者：英文设备上看到中文）：本模块不带字符串表，上屏文字英文在前、中文在后，按 App 实际选中的本地化取一句
//   （App 只带 en / zh-Hans 两份宿主字符串表，设备首选中文才选中 zh-Hans；与原生层 runtime/include/s2a_ui_lang.h S2A_TR 同一口径）
let hostUIChinese: Bool = Bundle.main.preferredLocalizations.first?.hasPrefix("zh") ?? false
@inline(__always) func L(_ en: String, _ zh: String) -> String { hostUIChinese ? zh : en }
