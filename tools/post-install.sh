#!/usr/bin/env bash
# post-install.sh — finish an Omarchy ARM Parallels VM: Parallels Tools,
# display config, first-boot helper. Run AFTER build.sh + the interactive
# first-boot wizard (which creates your user).
#
# usage: ./tools/post-install.sh [vm-name] [ssh-key] [guest-user]
#   vm-name    Parallels VM name            (default: "Omarchy ARM")
#   ssh-key    private key for root@guest   (default: ~/.ssh/id_ed25519)
#   guest-user desktop user from the wizard (default: auto-detect first uid-1000 user)
#
# What it does:
#   1. waits for SSH
#   2. installs Parallels Tools for Linux ARM64 (pure userspace, no kmods)
#   3. writes ~/.config/hypr/monitors.lua (2560x1600 @ scale 2) + reloads Hyprland
#   4. verifies: prltoolsd active, clipboard agent, resolution
set -euo pipefail

VM_NAME="${1:-Omarchy ARM}"
KEY="${2:-$HOME/.ssh/id_ed25519}"
GUEST_USER="${3:-}"
PVM="$HOME/Parallels/$VM_NAME.pvm"
LEASES="/Library/Preferences/Parallels/parallels_dhcp_leases"
TOOLS_ISO="/Applications/Parallels Desktop.app/Contents/Resources/Tools/prl-tools-lin-arm.iso"

log()  { printf '\033[1;32m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[[ -f "$KEY" ]] || die "ssh key not found: $KEY (pass it as 2nd arg)"
[[ -f "$TOOLS_ISO" ]] || die "Parallels Tools ISO not found: $TOOLS_ISO"
SSH="ssh -i $KEY -o ConnectTimeout=8 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
SCP="scp -i $KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

log "waiting for guest SSH (up to 5 min)…"
GIP=""
for _ in $(seq 1 30); do
  GIP=$(grep -o '10\.211\.55\.[0-9]*' "$LEASES" 2>/dev/null | tail -1)
  if [[ -n "$GIP" ]] && $SSH "root@$GIP" true 2>/dev/null; then break; fi
  GIP=""; sleep 10
done
[[ -n "$GIP" ]] || die "guest never became reachable — is the VM booted past the setup wizard?"
log "guest at $GIP"

if [[ -z "$GUEST_USER" ]]; then
  GUEST_USER=$($SSH "root@$GIP" "awk -F: '\$3>=1000 && \$3<60000 {print \$1; exit}' /etc/passwd" 2>/dev/null)
  [[ -n "$GUEST_USER" ]] || die "no desktop user found — complete the first-boot wizard in the VM window first (press Return, create your user), then re-run"
fi
log "desktop user: $GUEST_USER"

log "installing Parallels Tools (ARM64, userspace-only)…"
$SCP "$TOOLS_ISO" "root@$GIP:/root/" >/dev/null
$SSH "root@$GIP" "mkdir -p /mnt/tools && mount -o loop /root/prl-tools-lin-arm.iso /mnt/tools && /mnt/tools/installer/install-cli.sh --install --progress" 2>&1 | tail -2

log "writing Hyprland monitor config (2560x1600 @ scale 2)…"
$SSH "root@$GIP" "cat > /home/$GUEST_USER/.config/hypr/monitors.lua <<'EOF'
-- omarchy-parallels: sharp fullscreen-ready resolution for Parallels (virtio-gpu)
local omarchy_gdk_scale = 2
local omarchy_monitor_scale = 2

hl.env(\"GDK_SCALE\", tostring(omarchy_gdk_scale))
hl.monitor({ output = \"Virtual-1\", mode = \"2560x1600\", position = \"0x0\", scale = 2 })
EOF
chown $GUEST_USER:$GUEST_USER /home/$GUEST_USER/.config/hypr/monitors.lua
SIG=\$(ls /run/user/1000/hypr/ 2>/dev/null | head -1)
if [[ -n \"\$SIG\" ]]; then
  sudo -u $GUEST_USER env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1 HYPRLAND_INSTANCE_SIGNATURE=\$SIG hyprctl reload
fi" 2>&1 | grep -v "Warning:" | tail -4

log "verifying…"
$SSH "root@$GIP" "
echo \"prltoolsd: \$(systemctl is-active prltoolsd)\"
echo \"clipboard agents: \$(pgrep -c prlcc)\"
SIG=\$(ls /run/user/1000/hypr/ 2>/dev/null | head -1)
if [[ -n \"\$SIG\" ]]; then
  sudo -u $GUEST_USER env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1 HYPRLAND_INSTANCE_SIGNATURE=\$SIG hyprctl monitors 2>/dev/null | sed -n 2p
fi" 2>&1 | grep -v "Warning:"

cat <<EOF

done! Your Omarchy desktop should now be sharp and right-sized.
If the UI feels too small/big, edit one number inside the guest:
  ~/.config/hypr/monitors.lua  →  scale = 2   (bigger UI = higher number)
then: hyprctl reload
EOF
