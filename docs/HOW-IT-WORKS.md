# How it works — the complete engineering write-up

This documents everything learned while getting Omarchy ARM64 to boot natively
in Parallels Desktop on Apple Silicon, including every dead end.

## 1. Why the official ISO can never work

Facts established empirically (2026-09, Parallels Desktop 27.0.2, macOS 26.6,
M-series host):

- Parallels on Apple Silicon runs its VM in `arm64` mode with its own arm64
  firmware: `parallels.log` shows `VM app mode: arm64` and
  `Loaded ".../Resources/efia64.bin"` (an AArch64 EFI implementation).
- Attaching the official `omarchy-4.0.4.iso` and cold-booting:
  `[DVDROM] Connecting device ".../omarchy-4.0.4.iso"` then `IsBootable=0` —
  the arm64 EFI found nothing bootable.
- The ISO itself: MBR contains `isolinux.bin missing or corrupt.` (SYSLINUX
  hybrid, BIOS boot), ESP carries only `BOOTX64.EFI`; a full-image scan finds
  **zero** ARM64 boot artifacts (`BOOTAA64`/`GRUBARM64`/`SHIMAA64`: 0 hits).
- Parallels 27 ships `libMonitorX86Emu.dylib` and Rosetta-Linux plumbing, but
  it is gated on supported host **and** guest OS combos and was never engaged
  for this VM. Consider it unavailable.

Conclusion: x86_64 ISO on arm64-only Parallels is a permanent dead end. The
solution must be an ARM64 guest.

## 2. The ARM64 Omarchy that already exists

[try-omarchy](https://github.com/omacom/try-omarchy) ("Run Omarchy on MacOS
without any setup", MIT) ships `TryOmarchy.dmg`: a Swift launcher + a patched
QEMU 11 (HVF + GICv3) + a **project-built ARM64 Arch Linux image configured
with Omarchy Quattro**. Inside `Try Omarchy.app/Contents/Resources/guest/`:

| file | bytes | sha256 (truncated) |
|---|---|---|
| `rootfs.ext4.zst` | 1,379,286,984 | `43cebce0…` |
| `vmlinuz-linux` | 50,747,904 | `6c439977…` |
| `initramfs-linux.img` | 102,082,560 | `3369d1cb…` |
| `rootfs.ext4` (decompressed) | 6,442,450,944 (exactly 6 GiB) | `96349482…` |

`guest-manifest.json` declares the kernel command line used by their QEMU:
`root=/dev/vda rw rootwait console=tty0 console=hvc0 …` — i.e. **direct kernel
boot, no bootloader inside the image**. The rootfs is a bare ext4 filesystem
(label `omarchy-factory`), not a partitioned disk.

### The decisive finding: `modules.builtin`

A 943-entry initramfs is *minimal* — and it contains no `ahci.ko`, no
`sd_mod.ko`, no `ext4.ko`. Under QEMU that's fine (their `virt` machine +
direct boot). Under Parallels' AHCI controller it would be fatal — *unless*
the drivers are compiled into the kernel. They are. From the rootfs's
`/usr/lib/modules/7.2.6-1-aarch64-ARCH/modules.builtin`:

```
kernel/fs/ext4/ext4.ko
kernel/drivers/virtio/virtio.ko, virtio_ring.ko, virtio_pci.ko, virtio_blk.ko
kernel/drivers/scsi/scsi_mod.ko, sd_mod.ko, virtio_scsi.ko
kernel/drivers/ata/libata.ko, ahci.ko, libahci.ko
kernel/drivers/nvme/host/nvme-core.ko, nvme.ko, nvme-apple.ko
```

