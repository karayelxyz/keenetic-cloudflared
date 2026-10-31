#!/bin/sh
# Cloudflare Tunnel installer for Keenetic/Entware routers.
#
# Layout created by this script:
#   /opt/bin/cloudflared-bin            the real binary
#   /opt/bin/cloudflared                user facing wrapper
#   /opt/etc/init.d/S99cloudflared      service with the supervisor loop
#   /opt/etc/cloudflared-helpers.sh     HTTPS helpers, one copy only
#   /opt/etc/cloudflared.version        installed release tag
#   /opt/etc/cloudflared.script-version version marker of the installed scripts
#   /opt/var/log/cloudflared.log        tunnel log
#
# The built-in cloudflared updater stays disabled (--no-autoupdate): it restarts
# the process detached with a new PID, which leaves a stale PID file behind, and
# on mipsle it would replace our own build with a foreign architecture. Updates
# are done by this project's release feed instead (see auto_update in helpers).

ARCH=$(uname -m)
case "$ARCH" in
    aarch64|arm64) ASSET="cloudflared" ;;
    mipsel)        ASSET="cloudflared-mipsle" ;;
    mips)          echo "[-] $ARCH is big-endian MIPS; only a little-endian (mipsle) build is published."
                   exit 1 ;;
    *)             echo "[-] Unsupported architecture: $ARCH."
                   exit 1 ;;
esac

ASSET_URL="https://github.com/karayelxyz/keenetic-cloudflared/releases/latest/download/$ASSET"
HELPERS="/opt/etc/cloudflared-helpers.sh"
SERVICE="/opt/etc/init.d/S99cloudflared"
WRAPPER="/opt/bin/cloudflared"

# Bump whenever the generated files change, so a router can tell whether its
# copies of the scripts are older than what the repository publishes.
SCRIPT_VERSION="2026.10.31.1"

echo "[*] Architecture: $ARCH"

if [ -x "$SERVICE" ]; then
    "$SERVICE" stop >/dev/null 2>&1 || true
fi
killall cloudflared cloudflared-bin 2>/dev/null || true
rm -f /opt/var/run/cloudflared.pid /opt/var/run/cloudflared.stop /opt/var/run/cloudflared.checker.pid

mkdir -p /opt/var/log /opt/var/run /opt/etc/init.d

# --- shared helpers ---------------------------------------------------------
# Sourced by both this installer and the service script, so the download logic
# exists in exactly one place.
cat << 'HLP' > "$HELPERS"
# Shared helpers for the Keenetic cloudflared package.
# Sourced by install_cloudflared.sh and S99cloudflared. Do not edit by hand.

ASSET_URL="__ASSET_URL__"
API_URL="https://api.github.com/repos/karayelxyz/keenetic-cloudflared/releases/latest"
BIN="/opt/bin/cloudflared-bin"
VERSION_FILE="/opt/etc/cloudflared.version"
SCRIPT_FILE="/opt/etc/cloudflared.script-version"
SCRIPT_URL="https://raw.githubusercontent.com/karayelxyz/keenetic-cloudflared/main/install_cloudflared.sh"
CURL="$(command -v curl 2>/dev/null)"

