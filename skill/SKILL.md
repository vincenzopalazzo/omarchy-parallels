---
name: omarchy-parallels
description: Builds and boots an ARM64 Omarchy (Quattro) Linux VM natively in Parallels Desktop on Apple Silicon Macs. Use when someone wants Omarchy running in Parallels on an M-series Mac, when the official x86_64 Omarchy ISO fails to boot in Parallels (arm64 EFI + no x86 emulation), or when asked to convert the try-omarchy (QEMU/HVF) guest image into a native Parallels VM.
---

# Omarchy ARM64 in Parallels Desktop (Apple Silicon)

> **Canonical operating manual: [`AGENTS.md`](../AGENTS.md)** in the repo —
> file map, constants, SOPs (01–10), failure-mode table, verification
> checklist. This SKILL.md is the condensed wrapper; AGENTS.md always wins.

## Context you must know before acting

- The official Omarchy ISO (iso.omarchy.org) is **x86_64-only** (isolinux/SYSLINUX,
  BOOTX64.EFI, zero ARM64 loaders). Parallels on Apple Silicon runs **arm64
  guests only** — its arm64 EFI (`efia64.bin`) will report `IsBootable=0` for
  that ISO. No Parallels setting fixes an architecture mismatch.
- The official Mac path is `omacom/try-omarchy` (QEMU/HVF app). Its DMG bundles
  an **ARM64 Omarchy Quattro** rootfs (`rootfs.ext4.zst`), kernel
  (`vmlinuz-linux`), and initramfs — this is what we repackage for Parallels.
- The guest kernel (Arch ARM, `7.2.6-1-aarch64-ARCH`) has **storage built in**:
  ahci, libata, sd_mod, scsi_mod, ext4, virtio_blk, virtio_pci, nvme are all
  `=y` (verify via `modules.builtin` inside the rootfs). That is why the
  repackaged disk boots unmodified under Parallels' AHCI/virtio hardware model.

## Primary action

Run the maintained builder (does everything: download, verify, repartition,
ESP, GPT, plain .hds, VM scaffold, register, launch):

```bash
git clone https://github.com/vincenzopalazzo/omarchy-parallels
cd omarchy-parallels
./build.sh --ssh-key ~/.ssh/id_ed25519.pub     # add --vm-name NAME to choose a name
# 1. press Return in the VM window, create your user (first-boot wizard)
./tools/post-install.sh "Omarchy ARM" ~/.ssh/id_ed25519   # 2. tools + display
```

Requirements: Apple Silicon Mac, Parallels Desktop 19+ (tested 27.0.2 Standard
edition — Pro features are NOT required), Homebrew, ~15 GB free disk, internet.
The script is idempotent-safe: it refuses to overwrite an existing VM name.

## If build.sh cannot be used, the manual procedure

1. Get artifacts: download `TryOmarchy.dmg` from try-omarchy releases, mount,
   take `Contents/Resources/guest/{rootfs.ext4.zst, vmlinuz-linux,
   initramfs-linux.img}`; verify SHA256s against `guest-manifest.json`.
2. `zstd -d` the rootfs; `e2fsck -fy`; to grow it: truncate a new file to the
   target size, `dd` the fs in (`conv=notrunc,sparse`), `resize2fs <file> 16G`
   (e2fsprogs via Homebrew). UUID survives.
3. Extract the bootloader **from inside the rootfs** (macOS has no ext4 mount):
   `debugfs -R "dump /usr/lib/systemd/boot/efi/systemd-bootaa64.efi out.efi" rootfs.ext4`
4. ESP (1 GiB FAT32): `hdiutil attach -nomount` a raw file, `newfs_msdos -F 32
   /dev/diskN` (it refuses plain files — needs the /dev node), populate:
   `EFI/BOOT/BOOTAA64.EFI` + `EFI/systemd/` (the extracted bootloader),
   `/Image` (kernel), `/initramfs-linux.img`, `loader/entries/arch.conf`
   with `options root=UUID=<ext4-uuid> rw rootwait console=tty0
   tryomarchy.ssh_access=1 mitigations=off nowatchdog`.
   (`tryomarchy.ssh_access=1` makes the guest start sshd at boot.)
5. Layout (512-byte LBAs): ESP at 2048; rootfs right after; protective MBR +
   primary GPT at 0..33; backup GPT at `total-33..total-1`. Write it with
   `lib/gptbuild.py` (handles CRC32s and byte order).
6. Create the container with Parallels' own tool:
   `prl_disk_tool create --hdd <dir>/<name>-0.hdd --size <MiB> --alloc-policy sparse`
   (plain, non-expanding). Size must exceed the layout end by ≥128 MiB.
7. **Pour** MBR/GPT/ESP/rootfs into the generated
   `<name>-0.hdd.0.{5fbaabe3-6958-40ff-92a7-860e329aab41}.hds` (seek+write),
   adjusting the backup GPT to the new tail. Verify: GPT CRCs, `53 EF` at
   rootfs_start*512 + 1024 + 0x38, `55 AA` at ESP start + 510.
