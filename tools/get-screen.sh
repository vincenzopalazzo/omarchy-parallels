#!/usr/bin/env bash
# get-screen.sh — capture the Omarchy ARM VM's screen over SSH without any
# macOS screen-recording permission. Reads the guest framebuffer via SSH and
# converts BGRA → PNG locally.
#
# usage: ./tools/get-screen.sh [output.png] [key] [user@ip]
set -euo pipefail
OUT="${1:-/tmp/vm-screen.png}"
KEY="${2:-$HOME/.ssh/id_ed25519}"
DEST="${3:-root@10.211.55.5}"

INFO=$(ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  "$DEST" 'cat /sys/class/graphics/fb0/virtual_size; cat /sys/class/graphics/fb0/bits_per_pixel; dd if=/dev/fb0 bs=1M 2>/dev/null' 2>/dev/null) || {
  # fall back: two-step (size lines + raw stream)
  ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$DEST" \
    'dd if=/dev/fb0 bs=1M 2>/dev/null' > /tmp/fb.raw 2>/dev/null
  W=$(ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$DEST" 'cat /sys/class/graphics/fb0/virtual_size' 2>/dev/null | cut -d, -f1)
  H=$(ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$DEST" 'cat /sys/class/graphics/fb0/virtual_size' 2>/dev/null | cut -d, -f2)
  python3 - "$W" "$H" /tmp/fb.raw "$OUT" <<'PY'
import struct, sys, zlib
W, H, src, out = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3], sys.argv[4]
data = open(src, 'rb').read()
rows = bytearray()
for y in range(H):
    rows += b'\x00'
    base = y * W * 4
    for x in range(W):
        i = base + x * 4
        rows += bytes((data[i+2], data[i+1], data[i]))
def chunk(t, d):
    return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', W, H, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(bytes(rows), 6)) + chunk(b'IEND', b'')
open(out, 'wb').write(png)
print(out)
PY
  exit 0
}

# single-shot path: parse size + payload from combined stream
SIZE_LINE=$(printf '%s' "$INFO" | head -1)
BPP_LINE=$(printf '%s' "$INFO" | sed -n 2p)
W=${SIZE_LINE%,*}; H=${SIZE_LINE#*,}
printf '%s' "$INFO" | tail -c +$(( ${#SIZE_LINE} + ${#BPP_LINE} + 3 )) > /tmp/fb.raw
python3 - "$W" "$H" /tmp/fb.raw "$OUT" <<'PY'
import struct, sys, zlib
W, H, src, out = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3], sys.argv[4]
data = open(src, 'rb').read()
rows = bytearray()
for y in range(H):
    rows += b'\x00'
    base = y * W * 4
    for x in range(W):
        i = base + x * 4
        rows += bytes((data[i+2], data[i+1], data[i]))
def chunk(t, d):
    return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', W, H, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(bytes(rows), 6)) + chunk(b'IEND', b'')
open(out, 'wb').write(png)
print(out)
PY
