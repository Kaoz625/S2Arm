// 出库链移进 C#（11-01 出包线）：整份出库收尾的「发布核验 + 库容器打包 + ps_inputs 表 + keys.tsv」，逐字节照搬旧 Python：
//   graphics/tools/direct/lib_swap.py（LIBFILE、SDK、check_names、sdk_check_items）、graphics/tools/direct/lib_pack.py（pack_files）、graphics/tools/direct/ps_inputs.py（write），
//   编排同 translator/dmsh_build.py 末尾「if IOSOUT and PUBLISH」那段（Publish）。宿主读容器的代码在 graphics/nvn/lib_pack.inc。
// 给 Build.cs 的入口（一侧产物 = 「文件名 → 字节」内存表，IReadOnlyDictionary<string, byte[]>）：
//   Publish(mac, ios, noMac, publish, iosOut, chain, log) → null = 成；否则是 sys.exit 的报错文本（多行 [RED] …）。log 收 Python 那段 print 的各行
//   CheckNames(macNames, iosNames 或 null, noMac, log) → 红行；齐全时往 log 写一行（= lib_swap.check_names 的 print）
//   SdkCheckItems((名, 字节)…, plat, where) → 红行（= lib_swap.sdk_check_items）；IsLibFile(名)（= LIBFILE.match）；Sdk（= lib_swap.SDK）
//   PackFiles(names, get, d, chain[, vkfp]) → (红行, 汇总行)（= lib_pack.pack_files，d 下写 lib.NNN.pak + lib.idx）；给 vkfp = 出 Vulkan 库（#783：只收 _b.json / _b.spv，头部记 Vulkan 侧指纹）
//   PsInputsWrite((键, _b.json 文本, _b.metal 文本或 null)…, out) → 片元个数；Python 在这里 sys.exit 的情形抛 LibPack.Exit（Message 即报错文本）
// 与 Python 的口径（逐处核过）：文件名排序按 Unicode 码位（Python str 比较，不是 UTF-16 序）；格式化的小数按「精确有理数四舍六入五成双」（Python float 的 :.Nf，
//   这里两个分母都是 2 的幂、值在 double 里精确）；json 取字段时同名键取最后一个、真值判断同 Python；正则 $ 同 Python（允许末尾一个 \n）、\d 同为 Unicode 十进制数字。
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Numerics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

static class LibPack
{
    /// <summary>Python 那边 sys.exit(文本) 的情形（ps_inputs.write 报红）</summary>
    public sealed class Exit : Exception { public Exit(string m) : base(m) { } }

    // ---------------- 共用：Python 口径的排序 / repr / 格式化 / json ----------------
    /// <summary>Python str 的比较：按码位。UTF-16 序只在「代理对 vs U+E000–U+FFFF」处与码位序相反，把两段对调即可</summary>
    public static readonly Comparer<string> Cp = Comparer<string>.Create((a, b) =>
    {
        int n = Math.Min(a.Length, b.Length);
        for (int i = 0; i < n; i++)
        {
            char x = a[i], y = b[i]; if (x == y) continue;
            return Fix(x).CompareTo(Fix(y));
        }
        return a.Length.CompareTo(b.Length);
        static int Fix(char c) => c >= 0xD800 && c <= 0xDFFF ? c + 0x2000 : c >= 0xE000 ? c - 0x800 : c;
    });
    static List<string> Sorted(IEnumerable<string> s) { var l = s.ToList(); l.Sort(Cp); return l; }

    /// <summary>Python 的 repr(list[str])（名字都是库文件名 / 十六进制键，只需常见转义）</summary>
    static string PyList(IEnumerable<string> l) => "[" + string.Join(", ", l.Select(PyStr)) + "]";
    static string PyStr(string s)
    {
        char q = s.Contains('\'') && !s.Contains('"') ? '"' : '\'';
        var b = new StringBuilder().Append(q);
        foreach (char c in s)
        {
            if (c == '\\' || c == q) b.Append('\\').Append(c);
            else if (c == '\n') b.Append("\\n"); else if (c == '\r') b.Append("\\r"); else if (c == '\t') b.Append("\\t");
            else if (c < 0x20 || c == 0x7f) b.Append($"\\x{(int)c:x2}");
            else b.Append(c);
        }
        return b.Append(q).ToString();
    }

    /// <summary>num / den 按 Python f'{x:.{digits}f}'（den 为 2 的幂时 x 在 double 里精确）：精确有理数、五成双</summary>
    static string Fmt(BigInteger num, BigInteger den, int digits)
    {
        BigInteger scale = BigInteger.Pow(10, digits), q = BigInteger.DivRem(num * scale, den, out var r);
        int c = (r * 2).CompareTo(den);
        if (c > 0 || (c == 0 && !q.IsEven)) q += 1;
        string s = q.ToString().PadLeft(digits + 1, '0');
        return digits == 0 ? s : s[..^digits] + "." + s[^digits..];
    }

