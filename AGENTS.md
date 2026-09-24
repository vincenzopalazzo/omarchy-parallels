# AGENTS.md — operating manual for coding agents

**Canonical reference for any AI agent (or human) working in this repository.**
Read this before touching anything. If this file and your assumptions disagree,
this file wins — it is derived from a completed, verified build.

- Repo: https://github.com/vincenzopalazzo/omarchy-parallels
- Outcome: an **ARM64 Omarchy (Quattro) desktop running natively in Parallels
  Desktop** on an Apple Silicon Mac — correct resolution, clipboard, tools —
  with a single build command and zero Parallels Pro requirements.

---

## 1. Outcome contract ("definition of done")

A build is DONE when all of the following hold:

1. `prlctl list -a` shows the VM (default name `Omarchy ARM`) registered.
2. VM boots cold to the Omarchy desktop: Hyprland session active for the
   provisioned user, `omarchy-provision-owner` completed once.
3. `prltoolsd.service` active inside the guest (dynamic resolution, clipboard).
4. Guest reachable from host: `ping 10.211.55.<x>` and TCP port 22 open.
5. SSH as root works with the injected key (see SOP-04).
6. Screenshot possible via `tools/get-screen.sh` (framebuffer proof).

## 2. Environment contract

| Requirement | Value / check |
|---|---|
| Host | Apple Silicon (`uname -m == arm64`), macOS with Parallels Desktop ≥ 19 (verified: 27.0.2 **Standard** edition) |
| Parallels CLI | `/usr/local/bin/prlctl`, `/usr/local/bin/prl_disk_tool` (installed with Parallels) |
| Build deps | Homebrew; `zstd`; `e2fsprogs` (brew — provides `debugfs`, `e2fsck`, `resize2fs`, `dumpe2fs`); `python3`; `cpio` (system) |
| Network | Internet for the try-omarchy release download (~1.4 GB) |
| Disk | ~15 GB free |
| NOT required | Parallels Pro/Business (Standard is enough); no x86 emulation anywhere |

Pro-gated CLI (do not use): `prlctl start|stop|status|capture|snapshot-list|create`.
Free CLI: `prlctl list|register|unregister`. Launch via `open <file>.pvm`.

## 3. Repository map

| Path | Purpose |
|---|---|
| `build.sh` | One-shot pipeline: download try-omarchy release → verify SHA256 manifest → decompress/grow ext4 → extract systemd-boot → build ESP → GPT → pour into Parallels plain disk → scaffold `.pvm` → register → launch. Flags: `--vm-name --dmg --release --root-size-gib --esp-size-mib --disk-size-mib --workdir --ssh-key --skip-boot --keep-dmgs` |
| `lib/gptbuild.py` | Protective-MBR + GPT writer (`build_layout`) and verifier (`verify`: header/entries CRC32, ext4 magic `53 EF` at root+1024+0x38, `55 AA` at ESP+510). 512-byte LBAs only |
| `lib/patch_initramfs.py` | Splices a patched `/init` into the (uncompressed cpio) mkinitcpio initramfs: (a) early block — bring up `eth0`, stream `/proc/kmsg` over TCP to the host; (b) late block — write SSH pubkey into `/sysroot/root/.ssh/authorized_keys` before `switch_root`. Preserves cpio entry names **exactly** |
| `templates/config.pvs.tmpl` | Working Parallels VM config for a generic arm64 Linux guest (OsType 9 / OsNumber 2559, SATA HDD, EFI `EfiEnabled 5`, HDD-first boot order, virtio net). Placeholders: `__VM_NAME__ __VM_UUID__ __DISK_UUID__ __DISK_NAME__ __DISK_SIZE_MB__ __DISK_SIZE_ON_DISK_MB__` |
| `templates/VmInfo.pvi.tmpl` | Minimal per-VM info file |
| `tools/get-screen.sh` | Screenshot the guest screen over SSH by reading `/dev/fb0` and converting BGRA→PNG locally (no macOS screen-recording permission needed) |
| `tools/status.sh` | One-shot machine-readable state probe (host + guest), `key=value` lines |
| `tools/post-install.sh` | Finisher: waits for SSH → installs Parallels Tools ARM64 → writes `monitors.lua` (2560×1600 @ scale 2) → reloads Hyprland → verifies. Usage: `./tools/post-install.sh [vm-name] [ssh-key] [guest-user]`. STOPS with a clear error if the first-boot wizard hasn't created a desktop user yet |
| MAC addresses | **Randomized per build** (`001C42` OUI + random bytes for guest + host MACs). Cloned configs share MACs → DHCP fight → second VM never gets an IP. Template carries `__GUEST_MAC__`/`__HOST_MAC__` placeholders | → installs Parallels Tools ARM64 → writes `monitors.lua` (2560×1600 @ scale 2) → reloads Hyprland → verifies. Usage: `./tools/post-install.sh [vm-name] [ssh-key] [guest-user]` |
| `skill/SKILL.md` | Agent-skill wrapper (goose/Claude-style): triggers + condensed manual. Points here |
| `docs/HOW-IT-WORKS.md` | Full engineering write-up incl. every dead end and the resolution |
| `README.md` | Human-facing quickstart |

