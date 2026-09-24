#!/usr/bin/env python3
"""omarchy-parallels MCP server (stdio).

Exposes the exact operations used to build, debug, and operate the Omarchy
ARM VM on Parallels Desktop as MCP tools:

  vm_status      machine-readable host+guest state probe
  vm_screenshot  guest screen capture (framebuffer, or Hyprland/desktop via grim)
  vm_exec        run a shell command in the guest as root over SSH
  vm_display_get current Hyprland mode/scale
  vm_display_set pin a Hyprland mode+scale (monitors.lua + reload)

Transport: newline-delimited JSON-RPC 2.0 on stdio (MCP stdio transport).
Dependencies: none (stdlib only) + the `ssh` binary + a reachable guest.

Configuration (environment, all optional):
  OMARCHY_VM_NAME  Parallels VM name            (default "Omarchy ARM")
  OMARCHY_SSH_KEY  private key for root@guest   (default ~/.ssh/id_ed25519)
  OMARCHY_SSH_USER ssh user                     (default "root")
  OMARCHY_GUEST_IP guest IP; auto-detected from Parallels DHCP leases if unset
  OMARCHY_SSH_TIMEOUT seconds per ssh call      (default 15)
"""

import base64
import json
import os
import socket
import struct
import subprocess
import sys
import zlib

PROTOCOL_VERSIONS = ("2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25")
SERVER_VERSION = "1.0.0"
LEASES = "/Library/Preferences/Parallels/parallels_dhcp_leases"
MAX_OUT = 20000


def cfg():
    home = os.path.expanduser("~")
    return {
        "vm": os.environ.get("OMARCHY_VM_NAME", "Omarchy ARM"),
        "key": os.environ.get("OMARCHY_SSH_KEY", os.path.join(home, ".ssh", "id_ed25519")),
        "user": os.environ.get("OMARCHY_SSH_USER", "root"),
        "ip": os.environ.get("OMARCHY_GUEST_IP", ""),
        "timeout": int(os.environ.get("OMARCHY_SSH_TIMEOUT", "15")),
    }


def guest_ip(c):
    if c["ip"]:
        return c["ip"]
    try:
        with open(LEASES) as f:
            txt = f.read()
    except OSError:
        return ""
    import re
    hits = re.findall(r"10\.211\.55\.\d+", txt)
    return hits[-1] if hits else ""


def ssh(c, remote_cmd, timeout=None, raw=False):
    ip = guest_ip(c)
    if not ip:
        raise RuntimeError("guest IP unknown (no OMARCHY_GUEST_IP and no DHCP lease found)")
    cmd = ["ssh", "-i", c["key"], "-o", "BatchMode=yes",
           "-o", f"ConnectTimeout={c['timeout']}",
           "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
           f"{c['user']}@{ip}", remote_cmd]
    try:
        p = subprocess.run(cmd, capture_output=True,
                           timeout=timeout or c["timeout"] + 10)
    except FileNotFoundError:
        raise RuntimeError("ssh binary not found")
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"ssh timed out after {timeout or c['timeout']}s")
    out = p.stdout if raw else p.stdout.decode(errors="replace")
    err = p.stderr.decode(errors="replace")
    return p.returncode, out, err


def text(s):
    return {"content": [{"type": "text", "text": s}]}


def image(png_bytes, note=""):
    return {"content": [
        {"type": "image", "data": base64.b64encode(png_bytes).decode(),
         "mimeType": "image/png"},
        {"type": "text", "text": note or "guest screenshot (PNG)"},
    ]}


def png_from_bgra(data, w, h):
    need = w * h * 4
    if len(data) < need:
        raise RuntimeError(f"framebuffer short read ({len(data)} < {need})")
    rows = bytearray()
    for y in range(h):
        rows += b"\x00"
        base = y * w * 4
        for x in range(w):
            i = base + x * 4
            rows += bytes((data[i + 2], data[i + 1], data[i]))
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + \
            struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(rows), 6))
            + chunk(b"IEND", b""))


def hypr_env(c):
    return ('SIG=$(ls /run/user/1000/hypr/ 2>/dev/null | head -1); '
            'U=$(awk -F: \'$3>=1000 && $3<60000 {print $1; exit}\' /etc/passwd); '
            '[ -n "$SIG" ] && [ -n "$U" ] || { echo "no-hypr-session"; exit 3; } '
            '&& sudo -u $U env XDG_RUNTIME_DIR=/run/user/1000 '
            'WAYLAND_DISPLAY=wayland-1 HYPRLAND_INSTANCE_SIGNATURE=$SIG ')


