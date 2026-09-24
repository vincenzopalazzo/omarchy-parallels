# Changelog

## 1.0.0 — 2026-09-24

First release as an [Agent Plugins](https://agent-plugins.org)-conformant
package (spec v1.0.0, for [aaif-goose/goose#11043](https://github.com/aaif-goose/goose/issues/11043)).

- `plugin.json` manifest + `mcp.json` MCP declaration (both schema-validated).
- Skill moved to `skills/omarchy-parallels/` (was `skill/`); operational
  scripts moved to `skills/omarchy-parallels/scripts/` with thin
  backward-compatible wrappers left in `tools/`.
- New `mcp-server/`: stdio MCP server (stdlib-only Python) exposing the exact
  operations used to build and debug the VM — `vm_status`, `vm_screenshot`,
  `vm_exec`, `vm_display_get`, `vm_display_set`.
- `AGENTS.md` operating manual; `tools/status.sh` state probe; `build.sh`
  `--ssh-key` auto-generation; per-build randomized NIC MACs.

## 0.x (unreleased history)

- Proved the official Omarchy ISO is x86_64-only and cannot boot on Apple
  Silicon Parallels; repackaged the try-omarchy ARM64 rootfs into a GPT disk
  with systemd-boot and booted it natively.
- Fixed the boot panic (initramfs + `rootwait` + fresh ESP), the Parallels
  resume trap, cloned-MAC DHCP collisions, and the Wayland/DYNRES resolution
  story (2560×1600 @ scale 2 via Omarchy's Lua monitor config).
- Installed ARM64 Parallels Tools (pure userspace) for clipboard + dynamic
  resolution channel.
