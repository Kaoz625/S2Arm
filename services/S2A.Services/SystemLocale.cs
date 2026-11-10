using Ryujinx.HLE.HOS.SystemState;
using System;
using System.Runtime.InteropServices;

namespace S2A.Services
{
    // 系统语言缺省跟设备（维护者 10-20：「都要装上以后默认是中文版哈（系统本身也是中文版的）」）：
    //   没给 S2A_SYSTEM_LANGUAGE 时按 iPhone / Mac 的系统首选语言（CFLocaleCopyPreferredLanguages，BCP 47 标签如 zh-Hans-CN）映射 Switch SystemLanguage；
    //   测试资产 / 对真值局显式给的 S2A_SYSTEM_LANGUAGE 照旧优先。游戏不支持该语言时 Ryujinx GetDesiredLanguage 退到游戏支持的第一种。
    //   服务层是 InvariantGlobalization，CultureInfo 拿不到系统语言，所以直接调 CoreFoundation（iOS / macOS 同一个 C 接口）
    public static class SystemLocale
    {
        // BCP 47 标签 → Switch 系统语言；认不出返回 null（换首选列表里的下一个）
        public static SystemLanguage? Map(string tag)
        {
            if (string.IsNullOrEmpty(tag))
            {
                return null;
            }

            string[] p = tag.Replace('_', '-').ToLowerInvariant().Split('-');
            string lang = p[0];
            bool Has(string s) => Array.IndexOf(p, s, 1) >= 0;

            switch (lang)
            {
                case "zh":
                    // 有文字子标签按文字定；只有地区时：台 / 港 / 澳 = 繁体，其余简体
                    if (Has("hant")) return SystemLanguage.TraditionalChinese;
                    if (Has("hans")) return SystemLanguage.SimplifiedChinese;
                    return Has("tw") || Has("hk") || Has("mo") ? SystemLanguage.TraditionalChinese : SystemLanguage.SimplifiedChinese;
                case "ja": return SystemLanguage.Japanese;
                case "ko": return SystemLanguage.Korean;
                case "en": return Has("gb") || Has("au") || Has("nz") || Has("ie") || Has("in") || Has("za") ? SystemLanguage.BritishEnglish : SystemLanguage.AmericanEnglish;
                case "fr": return Has("ca") ? SystemLanguage.CanadianFrench : SystemLanguage.French;
                case "es": return p.Length == 1 || Has("es") ? SystemLanguage.Spanish : SystemLanguage.LatinAmericanSpanish;
                case "pt": return Has("br") ? SystemLanguage.BrazilianPortuguese : SystemLanguage.Portuguese;
                case "de": return SystemLanguage.German;
                case "it": return SystemLanguage.Italian;
                case "nl": return SystemLanguage.Dutch;
                case "ru": return SystemLanguage.Russian;
                case "pl": return SystemLanguage.Polish;
                case "th": return SystemLanguage.Thai;
                default: return null;
            }
        }

        // 首选语言列表里第一个认得的；都不认得（或取不到）回美式英语。来源写进 why 供日志
        public static SystemLanguage FromPreferred(string[] tags, out string why)
        {
            foreach (string t in tags)
            {
                SystemLanguage? l = Map(t);

                if (l.HasValue)
                {
                    why = $"系统首选语言 {t}";
                    return l.Value;
                }
            }

            why = tags.Length == 0 ? "取不到系统首选语言" : $"系统首选语言 {string.Join(",", tags)} 都没有对应的 Switch 语言";
            return SystemLanguage.AmericanEnglish;
        }

        // 游戏不支持系统语言时依次试的语言（交 Ryujinx GetDesiredLanguage，S2AHooks.TitleLanguageFallback）：系统首选语言列表依次 → 英语（美式 / 英式）→ 简中 → 繁中；
        //   首选里第一个认得的是中文时中文在英语前（简中 → 繁中 → 英语）。都不支持才轮到游戏自己的首选（11-03 归族：GB4 / FFR / JUMP FORCE 亚洲版只收韩 / 繁 / 简，
        //   上游取「游戏支持的第一个」= 韩语，玩家看到韩文界面）。11-10 维护者（英文设备上看到中文）：原先中文固定排在英语前，英文设备遇到不收美式英语的游戏
        //   （只收英式）会先落到简中；现在英文 / 其他语言设备一律先英语，只有中文设备才先中文
        public static TitleLanguage[] TitleFallback(string[] tags)
        {
            var r = new System.Collections.Generic.List<TitleLanguage>();
            void Add(TitleLanguage t) { if (!r.Contains(t)) r.Add(t); }
            bool zhFirst = false, seen = false;
            foreach (string tag in tags)
            {
                if (Map(tag) is SystemLanguage l && Enum.TryParse(l.ToString(), out TitleLanguage t))
                {
                    if (!seen) { zhFirst = l == SystemLanguage.SimplifiedChinese || l == SystemLanguage.TraditionalChinese; seen = true; }
                    Add(t);
                }
            }
            if (zhFirst) { Add(TitleLanguage.SimplifiedChinese); Add(TitleLanguage.TraditionalChinese); }
            Add(TitleLanguage.AmericanEnglish); Add(TitleLanguage.BritishEnglish);
            Add(TitleLanguage.SimplifiedChinese); Add(TitleLanguage.TraditionalChinese);
            return r.ToArray();
        }

        public static string[] Preferred()
        {
            IntPtr arr = CFLocaleCopyPreferredLanguages();

            if (arr == IntPtr.Zero)
            {
                return Array.Empty<string>();
            }

            try
            {
                long n = CFArrayGetCount(arr);
                string[] r = new string[n];
                byte[] buf = new byte[128];

                for (long i = 0; i < n; i++)
                {
                    IntPtr s = CFArrayGetValueAtIndex(arr, i);
                    r[i] = s != IntPtr.Zero && CFStringGetCString(s, buf, buf.Length, 0x08000100) ? System.Text.Encoding.UTF8.GetString(buf, 0, Array.IndexOf(buf, (byte)0)) : "";
                }

                return r;
            }
            finally
            {
                CFRelease(arr);
            }
        }

        private const string CF = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation";

        [DllImport(CF)] private static extern IntPtr CFLocaleCopyPreferredLanguages();
        [DllImport(CF)] private static extern long CFArrayGetCount(IntPtr array);
        [DllImport(CF)] private static extern IntPtr CFArrayGetValueAtIndex(IntPtr array, long index);
        [DllImport(CF)] [return: MarshalAs(UnmanagedType.I1)] private static extern bool CFStringGetCString(IntPtr s, byte[] buffer, long size, uint encoding);
        [DllImport(CF)] private static extern void CFRelease(IntPtr cf);
    }
}
