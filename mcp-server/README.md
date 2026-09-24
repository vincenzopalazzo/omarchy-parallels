# omarchy-parallels MCP server

Stdio [MCP](https://modelcontextprotocol.io/) server that operates the Omarchy
ARM VM — the same surface used to build and debug it (no new privileges, no
new protocols: SSH to the guest + `prlctl` on the host).

Declared portably in [`../mcp.json`](../mcp.json) per the
[Agent Plugins](https://agent-plugins.org) v1.0.0 spec
(for [aaif-goose/goose#11043](https://github.com/aaif-goose/goose/issues/11043)).

## Tools

| Tool | What it does |
|---|---|
| `vm_status` | Registration, guest IP, SSH reachability, kernel, Parallels Tools state, framebuffer size |
| `vm_screenshot` | Guest screen as PNG (`method`: `auto`/`framebuffer`/`desktop` via grim) |
| `vm_exec` | Shell command in the guest as root over SSH (truncated, exit code included) |
| `vm_display_get` | Hyprland monitor state via `hyprctl` |
| `vm_display_set` | Pin Hyprland mode+scale (`monitors.lua` + reload) |

## Run it

```bash
# stdio (what MCP clients launch; OMARCHY_* env all optional)
OMARCHY_SSH_KEY=~/.ssh/id_ed25519 ./server.py
```

Configuration (environment):

| Variable | Default | Purpose |
|---|---|---|
| `OMARCHY_VM_NAME` | `Omarchy ARM` | Parallels VM name |
| `OMARCHY_SSH_KEY` | `~/.ssh/id_ed25519` | Private key for guest SSH |
| `OMARCHY_SSH_USER` | `root` | Guest SSH user |
| `OMARCHY_GUEST_IP` | *(auto from DHCP leases)* | Pin the guest IP |
| `OMARCHY_SSH_TIMEOUT` | `15` | Seconds per SSH call |

Clients supply `PLUGIN_ROOT`/`PLUGIN_DATA` per the Agent Plugins spec; the
server also works standalone (derives paths from its own location when the
env vars are absent).

## Wire it into a client

Portable declaration lives in `mcp.json`. Native equivalents:

```jsonc
// Claude Code (~/.claude.json) / goose-style MCP config
{
  "mcpServers": {
    "omarchy-parallels": {
      "command": "python3",
      "args": ["/path/to/omarchy-parallels/mcp-server/server.py"],
      "env": { "OMARCHY_SSH_KEY": "/home/you/.ssh/id_ed25519" }
    }
  }
}
```

## Smoke test

```bash
printf '%s\n' \
 '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}' \
 '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
 '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
 '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"vm_status","arguments":{}}}' \
 | OMARCHY_SSH_KEY=~/.ssh/id_ed25519 python3 server.py
```

Implementation notes: stdlib only (no `mcp` package needed), single file,
newline-delimited JSON-RPC; negotiates `2024-11-05` through `2025-11-25`;
never exits the read loop on bad input (parse errors get `-32700`, unknown
methods `-32601`, bad args `-32602`, execution failures `-32000`).