    static readonly JsonDocumentOptions JOpt = new() { MaxDepth = 1000 };
    /// <summary>json.loads(bytes)：UTF-8 BOM 照 Python 跳过；解不了（含非法 UTF-8）抛 JsonException（= Python 的 ValueError）</summary>
    static JsonDocument JsonBytes(byte[] b)
    {
        ReadOnlyMemory<byte> m = b;
        if (b.Length >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) m = m[3..];
        return JsonDocument.Parse(m, JOpt);
    }
    /// <summary>json.loads(str)：Python 对 str 不认 BOM（报 ValueError）</summary>
    static JsonDocument JsonText(string s)
    {
        if (s.Length > 0 && s[0] == '﻿') throw new JsonException("Unexpected UTF-8 BOM");
        return JsonDocument.Parse(s, JOpt);
    }
    /// <summary>obj.get(name)：顶层不是对象时 Python 抛 AttributeError（没人接，整份出库崩）；同名键取最后一个；没有 → null</summary>
    static JsonElement? Get(JsonDocument d, string name)
    {
        if (d.RootElement.ValueKind != JsonValueKind.Object) throw new InvalidOperationException($"'{PyType(d.RootElement)}' object has no attribute 'get'");
        JsonElement? v = null;
        foreach (var p in d.RootElement.EnumerateObject()) if (p.Name == name) v = p.Value;
        return v;
    }
    static string PyType(JsonElement e) => e.ValueKind switch
    {
        JsonValueKind.Array => "list", JsonValueKind.String => "str", JsonValueKind.Number => e.TryGetInt64(out _) ? "int" : "float",
        JsonValueKind.True or JsonValueKind.False => "bool", JsonValueKind.Null => "NoneType", _ => "dict"
    };
    static bool Truthy(JsonElement e) => e.ValueKind switch
    {
        JsonValueKind.Null or JsonValueKind.False => false, JsonValueKind.String => e.GetString().Length > 0,
        JsonValueKind.Array => e.GetArrayLength() > 0, JsonValueKind.Object => e.EnumerateObject().Any(),
        JsonValueKind.Number => e.GetDouble() != 0, _ => true
    };
    /// <summary>Unicode 十进制数字串 → 整数（Python int(str)：\d 匹配到的任何 Nd 数字都认）</summary>
    static BigInteger PyInt(string s)
    {
        BigInteger v = 0;
        foreach (char c in s) v = v * 10 + System.Globalization.CharUnicodeInfo.GetDecimalDigitValue(c);
        return v;
    }
    static readonly UTF8Encoding Utf8 = new(false, true);   // bytes.decode()：严格，非法字节抛
    static readonly UTF8Encoding Utf8Out = new(false);

    // ---------------- lib_swap.py ----------------
    static readonly Regex KEY = new(@"\A([0-9a-f]{16})_b\.(metal|metallib|json)$", RegexOptions.CultureInvariant);
    /// <summary>lib_swap.LIBFILE：发布那一侧里属于库容器的文件（键文件 + 批库 u&lt;16 位&gt;.metallib）；含直通几何快路的 _bgs&lt;i&gt; / _bgc（11-06 漏收：Build.cs 编了、PackFiles 认了，发布这道过滤没收，金刚 kong_pt 包种类 64–97 为 0）</summary>
    static readonly Regex LIBFILE = new(@"\A(?:[0-9a-f]{16}_(?:b\.metallib|b\.json|bf\.metallib|bv\.metallib|ft\.metallib|se\.metallib|b_t[0-2]\.metallib|bg\d+\.(?:metallib|json)|bgv\.(?:metallib|json)|bgs\d+\.(?:metallib|json)|bgc\.(?:metallib|json))|u[0-9a-f]{16}\.metallib)$", RegexOptions.CultureInvariant);
    public static bool IsLibFile(string name) => LIBFILE.IsMatch(name);
    public static readonly IReadOnlyDictionary<string, string> Sdk = new Dictionary<string, string> { ["ios"] = "iphoneos", ["mac"] = "macosx" };

    static Dictionary<string, HashSet<string>> KeysOf(IEnumerable<string> names)
    {
        var by = new Dictionary<string, HashSet<string>>();
        foreach (var n in names)
        {
            var m = KEY.Match(n); if (!m.Success) continue;
            if (!by.TryGetValue(m.Groups[2].Value, out var s)) by[m.Groups[2].Value] = s = new();
            s.Add(m.Groups[1].Value);
        }
        return by;
    }
    static HashSet<string> G(Dictionary<string, HashSet<string>> by, string ext) => by.TryGetValue(ext, out var s) ? s : new();
    static HashSet<string> Minus(HashSet<string> a, params HashSet<string>[] b) { var r = new HashSet<string>(a); foreach (var x in b) r.ExceptWith(x); return r; }
    static string First3(HashSet<string> s) => PyList(Sorted(s).Take(3));