## 4. Architecture

### Boot chain (what makes it work)

```
Parallels arm64 EFI (efia64.bin)
  └─ GPT scan → ESP (FAT32) → /EFI/BOOT/BOOTAA64.EFI (systemd-boot)
       └─ /Image (vmlinuz, = stock Arch Linux ARM linux-aarch64 7.2.6-1,
          byte-identical, sha256 6c439977…) + /initramfs-linux.img
            └─ options: root=UUID=… rootfstype=ext4 rw rootwait console=…
                 └─ kernel mounts p2 (ext4, all storage drivers BUILT-IN)
                      └─ systemd → Hyprland (Omarchy 4.0.3)
```

Why it works: the kernel has `ahci libata sd_mod scsi_mod ext4 virtio_blk
virtio_pci nvme` **compiled in** (see `modules.builtin` inside the rootfs), so
Parallels' emulated AHCI/virtio hardware needs zero initramfs changes.

### Disk layout (512-byte LBAs) — inside the plain `.hds`

| Region | LBA start | Size (LBAs) |
|---|---|---|
| Protective MBR | 0 | 1 |
| Primary GPT header | 1 | 1 |
| Primary entries | 2 | 32 |
| **p1 ESP** (FAT32, type `C12A7328-F81F-11D2-BA4B-00A0C93EC93B`) | **2048** | `esp_size_mib * 2048` (default 1 GiB = 2097152) |
| **p2 rootfs** (ext4, type `0FC63DAF-8483-4772-8E79-3D69D8477DE4`) | 2048 + esp | default 16 GiB = 33554432 |
| Backup entries / header | `total-33` / `total-1` | — |

`total` LBAs = Parallels disk size in MiB × 2048. Disk must exceed the layout
by ≥128 MiB (script enforces). Container: `Type: Plain`, base image GUID
`{5fbaabe3-6958-40ff-92a7-860e329aab41}` (canonical — hand-written descriptors
are rejected with `PRL_ERR_DISK_XML_INVALID`).

### Fixed constants

| Constant | Value |
|---|---|
| ext4 UUID / label | `89054943-1f4e-4f14-b934-d6db3fba4254` / `omarchy-factory` (inherited from source image; survives resize2fs) |
| Kernel cmdline (working set) | `root=UUID=<ext4-uuid> rootfstype=ext4 rw rootwait console=ttyAMA0,115200 console=tty0 loglevel=4 tryomarchy.ssh_access=1 systemd.show_status=false rd.systemd.show_status=false mitigations=off nowatchdog` |
| `tryomarchy.ssh_access=1` | guest token → starts `sshd.service` at boot |
| Parallels shared net | host `10.211.55.2` (bridge100), guests `10.211.55.0/24` |
| DHCP lease file | `/Library/Preferences/Parallels/parallels_dhcp_leases` |
| kmsg stream (patched initramfs) | guest `10.211.55.9` → host `:4499` TCP |
| Parallels Tools ISO (ARM64) | `/Applications/Parallels Desktop.app/Contents/Resources/Tools/prl-tools-lin-arm.iso` — **pure userspace**, installs on Arch unmodified |
| Guest root login | `root` (factory image; no password) + SSH pubkey injected; desktop user created by first-boot wizard (e.g. `vincent`) |

