#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/versioning.sh"
[[ "$(next_marketing_version 1.9.01 patch)" == 1.9.02 ]]
[[ "$(next_marketing_version 1.9.09 patch)" == 1.9.10 ]]
[[ "$(next_marketing_version 1.9.99 patch)" == 1.9.100 ]]
[[ "$(next_marketing_version 1.9.01 minor)" == 1.10.00 ]]
[[ "$(next_marketing_version 1.9.01 major)" == 2.0.00 ]]
[[ "$(next_marketing_version 1.8 patch)" == 1.8.01 ]]
if next_marketing_version invalid patch 2>/dev/null; then exit 1; fi
if next_marketing_version 1.9.01 invalid 2>/dev/null; then exit 1; fi
echo 'PASS: version increments and invalid input'
