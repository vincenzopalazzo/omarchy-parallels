#!/usr/bin/env bash
# status.sh — one-shot machine-readable state probe for the Omarchy ARM VM.
# Emits `key=value` lines; every check degrades gracefully (never crashes).
#
# usage: ./tools/status.sh [vm-name] [ssh-key]
set -u
VM_NAME="${1:-Omarchy ARM}"
KEY="${2:-$HOME/.ssh/id_ed25519}"
PVM="$HOME/Parallels/$VM_NAME.pvm"
LOG="$PVM/parallels.log"
STAT="$PVM/statistic.log"
LEASES="/Library/Preferences/Parallels/parallels_dhcp_leases"
say() { printf '%s=%s\n' "$1" "${2-}"; }

# --- registration ---
REG=$(/usr/local/bin/prlctl list -a 2>/dev/null | grep -F "$VM_NAME" | awk '{print $1}')
say vm_registered "$([[ -n "$REG" ]] && echo true || echo false)"
say vm_uuid "$REG"

# --- vm state + process ---
if [[ -f "$STAT" ]]; then
  say vm_state "$(grep -oE 'VMS_[A-Z]+' "$STAT" | tail -1)"
fi
PID=$(pgrep -f "prl_vm_app.*$VM_NAME" | head -1)
say vm_pid "$PID"
if [[ -n "${PID:-}" ]]; then
  say vm_cpu "$(ps -o pcpu= -p "$PID" 2>/dev/null | tr -d ' ')"
  say vm_uptime_secs "$(ps -o etime= -p "$PID" 2>/dev/null | awk -F: '{if (NF==2) print $1*60+$2; else print $1*3600+$2*60+$3}')"
fi

# --- kernel loaded? (ESP read burst in current log) ---
if [[ -f "$LOG" && -n "${PID:-}" ]]; then
  say boot_reads_done "$(grep "$PID" "$LOG" | grep -c 'rh done')"
  say dynres_events "$(grep "$PID" "$LOG" | grep -c DYNRES)"
fi

# --- guest ip + reachability ---
GIP=$(grep -o '10\.211\.55\.[0-9]*' "$LEASES" 2>/dev/null | tail -1)
say guest_ip "$GIP"
if [[ -n "$GIP" ]]; then
  if ping -c1 -t2 "$GIP" >/dev/null 2>&1; then say ping true; else say ping false; fi
  if nc -z -G3 "$GIP" 22 >/dev/null 2>&1; then say ssh_port open; else say ssh_port closed; fi
  if [[ -f "$KEY" ]]; then
    say guest_uname "$(ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=6 \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "root@$GIP" 'uname -r' 2>/dev/null || echo unreachable)"
    say guest_tools "$(ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=6 \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "root@$GIP" 'systemctl is-active prltoolsd' 2>/dev/null || echo unknown)"
    say guest_resolution "$(ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=6 \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "root@$GIP" 'SIG=$(ls /run/user/1000/hypr/ 2>/dev/null | head -1); \
        if [ -n "$SIG" ]; then \
          sudo -u $(ls /home | head -1) env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1 \
            HYPRLAND_INSTANCE_SIGNATURE=$SIG hyprctl monitors 2>/dev/null | sed -n 2p; \
        else cat /sys/class/graphics/fb0/virtual_size 2>/dev/null; fi' 2>/dev/null || echo unknown)"
  fi
fi