## 5. Runtime state map

| What | Where |
|---|---|
| VM bundle | `~/Parallels/<name>.pvm/` |
| VM log | `~/Parallels/<name>.pvm/parallels.log` — grep: `IsBootable`, `rh done`, `VIRTIO`, `DYNRES`, `AHCI`, `Serial0` |
| VM state | `~/Parallels/<name>.pvm/statistic.log` — `VMS_STARTING` → `VMS_RUNNING`; `GUI:ViewModeSwitch` lines |
| VM process | `prl_vm_app` — CPU% ≈ guest activity |
| Suspend trap | `<pvm>/*.mem`, `*.mem.sh`, `vm.lock` — **delete before relaunch after a hard kill**, or Parallels resumes the dead state |
| Guest IP | `grep -o '10\.211\.55\.[0-9]*' /Library/Preferences/Parallels/parallels_dhcp_leases` |
| Guest display | `/sys/class/drm/card0-Virtual-*/` (16 dynamic heads; `card0-Virtual-1` active) |
| Guest tools | `systemctl is-active prltoolsd`; clipboard agent `prlcc` (per session) |
| Guest screen | `/dev/fb0` (BGRA, size in `/sys/class/graphics/fb0/virtual_size`) — **only shows the text console once Hyprland owns DRM**; for the real desktop use `grim` in the user session or `tools/get-screen.sh` for fb-era boots |

## 6. Standard operating procedures