Storage is fully built-in ⇒ Parallels' AHCI/SATA disk needs **zero initramfs
changes**. (Also present: `virtio_net.ko` in the initramfs and VirGL/venv
plumbing — matching Parallels' own virtio-net + VirGL device model.)

## 3. Repacking: from bare ext4 to a bootable GPT disk

### Boot chain we construct

```
Parallels arm64 EFI (efia64.bin)
  └─ scans GPT → ESP (FAT32) → /EFI/BOOT/BOOTAA64.EFI (systemd-boot)
       └─ loader/entries/arch.conf
            ├─ linux  /Image              (vmlinuz-linux, EFI-stub capable)
            ├─ initrd /initramfs-linux.img
            └─ options root=UUID=<ext4-uuid> rw rootwait console=tty0 …
                 └─ kernel mounts p2 (ext4, same UUID) → systemd → Omarchy
```

Why systemd-boot and not a UKI: the Arch ARM kernel is EFI-stub capable, but a
UKI needs a stub binary + rebuild tooling; `systemd-bootaa64.efi` is already
*inside* the guest rootfs (`/usr/lib/systemd/boot/efi/`) and is extractable
read-only on macOS via `debugfs -R "dump …"` (e2fsprogs) — no ext4 driver
required on the host.

### Partition layout (512-byte LBAs)

| LBA | content |
|---|---|
| 0 | protective MBR (`0xEE` entry) |
| 1 | primary GPT header |
| 2–33 | primary partition entries |
| 2048 … 2048+esp | p1 ESP, type `C12A7328-…` (FAT32, 1 GiB) |
| … root | p2 Linux fs, type `0FC63DAF-…` (ext4, grown to 16 GiB) |
| total−33 … total−1 | backup entries + backup header |

`lib/gptbuild.py` writes the MBR/GPT with correct little-endian GUIDs and
CRC32s, and `verify()` re-checks header/entries CRCs plus on-disk markers
(`53 EF` at `rootfs_start·512 + 1024 + 0x38`, `55 AA` at ESP start + 510).

### Growing the filesystem before first boot

The 6 GiB factory image is ~78% full. To add headroom *without* booting:
truncate a new sparse file to 16 GiB, `dd` the fs in
(`conv=notrunc,sparse`), then `resize2fs <file> 16G` (Homebrew e2fsprogs) —
performed on the bare filesystem before it is embedded. The UUID survives, so
`root=UUID=…` stays valid.

### ESP construction quirks (macOS)

- `newfs_msdos` refuses plain files ("Cannot get partition offset"): attach
  the raw ESP file first (`hdiutil attach -nomount`) and format the
  `/dev/diskN` node, then detach and re-attach to mount and populate.
- Don't hand the guest a FAT built from a truncated/sparse source; create the
  file at final size first (`truncate`), never with `mkfile -n` *after* data
  was written (a stray `mkfile` recreation is exactly how we lost a GPT once).

## 4. The Parallels container: plain `.hds` and its descriptor

Parallels expanding disks (`.hds` with `Type: Compressed`) use a proprietary
block format. Plain disks are raw bytes — that's what we need.

**Critical**: do **not** hand-write `DiskDescriptor.xml`. A faithful-looking
copy of the template was rejected at boot with:

```
The temporary uid is not found
Snapshot loading failed, err = 0xFFFFADF6
OpenDisk() returned error PRL_ERR_DISK_XML_INVALID (0xffffadf6)
BootableCheck: Failed to open disk image
```

The working recipe is to let Parallels generate it:

```bash
prl_disk_tool create --hdd "<pvm>/<name>-0.hdd" --size 17500 --alloc-policy sparse
```

which yields `Type: Plain`, `Blocksize: 2048`, and the canonical base image
GUID `{5fbaabe3-6958-40ff-92a7-860e329aab41}` for both the `Image/GUID`, the
`.hds` filename, and the snapshot entry. Then pour (seek+write) MBR, GPT,
partitions, and the **backup GPT recomputed for the new tail** (`total−33`,
`total−1`) into that `.hds`. Sizing rule: `--size` MiB must exceed the layout
end; the script adds 128 MiB slack.

Verification after pouring: `hdiutil attach -nomount -imagekey
diskimage-class=CRawDiskImage` should show `GUID_partition_scheme`,
`EFI`, and `Linux Filesystem` slices.

## 5. The VM bundle and registration

A minimal `.pvm` needs: `config.pvs` (+`.backup`), `VmInfo.pvi`, `NVRAM.dat`,
and optionally the `VM.app` stub. `templates/config.pvs.tmpl` is the working
generic-Linux arm64 config (OsType 9 / OsNumber 2559, SATA HDD `InterfaceType
2`, EFI `EfiEnabled 5`, HDD-first boot order) with placeholders.

Gotchas we hit:

- **Ghost identity**: an earlier failed `open` left "OmarchyARM" known to the
  dispatcher — `prlctl register` then fails with *"name already taken"* while
  `prlctl unregister` says *"VM could not be found"*. Fix: regenerate
  `VmUuid`/`SourceVmUuid` (the name collision message is actually about the
  cached identity) and register again. `build.sh` retries this automatically.
- **Do not redistribute Parallels files**: `VM.app` (and everything else in
  `/Applications/Parallels Desktop.app`) is proprietary. `build.sh` copies the
  stub from an existing local VM when present, otherwise synthesizes a minimal
  bundle shell.
- **Standard edition CLI limits**: `prlctl start/stop/status/capture/
  snapshot-list/create` are Pro/Business-gated. Registration, listing, and
  config edits are free; launching works via `open <file>.pvm`.

## 6. Boot evidence and runtime behavior

From `parallels.log` of the successful boot:

```
IsBootable=1
[hdd::sata:0] Connecting device ".../OmarchyARM-0.hdd"
[AHCI] Enable Command Queue Acceleration / [SATA0] controller reset
hdd: [RH] total 250 MB, 3962 reqs            ← kernel + initramfs read from ESP
[VIRTIO] Guest OK'd device 1AB8/5            ← guest driver bound
[NET0][VIRTIO] AckFeatures (…)               ← virtio-net negotiated
OpenGL.VirGL: 'modprobe' result:0            ← VirGL 3D path active
[DYNRES] Display [0]: W=1024; H=768 DPI=128  ← display negotiation
```

Useful debug signals:

- `prl_vm_app` CPU% ≈ guest activity (booting systemd: ~25%).
- `[DYNRES]` resolution change ⇒ the compositor is driving the display.
- Guest IP appears in `/Library/Preferences/Parallels/parallels_dhcp_leases`
  (Parallels shared network, `10.211.55.0/24`).
- The boot entry includes `tryomarchy.ssh_access=1` — the guest's documented
  switch to start `sshd.service` at boot (same token their launcher uses).

## 7. Limitations & future work

- Parallels' guest tools are not installed inside Omarchy (no Parallels Tools
  for this guest) → clipboard/resolution niceties come from the guest's own
  try-omarchy integrations, not Parallels Tools. Dynamic resolution via
  `[DYNRES]` works through Parallels' virtio display path.
- Sound, USB passthrough and 3D acceleration depend on Parallels' device model
  + guest drivers; expect a working desktop, and file issues with
  `parallels.log` excerpts if a device is missing.
- Nested virtualization inside the guest (their M3+/macOS 26 feature) is a
  QEMU/HVF property, not available through Parallels.
