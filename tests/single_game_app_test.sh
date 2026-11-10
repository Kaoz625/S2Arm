#!/bin/bash
# 门禁覆盖：tools/single_game_app.py pack/xcode_keys.py
# 单款游戏 App 出包单测（合成小件，不读游戏文件、不调 Xcode）：bash tests/single_game_app_test.sh
set -u; cd "$(dirname "$0")/.." || exit 1
"${S2A_PY:-python3}" -B tests/single_game_app_test.py 2>&1 | tail -3; rc=${PIPESTATUS[0]}
[ "$rc" = 0 ] && echo "single_game_app 单测全过" || { echo "single_game_app 单测有不通"; exit 1; }
