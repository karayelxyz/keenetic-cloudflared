## Installation Guide

### Step 1: Cloudflare Dashboard Configuration

1. Go to [dash.cloudflare.com](https://dash.cloudflare.com).
2. Click on **Zero Trust** in the left sidebar. On the Cloudflare One page that opens, go to **Network** -> **Tunnels & Mesh** -> **Create a tunnel**.
3. Copy and save the **token** provided in the installation command/script block by Cloudflare.
4. Go to **Rules** -> **Overview** -> **Request Header Transform Rules** -> **Create rule**:
   * **Rule name:** Keenetic Bypass
   * **Field:** hostname
   * **Operator:** equals
   * **Value:** *your tunnel domain*
   * **Then section (Remove):**
     * Origin
     * Referer
     * Sec-Ch-Ua
     * Sec-Ch-Ua-Mobile
     * Sec-Ch-Ua-Platform
     * Sec-Gpc
5. Go to **Rules** -> **Page Rules** -> **Create Page Rule**:
   * **URL:** *your tunnel domain*
   * **Then settings:**
     * Rocket Loader: Disabled
     * Browser Cache TTL: Bypass / 2 min
     * Cache Level: Bypass

---

### Step 2: Router Installation

6. Connect to your router via **SSH**.
7. Download the installation script:

```bash
wget -qO- https://raw.githubusercontent.com/karayelxyz/keenetic-cloudflared/main/install_cloudflared.sh | sh
```

### Available Commands
These commands can be used after the script is installed:
| Commands                 | Description                                                      |
|--------------------------|------------------------------------------------------------------|
| cloudflared start        | Start the tunnel service                                         |
| cloudflared stop         | Stop the tunnel service                                          |
| cloudflared restart      | Restart the tunnel service                                       |
| cloudflared status       | Check the current running status                                 |
| cloudflared token XXXXXX | Update your tunnel token and restart the service                 |
| cloudflared logs         | Stream live connection logs (tail -f)                            |
| cloudflared remove       | Completely remove cloudflared, binaries, logs, and service files |