    /// <summary>lib_swap.check_names：两侧文件名清单核齐全；iosNames null = 只出 Mac。齐全时往 log 写一行（Python 的 print）</summary>
    // 出成了但按设计没有库的键：反射带 gs_slice（几何阶段只转发图层号，宿主读 json、用顶点阶段的图层入口画，dmsh 出库不编库），有 _b.json、没有 _b.metallib。
    //   11-02：双人成行 / 八方2 的 439bed623be839b2 原被当成「编译失败」、不进 keys.tsv，「没出成 1 支」是误报
    static HashSet<string> NoLibKeys(IReadOnlyDictionary<string, byte[]> side)
    {
        var r = new HashSet<string>();
        foreach (var n in side.Keys)   // 先按名字筛、只读要看的 json（产物在出库数据文件里时取值即读盘，原先逐个读出全部产物字节再跳过）
        {
            if (!n.EndsWith("_b.json", StringComparison.Ordinal) || side.ContainsKey(n[..^".json".Length] + ".metallib")) continue;
            var b = side[n];
            try { using var d = System.Text.Json.JsonDocument.Parse(b); if (d.RootElement.ValueKind == System.Text.Json.JsonValueKind.Object && d.RootElement.TryGetProperty("gs_slice", out _)) r.Add(n[..^"_b.json".Length]); }
            catch (System.Text.Json.JsonException) { }
        }
        return r;
    }
    public static List<string> CheckNames(IEnumerable<string> macNames, IEnumerable<string> iosNames, bool noMac, TextWriter log, ISet<string> noLib = null)
    {
        var bad = new List<string>(); var orphan = new HashSet<string>();
        if (iosNames == null)
        {
            var mm = KeysOf(macNames); var mk0 = G(mm, "metallib");
            foreach (var ext in new[] { "metal", "json" })
            {
                var have = G(mm, ext); var d = Minus(mk0, have);
                if (d.Count > 0) bad.Add($"Mac 库 {d.Count} 个键有 _b.metallib 没有 _b.{ext}（如 {First3(d)}）");
                orphan.UnionWith(Minus(have, mk0));
            }
            if (mk0.Count == 0) bad.Add("一个键都没出");
            if (noLib != null) orphan.ExceptWith(noLib);   // 按设计无库（gs_slice：宿主读 json、用顶点阶段的图层入口画）：出成了，不算编译失败（11-02 双人成行 / 八方2 误报）
            if (bad.Count == 0) log.WriteLine($"[直连库] 核验齐全：{mk0.Count} 键，只出 Mac：Mac 三样都齐" + (orphan.Count > 0 ? $"；{orphan.Count} 个键只有 json / metal、没有 metallib（编译失败，不进 keys.tsv，如 {First3(orphan)}）" : ""));
            return bad;
        }
        var m = KeysOf(macNames); var i = KeysOf(iosNames);
        var ik = G(i, "metallib"); var ij = G(i, "json");
        { var d = Minus(ik, ij); if (d.Count > 0) bad.Add($"iOS 库 {d.Count} 个键有 _b.metallib 没有 _b.json（如 {First3(d)}）"); }
        if (noMac)
        {
            var mm = G(m, "metal");
            if (G(m, "metallib").Count > 0) bad.Add($"只出 iOS，Mac 库里却有 _b.metallib {m["metallib"].Count} 个（如 {First3(m["metallib"])}）");
            var mj = G(m, "json");
            { var d = Minus(mm, mj); if (d.Count > 0) bad.Add($"Mac 侧 {d.Count} 个键有 _b.metal 没有 _b.json（如 {First3(d)}）"); }
            { var d = Minus(ik, mm); if (d.Count > 0) bad.Add($"{d.Count} 个出成的键 Mac 侧没有 _b.metal（如 {First3(d)}）"); }
            { var d = Minus(mm, ij, ik); if (d.Count > 0) bad.Add($"Mac 侧 {mm.Count} 键、iOS 侧 {new HashSet<string>(ij.Concat(ik)).Count} 键，键集不同（如 {First3(d)}）"); }
            orphan = Minus(ij, ik); orphan.UnionWith(Minus(mj, mm));
        }
        else
        {
            var mk = G(m, "metallib");
            foreach (var ext in new[] { "metal", "json" })
            {
                var have = G(m, ext); var d = Minus(mk, have);
                if (d.Count > 0) bad.Add($"Mac 库 {d.Count} 个键有 _b.metallib 没有 _b.{ext}（如 {First3(d)}）");
                orphan.UnionWith(Minus(have, mk));
            }
            orphan.UnionWith(Minus(ij, ik));
            if (!mk.SetEquals(ik)) { var x = new HashSet<string>(mk); x.SymmetricExceptWith(ik); bad.Add($"Mac 库 {mk.Count} 键、iOS 库 {ik.Count} 键，键集不同（如 {First3(x)}）"); }
        }
        if (ik.Count == 0) bad.Add("一个键都没出");
        if (noLib != null) orphan.ExceptWith(noLib);   // 同上：按设计无库的键不算编译失败
        if (bad.Count == 0) log.WriteLine($"[直连库] 核验齐全：{ik.Count} 键，" + (noMac ? "只出 iOS：Mac 两样（无库）/ iOS 两样都齐" : "Mac 三样 / iOS 两样都齐")
                                          + (orphan.Count > 0 ? $"；{orphan.Count} 个键只有 json / metal、没有 metallib（编译失败，不进 keys.tsv，如 {First3(orphan)}）" : ""));
        return bad;
    }