### SOP-01 — Build a new VM
```bash
git clone https://github.com/vincenzopalazzo/omarchy-parallels && cd omarchy-parallels
./build.sh --vm-name "Omarchy ARM" --ssh-key ~/.ssh/id_ed25519.pub
```
Then, in order:
1. In the VM window: press Return at the setup screen, create your user
   (Omarchy's interactive first-boot wizard).
2. Back on the Mac: `./tools/post-install.sh "Omarchy ARM" ~/.ssh/id_ed25519`
   (Parallels Tools + display config + verification).

### SOP-02 — Verify a boot
```bash
./tools/status.sh                    # or read outputs manually:
tail -3 ~/Parallels/"Omarchy ARM.pvm"/statistic.log
grep -c DYNRES ~/Parallels/"Omarchy ARM.pvm"/parallels.log   # >0 = display negotiated
ping -c1 -t2 10.211.55.5; nc -z -G3 10.211.55.5 22
```

### SOP-03 — Screenshot the guest
```bash
./tools/get-screen.sh screen.png <key> root@<guest-ip>       # boots in fb era
# after Hyprland owns DRM:
ssh -i <key> root@<ip> 'pacman -S --noconfirm grim'
ssh -i <key> root@<ip> "SIG=\$(ls /run/user/1000/hypr/ | head -1); \
  sudo -u vincent env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1 \
  HYPRLAND_INSTANCE_SIGNATURE=\$SIG grim /tmp/d.png"
scp -i <key> root@<ip>:/tmp/d.png .
```

### SOP-04 — SSH access
```bash
ssh -i <key> root@<guest-ip>     # key injected at boot by patched initramfs
# password auth is OFF for root; password of the wizard-created user is
# whatever was typed during setup
```

### SOP-05 — Change kernel cmdline (existing VM)
```bash
HDS=~/Parallels/"<name>.pvm"/<disk>.hdd/*.{5fbaabe3-…}.hds
dd if="$HDS" of=/tmp/esp.img bs=512 skip=2048 count=2097152 status=none
M=$(hdiutil attach -nobrowse /tmp/esp.img | sed -n 's/.*\(\/Volumes\/.*\)$/\1/p' | tail -1)
$EDITOR "$M/loader/entries/"*.conf
hdiutil detach "$M"; dd if=/tmp/esp.img of="$HDS" bs=512 seek=2048 conv=notrunc status=none
# then cold-reboot: delete *.mem* + vm.lock first (trap 2 below)
```

### SOP-06 — Inject SSH key on an EXISTING VM (no initramfs rebuild)
Never raw-write the ext4 (`debugfs -w` gets reverted by journal replay).
Re-apply the initramfs patch instead: `python3 lib/patch_initramfs.py
<initramfs> <same> 10.211.55.2 4499 <pubkey>`, swap into ESP (SOP-05), reboot.

### SOP-07 — Fix resolution / window size

**How it actually works** (learned 2026-09-24): Parallels pushes the *window's
logical size + DPI* to the guest over the tools channel (`[DYNRES] … Display
[0]: W H DPI` in `parallels.log` + guest confirmation). On **X11** their video
driver turns that into an `xrandr` modeset. On **Wayland/Hyprland nothing
applies it** — the pushed mode never appears in the connector's mode list, so
the guest stays at the EFI resolution (1160×768) and the host upscales it →
"everything way too big".

Also: `HostRetinaEnabled` / `OsResolutionInFullScreen` in `config.pvs` must be
`1` (Parallels GUI: use Retina resolution / change resolution in fullscreen).
With them on, fullscreen pushes native pixels (e.g. 2320×1536 on a Retina
panel) — but again, Wayland still needs the static rule below.

**Fix — Omarchy 4 uses a LUA config, not `hyprland.conf`** (a `hyprland.conf`
edit is silently ignored; the log line is `[cfg] Regular config at
…/hyprland.lua`):

```bash
cat > /home/<user>/.config/hypr/monitors.lua <<'EOF'
local omarchy_gdk_scale = 2
local omarchy_monitor_scale = 2
hl.env("GDK_SCALE", tostring(omarchy_gdk_scale))
hl.monitor({ output = "Virtual-1", mode = "2560x1600", position = "0x0", scale = 2 })
EOF
chown <user>:<user> /home/<user>/.config/hypr/monitors.lua
# reload as the user (SIG = ls /run/user/1000/hypr/ | head -1):
sudo -u <user> env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1 \
  HYPRLAND_INSTANCE_SIGNATURE=$SIG hyprctl reload
```

`2560x1600` is in the virtio-gpu mode list and is 16:10 Retina-class.
**Verified-by-user final state: mode 2560x1600, scale 2 → logical 1280×800** —
matches the Parallels window's point size on a 2× Retina display.
Tuning rule: bigger UI = higher scale, smaller UI = lower scale.
Available modes: 1160x768, 1920x1440, 2560x1600, 4096x2160.

### SOP-08 — (Re)install Parallels Tools
```bash
scp "/Applications/Parallels Desktop.app/Contents/Resources/Tools/prl-tools-lin-arm.iso" root@<ip>:/root/
ssh -i <key> root@<ip> "mkdir -p /mnt/tools && mount -o loop /root/prl-tools-lin-arm.iso /mnt/tools && \
  /mnt/tools/installer/install-cli.sh --install --progress"
```
ARM64 tools are pure userspace — no kernel headers, no Arch patching needed.
Verify: `systemctl is-active prltoolsd` and `pgrep prlcc` (in session).

### SOP-09 — Recover from boot hang/panic
1. Read the screen: SOP-03 (during fb-era boots) or the guest's own panic text in the window.
2. Cold-reboot properly: `kill -9 $(pgrep -f prl_vm_app)`; **delete `*.mem*` and `vm.lock`** in the `.pvm`; relaunch. (Skipping the delete resumes the dead state — trap.)
3. Still hung? Verify the ESP entry has the initramfs line + `rootwait`; rebuild the ESP from scratch (fresh `newfs_msdos` + pour) — stale FAT after many edits causes loader hangs.
4. Log breadcrumbs: `parallels.log` → `rh done … 255 MB` = kernel+initrd loaded; nothing after that = kernel-early issue (check `GIC: … RAZ` lines).

### SOP-10 — Teardown
```bash
prlctl unregister "<name>" && rm -rf ~/Parallels/"<name>.pvm" ~/Downloads/omarchy-parallels-build
```

## 7. Failure modes → fixes

| Symptom | Cause | Fix |
|---|---|---|
| `PRL_ERR_DISK_XML_INVALID (0xffffadf6)`, "temporary uid not found" | hand-written `DiskDescriptor.xml` | generate with `prl_disk_tool create --hdd … --size <MiB> --alloc-policy sparse`, pour data into its `.hds` |
| `IsBootable=0` | x86_64-only ISO, or invalid GPT | use this repo's ARM64 repack; verify GPT CRCs (`gptbuild.verify`) |
| register: "name already taken" but unregister: "not found" | ghost VM identity | regenerate `VmUuid`+`SourceVmUuid` in `config.pvs`, register again (build.sh retries ×3) |
| `newfs_msdos: Cannot get partition offset` | given a plain file | `hdiutil attach -nomount` first, format the `/dev/diskN` node |
| Disk all zeros after assembly | file recreated/truncated after writing | assemble atomically (truncate once → seek+write → verify) |
| Panic `VFS: unable to mount root` | no-initramfs entry raced AHCI | keep initramfs + `rootwait` (build.sh default) |
| VM resumes dead state | suspend snapshot after `kill -9` | delete `*.mem*` + `vm.lock`, relaunch |
| Loader hangs, no guest CPU | stale/edited FAT | rebuild ESP from scratch |
| Serial (`/dev/cu.debug-console`, serial-to-file) silent | guest UART not wired to host sinks | use framebuffer read (SOP-03) or initramfs kmsg stream |
| No working init found after initramfs repack | cpio entry named `./init` | entry name must be exactly `init` (`patch_initramfs.py` guarantees it) |
| SSH key injected via `debugfs -w` vanished | journal replay reverted raw writes | inject via initramfs (SOP-06), not fs surgery |
| `debugfs sif mode` → `Type: bad type` | mode set without type bits | dirs `040xxx`, files `100xxx` |
| Wayland env "not set" for `hyprctl`/`grim` | vars not in process env | derive: `SIG=$(ls /run/user/1000/hypr/ \| head -1)`, `WAYLAND_DISPLAY=wayland-1`, `XDG_RUNTIME_DIR=/run/user/1000` |
| "screen way bigger" — guest stuck at 1160×768, upscaled | Parallels pushes logical size+DPI; **Wayland never applies it** (tools modeset path is X11-only) | set `HostRetinaEnabled`+`OsResolutionInFullScreen`=1 in `config.pvs`; pin a real mode via Omarchy's **Lua** config (`~/.config/hypr/monitors.lua` → `hl.monitor({output="Virtual-1", mode="2560x1600", position="0x0", scale=1})`) + `hyprctl reload`; see SOP-07 |
| Omarchy config edits ignored | Omarchy 4 Hyprland config is **Lua** (`hyprland.lua`, `monitors.lua`) | edit the `.lua` files; `hyprland.conf` is dead text (Hyprland log: `[cfg] Regular config at …/hyprland.lua`) |

## 8. Hard-won rules (do NOT)

- Do **not** try to boot the official Omarchy ISO on Apple Silicon Parallels — x86_64 vs arm64, permanent dead end.
- Do **not** hand-write Parallels `DiskDescriptor.xml`.
- Do **not** `mkfile`/truncate a disk file after data was written into it.
- Do **not** redistribute Parallels files (VM.app stub: copy from a local VM or synthesize) or the try-omarchy artifacts (download at runtime).
- Do **not** raw-write the ext4 from macOS; use the initramfs injection path.
- Do **not** trust `statistic.log`'s `VMS_RUNNING` alone — verify via network + CPU + DYNRES.

## 9. Legal

MIT (see LICENSE). Nothing proprietary is redistributed; artifacts are
downloaded from upstream at build time. Omarchy's name/brand belong to the
Omarchy project; try-omarchy is MIT; Parallels Desktop is commercial software
(this repo only drives its documented CLI on the user's machine).