# The busybox wget that comes first in PATH cannot speak HTTPS, so the Entware
# tools are tried explicitly. curl comes first because it always sends a
# User-Agent header, which the GitHub API requires.
_http_tools() {
    for _c in /opt/bin/curl /opt/bin/wget /opt/libexec/wget-ssl wget wget-ssl curl; do
        case "$_c" in
            /*) [ -x "$_c" ] || continue ;;
            *)  command -v "$_c" >/dev/null 2>&1 || continue ;;
        esac
        echo "$_c"
    done
}

# http_get <url> - print the body, fail when nothing was fetched.
http_get() {
    for _c in $(_http_tools); do
        case "$_c" in
            *curl*) _body=$("$_c" -fsSL --max-time 10 "$1" 2>/dev/null) ;;
            *)      _body=$("$_c" -q -O - -T 10 "$1" 2>/dev/null) ;;
        esac
        if [ -n "$_body" ]; then
            printf '%s\n' "$_body"
            return 0
        fi
    done
    return 1
}

# http_download <url> <path> - store the body, accept only a real ELF binary.
http_download() {
    for _c in $(_http_tools); do
        rm -f "$2"
        case "$_c" in
            *curl*) "$_c" -fsSL -o "$2" "$1" 2>/dev/null ;;
            *)      "$_c" -q -O "$2" "$1" 2>/dev/null ;;
        esac
        if [ -s "$2" ] && head -c 4 "$2" 2>/dev/null | grep -q ELF; then
            return 0
        fi
    done
    rm -f "$2"
    return 1
}

# latest_tag - newest published release tag, fails when the feed is unreadable.
latest_tag() {
    _json=$(http_get "$API_URL") || return 1
    _tag=$(printf '%s\n' "$_json" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
    [ -n "$_tag" ] || return 1
    printf '%s\n' "$_tag"
}

# script_version - version marker of the scripts installed on this router.
script_version() {
    cat "$SCRIPT_FILE" 2>/dev/null
}

# published_script_version - version marker currently published in the repo.
# curl only: the Entware wget builds ignore their own timeout against an
# unreachable host and would freeze status for minutes.
published_script_version() {
    [ -n "$CURL" ] || return 1
    "$CURL" -fsSL --connect-timeout 3 --max-time 5 "$SCRIPT_URL" 2>/dev/null |
        sed -n 's/^SCRIPT_VERSION="\(.*\)"$/\1/p' | head -n 1
}

# scripts_report - freshness line for the installed scripts, empty when the
# router has no marker yet. Prints nothing on a failed check instead of blocking.
scripts_report() {
    _cur=$(script_version)
    [ -n "$_cur" ] || return 0
    _pub=$(published_script_version)
    if [ -z "$_pub" ]; then
        echo "scripts $_cur (update check failed)"
    elif [ "$_pub" = "$_cur" ]; then
        echo "scripts $_cur (up to date)"
    else
        echo "scripts $_cur (update available: $_pub)"
        echo "    Reinstall to update: wget -qO- $SCRIPT_URL | sh"
    fi
}

# tunnel_pid - PID of a running cloudflared-bin process, empty when none.
tunnel_pid() {
    for _d in /proc/[0-9]*; do
        _p=${_d#/proc/}
        [ "$_p" = "$$" ] && continue
        # A process can exit mid-scan, so skip unreadable entries quietly.
        [ -r "$_d/cmdline" ] || continue
        tr '\0' ' ' < "$_d/cmdline" | grep -q cloudflared-bin && { echo "$_p"; return 0; }
    done
    return 1
}

# auto_update - replace the binary with the newest release and restart the
# tunnel. Returns 0 when the binary was replaced, 1 when nothing changed or the
# download failed.
auto_update() {
    _new=$(latest_tag) || { echo "[!] Could not read the release feed."; return 1; }
    _cur=$(cat "$VERSION_FILE" 2>/dev/null)
    if [ "$_new" = "$_cur" ]; then
        echo "[=] Already up to date ($_cur)."
        return 1
    fi
    echo "[*] Release $_new found (installed: ${_cur:-unknown}), downloading..."
    if http_download "$ASSET_URL" "$BIN.new"; then
        chmod +x "$BIN.new"
        mv -f "$BIN.new" "$BIN"
        printf '%s\n' "$_new" > "$VERSION_FILE"
        # Renaming over a running binary is safe: the old inode stays mapped
        # until the process exits. Killing it lets the supervisor restart the
        # tunnel with the new binary.
        _p=$(tunnel_pid)
        [ -n "$_p" ] && kill "$_p" 2>/dev/null
        echo "[+] Updated to $_new."
        return 0
    fi
    rm -f "$BIN.new"
    echo "[!] Download failed, keeping the installed binary."
    return 1
}
HLP

sed -i "s|__ASSET_URL__|$ASSET_URL|" "$HELPERS"
. "$HELPERS"

# --- binary -----------------------------------------------------------------
echo "[*] Downloading $ASSET..."
if ! http_download "$ASSET_URL" "$BIN.new"; then
    echo "[-] Download failed: $ASSET_URL"
    rm -f "$BIN.new"
    exit 1
fi
chmod +x "$BIN.new"
mv -f "$BIN.new" "$BIN"

TAG=$(latest_tag 2>/dev/null)
if [ -n "$TAG" ]; then
    printf '%s\n' "$TAG" > "$VERSION_FILE"
    echo "[+] Installed release: $TAG"
else
    echo "[!] Could not read the release tag; the next update check will retry."
fi
printf '%s\n' "$SCRIPT_VERSION" > "$SCRIPT_FILE"

# --- wrapper ----------------------------------------------------------------
cat << 'WOF' > "$WRAPPER"
#!/bin/sh
SERVICE="/opt/etc/init.d/S99cloudflared"
LOG="/opt/var/log/cloudflared.log"

case "$1" in
    start|stop|restart|status|update)
        exec "$SERVICE" "$1"
        ;;
    token)
        [ -z "$2" ] && { echo "Usage: cloudflared token <TOKEN>"; exit 1; }
        NEW=$(printf '%s' "$2" | tr -d '\r\n')
        sed -i "s|^TOKEN=.*|TOKEN=\"$NEW\"|" "$SERVICE"
        echo "Token updated, restarting..."
        exec "$SERVICE" restart
        ;;
    logs)
        [ -f "$LOG" ] || { echo "No log file yet: $LOG"; exit 1; }
        # Follow only when stdout is a terminal: without one no session can
        # deliver SIGHUP, so a follower would outlive the caller.
        if [ -t 1 ]; then
            tail -n 50 -f "$LOG"
        else
            tail -n 50 "$LOG"
        fi
        ;;
    remove)
        "$SERVICE" stop
        rm -f /opt/bin/cloudflared-bin
        rm -f /opt/bin/cloudflared
        rm -f "$SERVICE"
        rm -f /opt/etc/cloudflared-helpers.sh
        rm -f /opt/etc/cloudflared.version
        rm -f /opt/etc/cloudflared.script-version
        rm -f "$LOG"
        rm -f /opt/var/run/cloudflared.pid
        rm -f /opt/var/run/cloudflared.stop
        rm -f /opt/var/run/cloudflared.checker.pid
        echo "cloudflared removed."
        ;;
    *)
        echo "Usage: cloudflared {start|stop|restart|status|update|token <TOKEN>|logs|remove}"
        exit 1
        ;;
esac
WOF
chmod +x "$WRAPPER"

# --- token ------------------------------------------------------------------
if [ -n "$1" ]; then
    TOKEN="$1"
else
    CURRENT=$(sed -n 's/^TOKEN="\(.*\)"$/\1/p' "$SERVICE" 2>/dev/null | tr -d '\r\n')
    read -p "Cloudflare Tunnel Token${CURRENT:+ [enter to keep current]}: " TOKEN </dev/tty
    [ -z "$TOKEN" ] && TOKEN="$CURRENT"
fi
# A token pasted from a CRLF terminal or copied out of a Windows file carries
# stray carriage returns, which cloudflared rejects at runtime.
TOKEN=$(printf '%s' "$TOKEN" | tr -d '\r\n')
[ -z "$TOKEN" ] && { echo "[-] Token cannot be empty."; exit 1; }

# --- service ----------------------------------------------------------------
# Two background subshells: the supervisor keeps the tunnel alive, the checker
# compares the installed release tag with the feed once a day and swaps the
# binary in place. --no-autoupdate is a global flag on this build, so it has to
# be passed before the subcommand.
cat << EOD > "$SERVICE"
#!/bin/sh
# Generated by install_cloudflared.sh.
LOG="/opt/var/log/cloudflared.log"
TOKEN="$TOKEN"
PIDFILE="/opt/var/run/cloudflared.pid"
STOPFLAG="/opt/var/run/cloudflared.stop"
CHECKPID="/opt/var/run/cloudflared.checker.pid"
. "/opt/etc/cloudflared-helpers.sh"

manager_alive() {
    _p=\$(cat "\$PIDFILE" 2>/dev/null)
    [ -n "\$_p" ] || return 1
    [ -d "/proc/\$_p" ] || return 1
    [ -r "/proc/\$_p/cmdline" ] || return 1
    tr '\0' ' ' < "/proc/\$_p/cmdline" | grep -q S99cloudflared
}

check_loop() {
    while [ ! -f "\$STOPFLAG" ]; do
        sleep 86400
        [ -f "\$STOPFLAG" ] && return 0
        auto_update >> "\$LOG" 2>&1
    done
}

case "\$1" in
    start)
        if manager_alive; then
            echo "already running (pid \$(cat "\$PIDFILE"))"
            exit 0
        fi
        rm -f "\$PIDFILE" "\$STOPFLAG" "\$CHECKPID"
        killall cloudflared cloudflared-bin 2>/dev/null || true
        (
            while [ ! -f "\$STOPFLAG" ]; do
                "\$BIN" --no-autoupdate tunnel run --token "\$TOKEN" >> "\$LOG" 2>&1
                sleep 5
            done
        ) &
        echo \$! > "\$PIDFILE"
        check_loop &
        echo \$! > "\$CHECKPID"
        echo "started (pid \$(cat "\$PIDFILE"))"
        ;;
    stop)
        touch "\$STOPFLAG"
        _c=\$(cat "\$CHECKPID" 2>/dev/null)
        [ -n "\$_c" ] && kill "\$_c" 2>/dev/null
        _p=\$(cat "\$PIDFILE" 2>/dev/null)
        if [ -n "\$_p" ] && kill -0 "\$_p" 2>/dev/null; then
            kill "\$_p" 2>/dev/null
            _n=0
            while kill -0 "\$_p" 2>/dev/null && [ "\$_n" -lt 10 ]; do
                sleep 1
                _n=\$((_n + 1))
            done
            kill -9 "\$_p" 2>/dev/null
        fi
        killall cloudflared cloudflared-bin 2>/dev/null || true
        rm -f "\$PIDFILE" "\$STOPFLAG" "\$CHECKPID"
        echo "stopped"
        ;;
    restart)
        "\$0" stop
        sleep 1
        "\$0" start
        ;;
    status)
        _t=\$(tunnel_pid)
        _rc=1
        if manager_alive; then
            echo "running (supervisor pid \$(cat "\$PIDFILE"), tunnel \${_t:-restarting})"
            _rc=0
        elif [ -n "\$_t" ]; then
            echo "running (unmanaged pid \$_t)"
            _rc=0
        else
            echo "stopped"
        fi
        scripts_report
        exit \$_rc
        ;;
    update)
        auto_update
        _rc=\$?
        scripts_report
        exit \$_rc
        ;;
    *)
        echo "Usage: \$0 {start|stop|restart|status|update}"
        exit 1
        ;;
esac
EOD

chmod +x "$SERVICE"

# --- start ------------------------------------------------------------------
echo "[*] Starting service..."
"$SERVICE" restart

echo ""
if "$SERVICE" status; then
    echo "[+] Installation complete."
else
    echo "[!] cloudflared did not start. Check: cloudflared logs"
fi
