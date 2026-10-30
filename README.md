<p align="center">
  <h1 align="center">☁️ Keenetic Cloudflared</h1>
  <p align="center">
    <strong>Cloudflare Tunnel installer for Keenetic / Netcraze routers</strong><br/>
    Lightweight <code>cloudflared</code> setup for <code>arm64</code> & <code>mipsle</code> — no Entware hassle, one command install.
  </p>
  <p align="center">
    <a href="https://github.com/karayelxyz/keenetic-cloudflared/blob/main/LICENSE"><img src="https://img.shields.io/github/license/karayelxyz/keenetic-cloudflared?style=flat-square&color=orange" alt="License: MIT"/></a>
    <img src="https://img.shields.io/badge/platform-Keenetic%20%2F%20Netcraze-0066CC?style=flat-square" alt="Platform"/>
    <img src="https://img.shields.io/badge/arch-arm64%20%7C%20mipsle-success?style=flat-square" alt="Arch"/>
    <img src="https://img.shields.io/badge/cloudflared-tunnel-F38020?style=flat-square&logo=cloudflare&logoColor=white" alt="Cloudflare Tunnel"/>
  </p>
</p>

---

## ✨ Features

- **One-line installer** — auto-detects `arm64` / `mipsle` and installs the correct binary to `/opt/bin`
- **Self-healing service** — `S99cloudflared` init script with a watchdog that restarts the tunnel within 5 s of a crash
- **Truthful status** — reports both the supervisor and the tunnel PID, and never deletes its own state files
- **Self-updating** — a daily check swaps in the newest release from this repository and restarts the tunnel
- **Simple CLI** — `cloudflared start|stop|restart|status|update|token|logs|remove`
- **No dependencies** — works with `wget` / `wget-ssl` / `curl`

## ✅ Compatibility

| Router Family | Architecture | Binary | Status |
|---------------|--------------|--------|--------|
| Keenetic Hopper, Titan, Peak, etc. (ARM) | `aarch64` / `arm64` | `cloudflared` | ✅ Tested |
| Keenetic Extra, Omni, Viva, etc. (MIPS) | `mipsle` | `cloudflared-mipsle` | ✅ Tested |

> Requires USB storage or internal `/opt` with Entware-ready partition.

## 🚀 Installation

**1.** Create a tunnel and copy the token:

Go to [dash.cloudflare.com](https://dash.cloudflare.com) → **Zero Trust** → **Network** → **Tunnels & Mesh** → **Create a tunnel** → copy the **token** from the install command.

**2.** Connect to your router via **SSH**.

**3.** Run the installer:

```bash
wget -qO- https://raw.githubusercontent.com/karayelxyz/keenetic-cloudflared/main/install_cloudflared.sh | sh
```

> The script will prompt `Cloudflare Tunnel Token:` — paste your token and it will automatically start the service.
>
> Re-running the installer updates the binary. On an existing installation press **Enter** at the prompt to keep the current token.
>
> cloudflared's built-in autoupdater is disabled (`--no-autoupdate`): it shuts the process down and relaunches itself detached with a new PID, which makes the PID file stale and leaves two processes behind. On `mipsle` it is dangerous as well, because Cloudflare publishes no build for that architecture — see [Automatic updates](#-automatic-updates).

#### Available Commands

| Command | Description |
|---------|-------------|
| `cloudflared start` | Start the tunnel service (no-op if already running) |
| `cloudflared stop` | Stop the supervisor and the tunnel, then clean up state files |
| `cloudflared restart` | Restart the tunnel service |
| `cloudflared status` | Check running status with supervisor and tunnel PIDs (`running` / `stopped`) |
| `cloudflared update` | Check this repository for a newer release and apply it (exit `0` when updated) |
| `cloudflared token XXXXXX` | Update tunnel token and restart |
| `cloudflared logs` | Stream live logs (`tail -f /opt/var/log/cloudflared.log`) |
| `cloudflared remove` | Completely remove binaries, service and logs |

---

## 🔄 Automatic Updates

The service checks this repository's latest release once a day. The installed tag lives in `/opt/etc/cloudflared.version`; when the feed reports a different tag, the new binary is downloaded to `/opt/bin/cloudflared-bin.new`, validated as a real ELF file, renamed over the old one and the tunnel is restarted by the watchdog. A failed download leaves the installed binary untouched.

```bash
cloudflared update      # trigger the check now instead of waiting for the daily run
```

The check needs `https://api.github.com` to be reachable. If it is not (offline router, rate limit), the check is silently skipped and retried the next day.

---

## ⚙️ Additional Configuration (Optional)

> **Optional** — only if you want to access your **Keenetic dashboard remotely** via your tunnel domain. The repository is primarily an installer; this section is just an extra guide.

**1. Request Header Transform Rule** → **Rules** → **Overview** → **Request Header Transform Rules** → **Create rule**:

- **Rule name:** `Keenetic Dashboard`
- **When:** `hostname equals your-tunnel-domain`
- **Then → Remove headers:**
  `Origin`, `Referer`, `Sec-Ch-Ua`, `Sec-Ch-Ua-Mobile`, `Sec-Ch-Ua-Platform`, `Sec-Gpc`

**2. Page Rule** → **Rules** → **Page Rules** → **Create Page Rule**:

- **URL:** `your-tunnel-domain/*`
- **Settings:**
  - Rocket Loader: **Off**
  - Browser Cache TTL: **Bypass**
  - Cache Level: **Bypass**
