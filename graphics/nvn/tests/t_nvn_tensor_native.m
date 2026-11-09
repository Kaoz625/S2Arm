// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Native tensor metadata must reach the real compute dispatch, including the encoder thread.
#include "../gfx/nvn/nvn_mtl.m"
const char *s2a_dsh_xfp(void) { return "tensor_test"; }
static unsigned checks;
#define REQUIRE(c) do { checks++; if (!(c)) { fprintf(stderr,"FAIL %d: %s\n",__LINE__,#c); return 1; } } while (0)
static void save_json(NSString *dir, NSString *name, NSDictionary *j) {
    [[NSJSONSerialization dataWithJSONObject:j options:0 error:nil] writeToFile:[NSString stringWithFormat:@"%@/%@.json",dir,name] atomically:YES];
}
int main(void) { @autoreleasepool {
    alarm(90); setenv("DM_PRESENT_LINK","0",1);
    char path[] = "/tmp/s2arm-tensor-native-XXXXXX"; REQUIRE(mkdtemp(path)); NSString *dir = @(path);
    setenv("DM_MSL_FALLBACK",path,1); setenv("DM_MSL_DIR","/nonexistent/tensor-test",1);
    mtl_init(); (void)lp_pack_get();
    NSMutableDictionary *j = [@{@"route":@"B",@"chain":@DMSH_CHAIN,@"xfp":@"tensor_test",@"stage":@"cs",@"entry":@"main0",@"threadgroup_size":@[@32,@1,@1],
        @"bindings":@[@{@"kind":@"sbuf",@"reg":@0,@"index":@0,@"rw":@YES,@"arg_id":@0}],@"tensor_mma_abi":@1,@"tensor_mma_count":@1} mutableCopy];
    // Old or mixed containers must never opt one missing translated layer into a native network.
    REQUIRE(!tensor_native_json(j));
    save_json(dir,@"old_b",j); t_refl_only=1;
    NvShader *old = shader_build(@"old_b",5,0,0); REQUIRE(old && old->tensor==1 && !old->fn);
    // Unit fixture for the capability word read from a successfully opened container; no provider is replaced.
    static uint8_t header[48]; uint32_t flags=1; memcpy(header+20,&flags,4); g_libpack.idx=header; g_libpack_ok=1;
    BOOL disabled = getenv("DM_NVN_TENSOR_NATIVE") && !strcmp(getenv("DM_NVN_TENSOR_NATIVE"),"0");
    REQUIRE(tensor_native_json(j)==!disabled);
    j[@"tensor_mma_abi"]=@2; REQUIRE(!tensor_native_json(j));
    j[@"tensor_mma_abi"]=@1; j[@"tensor_mma_count"]=@0; REQUIRE(!tensor_native_json(j)); j[@"tensor_mma_count"]=@1;
    NSString *src=@"#include <metal_stdlib>\nusing namespace metal;\nstruct Args { device uint* out [[id(0)]]; };\nkernel void main0(constant Args& a [[buffer(0)]], uint x [[thread_position_in_grid]]) { a.out[x]=0x12340000u+x; }\n";
    REQUIRE([src writeToFile:[dir stringByAppendingPathComponent:@"native_b.metal"] atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    save_json(dir,@"native_b",j); NvShader *cs=shader_build(@"native_b",5,0,0); t_refl_only=0;
    REQUIRE(cs && cs->tensor==(disabled?1:3));
    if (!disabled) {
        REQUIRE(cs->fn);
        uint8_t *mem=NULL; REQUIRE(!posix_memalign((void **)&mem,65536,65536)); memset(mem,0,65536);
        nvn_be_pool_add(mem,65536);
        prog_t p={0}; p.magic=MAGIC('P','R','O','G'); p.serial=nvn_new_serial();
        NvProg *np=[NvProg new]; np->sh[5]=cs; serial_put(p.serial,np);
        S.cprog=&p; S.ssbo[5][0]=(p_bind_buf){.addr=(uint64_t)(uintptr_t)mem,.size=128};
        uint64_t skipped=g_tensor_skip, up=g_tensor_up, native=g_tensor_native_runs;
        nvn_be_sub_begin(); dispatch(&(p_dispatch){.x=1,.y=1,.z=1});
        uint64_t f=nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f,10000000000ull)); REQUIRE(!mtl_last_commit_error());
        void *buf=NULL; uint64_t off=0; REQUIRE(nvn_be_addr((uint64_t)(uintptr_t)mem,128,&buf,&off));
        const uint32_t *got=(const uint32_t *)((const uint8_t *)((__bridge id<MTLBuffer>)buf).contents+off);
        for (unsigned x=0;x<32;x++) REQUIRE(got[x]==0x12340000u+x);
        REQUIRE(g_tensor_skip==skipped && g_tensor_up==up);
        REQUIRE(g_tensor_native_runs==native+1);
    }
    g_libpack.idx=NULL; g_libpack_ok=0; nvn_be_drain();
    [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
    printf("tensor native dispatch: %u checks, 0 failures; Metal%d, encoder=%s, disabled=%d\n",checks,g_m3?3:4,getenv("DM_NVN_ENC_THREAD")?:"default",disabled);
    return 0;
} }
