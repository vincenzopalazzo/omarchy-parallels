#!/usr/bin/env bash
# build-omarchy-arm-iso.sh — generate a bootable ARM64 Omarchy ISO from inside
# a running Omarchy ARM system (e.g. the Parallels VM from this repo).
#
# Produces an El-Torito EFI-bootable ISO containing:
#   - systemd-boot (BOOTAA64.EFI) + Linux Image + live initramfs (custom /init:
#     finds the ISO device, loop-mounts the squashfs, overlayfs, switch_root)
#   - omarchy.sfs ......... squashfs snapshot of the running system
#   - omarchy-arm-install .. installer (partition + unsquashfs + bootloader)
#
# Run as root inside the guest. See skills/omarchy-iso/SKILL.md.
# MIT licensed (part of omarchy-parallels, unofficial community tooling).
set -euo pipefail

LABEL="OMARCHY_ARM"
OUT_DIR="/root"
WORK="/var/tmp/iso-build"   # persistent across reboots (/tmp is tmpfs)
INJECT_KEY=""     # testing only: authorized_keys for live root (removed for release)
SFS_COMP="xz"
SFS_EXTRA="-Xbcj arm"

log()  { printf '\033[1;32m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
trap 'printf "\033[1;31mbuilder failed on line %s\033[0m\n" "$LINENO" >&2' ERR

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ssh-key) INJECT_KEY="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --work)    WORK="$2"; shift 2 ;;
    --comp)    SFS_COMP="$2"; shift 2 ;;
    -h|--help)
      echo "usage: $0 [--ssh-key PUBKEY] [--out-dir DIR] [--work DIR] [--comp xz|gzip]"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
if [[ "$SFS_COMP" != "xz" ]]; then SFS_EXTRA=""; fi

[[ "$(id -u)" == "0" ]] || die "run as root"
[[ "$(uname -m)" == "aarch64" ]] || die "aarch64 guest required"
for t in mksquashfs unsquashfs xorriso mkfs.fat busybox modinfo cpio bootctl; do
  command -v "$t" >/dev/null || die "missing tool: $t (pacman -S busybox libisoburn squashfs-tools dosfstools gptfdisk)"
done
FREE_GB=$(df -BG / --output=avail | tail -1 | tr -dc 0-9)
[[ "${FREE_GB:-0}" -ge 8 ]] || die "need ~8 GB free on / (have ${FREE_GB} GB)"
[[ -n "$INJECT_KEY" && ! -f "$INJECT_KEY" ]] && die "ssh key not found: $INJECT_KEY"

STAMP=$(date +%Y%m%d)
ISO_NAME="omarchy-arm-${STAMP}-aarch64.iso"
KVER=$(uname -r)
MODDIR="/usr/lib/modules/$KVER"

rm -rf "$WORK"; mkdir -p "$WORK/iso-root" "$WORK/fat" "$WORK/initrd" "$WORK/esp-mnt"

