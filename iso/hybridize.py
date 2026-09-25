#!/usr/bin/env python3
"""hybridize.py — add a GPT (with ESP) to an El Torito EFI ISO, in place.

Points the ESP partition at the FAT image already inside the ISO
(/EFI/BOOT/EFIBOOT.IMG), so the same file boots via El Torito *and* via GPT
— the layout Debian/Ubuntu ARM ISOs use. Pure stdlib, no xorriso needed.

Why: some EFI implementations (Parallels) reject El Torito entries whose
sector-count field is 0 (which xorriso 1.5.8 writes for -no-emul-boot and
refuses to override), but happily boot a GPT ESP on the same disc.

usage: hybridize.py <iso-path> [fat-iso-path=EFI/BOOT/EFIBOOT.IMG]
"""
import struct
import sys
import uuid
import zlib

SECT = 512


def crc(data: bytes) -> int:
    return zlib.crc32(data) & 0xFFFFFFFF


def read_dir(f, lba, size):
    f.seek(lba * 2048)
    blob = f.read(size)
    out = []
    off = 0
    while off < len(blob):
        L = blob[off]
        if L == 0:
            break
        nl = blob[off + 32]
        name = blob[off + 33:off + 33 + nl].decode("utf8", "replace")
        flags = blob[off + 25]
        flba = struct.unpack("<I", blob[off + 2:off + 6])[0]
        fsize = struct.unpack("<I", blob[off + 10:off + 14])[0]
        out.append((name, flags, flba, fsize))
        off += L
    return out


def find_file(f, iso_path):
    parts = iso_path.strip("/").split("/")
    f.seek(16 * 2048)
    vd = f.read(2048)
    root = vd[156:190]  # ECMA-119: root dir record at offset 156
    lba = struct.unpack("<I", root[2:6])[0]
    size = struct.unpack("<I", root[10:14])[0]
    for part in parts:
        want = part.upper() + ";1"
        entries = read_dir(f, lba, size)
        hit = [(n, fl, flba, fs) for n, fl, flba, fs in entries
               if n.upper() == want or n.split(";")[0].upper() == part.upper()]
        if not hit:
            raise SystemExit(f"not found in ISO: {part} (of {iso_path})")
        _, flags, lba, size = hit[0]
        if not (flags & 2) and part != parts[-1]:
            raise SystemExit(f"{part} is not a directory")
    return lba, size


def main():
    iso = sys.argv[1]
    fat_path = sys.argv[2] if len(sys.argv) > 2 else "EFI/BOOT/EFIBOOT.IMG"
    f = open(iso, "r+b")
    f.seek(0, 2)
    total_2048 = f.tell() // 2048

    fat_lba_2048, fat_size = find_file(f, fat_path)
    # FAT image starts at a 2048-aligned offset, which is 512-aligned too
    esp_start_512 = fat_lba_2048 * 4
    esp_sectors_512 = (fat_size + 511) // 512
    # pad the file so the backup GPT lands in fresh zeros, never in ISO data
    pad_sectors = 64
    total_512 = total_2048 * 4 + pad_sectors
    f.seek(total_2048 * 4 * SECT)
    f.write(b"\x00" * pad_sectors * SECT)
    f.flush()
    print(f"FAT at ISO9660 LBA {fat_lba_2048} ({fat_size} bytes)")
    print(f"ESP: start={esp_start_512} sectors={esp_sectors_512} (512B)")

    # protective MBR at LBA 0 (ISO9660 system area allows this: hybrids do it)
    mbr = bytearray(SECT)
    mbr[446:462] = (bytes([0x00, 0x00, 0x02, 0x00, 0xEE, 0xFF, 0xFF, 0xFF])
                    + struct.pack("<II", 1, min(total_512 - 1, 0xFFFFFFFF)))
    mbr[510:512] = b"\x55\xAA"

    ESP = "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"

    def header(cur, bak, entries_lba):
        h = bytearray(92)
        h[0:8] = b"EFI PART"
        struct.pack_into("<I", h, 8, 0x00010000)
        struct.pack_into("<I", h, 12, 92)
        struct.pack_into("<Q", h, 24, cur)
        struct.pack_into("<Q", h, 32, bak)
        struct.pack_into("<Q", h, 40, 2)
        struct.pack_into("<Q", h, 48, total_512 - 34)
        h[56:72] = uuid.uuid4().bytes
        struct.pack_into("<Q", h, 72, entries_lba)
        struct.pack_into("<I", h, 80, 128)
        struct.pack_into("<I", h, 84, 128)
        return h

    ent = bytearray(128 * 128)
    e = bytearray(128)
    e[0:16] = uuid.UUID(ESP).bytes_le
    e[16:32] = uuid.uuid4().bytes_le
    struct.pack_into("<QQ", e, 32, esp_start_512, esp_start_512 + esp_sectors_512 - 1)
    e[56:56 + 6] = "ESP".encode("utf-16-le")
    ent[0:128] = e
    e_crc = crc(bytes(ent))

    h = header(1, total_512 - 1, 2)
    struct.pack_into("<I", h, 88, e_crc)
    struct.pack_into("<I", h, 16, crc(bytes(h)))
    bh = header(total_512 - 1, 1, total_512 - 33)
    struct.pack_into("<I", bh, 88, e_crc)
    struct.pack_into("<I", bh, 16, crc(bytes(bh)))

    f.seek(0)
    f.write(mbr)
    f.seek(SECT)
    f.write(h)
    f.seek(2 * SECT)
    f.write(ent)
    f.seek((total_512 - 33) * SECT)
    f.write(ent)
    f.seek((total_512 - 1) * SECT)
    f.write(bh)
    f.close()
    print(f"hybrid GPT written: ESP partition -> internal FAT "
          f"({esp_sectors_512 * 512 // 1048576} MiB)")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        raise SystemExit(2)
    main()
