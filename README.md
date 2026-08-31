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
- **Auto service** — creates `S99cloudflared` init script, runs on boot, manages PID & logs
- **Simple CLI** — `cloudflared start|stop|restart|status|token|logs|remove`
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

#### Available Commands

| Command | Description |
|---------|-------------|
| `cloudflared start` | Start the tunnel service |
| `cloudflared stop` | Stop the tunnel service |
| `cloudflared restart` | Restart the tunnel service |
| `cloudflared status` | Check running status (`running` / `stopped`) |
| `cloudflared token XXXXXX` | Update tunnel token and restart |
| `cloudflared logs` | Stream live logs (`tail -f /opt/var/log/cloudflared.log`) |
| `cloudflared remove` | Completely remove binaries, service and logs |

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