# ---------------- tools ----------------

def t_status(c, a):
    lines = []
    reg = subprocess.run(["prlctl", "list", "-a"], capture_output=True,
                         text=True, timeout=20)
    hit = [l for l in reg.stdout.splitlines() if c["vm"] in l]
    lines.append(f"vm_registered={'true' if hit else 'false'}")
    if hit:
        lines.append("vm_uuid=" + hit[0].split()[0])
    ip = guest_ip(c)
    lines.append(f"guest_ip={ip or 'unknown'}")
    if ip:
        s = socket.socket()
        s.settimeout(3)
        try:
            s.connect((ip, 22))
            lines.append("ssh_port=open")
        except OSError:
            lines.append("ssh_port=closed")
        finally:
            s.close()
        try:
            rc, out, _ = ssh(c, "uname -r; systemctl is-active prltoolsd; "
                             "cat /sys/class/graphics/fb0/virtual_size")
            if rc == 0:
                o = out.strip().splitlines()
                lines.append(f"guest_kernel={o[0] if len(o) > 0 else '?'}")
                lines.append(f"guest_tools={o[1] if len(o) > 1 else '?'}")
                lines.append(f"guest_fb={o[2] if len(o) > 2 else '?'}")
            else:
                _, _, err = ssh(c, "true")
                hint = err.strip().splitlines()
                lines.append(f"guest_ssh=failed ({hint[-1] if hint else f'exit {rc}'})")
        except RuntimeError as e:
            lines.append(f"guest_ssh=error ({e})")
    return text("\n".join(lines))


def t_screenshot(c, a):
    method = (a.get("method") or "auto").lower()
    if method not in ("auto", "framebuffer", "desktop"):
        raise ValueError("method must be auto|framebuffer|desktop")
    if method in ("auto", "framebuffer"):
        try:
            rc, size, err = ssh(c, "cat /sys/class/graphics/fb0/virtual_size")
            if rc == 0 and "," in size:
                w, h = (int(x) for x in size.strip().split(","))
                _, raw, _ = ssh(c, "dd if=/dev/fb0 bs=1M 2>/dev/null", raw=True)
                return image(png_from_bgra(raw, w, h),
                             f"framebuffer {w}x{h}")
        except RuntimeError as e:
            if method == "framebuffer":
                raise
    # desktop path (Hyprland owns DRM): grim over ssh, PNG on stdout
    rc, out, err = ssh(c, hypr_env(c) + "grim -", raw=True, timeout=40)
    if rc != 0:
        tail = (out[-500:] if isinstance(out, bytes) else out).decode(errors="replace") \
            if isinstance(out, bytes) else str(out)
        raise RuntimeError(f"desktop capture failed (no Hyprland session?): {tail or err}")
    if not out.startswith(b"\x89PNG"):
        raise RuntimeError("desktop capture did not return PNG data")
    return image(out, "Hyprland desktop via grim")


def t_exec(c, a):
    command = a.get("command", "")
    if not command:
        raise ValueError("command is required")
    timeout = min(int(a.get("timeout", 60)), 300)
    rc, out, err = ssh(c, command, timeout=timeout)
    if isinstance(out, bytes):
        out = out.decode(errors="replace")
    body = (out or "")[-MAX_OUT:]
    if err.strip():
        body += "\n[stderr]\n" + err.strip()[-2000:]
    return text(f"[exit {rc}]\n{body}")


def t_display_get(c, a):
    rc, out, err = ssh(c, hypr_env(c) + "hyprctl monitors")
    if rc != 0:
        raise RuntimeError(f"hyprctl failed: {err.strip() or out}")
    return text(out.strip())


def t_display_set(c, a):
    mode = a.get("mode", "2560x1600")
    scale = a.get("scale", 2)
    try:
        scale_f = float(scale)
    except (TypeError, ValueError):
        raise ValueError("scale must be a number")
    lua = (f'-- managed by omarchy-parallels MCP\\n'
           f'local omarchy_gdk_scale = 2\\n'
           f'local omarchy_monitor_scale = {scale_f:g}\\n'
           f'hl.env("GDK_SCALE", tostring(omarchy_gdk_scale))\\n'
           f'hl.monitor({{ output = "Virtual-1", mode = "{mode}", '
           f'position = "0x0", scale = {scale_f:g} }})\\n')
    script = (hypr_env(c)
              + f'U_HOME=$(getent passwd $U | cut -d: -f6); '
              + f'printf %s \'{lua}\' > "$U_HOME/.config/hypr/monitors.lua"; '
              + 'chown $U "$U_HOME/.config/hypr/monitors.lua"; '
              + 'hyprctl reload && sleep 2 && hyprctl monitors | head -3')
    rc, out, err = ssh(c, script)
    if rc != 0:
        raise RuntimeError(f"display change failed: {err.strip() or out}")
    return text(out.strip())