    /// <summary>lib_swap.sdk_check_items：每个反射（LIBFILE 里的 *.json）的 chain_metal 都要带 -sdk &lt;plat 的 SDK&gt;</summary>
    public static List<string> SdkCheckItems(IEnumerable<(string Name, byte[] Data)> items, string plat, string where = "库")
    {
        string want = Sdk[plat]; var bad = new List<string>(); int n = 0;
        foreach (var (name, data) in items)
        {
            if (!name.EndsWith(".json", StringComparison.Ordinal) || !LIBFILE.IsMatch(name)) continue;
            string rec;
            using (var d = JsonBytes(data))
            {
                var v = Get(d, "chain_metal");
                if (v == null) rec = "";
                else if (v.Value.ValueKind == JsonValueKind.String) rec = v.Value.GetString();
                else throw new InvalidOperationException($"can only concatenate str (not \"{PyType(v.Value)}\") to str");   // Python：rec + ' ' 抛 TypeError
            }
            n++;
            if (!(rec + " ").Contains($"-sdk {want} ", StringComparison.Ordinal)) bad.Add(name);
        }
        if (n == 0) return new() { $"{where} 没有反射，核不了平台" };
        return bad.Count > 0 ? new() { $"目标 {plat} 要 -sdk {want}，{bad.Count} / {n} 个反射不是（如 {PyList(bad.Take(3))}）" } : new();
    }

    // ---------------- lib_pack.py ----------------
    const int VER = 1, ALIGN = 16; const long SHARD_MAX = 64L << 20;   // 分片上限 64 MB（运行时按需映射，iOS 虚拟地址紧）
    static readonly byte[] MAGIC = Encoding.ASCII.GetBytes("S2ALIB\0\0");
    static readonly Regex NAME = new(@"\A([0-9a-f]{16})_(b\.metallib|b\.json|b\.spv|bf\.metallib|bv\.metallib|ft\.metallib|se\.metallib|b_t([0-2])\.metallib|bg(\d+)\.(metallib|json)|bgv\.(metallib|json)|bgs(\d+)\.(metallib|json)|bgc\.(metallib|json))$", RegexOptions.CultureInvariant);
    static readonly Regex VKFP = new(@"\A[0-9a-f]{16}\z", RegexOptions.CultureInvariant);
    const int K_SPV = 52;   // Vulkan 库的 _b.spv（#783）；0–51 是 Metal 的种类
    static readonly Regex CHAIN = new(@"\A[0-9a-z]{1,12}\z", RegexOptions.CultureInvariant);
    static readonly Regex KEYFILE = new(@"\A[0-9a-f]{16}_", RegexOptions.CultureInvariant);
    static readonly Regex BATCH = new(@"\Au[0-9a-f]{16}\z", RegexOptions.CultureInvariant);

    /// <summary>种类号（lib_pack.kind）：0 _b.metallib 1 _b.json 2 _bf 3 _bv 4+d _b_t&lt;d&gt; 16+i _bg&lt;i&gt;.metallib 32+i _bg&lt;i&gt;.json 48/49 _bgv 50 _ft 51 _se 52 _b.spv（Vulkan 库）
    /// 64+i _bgs&lt;i&gt;.metallib 80+i _bgs&lt;i&gt;.json 96/97 _bgc（直通几何快路：只算副作用的几何核、读抓顶点的主遍顶点变体）；i &gt; 15 → null</summary>
    static int? Kind(Match m)
    {
        string s = m.Groups[2].Value;
        switch (s) { case "b.metallib": return 0; case "b.json": return 1; case "bf.metallib": return 2; case "bv.metallib": return 3; case "ft.metallib": return 50; case "se.metallib": return 51; case "b.spv": return K_SPV; }
        if (m.Groups[3].Success) return 4 + (m.Groups[3].Value[0] - '0');
        if (m.Groups[4].Success)
        {
            var i = PyInt(m.Groups[4].Value);
            return i > 15 ? null : (m.Groups[5].Value == "metallib" ? 16 : 32) + (int)i;
        }
        if (m.Groups[7].Success)
        {
            var i = PyInt(m.Groups[7].Value);
            return i > 15 ? null : (m.Groups[8].Value == "metallib" ? 64 : 80) + (int)i;
        }
        if (m.Groups[9].Success) return m.Groups[9].Value == "metallib" ? 96 : 97;
        return m.Groups[6].Value == "metallib" ? 48 : 49;
    }

