# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# native-test-nvn_tensor_native：本单测的构建规则
NATIVE_TEST_OWN += nvn_tensor_native
ifeq ($(shell uname -s),Darwin)
# Native tensor ABI selection and real compute dispatch: Metal 4 encoder off/on, Metal 3, opt-out.
$(BUILD)/tests/t_nvn_tensor_native: graphics/nvn/tests/t_nvn_tensor_native.m $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_tensor_native.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_tensor_native
native-test-nvn_tensor_native: $(BUILD)/tests/t_nvn_tensor_native
	NXGAL_BE=mtl4 DM_NVN_ENC_THREAD=0 $(BUILD)/tests/t_nvn_tensor_native
	NXGAL_BE=mtl4 DM_NVN_ENC_THREAD=1 $(BUILD)/tests/t_nvn_tensor_native
	NXGAL_BE=mtl3 DM_NVN_ENC_THREAD=0 $(BUILD)/tests/t_nvn_tensor_native
	DM_NVN_TENSOR_NATIVE=0 $(BUILD)/tests/t_nvn_tensor_native
TEST_TARGETS += native-test-nvn_tensor_native
endif