# ---------- 1. squashfs snapshot of the live system ----------
log "snapshotting / -> squashfs (direct, excludes applied)"
# NOTE: paths must be absolute (source is /); wildcards allowed
cat > "$WORK/excludes.txt" <<EOF
/proc
/proc/*
/sys
/sys/*
/dev
/dev/*
/run
/run/*
/tmp
/tmp/*
/var/tmp
/var/tmp/*
/media
/media/*
/mnt
/mnt/*
/lost+found
/var/cache/pacman/pkg/*
/var/log/journal/*
/var/tmp/*
/etc/machine-id
/etc/ssh/ssh_host_*
/root/.ssh
/root/.ssh/*
/root/.bash_history
/root/.cache
/root/.cache/*
/root/prl-tools-lin-arm.iso
/root/*.log
/root/*.iso
/home
/home/*
${WORK}
${WORK}/*
EOF
log "snapshotting / -> squashfs (direct, excludes applied)"
set +o pipefail
mksquashfs / "$WORK/iso-root/omarchy.sfs" -comp "$SFS_COMP" $SFS_EXTRA \
  -b 1M -ef "$WORK/excludes.txt" > "$WORK/mksquashfs.log" 2>&1
MKSQ=$?
set -o pipefail
tail -2 "$WORK/mksquashfs.log"
# mksquashfs exits non-zero on unreadable pseudo-files; the artifact + its
# superblock are the real verdict (verified below)
[[ -f "$WORK/iso-root/omarchy.sfs" ]] || die "mksquashfs produced no image (exit $MKSQ)"
unsquashfs -s "$WORK/iso-root/omarchy.sfs" >/dev/null || die "squashfs superblock invalid"
if unsquashfs -l "$WORK/iso-root/omarchy.sfs" 2>/dev/null | grep -qE "squashfs-root/(proc|sys|dev|run|tmp|mnt|media)/"; then
  die "pseudo-filesystems leaked into the image — check excludes.txt"
fi
log "squashfs verified clean"
ls -la "$WORK/iso-root/omarchy.sfs"

# ---------- 2. live initramfs (/init finds ISO -> squashfs -> overlay) ----------
log "building live initramfs"
I="$WORK/initrd"
mkdir -p "$I"/{bin,sbin,proc,sys,dev,iso,sfs,ovl,sysroot,lib/modules}
cp /usr/bin/busybox "$I/bin/"
for lib in $(ldd /usr/bin/busybox | grep -o '/[^ ]*'); do
  mkdir -p "$I$(dirname "$lib")"; cp -L "$lib" "$I$lib"
done
for a in sh mount umount switch_root insmod blkid sleep echo cat ls mkdir mknod uname ip nc ifconfig timeout; do
  ln -sf busybox "$I/bin/$a"
done
# storage + network modules for early userspace (loop, squashfs, overlay,
# iso9660, virtio_net — all =m on this kernel; resolve deps recursively)
MODS_DONE=""
copy_mod() {
  local m="$1" ko dep
  case " $MODS_DONE " in *" $m "*) return 0;; esac
  MODS_DONE="$MODS_DONE $m"
  KO=$(modinfo -n "$m" 2>/dev/null || find "$MODDIR/kernel" -name "$m.ko" 2>/dev/null | head -1)
  [[ -n "$KO" && -f "$KO" ]] || die "module not found: $m"
  cp "$KO" "$I/lib/modules/"
  for dep in $(modinfo -F depends "$KO" 2>/dev/null | tr ',' ' '); do
    [[ -n "$dep" ]] && copy_mod "$dep"
  done
}
for m in loop squashfs overlay isofs virtio_net; do copy_mod "$m"; done
cat > "$I/init" <<'INIT_EOF'
#!/bin/sh
# omarchy-arm live init: ISO -> squashfs -> overlay -> switch_root
export PATH=/bin:/sbin
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sys /sys 2>/dev/null
mount -t devtmpfs dev /dev 2>/dev/null
echo "[live-init] loading drivers"
for pass in 1 2 3; do
  for m in /lib/modules/*.ko; do insmod "$m" 2>/dev/null; done
done
ISO_DEV=""
for kv in $(cat /proc/cmdline); do
  case "$kv" in iso_dev=*) ISO_DEV="${kv#iso_dev=}";; esac
done
if [ "$ISO_DEV" = "auto" ] || [ -z "$ISO_DEV" ]; then
  echo "[live-init] scanning for ISO device"
  mark SCAN_START 2049
  # NOTE: single mount-try path only (busybox blkid was observed to hang on
  # some ATAPI devices). Every attempt is timeout-guarded; TRY_* shows the
  # latest attempt on the scratch-disk breadcrumb trail.
  for d in /dev/sr0 /dev/sr1 /dev/sr[0-9]* /dev/hd[a-z] /dev/sd[a-z] /dev/vd[a-z] /dev/nvme[0-9]n[0-9]; do
    [ -b "$d" ] || continue
    mark "TRY_$d" 2060
    if timeout 20 mount -t iso9660 -o ro "$d" /iso 2>/dev/null; then
      if [ -f /iso/omarchy.sfs ]; then ISO_DEV="$d"; umount /iso; break; fi
      umount /iso 2>/dev/null
    fi
  done
fi
[ -n "$ISO_DEV" ] || { echo "[live-init] FATAL: no ISO device found"; exec sh; }
echo "[live-init] ISO on $ISO_DEV"
mark "ISO_DEV=$ISO_DEV" 2050
mount -t iso9660 -o ro "$ISO_DEV" /iso || { echo "[live-init] FATAL: ISO mount failed"; exec sh; }
mark ISO_MOUNTED 2052
mount -t squashfs -o loop,ro /iso/omarchy.sfs /sfs || { echo "[live-init] FATAL: squashfs mount failed"; exec sh; }
mark SFS_MOUNTED 2054
mount -t tmpfs tmpfs /ovl
mkdir -p /ovl/upper /ovl/work
# black-box breadcrumb trail: with live_debug=1 on the cmdline, write stage
# markers to the scratch disk (/dev/sda) so the host can read them back with
# dd even when network/console are unavailable. Never touches user data
# (installer wipes the target disk anyway).
LIVE_DEBUG=0
for kv in $(cat /proc/cmdline); do
  case "$kv" in live_debug=1) LIVE_DEBUG=1;; esac
done
mark() {
  [ "$LIVE_DEBUG" = "1" ] || return 0
  echo "LIVE $1 up=$(cat /proc/uptime 2>/dev/null)" | dd of=/dev/sda bs=512 seek=$2 conv=notrunc 2>/dev/null || true
}
mark INIT_START 2048
# debug stream: best-effort kmsg over TCP to the build host (10.211.55.2:4499)
# NOTE: interface names are unpredictable (enp0s5, not eth0) — try them all
(
  ip link set lo up 2>/dev/null
  for IF in $(ls /sys/class/net 2>/dev/null | grep -v '^lo$'); do
    ip link set "$IF" up 2>/dev/null
    ip addr add 10.211.55.9/24 dev "$IF" 2>/dev/null
  done
  echo '=== omarchy-arm-iso kmsg ==='
  while true; do
    cat /proc/kmsg 2>/dev/null | nc 10.211.55.2 4499 2>/dev/null
    sleep 5
  done
) &
mount -t overlay overlay -o lowerdir=/sfs,upperdir=/ovl/upper,workdir=/ovl/work /sysroot \
  || { echo "[live-init] FATAL: overlay mount failed"; exec sh; }
# neutralize installer-time fstab (points at the build machine's disks)
: > /sysroot/etc/fstab
# optional live SSH key (builder substitutes __LIVE_SSH_KEY__ with a pubkey,
# or with the empty string for release builds)
LIVE_SSH_KEY="__LIVE_SSH_KEY__"
if [ -n "$LIVE_SSH_KEY" ]; then
  mkdir -p /sysroot/root/.ssh
  echo "$LIVE_SSH_KEY" > /sysroot/root/.ssh/authorized_keys
  chmod 700 /sysroot/root/.ssh
  chmod 600 /sysroot/root/.ssh/authorized_keys
  echo "[live-init] live SSH key installed"
fi
mount --move /proc /sysroot/proc 2>/dev/null
mount --move /sys /sysroot/sys 2>/dev/null
mount --move /dev /sysroot/dev 2>/dev/null
echo "[live-init] switching to Omarchy"
mark PRE_SWITCH_ROOT 2056
exec switch_root /sysroot /sbin/init
INIT_EOF
chmod +x "$I/init"
if [[ -n "$INJECT_KEY" ]]; then
  log "injecting live SSH key into initramfs (testing only — omit for release builds)"
  KEYDATA=$(cat "$INJECT_KEY")
  sed -i "s|__LIVE_SSH_KEY__|${KEYDATA}|g" "$I/init"
else
  sed -i "s|__LIVE_SSH_KEY__||g" "$I/init"
fi
(cd "$I" && find . -print0 | LC_ALL=C sort -z | cpio -0 -o -H newc --owner 0:0 2>/dev/null | gzip -9 > "$WORK/initramfs-live.img")
ls -la "$WORK/initramfs-live.img"

# ---------- 3. EFI FAT image ----------
log "building EFI boot image"
# NOTE: FAT size is informational only (EDK2 sizes the image from the FAT
# itself), but keep it snug: Image (~50M) + gzipped live initramfs + bootloader.
FAT="$WORK/efiboot.img"
python3 -c "open('$FAT','wb').truncate(100*1024*1024)"
LOOP=$(losetup -f --show "$FAT")
mkfs.fat -F 32 -n OMARCHYLIVE "$LOOP" >/dev/null
mount "$LOOP" "$WORK/esp-mnt"
mkdir -p "$WORK/esp-mnt/EFI/BOOT" "$WORK/esp-mnt/loader/entries"
cp /usr/lib/systemd/boot/efi/systemd-bootaa64.efi "$WORK/esp-mnt/EFI/BOOT/BOOTAA64.EFI"
cp /boot/Image "$WORK/esp-mnt/"
cp "$WORK/initramfs-live.img" "$WORK/esp-mnt/"
cat > "$WORK/esp-mnt/loader/loader.conf" <<'EOF'
timeout 5
default live
console-mode keep
EOF
cat > "$WORK/esp-mnt/loader/entries/live.conf" <<'EOF'
title   Omarchy ARM (live ISO)
linux   /Image
initrd  /initramfs-live.img
options iso_dev=auto live_debug=1 rw console=tty0 loglevel=4 tryomarchy.ssh_access=1 systemd.show_status=false mitigations=off nowatchdog
EOF
umount "$WORK/esp-mnt"; losetup -d "$LOOP"

# ---------- 4. ISO tree + El Torito ----------
log "assembling ISO tree"
R="$WORK/iso-root"
mkdir -p "$R/EFI/BOOT" "$R/boot" "$R/loader/entries"
cp "$FAT" "$R/EFI/BOOT/efiboot.img"
cp /boot/Image "$R/boot/"
cp "$WORK/initramfs-live.img" "$R/boot/"
cp "$0" "$R/omarchy-arm-install.sh" 2>/dev/null || true
# installer rides along (copied next to this script, or fetched separately)
if [[ -f "$(dirname "$0")/omarchy-arm-install.sh" ]]; then
  cp "$(dirname "$0")/omarchy-arm-install.sh" "$R/"
fi

log "running xorriso (El Torito EFI boot)"
# NOTE: -boot-load-size is load-bearing. xorriso writes 0 as the El Torito
# sector count for -no-emul-boot unless told otherwise, and strict EFI
# implementations (Parallels: IsBootable=0) reject a 0 count. EDK2-derived
# firmware determines the real image size from the FAT itself, so the dummy
# value 4 (conventional, same as Ubuntu ARM ISOs) is safe.
xorriso -as mkisofs -o "$OUT_DIR/$ISO_NAME" -V "$LABEL" \
  -J -joliet-long -r \
  -e EFI/BOOT/efiboot.img -no-emul-boot -boot-load-size 4 \
  "$R"
log "adding GPT+ESP hybrid (internal FAT reference, own script — xorriso 1.5.x
  cannot do this in one -as mkisofs pass and its -dev mode drops El Torito)"
python3 "$(dirname "$0")/hybridize.py" "$OUT_DIR/$ISO_NAME" EFI/BOOT/EFIBOOT.IMG
sha256sum "$OUT_DIR/$ISO_NAME" | tee "$OUT_DIR/$ISO_NAME.sha256"
ls -la "$OUT_DIR/$ISO_NAME"

# ---------- 5. verify ----------
log "verifying ISO"
xorriso -indev "$OUT_DIR/$ISO_NAME" -report_el_torito plain 2>&1 | grep -iE "boot|efi" | head -4
mkdir -p "$WORK/verify" && mount -o loop,ro "$OUT_DIR/$ISO_NAME" "$WORK/verify" \
  && ls "$WORK/verify/" && unsquashfs -s "$WORK/verify/omarchy.sfs" | head -6 \
  && umount "$WORK/verify"
echo
log "done: $OUT_DIR/$ISO_NAME"
echo "    boot it as a CD in Parallels/UTM/QEMU (aarch64, UEFI)."
echo "    live session runs the installer:  sudo omarchy-arm-install /dev/sdX"