    /// <summary>
    /// lib_pack.pack_files：按键文件 → &lt;d&gt;/lib.NNN.pak + lib.idx（d 已存在、里面没有 lib.idx）。names：文件名清单；get(名) → 字节或 null（可取 names 以外的名字）。
    /// → (红行, 汇总行)；有红行时 d 里不留任何临时文件。lib.idx 小端：头 48 字节 + 分片表 nshard×16 + 记录 n×24（u64 键、u8 种类、u8 分片、u16 0、u32 长、u64 偏移），段起点 16 字节对齐
    /// vkfp（#783 合入线 11-03 答 ①）：给了 = Vulkan 库，16 位小写十六进制的 Vulkan 侧指纹按 u64 写进头部 36–43（44–47 仍为 0），只收 _b.json / _b.spv；
    ///   不给 = Metal 库，头部 36–47 全 0、不收 _b.spv（与改前逐字节相同）
    /// </summary>
    public static (List<string> Bad, string Line) PackFiles(IEnumerable<string> names, Func<string, byte[]> get, string d, string chain, string vkfp = null)
    {
        if (!CHAIN.IsMatch(chain)) return (new() { $"链版本 {chain} 不对（至多 12 位）" }, "");
        if (vkfp != null && !VKFP.IsMatch(vkfp)) return (new() { $"Vulkan 侧指纹 {vkfp} 不对（16 位小写十六进制）" }, "");
        if (File.Exists(Path.Combine(d, "lib.idx")) || Directory.Exists(Path.Combine(d, "lib.idx"))) return (new() { $"{d} 已有 lib.idx（打过包了）" }, "");
        var nameList = names.ToList();
        var ents = new List<(ulong Key, int K, string N)>(); var bad = new List<string>();
        foreach (var n in Sorted(nameList))
        {
            var m = NAME.Match(n);
            if (m.Success)
            {
                var k = Kind(m);
                if (k == null) bad.Add($"认不出的种类：{n}");
                else ents.Add((Convert.ToUInt64(m.Groups[1].Value, 16), k.Value, n));
            }
            else if (KEYFILE.IsMatch(n)) bad.Add($"认不出的键文件：{n}");   // 不认识的按键文件不能悄悄留在包外
        }
        if (bad.Count > 0) return (bad, "");
        if (vkfp == null && ents.Any(e => e.K == K_SPV)) return (new() { $"有 _b.spv（Vulkan 库的种类）却没给 Vulkan 侧指纹" }, "");
        if (vkfp != null && ents.Any(e => e.K != K_SPV && e.K != 1)) return (new() { $"给了 Vulkan 侧指纹却混进了 Metal 段（如 {ents.First(e => e.K != K_SPV && e.K != 1).N}；Vulkan 库只收 _b.json / _b.spv）" }, "");
        if (ents.Count == 0) return (new() { $"{d} 一个键文件都没有" }, "");
        // A network's layers must all execute, or all use the old stand-in. Per-key opt-in would
        // mix newly translated missing keys with old packaged scalar layers and read unwritten buffers.
        bool tensorNative = vkfp == null, anyCompute = false;
        foreach (var ent in ents.Where(e => e.K == 1))
        {
            try
            {
                using var doc = JsonBytes(get(ent.N));
                var root = doc.RootElement;
                if (!root.TryGetProperty("stage", out var st)) { tensorNative = false; continue; }
                if (st.GetString() != "cs") continue;
                anyCompute = true;
                tensorNative &= root.TryGetProperty("tensor_mma_abi", out var abi) && abi.TryGetInt32(out int a) && a == 1 &&
                    root.TryGetProperty("tensor_mma_count", out var count) && count.TryGetInt32(out int c) && c >= 0;
            }
            catch (Exception e) when (e is JsonException || e is ArgumentException || e is InvalidOperationException) { tensorNative = false; }
        }
        tensorNative &= anyCompute;
        ents.Sort((a, b) => a.Key != b.Key ? a.Key.CompareTo(b.Key) : a.K != b.K ? a.K.CompareTo(b.K) : Cp.Compare(a.N, b.N));
        // 种类 0 换成所在批库（json fn_lib）：批库没了 = 不齐，不打包
        var src = new Dictionary<string, string>(); var have = new HashSet<string>(nameList);
        foreach (var (key, k, n) in ents)
        {
            if (k != 0) continue;
            string lib = null;
            var jb = get($"{key:x16}_b.json");
            if (jb != null)   // Python：json.loads(None) 的 TypeError 与解析失败的 ValueError 都当没有批库
            {
                JsonDocument doc = null;
                try { doc = JsonBytes(jb); } catch (JsonException) { }
                if (doc != null) using (doc)
                {
                    var v = Get(doc, "fn_lib");
                    if (v != null && Truthy(v.Value))
                    {
                        if (v.Value.ValueKind != JsonValueKind.String) throw new InvalidOperationException($"expected string or bytes-like object, got '{PyType(v.Value)}'");   // Python re.fullmatch 抛 TypeError
                        lib = v.Value.GetString();
                    }
                }
            }
            if (!string.IsNullOrEmpty(lib))
            {
                if (!BATCH.IsMatch(lib) || !have.Contains(lib + ".metallib")) bad.Add($"键 {key:x16} 的批库 {lib}.metallib 不在");
                else src[n] = lib + ".metallib";
            }
        }
        if (bad.Count > 0) return (bad, "");

        var recs = new List<(ulong Key, int K, int S, uint Len, ulong Off)>(); var shards = new List<string>();
        var digest = new Dictionary<(ulong, int), string>(); var libDigest = new Dictionary<string, string>();
        var same = new Dictionary<string, (int S, long Off, long Len)>(); var put = new Dictionary<string, (int S, long Off, long Len)>();
        FileStream cur = null; int sh = -1, dup = 0; bool ok = false; string idxTmp = Path.Combine(d, "lib.idx.tmp");
        var sizes = new List<long>(); byte[] idx = null;
        try
        {
            foreach (var (key, k, n) in ents)
            {
                src.TryGetValue(n, out var sn);
                if (sn != null && put.TryGetValue(sn, out var p0))   // 同一批库已写过：指向那一段
                { recs.Add((key, k, p0.S, (uint)p0.Len, (ulong)p0.Off)); digest[(key, k)] = libDigest[sn]; continue; }
                var b = get(sn ?? n);
                if (b == null) return (new() { $"取不到 {sn ?? n}" }, "");
                string h = Convert.ToHexString(SHA256.HashData(b));
                if (same.TryGetValue(h, out var s0))   // 字节相同的段只存一次
                {
                    recs.Add((key, k, s0.S, (uint)s0.Len, (ulong)s0.Off)); digest[(key, k)] = h; dup++;
                    if (sn != null) { put[sn] = s0; libDigest[sn] = h; }
                    continue;
                }
                if (cur == null || (cur.Position != 0 && cur.Position + b.Length > SHARD_MAX))
                {
                    if (cur != null) { sizes.Add(cur.Position); cur.Dispose(); }
                    sh++; shards.Add(Path.Combine(d, $"lib.{sh:D3}.pak.tmp")); cur = new FileStream(shards[^1], FileMode.Create, FileAccess.Write, FileShare.None, 1 << 20);
                }
                int pad = (int)((ALIGN - cur.Position % ALIGN) % ALIGN); if (pad > 0) cur.Write(new byte[pad]);
                long off = cur.Position;
                recs.Add((key, k, sh, (uint)b.Length, (ulong)off)); digest[(key, k)] = h; same[h] = (sh, off, b.Length);
                if (sn != null) { put[sn] = (sh, off, b.Length); libDigest[sn] = h; }
                cur.Write(b);
            }
            sizes.Add(cur.Position); cur.Dispose(); cur = null;
            if (sh > 255) return (new() { $"分片 {sh + 1} 个，超过 256" }, "");
            for (int i = 0; i < shards.Count; i++) sizes[i] = new FileInfo(shards[i]).Length;   // 同 Python os.path.getsize
            idx = new byte[48 + 16 * shards.Count + 24 * recs.Count];
            var w = idx.AsSpan();
            MAGIC.CopyTo(w); W32(w, 8, VER); W32(w, 12, (uint)recs.Count); W32(w, 16, (uint)shards.Count); W32(w, 20, tensorNative ? 1u : 0u);
            Encoding.ASCII.GetBytes(chain).CopyTo(w[24..]);   // 12 字节链版本，不足补 0；36–47 为 0
            if (vkfp != null) W64(w, 36, Convert.ToUInt64(vkfp, 16));   // Vulkan 库：36–43 = Vulkan 侧指纹（u64），44–47 仍为 0
            for (int i = 0; i < shards.Count; i++) W64(w, 48 + 16 * i, (ulong)sizes[i]);
            int o = 48 + 16 * shards.Count;
            foreach (var r in recs) { W64(w, o, r.Key); w[o + 8] = (byte)r.K; w[o + 9] = (byte)r.S; W32(w, o + 12, r.Len); W64(w, o + 16, r.Off); o += 24; }
            File.WriteAllBytes(idxTmp, idx);
            // 回读核验：按索引从分片取每段，与原字节的摘要比；每段只核一次。逐片读（一片至多 SHARD_MAX）、核完就丢——
            //   审计 #1417 P1-87：原先把全部分片一次读进一个列表，大库发布段的常驻再涨出一整份库
            var seg = new Dictionary<(int, ulong, uint), string>();
            foreach (var g in recs.GroupBy(r => r.S).OrderBy(g => g.Key))
            {
                var map = File.ReadAllBytes(shards[g.Key]);
                foreach (var r in g)
                {
                    if (!seg.TryGetValue((r.S, r.Off, r.Len), out var h))
                        seg[(r.S, r.Off, r.Len)] = h = Convert.ToHexString(SHA256.HashData(map.AsSpan((int)r.Off, (int)r.Len)));
                    if (h != digest[(r.Key, r.K)]) return (new() { $"回读不符：键 {r.Key:x16} 种类 {r.K}" }, "");
                }
            }
            ok = true;
        }
        catch (Exception e) when (e is IOException || e is UnauthorizedAccessException)
        {
            return (new() { $"写分片 / 索引失败：{e.Message}" }, "");
        }
        finally
        {
            cur?.Dispose();
            if (!ok) foreach (var p in shards.Append(idxTmp)) if (File.Exists(p)) File.Delete(p);   // 没打成：临时分片 / 索引清掉
        }
        foreach (var p in shards) File.Move(p, p[..^4], true);
        File.Move(idxTmp, Path.Combine(d, "lib.idx"), true);
        int nk = ents.Select(e => e.Key).Distinct().Count();
        return (new(), $"[直连库] 打包：{nk} 键 {recs.Count} 段（其中 {src.Count} 个键的 _b 库来自 {put.Count} 个批库；另有 {dup} 段与已存的段字节相同、只存一次）→ {shards.Count} 个分片 {Fmt(sizes.Sum(), 1048576, 1)} MB + lib.idx {Fmt(idx.Length, 1024, 0)} KB（回读逐段相符）");
    }
    static void W32(Span<byte> w, int o, uint v) => System.Buffers.Binary.BinaryPrimitives.WriteUInt32LittleEndian(w[o..], v);
    static void W64(Span<byte> w, int o, ulong v) => System.Buffers.Binary.BinaryPrimitives.WriteUInt64LittleEndian(w[o..], v);

