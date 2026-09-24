# Omarchy ARM64 on Parallels Desktop — natively, on Apple Silicon

> **AI agents / automation**: start with [`AGENTS.md`](AGENTS.md) — it is the
> canonical operating manual (file map, constants, SOPs, failure modes,
> verification checklist). [`tools/status.sh`](tools/status.sh) emits a
> machine-readable state probe; [`skills/omarchy-parallels/SKILL.md`](skills/omarchy-parallels/SKILL.md) is the
> packaged skill wrapper.

**Run [Omarchy](https://omarchy.org) (Quattro) on your M-series Mac inside
Parallels Desktop — no Parallels Pro, no x86 emulation, no QEMU.**

The official Omarchy ISO is x86_64-only, and Parallels on Apple Silicon boots
arm64 guests only, so `omarchy-4.0.4.iso` simply cannot boot there (`IsBootable=0`).
This project bridges that gap: it takes the **ARM64 Omarchy build that the
official [try-omarchy](https://github.com/omacom/try-omarchy) app ships for
QEMU**, repackages it into a GPT disk with a real EFI bootloader, and wires it
into a normal Parallels VM — running **natively virtualized** with Parallels'
own AHCI/virtio device model and VirGL graphics.

```
official try-omarchy.dmg ──► ARM64 Omarchy rootfs ──► GPT disk (ESP + ext4)
        (MIT)                    (kernel w/ storage      ▲ systemd-boot
                                  drivers built-in)      │
                                                   Parallels plain .hds
                                                         │
                                              Parallels VM (arm64 EFI)
                                                         │
                                                  Omarchy desktop 🎉
```

## Requirements

- Apple Silicon Mac (M1 and later), macOS with Parallels Desktop installed
  (tested: Parallels Desktop **27.0.2 Standard** — Pro features not required)
- [Homebrew](https://brew.sh) (for `zstd` + `e2fsprogs`)
- ~15 GB free disk space, internet access
- ~15 minutes

## Quickstart

```bash
git clone https://github.com/vincenzopalazzo/omarchy-parallels
cd omarchy-parallels
./build.sh --ssh-key ~/.ssh/id_ed25519.pub   # creates a VM named "Omarchy ARM"
```

The script downloads the official `TryOmarchy.dmg` (~1.4 GB), verifies every
artifact SHA256 against the bundled manifest, builds the disk, creates and
registers the VM, and opens it in Parallels.

**Then finish in two steps:**

1. **In the VM window**: press Return at the setup screen and create your user
   (Omarchy's interactive first-boot wizard — takes ~1 minute).
2. **Back on your Mac** — Parallels Tools + sharp display, one command:
   ```bash
   ./tools/post-install.sh "Omarchy ARM" ~/.ssh/id_ed25519
   ```
   This installs the ARM64 Parallels Tools (dynamic-resolution channel +
   clipboard), pins the Hyprland mode to 2560×1600 @ scale 2, and verifies
   everything. If the UI feels too small/big afterwards, change one number
   (`scale = 2`) in `~/.config/hypr/monitors.lua` inside the guest.

Useful flags:

```text
--vm-name NAME        VM display name            (default: "Omarchy ARM")
--root-size-gib N     ext4 size after resize     (default: 16)
--disk-size-mib N     total Parallels disk size  (default: layout + 128 MiB)
--dmg PATH            reuse a local TryOmarchy.dmg instead of downloading
--workdir DIR         build workspace            (default: ~/Downloads/omarchy-parallels-build)
--skip-boot           register but don't open the VM
--keep-dmgs           keep the downloaded DMG after building
```

## SSH into the guest

The generated boot entry passes `tryomarchy.ssh_access=1`, which the guest
honors by starting `sshd`:

```bash
GUEST_IP=$(grep -o '10\.211\.55\.[0-9]*' /Library/Preferences/Parallels/parallels_dhcp_leases | head -1)
ssh "omarchy@${GUEST_IP}"     # or the desktop user you set up
```

## How it works

The full engineering write-up (partition map, the `modules.builtin` detective
work, Parallels' disk descriptor format, every failure mode we hit) is in
[docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md). Short version:

1. **The blocker** — Parallels on Apple Silicon = arm64 EFI, x86_64-only ISO:
   dead end, permanently.
2. **The door** — `try-omarchy` (MIT) builds an ARM64 Omarchy Quattro image for
   its QEMU/HVF Mac app. Its kernel has `ahci`, `libata`, `sd_mod`, `scsi_mod`,
   `ext4`, and `virtio_blk` compiled **into** the kernel (`modules.builtin`),
   so it boots on Parallels' emulated AHCI/virtio hardware without touching the
   initramfs.
3. **The repack** — the rootfs is a bare ext4 image that QEMU direct-boots; we
   give it a 1 GiB FAT32 ESP with `systemd-boot` (extracted from the rootfs
   itself via `debugfs`) + kernel + initramfs + a loader entry, wrap it in a
   GPT, and pour it into a **plain** `.hds` created by `prl_disk_tool`
   (hand-written Parallels descriptors get rejected — details in the docs).
4. **The VM** — a standard `.pvm` bundle (config template included) registered
   via `prlctl`, booting through Parallels' arm64 EFI with VirGL 3D and
   virtio-net.

## Troubleshooting

See `docs/HOW-IT-WORKS.md` for the complete table (GPT/`hdiutil`/`newfs_msdos`
quirks, ghost registrations, descriptor format, boot debugging via
`parallels.log` and DHCP leases). The agent skill in
[`skills/omarchy-parallels/SKILL.md`](skills/omarchy-parallels/SKILL.md) encodes the same knowledge for coding agents.

## Tools

- `tools/get-screen.sh` — screenshot the VM's screen over SSH (reads the guest
  framebuffer; needs no macOS screen-recording permission):
  `./tools/get-screen.sh screen.png ~/.ssh/id_ed25519 root@10.211.55.5`
  (thin wrappers — canonical scripts live in
  `skills/omarchy-parallels/scripts/`)

## Agent Plugin (skills + MCP, portable)

This repo is packaged as an [Agent Plugins](https://agent-plugins.org) v1.0.0
plugin (see [aaif-goose/goose#11043](https://github.com/aaif-goose/goose/issues/11043)):

```text
omarchy-parallels/
├── plugin.json                  # manifest (identity + spec version)
├── mcp.json                     # MCP server declaration (stdio)
├── skills/omarchy-parallels/    # agent skill (SKILL.md + scripts/)
│   ├── SKILL.md
│   └── scripts/                 # status.sh, get-screen.sh, post-install.sh
├── mcp-server/server.py         # stdio MCP server (stdlib-only Python)
└── … (build.sh, lib/, templates/, docs/ — the builder itself)
```

- **Skill**: `skills/omarchy-parallels/SKILL.md` (Agent Skills format).
- **MCP server**: `mcp-server/server.py` exposes `vm_status`,
  `vm_screenshot`, `vm_exec`, `vm_display_get`, `vm_display_set` — the exact
  operations used to build and debug the VM. Run
  `OMARCHY_SSH_KEY=~/.ssh/id_ed25519 python3 mcp-server/server.py`
  (see `mcp-server/README.md` for client wiring + smoke test).
- Install the whole directory as a plugin in any Agent-Plugins-compatible
  client; `tools/*.sh` remain as CLI wrappers for humans.

## FAQ

**Why not just boot the official ISO in UTM/QEMU emulation?**
You can — but it's TCG emulation (10–20× slower). This project runs the same
Omarchy desktop natively virtualized.

**Why not just use the try-omarchy app?**
You can — it's great. This project exists for people who want Omarchy *inside
Parallels*: snapshots, Coherence, shared folders, USB passthrough, and
management alongside their other Parallels VMs.

**Does this modify Parallels or my Mac?**
No. It creates one self-contained `.pvm` in `~/Parallels`. Nothing else changes.

**Is this affiliated with Omarchy, basecamp, or Parallels?**
No. Unofficial community tooling. The Omarchy name and brand belong to the
Omarchy project.

## Legal

- Code in this repository: MIT (see [LICENSE](LICENSE)).
- Nothing proprietary is redistributed. `build.sh` downloads the official
  try-omarchy release at runtime and verifies its SHA256 manifest; the Omarchy
  rootfs, Arch Linux ARM packages, and their licenses remain those of their
  respective projects. The Omarchy mark is subject to Omarchy's trademark
  rights. Parallels Desktop is commercial software by Alludo/Parallels — this
  project only drives its documented command-line tools on your machine.

## Credits

- [try-omarchy](https://github.com/omacom/try-omarchy) — the ARM64 Omarchy
  guest build and the QEMU/HVF runtime that inspired the deep-dive; MIT.
- [Omarchy](https://github.com/basecamp/omarchy) by DHH & basecamp — the
  beautiful, fun & agentic Linux itself.
- The Parallels Desktop team — for `prlctl`/`prl_disk_tool`, which make this
  scriptable at all.
