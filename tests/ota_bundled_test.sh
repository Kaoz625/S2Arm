#!/bin/bash
# 门禁覆盖：ios/ota_place.m
# 随包资源包（单款游戏 App，包里 Games/<游戏号>/ota/）落点单测（合成小资源包，不连手机、不读游戏文件）：bash tests/ota_bundled_test.sh
set -u; cd "$(dirname "$0")/.." || exit 1
python3 -B tests/ota_bundled_test.py 2>&1 | tail -3; rc=${PIPESTATUS[0]}
[ "$rc" = 0 ] && echo "ota_bundled 单测全过" || { echo "ota_bundled 单测有不通"; exit 1; }