    // ---------------- ps_inputs.py ----------------
    const string PS_HEAD = "# 片元键\t它读的 user(locn) 位置（逗号分隔，可空）\n";
    static readonly Regex LOCN = new(@"\[\[user\(locn(\d+)\)", RegexOptions.CultureInvariant);

    /// <summary>ps_inputs.write：items 按 _b.json 文件名排序的 (键, _b.json 文本, _b.metal 文本或 null) → 写 out，返回片元个数；读不了反射 / 片元没 MSL 抛 Exit（不写 out）</summary>
    public static int PsInputsWrite(IEnumerable<(string Key, string Text, string Msl)> items, string outPath)
    {
        var rows = new StringBuilder(); int nrow = 0;
        foreach (var (key, text, msl) in items)
        {
            bool ps;
            JsonDocument d;
            try { d = JsonText(text); } catch (JsonException) { throw new Exit($"【红】读不了 {key}_b.json"); }
            using (d) { var v = Get(d, "stage"); ps = v != null && v.Value.ValueKind == JsonValueKind.String && v.Value.GetString() == "ps"; }
            if (!ps) continue;
            if (msl == null) throw new Exit($"【红】片元 {key}_b.json 没有 MSL（{key}_b.metal）");
            var locs = new SortedSet<BigInteger>(LOCN.Matches(msl).Select(m => PyInt(m.Groups[1].Value)));
            rows.Append(key).Append('\t').Append(string.Join(",", locs)).Append('\n'); nrow++;
        }
        File.WriteAllText(outPath, PS_HEAD + rows, Utf8Out);
        return nrow;
    }

