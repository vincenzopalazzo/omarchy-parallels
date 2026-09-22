#!/usr/bin/env python3
"""Minimal GPT (GUID Partition Table) writer for omarchy-parallels.

Builds a protective MBR + primary/backup GPT for a two-partition layout:
  p1: EFI System Partition (C12A7328-F81F-11D2-BA4B-00A0C93EC93B)
  p2: Linux filesystem (0FC63DAF-8483-4772-8E79-3D69D8477DE4)

All offsets are 512-byte LBAs, matching Parallels plain disks.
"""
import struct
import uuid
import zlib

SECT = 512
ESP_GUID = "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
LINUX_GUID = "0FC63DAF-8483-4772-8E79-3D69D8477DE4"


def _crc(data: bytes) -> int:
    return zlib.crc32(data) & 0xFFFFFFFF


def _entry(type_guid: str, start: int, count: int, name: str) -> bytes:
    e = bytearray(128)
    e[0:16] = uuid.UUID(type_guid).bytes_le
    e[16:32] = uuid.uuid4().bytes_le
    struct.pack_into("<QQ", e, 32, start, start + count - 1)
    e[56:56 + len(name) * 2] = name.encode("utf-16-le")
    return bytes(e)


def build_layout(esp_start: int, esp_sectors: int, root_start: int,
                 root_sectors: int, total_lbas: int,
                 esp_label: str = "ESP", root_label: str = "rootfs"):
    """Return (mbr, gpt_header, entries, backup_header, backup_entries)."""
    if root_start + root_sectors > total_lbas - 33:
        raise ValueError("layout does not fit in total_lbas")

    # protective MBR
    mbr = bytearray(SECT)
    mbr[446:462] = bytes([
        0x00, 0x00, 0x02, 0x00, 0xEE, 0xFF, 0xFF, 0xFF,
    ]) + struct.pack("<II", 1, min(total_lbas - 1, 0xFFFFFFFF))
    mbr[510:512] = b"\x55\xAA"

    def header(cur, bak, entries_lba):
        h = bytearray(92)
        h[0:8] = b"EFI PART"
        struct.pack_into("<I", h, 8, 0x00010000)
        struct.pack_into("<I", h, 12, 92)
        struct.pack_into("<I", h, 16, 0)
        struct.pack_into("<Q", h, 24, cur)
        struct.pack_into("<Q", h, 32, bak)
        struct.pack_into("<Q", h, 40, 2)
        struct.pack_into("<Q", h, 48, total_lbas - 33)
        h[56:72] = uuid.uuid4().bytes
        struct.pack_into("<Q", h, 72, entries_lba)
        struct.pack_into("<I", h, 80, 128)
        struct.pack_into("<I", h, 84, 128)
        return h

    entries = bytearray(128 * 128)
    entries[0:128] = _entry(ESP_GUID, esp_start, esp_sectors, esp_label)
    entries[128:256] = _entry(LINUX_GUID, root_start, root_sectors, root_label)
    e_crc = _crc(bytes(entries))

    h = header(1, total_lbas - 1, 2)
    struct.pack_into("<I", h, 88, e_crc)
    struct.pack_into("<I", h, 16, _crc(bytes(h)))

    bh = header(total_lbas - 1, 1, total_lbas - 33)
    struct.pack_into("<I", bh, 88, e_crc)
    struct.pack_into("<I", bh, 16, _crc(bytes(bh)))

    return bytes(mbr), bytes(h), bytes(entries), bytes(bh), bytes(entries)


def verify(path: str, esp_start: int, root_start: int) -> bool:
    """Sanity-check a poured disk: GPT CRCs + ext4 magic at the right spots."""
    with open(path, "rb") as f:
        f.seek(512)
        h = f.read(512)
        if h[:8] != b"EFI PART":
            return False
        h2 = bytearray(h[:92])
        struct.pack_into("<I", h2, 16, 0)
        if _crc(bytes(h2)) != struct.unpack("<I", h[16:20])[0]:
            return False
        pe_lba = struct.unpack("<Q", h[72:80])[0]
        cnt = struct.unpack("<I", h[80:84])[0]
        sz = struct.unpack("<I", h[84:88])[0]
        f.seek(pe_lba * SECT)
        tab = f.read(cnt * sz)
        if _crc(tab) != struct.unpack("<I", h[88:92])[0]:
            return False
        f.seek(root_start * SECT + 1024 + 0x38)
        if f.read(2) != b"\x53\xEF":
            return False
        f.seek(esp_start * SECT + 510)
        if f.read(2) != b"\x55\xAA":
            return False
    return True


if __name__ == "__main__":
    print("module - see build.sh")
