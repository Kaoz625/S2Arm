// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Real GPU oracle for the production HMMA helper: independently pack PTX fragments from matrices.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <math.h>

static uint32_t pack(float a, float b) {
    _Float16 h[2] = {a, b}; uint32_t w; memcpy(&w, h, 4); return w;
}
static void unpack(uint32_t w, float *a, float *b) {
    _Float16 h[2]; memcpy(h, &w, 4); *a = h[0]; *b = h[1];
}
int main(int argc, char **argv) { @autoreleasepool {
    if (argc != 2) return 2;
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (!dev || ![dev supportsFamily:MTLGPUFamilyApple7]) { fprintf(stderr, "Apple7 GPU required\n"); return 2; }
    NSError *err = nil;
    NSString *src = [NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:&err];
    MTLCompileOptions *opts = [MTLCompileOptions new]; opts.languageVersion = MTLLanguageVersion3_1;
    opts.mathMode = MTLMathModeSafe;
    id<MTLLibrary> lib = [dev newLibraryWithSource:src options:opts error:&err];
    id<MTLFunction> fn = [lib newFunctionWithName:@"hmma_test"];
    id<MTLComputePipelineState> ps = fn ? [dev newComputePipelineStateWithFunction:fn error:&err] : nil;
    if (!ps) { fprintf(stderr, "%s\n", err.localizedDescription.UTF8String); return 2; }
    if (ps.threadExecutionWidth != 32) { fprintf(stderr, "SIMD width %lu != 32\n", ps.threadExecutionWidth); return 2; }
    id<MTLCommandQueue> queue = [dev newCommandQueue];
    unsigned checked = 0, bad = 0;
    for (int test = 0; test < 5; test++) {
        enum { WARPS = 8, LANES = 32, WORDS = 8 };
        uint32_t in[WARPS * LANES * WORDS], expected[WARPS * LANES * 2];
        for (int w = 0; w < WARPS; w++) {
            float a[16][16], b[16][8], c[16][8], d[16][8];
            for (int r = 0; r < 16; r++) for (int k = 0; k < 16; k++)
                a[r][k] = test == 4 ? 1 : test == 0 ? (r == k) : ((r * 3 + k * 5 + w) % 11 - 5) / 8.0f;
            for (int k = 0; k < 16; k++) for (int n = 0; n < 8; n++)
                b[k][n] = test == 4 ? (k == 0 || k == 8 ? 1.0f / 2048 : 0) : ((k * 7 + n * 2 + w) % 13 - 6) / 8.0f;
            for (int r = 0; r < 16; r++) for (int n = 0; n < 8; n++) {
                // Each K tile adds half an F16 ULP to 1.0. Rounding after each
                // tile gives 1.0 twice; rounding the full dot product gives 1+1/1024.
                c[r][n] = test == 4 ? 1 : ((r * 5 + n + w) % 9 - 4) / 16.0f;
                float acc = c[r][n];
                for (int k = 0; k < 16; k++) acc += a[r][k] * b[k][n];
                d[r][n] = (_Float16)acc;
                if (test == 2) { // second instruction's C is the first instruction's rounded result
                    acc = d[r][n];
                    for (int k = 0; k < 16; k++) acc += a[r][k] * b[k][n];
                    d[r][n] = (_Float16)acc;
                }
            }
            for (int lane = 0; lane < LANES; lane++) {
                int g = lane / 4, t = lane % 4, o = (w * LANES + lane) * WORDS;
                in[o] = pack(a[g][2*t], a[g][2*t+1]);
                in[o+1] = pack(a[g+8][2*t], a[g+8][2*t+1]);
                in[o+2] = pack(a[g][2*t+8], a[g][2*t+9]);
                in[o+3] = pack(a[g+8][2*t+8], a[g+8][2*t+9]);
                in[o+4] = pack(b[2*t][g], b[2*t+1][g]);
                in[o+5] = pack(b[2*t+8][g], b[2*t+9][g]);
                in[o+6] = pack(c[g][2*t], c[g][2*t+1]);
                in[o+7] = pack(c[g+8][2*t], c[g+8][2*t+1]);
                expected[(w*LANES+lane)*2] = pack(d[g][2*t], d[g][2*t+1]);
                expected[(w*LANES+lane)*2+1] = pack(d[g+8][2*t], d[g+8][2*t+1]);
            }
        }
        id<MTLBuffer> input = [dev newBufferWithBytes:in length:sizeof in options:MTLResourceStorageModeShared];
        id<MTLBuffer> output = [dev newBufferWithLength:sizeof expected options:MTLResourceStorageModeShared];
        uint32_t repeats = test == 2 ? 2 : 1;
        id<MTLCommandBuffer> cb = [queue commandBuffer]; id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:ps]; [enc setBuffer:input offset:0 atIndex:1]; [enc setBuffer:output offset:0 atIndex:2]; [enc setBytes:&repeats length:4 atIndex:3];
        // test 3 uses 2D groups: subgroup scratch offset must use the flattened local index.
        [enc dispatchThreadgroups:MTLSizeMake(2,1,1) threadsPerThreadgroup:test == 3 ? MTLSizeMake(32,4,1) : MTLSizeMake(128,1,1)];
        [enc endEncoding]; [cb commit]; [cb waitUntilCompleted];
        if (cb.status != MTLCommandBufferStatusCompleted) { fprintf(stderr, "%s\n", cb.error.localizedDescription.UTF8String); return 2; }
        const uint32_t *got = output.contents;
        unsigned mismatches = 0;
        for (unsigned i = 0; i < sizeof expected / 4; i++) {
            checked += 2;
            if (got[i] != expected[i]) {
                mismatches++; bad++;
                if (mismatches <= 3) { float x,y,u,v; unpack(got[i],&x,&y);unpack(expected[i],&u,&v); fprintf(stderr,"case%d word%u: expected %g,%g got %g,%g\n",test,i,u,v,x,y); }
            }
        }
        printf("case%d: 8 warps / 1024 elements, mismatched words %u\n", test, mismatches);
    }
    printf("HMMA native GPU: %u elements, %u mismatched words (%s)\n", checked, bad, dev.name.UTF8String);
    return bad ? 1 : 0;
} }