TOOLS = [
    {"name": "vm_status",
     "description": "Probe the Omarchy ARM Parallels VM: registration, guest IP, SSH reachability, kernel version, Parallels Tools state, framebuffer size.",
     "inputSchema": {"type": "object", "properties": {
         "vm_name": {"type": "string", "description": "Override OMARCHY_VM_NAME for this call"}}}},
    {"name": "vm_screenshot",
     "description": "Capture the guest screen as PNG. Framebuffer is instant but only shows the text console once Hyprland owns DRM; 'desktop' uses grim inside the Hyprland session; 'auto' tries framebuffer then desktop.",
     "inputSchema": {"type": "object", "properties": {
         "method": {"type": "string", "enum": ["auto", "framebuffer", "desktop"],
                    "description": "Capture path (default auto)"}}}},
    {"name": "vm_exec",
     "description": "Run a shell command in the guest as root over SSH. Output truncated to 20KB. Prefer specific read-only commands; the guest is a full Omarchy desktop you can change.",
     "inputSchema": {"type": "object", "properties": {
         "command": {"type": "string", "description": "Shell command to run"},
         "timeout": {"type": "integer", "description": "Seconds (default 60, max 300)"}},
      "required": ["command"]}},
    {"name": "vm_display_get",
     "description": "Show Hyprland monitor state (mode, scale, position) via hyprctl.",
     "inputSchema": {"type": "object", "properties": {}}},
    {"name": "vm_display_set",
     "description": "Pin the Hyprland monitor rule (writes monitors.lua, reloads). Use when the desktop looks too big/small: higher scale = bigger UI. Known-good modes: 1160x768, 1920x1440, 2560x1600, 4096x2160.",
     "inputSchema": {"type": "object", "properties": {
         "mode": {"type": "string", "description": "e.g. 2560x1600 (default)"},
         "scale": {"type": "number", "description": "e.g. 2 (default)"}}}},
]

HANDLERS = {"vm_status": t_status, "vm_screenshot": t_screenshot,
            "vm_exec": t_exec, "vm_display_get": t_display_get,
            "vm_display_set": t_display_set}


# ---------------- JSON-RPC loop ----------------

def reply(rid, result=None, error=None):
    msg = {"jsonrpc": "2.0", "id": rid}
    if error is not None:
        msg["error"] = error
    else:
        msg["result"] = result if result is not None else {}
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def err(rid, code, message):
    reply(rid, error={"code": code, "message": message})


def main():
    c = cfg()
    if len(sys.argv) > 1 and sys.argv[1] in ("--help", "-h"):
        print(__doc__)
        return
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            reply(None, error={"code": -32700, "message": "Parse error"})
            continue
        rid, method, params = msg.get("id"), msg.get("method"), msg.get("params") or {}
        if method == "initialize":
            want = params.get("protocolVersion", "")
            ver = want if want in PROTOCOL_VERSIONS else "2024-11-05"
            reply(rid, {"protocolVersion": ver,
                        "capabilities": {"tools": {}},
                        "serverInfo": {"name": "omarchy-parallels",
                                       "version": SERVER_VERSION}})
        elif method in ("notifications/initialized", "notifications/cancelled"):
            pass
        elif method == "ping":
            reply(rid, {})
        elif method == "tools/list":
            reply(rid, {"tools": TOOLS})
        elif method == "tools/call":
            name, args = params.get("name", ""), params.get("arguments") or {}
            fn = HANDLERS.get(name)
            if fn is None:
                err(rid, -32602, f"unknown tool: {name}")
                continue
            if not isinstance(args, dict):
                err(rid, -32602, "arguments must be an object")
                continue
            try:
                cc = dict(c)
                if name == "vm_status" and args.get("vm_name"):
                    cc["vm"] = args["vm_name"]
                reply(rid, fn(cc, args))
            except ValueError as e:
                err(rid, -32602, str(e))
            except RuntimeError as e:
                err(rid, -32000, str(e))
            except Exception as e:  # never break the loop
                err(rid, -32000, f"internal error: {e}")
        else:
            if rid is not None:
                err(rid, -32601, f"method not found: {method}")


if __name__ == "__main__":
    main()