    // ---------------- dmsh_build.py 末尾「if IOSOUT and PUBLISH」 ----------------
    static readonly Regex KEYSLIB = new(@"\A[0-9a-f]{16}_b\.metallib\z", RegexOptions.CultureInvariant);

    /// <summary>
    /// 整份出库收尾：核验两侧齐全 → 核发布侧反射 -sdk → 发布侧库容器打进 iosOut（b-&lt;链&gt;/）→ dirname(iosOut)/ps_inputs.tsv（从 Mac 侧算）与 keys.tsv（发布侧出成的键）。
    /// mac / ios：两侧「文件名 → 字节」表（ios null = DMSH_NO_IOS_LIB）；noMac = DMSH_NO_MAC_LIB；publish = S2A_DIRECT_PUBLISH（ios / mac）。
    /// → null 成；否则返回 sys.exit 的文本。log 收 Python 那段 print 的各行（不含之前的 library stamp 行）
    /// 与 Python 唯一的有意不同：publish = ios 而 ios 为 null 时 Python 在 _pub.names() 上 AttributeError 崩掉，这里照常返回红行
    /// </summary>
    public static string Publish(IReadOnlyDictionary<string, byte[]> mac, IReadOnlyDictionary<string, byte[]> ios, bool noMac, string publish, string iosOut, string chain, TextWriter log)
    {
        var noLib = NoLibKeys(publish == "mac" ? mac : ios ?? mac);
        var bad = CheckNames(mac.Keys, ios?.Keys, noMac, log, noLib);
        if (publish == "ios" && ios == null) bad.Add("发布 iOS 库却没编 iOS 那份（DMSH_NO_IOS_LIB）");
        if (!Sdk.ContainsKey(publish)) bad.Add($"S2A_DIRECT_PUBLISH 只认 ios / mac，给了 {publish}");
        var pub = publish == "mac" ? mac : ios;
        if (bad.Count == 0) bad = SdkCheckItems(Sorted(pub.Keys).Where(n => n.EndsWith(".json", StringComparison.Ordinal) && LIBFILE.IsMatch(n)).Select(n => (n, pub[n])), publish, $"{publish} 库");   // 只核 json：先筛再读（同 SdkCheckItems 循环里的条件；原先连 8 万多个指向批库的 _b.metallib 一起读盘）
        if (bad.Count == 0) log.WriteLine($"[直连库] 发布 {publish} 库：反射全部 -sdk {Sdk[publish]}");
        string line = null;
        if (bad.Count == 0) (bad, line) = PackFiles(pub.Keys.Where(IsLibFile).ToList(), n => pub.TryGetValue(n, out var b) ? b : null, iosOut, chain);
        if (bad.Count > 0) return string.Join("\n", bad.Take(20).Select(b => $"[RED] {b}"));
        log.WriteLine(line);
        string top = Path.GetDirectoryName(iosOut);
        var items = Sorted(mac.Keys.Where(n => n.EndsWith("_b.json", StringComparison.Ordinal)))
            .Select(n => (n[..^"_b.json".Length], Utf8.GetString(mac[n]), mac.TryGetValue(n[..^5] + ".metal", out var t) ? Utf8.GetString(t) : null));
        int nps;
        try { nps = PsInputsWrite(items, Path.Combine(top, "ps_inputs.tsv")); } catch (Exit e) { return e.Message; }
        log.WriteLine($"ps_inputs.tsv: {nps} pixel shaders");
        // keys.tsv = 出成的键：有 _b.metallib 的，加按设计无库、发布侧有 _b.json 的（gs_slice）。宿主 gfxmode.c 拿它判「直连就绪」（要覆盖通用模式见过的全部键），漏了这类键就判不就绪
        var built = new HashSet<string>(pub.Keys.Where(n => KEYSLIB.IsMatch(n)).Select(n => n[..^"_b.metallib".Length]));
        if (noLib != null) foreach (var k in noLib) if (pub.ContainsKey(k + "_b.json")) built.Add(k);
        File.WriteAllText(Path.Combine(top, "keys.tsv"), string.Concat(Sorted(built).Select(k => k + "\n")), Utf8Out);
        return null;
    }

