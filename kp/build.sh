#!/usr/bin/env bash
# kp/build.sh — 区域构建入口；实际逻辑在 tools/build-core.sh
set -euo pipefail
exec bash "$(cd "$(dirname "$0")/.." && pwd)/tools/build-core.sh" "kp" "$@"
