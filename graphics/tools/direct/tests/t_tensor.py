#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Production Ampere -> MSL -> real GPU. Expected matrices are computed independently in tensor_run.m."""
import json
from pathlib import Path
import re
import struct
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
sys.path[:0] = [str(ROOT / 'tests/ampere_isa'), str(HERE)]
import cases
import dshfn


def compile_shader(mixed=False, threads=128):
    body = [cases.MOVC(i + 4, i) for i in range(8)]
    body += [cases.inst(0x23c, rd=(16, 0), ra=(24, 4), rb=(32, 8), rc=(64, 10), size=(75, 1))]
    if mixed:
        body += [cases.inst(0x23c, rd=(16, 0), ra=(24, 4), rb=(32, 8), rc=(64, 10), size=(75, 1), f32=(76, 1))]
    body += [cases.LDC64(12, 0x10), cases.STG32(12, 0, 0), cases.STG32(12, 1, 4)]
    stage, code, ctl = cases.cs_shader(body, ssbos=1)
    ctl = bytearray(ctl)
    struct.pack_into('<III', ctl, 0x58, threads, 1, 1)
    out = dshfn.fn('ampere_compile', stage, code.hex(), ctl.hex(), None, dsx=dshfn.DSX)
    assert out[0] != 'fail', out
    return out[0], json.loads(out[1])


def main():
    src, meta = compile_shader()
    assert 'simdgroup_multiply_accumulate' in src, 'HMMA remains a scalar expansion'
    assert meta.get('tensor_mma_abi') == 1 and meta.get('tensor_mma_count') == 1, meta
    for kwargs in ({'mixed': True}, {'threads': 16}, {'threads': 0}):
        other, m = compile_shader(**kwargs)
        assert m.get('tensor_mma_abi', 0) == 0, ('partly supported program marked native', kwargs)
        assert 'simdgroup_multiply_accumulate' not in other
    plain = dshfn.fn('ampere_compile', *plain_shader(), None, dsx=dshfn.DSX)
    assert 'simdgroup_multiply_accumulate' not in plain[0], 'non-HMMA shader changed'
    assert json.loads(plain[1]).get('tensor_mma_count') == 0
    helper = re.search(r'\bint (dmsh_hmma16816_f16)\(', src).group(1)
    # Same helper as the production compiler, called with independently packed fragments.
    src += '''
kernel void hmma_test(device const uint* input [[buffer(1)]], device uint* output [[buffer(2)]], constant uint& repeats [[buffer(3)]],
    uint3 pos [[thread_position_in_threadgroup]], uint3 group [[threadgroup_position_in_grid]], uint3 size [[threads_per_threadgroup]]) {
    threadgroup spvUnsafeArray<uint, 1024> scratch;
    uint flat = pos.x + size.x * (pos.y + size.y * pos.z);
    uint index = group.x * 128 + flat, base = index * 8;
    int lane = int(flat & 31), block = int((flat >> 5) * 256);
    int a0 = int(input[base]), a1 = int(input[base+1]), a2 = int(input[base+2]), a3 = int(input[base+3]);
    int b0 = int(input[base+4]), b1 = int(input[base+5]), c0 = int(input[base+6]), c1 = int(input[base+7]), d1;
    for (uint i = 0; i < repeats; i++) {
        int d0 = HELPER(lane, block, a0, a1, a2, a3, b0, b1, c0, c1, d1, scratch);
        c0 = d0; c1 = d1;
    }
    output[index*2] = uint(c0); output[index*2+1] = uint(c1);
}
'''.replace('HELPER', helper)
    with tempfile.TemporaryDirectory(prefix='tensor-gpu-') as tmp:
        p = Path(tmp)
        metal = p / 'test.metal'
        metal.write_text(src)
        runner = p / 'run'
        subprocess.run(['xcrun', 'clang', '-O1', '-fobjc-arc', str(HERE / 'tensor_run.m'), '-framework', 'Metal', '-framework', 'Foundation', '-o', str(runner)], check=True)
        subprocess.run([str(runner), str(metal)], check=True)
        # Wrong B transpose must be observed by the independent GPU oracle.
        assert 'ulong2(0), true' in src
        metal.write_text(src.replace('ulong2(0), true', 'ulong2(0), false'))
        neg = subprocess.run([str(runner), str(metal)], capture_output=True, text=True)
        assert neg.returncode == 1, ('transpose negative control failed', neg.stdout, neg.stderr)
        print('negative control: wrong B transpose -> GPU mismatches (exit 1)')
    print('tensor native: compiler eligibility 5 cases + GPU 5120 elements + negative control passed')


def plain_shader():
    stage, code, ctl = cases.cs_shader([cases.MOVI(0, 1), cases.LDC64(12, 0x10), cases.STG32(12, 0, 0)], ssbos=1)
    return stage, code.hex(), ctl.hex()


if __name__ == '__main__':
    main()
