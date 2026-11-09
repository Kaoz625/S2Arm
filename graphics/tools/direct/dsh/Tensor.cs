// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// HMMA.16816 F16 fragment layout follows InstEmitAmpereTensor / GenerateHmma16816F16.
// Keep that helper's argument and scratch-memory ABI; replace only its scalar body.
using System;
using System.Linq;
using System.Text.RegularExpressions;

namespace S2A.Dsh
{
    static class DshTensor
    {
        // 0: no HMMA; -1: at least one unsupported form. Never mark a partly lowered network native.
        internal static int Count(byte[] code)
        {
            int count = 0;
            for (int p = 0; p + 16 <= code.Length; p += 16)
            {
                ulong lo = BitConverter.ToUInt64(code, p), hi = BitConverter.ToUInt64(code, p + 8);
                if ((lo & 0xfff) != 0x23c) continue;
                // Size bits 75 / 78 = 1 / 0, accumulator bit 76 = half, source bits 82..83 = half.
                if ((hi & ((1ul << 11) | (1ul << 14) | (1ul << 12) | (3ul << 18))) != (1ul << 11)) return -1;
                count++;
            }
            return count;
        }

        internal static string Lower(string source)
        {
            var match = Regex.Match(source, @"\bint dmsh_hmma16816_f16\(([^\n]+)\)\s*\{");
            if (!match.Success) throw new DshError("tensor MSL failed", "HMMA helper missing");
            // Split at parameter boundaries (the array template itself contains a comma).
            var args = Regex.Split(match.Groups[1].Value, @",\s*(?=(?:thread|threadgroup|device)\b)");
            if (args.Length != 12 || args.Take(10).Any(a => !Regex.IsMatch(a, @"^thread const int& \w+$")) ||
                !Regex.IsMatch(args[10], @"^thread int& \w+$") ||
                !Regex.IsMatch(args[11], @"^threadgroup spvUnsafeArray<uint, \d+>& \w+$"))
                throw new DshError("tensor MSL failed", "HMMA helper ABI changed");
            string[] names = args.Select(a => Regex.Match(a, @"\w+$").Value).ToArray();
            int start = match.Index + match.Length, end = start, depth = 1;
            for (; end < source.Length && depth != 0; end++)
                depth += source[end] == '{' ? 1 : source[end] == '}' ? -1 : 0;
            if (depth != 0) throw new DshError("tensor MSL failed", "HMMA helper body unterminated");
            string body = @"
    const uint lane = uint($0), group = lane >> 2, pair = lane & 3;
    threadgroup float* f = reinterpret_cast<threadgroup float*>(&$11[uint($1)]);
    const uint col = pair * 2, at = group * 8 + col;
    float2 c0 = float2(as_type<half2>(uint($8))), c1 = float2(as_type<half2>(uint($9)));
    f[at] = c0.x; f[at + 1] = c0.y;
    f[64 + at] = c1.x; f[64 + at + 1] = c1.y;
    simdgroup_barrier(mem_flags::mem_threadgroup);
    simdgroup_float8x8 top, bottom;
    simdgroup_load(top, f, 8); simdgroup_load(bottom, f + 64, 8);
    simdgroup_barrier(mem_flags::mem_threadgroup);
    // C is in float registers. Reuse the block for packed-half A/B fragments;
    // mixed half x half -> float matrix multiplies keep the full dot product's precision.
    threadgroup uint* words = &$11[uint($1)];
    words[group * 8 + pair] = uint($2);
    words[(group + 8) * 8 + pair] = uint($3);
    words[group * 8 + pair + 4] = uint($4);
    words[(group + 8) * 8 + pair + 4] = uint($5);
    words[128 + group * 8 + pair] = uint($6);
    words[128 + group * 8 + pair + 4] = uint($7);
    simdgroup_barrier(mem_flags::mem_threadgroup);
    threadgroup half* h = reinterpret_cast<threadgroup half*>(words);
    simdgroup_half8x8 a00, a01, a10, a11, b0, b1;
    simdgroup_load(a00, h, 16); simdgroup_load(a01, h + 8, 16);
    simdgroup_load(a10, h + 128, 16); simdgroup_load(a11, h + 136, 16);
    simdgroup_load(b0, h + 256, 16, ulong2(0), true);
    simdgroup_load(b1, h + 264, 16, ulong2(0), true);
    simdgroup_multiply_accumulate(top, a00, b0, top);
    simdgroup_multiply_accumulate(top, a01, b1, top);
    simdgroup_multiply_accumulate(bottom, a10, b0, bottom);
    simdgroup_multiply_accumulate(bottom, a11, b1, bottom);
    simdgroup_barrier(mem_flags::mem_threadgroup);
    simdgroup_store(top, f, 8); simdgroup_store(bottom, f + 64, 8);
    simdgroup_barrier(mem_flags::mem_threadgroup);
    // Round only the completed dot product to F16, as the scalar oracle does.
    const int d0 = int(as_type<uint>(half2(f[at], f[at + 1])));
    $10 = int(as_type<uint>(half2(f[64 + at], f[64 + at + 1])));
    simdgroup_barrier(mem_flags::mem_threadgroup);
    return d0;
}
";
            // Replace highest indices first ($1 must not rewrite $10 / $11).
            for (int i = 11; i >= 0; i--) body = body.Replace("$" + i, names[i]);
            string result = source[..start] + body + source[end..];
            return "#include <metal_simdgroup_matrix>\n" + result;
        }
    }
}
