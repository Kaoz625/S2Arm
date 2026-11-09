#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁覆盖：graphics/tools/direct/dsh/Tensor.cs graphics/tools/direct/dsh/Dsh.cs graphics/tools/direct/tests/t_tensor.py graphics/tools/direct/tests/tensor_run.m
set -eu
cd "$(dirname "$0")/.."
python3 graphics/tools/direct/tests/t_tensor.py
