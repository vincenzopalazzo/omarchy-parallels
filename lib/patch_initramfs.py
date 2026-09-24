#!/usr/bin/env python3
"""patch_initramfs.py — splice a patched /init into an (uncompressed cpio)
mkinitcpio initramfs.

The patched init gains two omarchy-parallels blocks:
  1. early: bring up eth0 and stream /proc/kmsg over TCP to the host
            (kernel log visible from the Mac even without a working UART)
  2. late:  write an SSH public key into /sysroot/root/.ssh/authorized_keys
            just before switch_root (journal-safe key injection)

Entry names are preserved byte-for-byte: the kernel looks up exactly "init";
a "./init" entry is silently ignored (learned the hard way).

usage: patch_initramfs.py <in.img> <out.img> <host-ip> <port> <ssh-pubkey-file>
"""
import struct
import sys

KMSG_BLOCK = """
# omarchy-parallels debug: stream kmsg to host over TCP
(
  ip link set lo up 2>/dev/null
  ip link set eth0 up 2>/dev/null
  ip addr add {ip}/24 dev eth0 2>/dev/null
  ip route add default via 10.211.55.2 2>/dev/null
  sleep 1
  echo '=== omarchy-parallels kmsg stream start ==='
  nc {host} {port} < /proc/kmsg
) &
"""

KEY_BLOCK = """
# omarchy-parallels: inject ssh key into the real root
(
  mkdir -p /sysroot/root/.ssh 2>/dev/null
  echo '{pubkey}' > /sysroot/root/.ssh/authorized_keys
  chmod 700 /sysroot/root/.ssh
  chmod 600 /sysroot/root/.ssh/authorized_keys
) 2>/dev/null || true

"""


def parse(orig: bytes, start: int):
    entries = []
    off = start
    while off + 110 <= len(orig):
        if orig[off:off + 6] != b'070701':
            off += 1
            continue
        namesize = int(orig[off + 94:off + 102], 16)
        filesize = int(orig[off + 54:off + 62], 16)
        mode = int(orig[off + 14:off + 22], 16)
        uid = int(orig[off + 22:off + 30], 16)
        gid = int(orig[off + 30:off + 38], 16)
        mtime = int(orig[off + 46:off + 54], 16)
        nlink = int(orig[off + 38:off + 46], 16)
        name = orig[off + 110:off + 110 + namesize - 1]
        hdrlen = (110 + namesize + 3) & ~3
        if name == b'TRAILER!!!':
            break
        entries.append((name, mode, uid, gid, mtime, nlink,
                        orig[off + hdrlen:off + hdrlen + filesize]))
        off += hdrlen + ((filesize + 3) & ~3)
    return entries


def newc(ino, name, mode, uid, gid, nlink, mtime, fdata):
    f8 = lambda v: b'%08X' % v
    out = bytearray(b'070701' + f8(ino) + f8(mode) + f8(uid) + f8(gid) +
                    f8(nlink) + f8(mtime) + f8(len(fdata)) + f8(0) + f8(0) +
                    f8(0) + f8(0) + f8(len(name) + 1) + f8(0))
    assert len(out) == 110
    out += name + b'\x00'
    while len(out) % 4:
        out += b'\x00'
    out += fdata
    while len(out) % 4:
        out += b'\x00'
    return bytes(out)


def main():
    src, dst, host, port, pubkey_path = sys.argv[1:6]
    orig = open(src, 'rb').read()
    pubkey = open(pubkey_path).read().strip()
    EARLY = 10240  # mkinitcpio: segment 1 is a 10 KiB early cpio

    entries = parse(orig, EARLY)
    assert any(n == b'init' for n, *_ in entries), "no 'init' entry found"

    blob = bytearray()
    ino = 300000
    for name, mode, uid, gid, mtime, nlink, fdata in entries:
        if name == b'init':
            s = fdata.decode()
            anchor = "parse_cmdline </proc/cmdline\n"
            assert anchor in s, "init anchor missing"
            s = s.replace(anchor, anchor + KMSG_BLOCK.format(ip="10.211.55.9",
                        host=host, port=port), 1)
            anchor2 = "exec env -i \\"
            assert anchor2 in s, "switch_root anchor missing"
            s = s.replace(anchor2, KEY_BLOCK.format(pubkey=pubkey) + anchor2, 1)
            fdata = s.encode()
        ino += 1
        blob += newc(ino, name, mode, uid, gid, max(nlink, 1), mtime, fdata)
    blob += newc(ino + 1, b'TRAILER!!!', 0, 0, 0, 1, 0, b'')
    while len(blob) % 512:
        blob += b'\x00'

    open(dst, 'wb').write(orig[:EARLY] + bytes(blob))
    print(f"patched initramfs written: {dst} ({len(orig[:EARLY]) + len(blob)} bytes)")


if __name__ == '__main__':
    main()
