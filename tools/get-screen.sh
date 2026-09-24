#!/usr/bin/env bash
# get-screen.sh — capture the Omarchy ARM VM's screen over SSH without any
# macOS screen-recording permission. Two-step, reliable:
#   1) read framebuffer geometry + raw BGRA via ssh
#   2) convert BGRA → PNG locally (python3, stdlib only)
#
# NOTE: /dev/fb0 shows the *text console*. Once Hyprland owns DRM, use grim
# inside the session instead (see AGENTS.md SOP-03).
#
# usage: ./tools/get-screen.sh [output.png] [ssh-key] [user@ip]
set -euo pipefail
OUT="${1:-/tmp/vm-screen.png}"
KEY="${2:-$HOME/.ssh/id_ed25519}"
DEST="${3:-root@10.211.55.5}"
SSH="ssh -i $KEY -o ConnectTimeout=8 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

SIZE=$($SSH "$DEST" 'cat /sys/class/graphics/fb0/virtual_size' 2>/dev/null)
W=${SIZE%,*}; H=${SIZE#*,}
[[ "$W" =~ ^[0-9]+$ && "$H" =~ ^[0-9]+$ ]] || { echo "ERROR: cannot read framebuffer size (guest up? ssh key ok?)" >&2; exit 1; }

TMP=$(mktemp /tmp/fb.XXXXXX.raw)
trap 'rm -f "$TMP"' EXIT
$SSH "$DEST" "dd if=/dev/fb0 bs=1M 2>/dev/null" > "$TMP"

python3 - "$W" "$H" "$TMP" "$OUT" <<'PY'
import struct, sys, zlib
W, H, src, out = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3], sys.argv[4]
data = open(src, 'rb').read()
need = W * H * 4
if len(data) < need:
    print(f"ERROR: framebuffer short read ({len(data)} < {need})", file=sys.stderr)
    sys.exit(1)
rows = bytearray()
for y in range(H):
    rows += b'\x00'
    base = y * W * 4
    for x in range(W):
        i = base + x * 4
        rows += bytes((data[i + 2], data[i + 1], data[i]))  # BGRA → RGB
def chunk(t, d):
    return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
png = (b'\x89PNG\r\n\x1a\n'
       + chunk(b'IHDR', struct.pack('>IIBBBBB', W, H, 8, 2, 0, 0, 0))
       + chunk(b'IDAT', zlib.compress(bytes(rows), 6))
       + chunk(b'IEND', b''))
open(out, 'wb').write(png)
print(out)
PY
