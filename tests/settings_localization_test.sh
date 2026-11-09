#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁覆盖：ios/Settings.bundle/* ios/l10n/* ios/settings.m tests/settings_localization/* tests/settings_localization_test.sh
# Real Foundation lookups only; does not launch UIKit, native graphics or GPU.
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/settings-localization.XXXXXX")
trap 'rm -rf "$T"' EXIT
xcrun --sdk macosx clang -fobjc-arc -framework Foundation \
  "$H/tests/settings_localization/lookup.m" -o "$T/lookup"
"$T/lookup" "${1:-$H/ios/Settings.bundle}" "${2:-$H/ios/l10n}"
