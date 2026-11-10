#!/bin/bash
# 门禁覆盖：tools/ota_pack.py
# OTA 资源包导出单测（合成小资源包，不连手机、不读游戏文件）：bash tests/ota_pack_test.sh
set -u; cd "$(dirname "$0")/.." || exit 1
python3 -B tests/ota_pack_test.py 2>&1 | tail -3; rc=${PIPESTATUS[0]}
[ "$rc" = 0 ] && echo "ota_pack 单测全过" || { echo "ota_pack 单测有不通"; exit 1; }
