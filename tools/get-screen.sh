#!/usr/bin/env bash
# Backward-compatible wrapper — canonical script lives at
# skills/omarchy-parallels/scripts/get-screen.sh (Agent Plugins layout).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$HERE/../skills/omarchy-parallels/scripts/get-screen.sh" "$@"