8. Scaffold `<name>.pvm`: config.pvs from `templates/config.pvs.tmpl`
   (placeholders: __VM_NAME__, __VM_UUID__, __DISK_UUID__, __DISK_NAME__,
   __DISK_SIZE_MB__, __DISK_SIZE_ON_DISK_MB__), VmInfo.pvi, NVRAM.dat (copy
   from any existing VM, else 385024 zero bytes), VM.app stub (copy from an
   existing VM; do not redistribute Parallels' files).
9. `prlctl register <pvm>`; then `open -a "Parallels Desktop" <pvm>`.

## Known failure modes (all verified the hard way)

| Symptom | Cause | Fix |
|---|---|---|
| `PRL_ERR_DISK_XML_INVALID (0xffffadf6)`, "temporary uid not found" | hand-written DiskDescriptor.xml | always generate the descriptor with `prl_disk_tool create` and pour data into its `.hds`; it needs the canonical base GUID `{5fbaabe3-6958-40ff-92a7-860e329aab41}` |
| `IsBootable=0` | ISO is x86_64-only, or GPT invalid | use the ARM64 repack; verify GPT CRCs and that macOS `hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage` shows the EFI + Linux partitions |
| `prlctl register`: "name already taken" but VM "not found" | ghost identity from a previous open attempt | regenerate `VmUuid` + `SourceVmUuid` in config.pvs and register again (build.sh retries 3x) |
| `newfs_msdos: Cannot get partition offset` | passed a plain/sparse file | attach the raw file first and format the `/dev/diskN` node |
| disk appears as raw zeros after assembly | recreated/truncated the file with `mkfile` after writing | assemble atomically: truncate once, then seek+write; verify GPT before pouring data |
| boot hangs at `VMS_STARTING` with no guest CPU | initramfs lacks storage drivers | this kernel has them built in; for other kernels inject modules or pick one with `ahci`/`ext4` `=y` |

## Debugging a booted VM

- VM log: `~/Parallels/<name>.pvm/parallels.log` (grep `IsBootable`, `DVDROM`,
  `AHCI`, `VIRTIO`, `DYNRES`); state: `statistic.log` (`VMS_STARTING` →
  `VMS_RUNNING`), `prl_vm_app` CPU% ≈ guest activity.
- Guest IP: `grep -o '10\.211\.55\.[0-9]*' /Library/Preferences/Parallels/parallels_dhcp_leases`
- SSH: enabled by `tryomarchy.ssh_access=1` on the kernel cmdline (already in
  build.sh's entry). To change cmdline later: dd the ESP slice out of the
  `.hds`, edit `loader/entries/arch.conf`, dd back, reboot.
- A resolution change in `[DYNRES]` log lines = desktop compositor is up.
- Parallels Standard edition: `prlctl start/stop/status/capture/snapshot-list/
  create` are Pro-gated; use `open <pvm>` to launch, and GUI for power ops.

- **Eyes on the guest (no UART, no macOS permissions)**

- `tools/get-screen.sh` — SSH in, `dd if=/dev/fb0`, convert BGRA→PNG locally:
  pixel-exact screenshots of the VM window.
- `lib/patch_initramfs.py` — splice a patched `/init` into the initramfs that
  streams `/proc/kmsg` over TCP to the host and injects an SSH public key into
  `/sysroot/root/.ssh` before `switch_root`. build.sh does this automatically
  with `--ssh-key <pubkey>`.
- Raw `debugfs -w` writes bypass journaling AND `sif mode` sets raw mode bits
  (directories need `040xxx`, files `100xxx`) — prefer the initramfs injection.

### SOP-07 — Resolution / display drivers (the real story)

- Install tools from `prl-tools-lin-arm.iso` (in the Parallels app's
  `Resources/Tools/`) — ARM64 tools are **pure userspace** (no kernel modules;
  the `prl_tg`/`prl_fs` modprobe failures in `journalctl -u prltoolsd` are
  cosmetic). `prltoolsd` + `prlcc` = dynamic-resolution channel + clipboard.
- Parallels pushes the *window's logical size + DPI* (`[DYNRES]` lines) and
  the guest confirms — but on **Wayland nothing applies it**: the pushed mode
  never reaches the connector, so the guest stays at the EFI resolution and
  the host upscales → "everything way too big".
- `HostRetinaEnabled` + `OsResolutionInFullScreen` must be `1` in `config.pvs`
  so fullscreen pushes native pixels.
- **Omarchy 4 config is LUA** (`hyprland.lua` + `monitors.lua`) — edits to
  `hyprland.conf` are silently ignored. Override:
  `~/.config/hypr/monitors.lua` with
  `hl.monitor({ output = "Virtual-1", mode = "2560x1600", position = "0x0", scale = 2 })`
  then `hyprctl reload` (verified live: `2560x1600@59.99`, scale 2 → logical 1280×800 on a 2× window — user-confirmed perfect).

### The three traps that cost a day (all fixed in build.sh)

1. **No-initramfs panic**: without initramfs the kernel mounts root immediately;
   if AHCI hasn't enumerated yet → `VFS: unable to mount root` panic. Always
   keep the initramfs entry + `rootwait`.
2. **Resume trap**: killing `prl_vm_app` leaves `*.mem`/`*.mem.sh` — Parallels
   then *resumes the dead state* on next open instead of cold-booting. Delete
   `*.mem*` and `vm.lock` in the `.pvm` before relaunching.
3. **Stale ESP flakiness**: after several dd-in-place edits, rebuild the ESP
   from scratch (fresh `newfs_msdos` + pour) — loader hangs vanished.

### Eyes on the guest (no UART, no macOS permissions)

- `tools/get-screen.sh` — SSH in, `dd if=/dev/fb0`, convert BGRA→PNG locally:
  pixel-exact screenshots of the VM window.
- `lib/patch_initramfs.py` — splice a patched `/init` into the initramfs that
  streams `/proc/kmsg` over TCP to the host and injects an SSH public key into
  `/sysroot/root/.ssh` before `switch_root`. build.sh does this automatically
  with `--ssh-key <pubkey>`.
- Raw `debugfs -w` writes bypass journaling AND `sif mode` sets raw mode bits
  (directories need `040xxx`, files `100xxx`) — prefer the initramfs injection.

## Ethics & legal

Do not redistribute Parallels' or the try-omarchy artifacts; build.sh downloads
everything from upstream at runtime. Omarchy's name/brand belong to the Omarchy
project — this is an unofficial community tool. try-omarchy is MIT.