    static Dictionary<string, byte[]> LoadDir(string dir) =>
        Directory.EnumerateFiles(dir).ToDictionary(p => Path.GetFileName(p), File.ReadAllBytes);

    /// <summary>
    /// 对拍入口：dsh_batch --libpack &lt;输入目录&gt; &lt;输出目录&gt; &lt;链号&gt; &lt;mac|ios&gt; [--no-mac-lib]
    ///   输入目录下有 mac/（必有）与 ios/（可无 = 只出 Mac）两个平铺的产物目录；没有 mac/ 时输入目录本身同时当两侧。
    ///   输出：&lt;输出目录&gt;/b-&lt;链号&gt;/lib.NNN.pak + lib.idx，&lt;输出目录&gt;/ps_inputs.tsv、keys.tsv；各行进标准输出，报红进标准错误、退出 1
    /// </summary>
    //   dsh_batch --libpack pack <输入目录> <输出目录> <链号> [<Vulkan 侧指纹>]：只打容器（PackFiles，不核两侧齐全、不核 -sdk、不出 ps_inputs / keys.tsv）：输入目录里的文件全部交给 PackFiles；
    //     给了指纹 = Vulkan 库（#783，t_lib_pack_vk.py）
    //     （认不出的按键文件照样报红），lib.NNN.pak + lib.idx 写进输出目录（不在就建）；汇总行进标准输出，报红进标准错误、退出 1。单测造容器用（t_lib_pack.py、graphics/nvn/tests/t_nvn_red.m）
    public static int Cli(string[] argv)
    {
        if ((argv.Length == 4 || argv.Length == 5) && argv[0] == "pack")
        {
            var names = Directory.EnumerateFiles(argv[1]).Select(Path.GetFileName).ToList();
            Directory.CreateDirectory(argv[2]);
            var (pb, pl) = PackFiles(names, n => File.Exists(Path.Combine(argv[1], n)) ? File.ReadAllBytes(Path.Combine(argv[1], n)) : null, argv[2], argv[3], argv.Length == 5 ? argv[4] : null);
            if (pb.Count > 0) { var pe = Console.OpenStandardError(); var pbs = Utf8Out.GetBytes(string.Join("\n", pb.Select(b => $"[RED] {b}")) + "\n"); pe.Write(pbs); pe.Flush(); return 1; }
            var so = Console.OpenStandardOutput(); var sb = Utf8Out.GetBytes(pl + "\n"); so.Write(sb); so.Flush();
            return 0;
        }
        bool noMac = argv.Contains("--no-mac-lib"); var a = argv.Where(x => x != "--no-mac-lib").ToArray();
        if (a.Length != 4) { Console.Error.WriteLine("用法：dsh_batch --libpack <输入目录> <输出目录> <链号> <mac|ios> [--no-mac-lib]"); return 2; }
        string inp = a[0], outDir = a[1], chain = a[2], plat = a[3];
        Dictionary<string, byte[]> mac, ios;
        if (Directory.Exists(Path.Combine(inp, "mac"))) { mac = LoadDir(Path.Combine(inp, "mac")); ios = Directory.Exists(Path.Combine(inp, "ios")) ? LoadDir(Path.Combine(inp, "ios")) : null; }
        else mac = ios = LoadDir(inp);
        string iosOut = Path.Combine(outDir, "b-" + chain); Directory.CreateDirectory(iosOut);
        var log = new StringWriter();
        string err;
        try { err = Publish(mac, ios, noMac, plat, iosOut, chain, log); }
        catch (Exception x) { err = $"{x.GetType().Name}: {x.Message}"; }   // Python 那边是没人接的异常（反射 json 解不了等），整份出库崩；这里同样退出 1，文案不同
        var o = Console.OpenStandardOutput(); var lb = Utf8Out.GetBytes(log.ToString()); o.Write(lb); o.Flush();
        if (err == null) return 0;
        var e = Console.OpenStandardError(); var eb = Utf8Out.GetBytes(err + "\n"); e.Write(eb); e.Flush();
        return 1;
    }
}
