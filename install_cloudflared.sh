#!/bin/sh
SCRIPT_VERSION="2026.11.16.2"
# ^ Bump whenever the generated files change, so a router can tell whether its
# copies of the scripts are older than what the repository publishes. The plain
# assignment sits on line 2 on purpose: the daily check reads this marker with a
# 4 KB ranged request, so it has to stay near the top of the file.
#
# Cloudflare Tunnel installer for Keenetic/Entware routers.
#
# Layout created by this script:
#   /opt/bin/cloudflared-bin            the real binary
#   /opt/bin/cloudflared                user facing wrapper
#   /opt/etc/init.d/S99cloudflared      service with the supervisor loop
#   /opt/etc/cloudflared/helpers.sh     HTTPS helpers, one copy only
#   /opt/etc/cloudflared/version        installed release tag
#   /opt/etc/cloudflared/script-version version marker of the installed scripts
#   /opt/etc/cloudflared/lastrun        UTC date of the last daily check
#   /opt/var/log/cloudflared.log        tunnel log (lines older than 30 days dropped)
#
# Only the files that must be found by name at a fixed path stay outside that
# directory: init.d is scanned by rc.unslung and /opt/bin is on PATH.
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
ETC_DIR="/opt/etc/cloudflared"
HELPERS="$ETC_DIR/helpers.sh"
SERVICE="/opt/etc/init.d/S99cloudflared"
WRAPPER="/opt/bin/cloudflared"

echo "[*] Architecture: $ARCH"

if [ -x "$SERVICE" ]; then
    "$SERVICE" stop >/dev/null 2>&1 || true
fi
killall cloudflared cloudflared-bin 2>/dev/null || true
rm -f /opt/var/run/cloudflared.pid /opt/var/run/cloudflared.stop /opt/var/run/cloudflared.checker.pid /opt/var/run/cloudflared.wait

mkdir -p /opt/var/log /opt/var/run /opt/etc/init.d "$ETC_DIR"
# State files from releases that kept them side by side in /opt/etc.
rm -f /opt/etc/cloudflared-helpers.sh /opt/etc/cloudflared.version \
      /opt/etc/cloudflared.script-version /opt/etc/cloudflared.lastrun

# --- shared helpers ---------------------------------------------------------
# Sourced by both this installer and the service script, so the download logic
# exists in exactly one place.
cat << 'HLP' > "$HELPERS"
# Shared helpers for the Keenetic cloudflared package.
# Sourced by install_cloudflared.sh and S99cloudflared. Do not edit by hand.

ASSET_URL="__ASSET_URL__"
BIN="/opt/bin/cloudflared-bin"
ETC_DIR="/opt/etc/cloudflared"
VERSION_FILE="$ETC_DIR/version"
SCRIPT_FILE="$ETC_DIR/script-version"
PIDFILE="/opt/var/run/cloudflared.pid"
WAITFIFO="/opt/var/run/cloudflared.wait"
LASTRUN="$ETC_DIR/lastrun"
LOGDIR="/opt/var/log"
LOG="$LOGDIR/cloudflared.log"
LOG_DAYS=30
SCRIPT_URL="https://raw.githubusercontent.com/karayelxyz/keenetic-cloudflared/main/install_cloudflared.sh"
CURL="$(command -v curl 2>/dev/null)"

# The busybox wget that comes first in PATH cannot speak HTTPS, so the Entware
# tools are tried explicitly. curl comes first because it always sends a
# User-Agent header and honours --max-time, unlike the Entware wget builds.
_http_tools() {
    for _c in /opt/bin/curl /opt/bin/wget /opt/libexec/wget-ssl wget wget-ssl curl; do
        case "$_c" in
            /*) [ -x "$_c" ] || continue ;;
            *)  command -v "$_c" >/dev/null 2>&1 || continue ;;
        esac
        echo "$_c"
    done
}

# http_download <url> <path> - store the body, accept only a real ELF binary.
http_download() {
    for _c in $(_http_tools); do
        rm -f "$2"
        case "$_c" in
            *curl*) "$_c" -fsSL --max-time 600 -o "$2" "$1" 2>/dev/null ;;
            *)      "$_c" -q -O "$2" "$1" 2>/dev/null ;;
        esac
        if [ -s "$2" ] && head -c 4 "$2" 2>/dev/null | grep -q ELF; then
            return 0
        fi
    done
    rm -f "$2"
    return 1
}

# latest_tag - newest published release tag, read from the redirect that the
# releases/latest URL issues. The GitHub API is deliberately not used: it allows
# 60 unauthenticated calls per hour per IP, which a shared home connection
# exhausts, and the version block then reports a false "check failed".
# curl only: the Entware wget builds ignore their own timeout against an
# unreachable host and would freeze the command for minutes.
latest_tag() {
    [ -n "$CURL" ] || return 1
    _h=$("$CURL" -sSI --max-time 10 "$ASSET_URL" 2>/dev/null)
    _tag=$(printf '%s\n' "$_h" |
        sed -n 's|.*/releases/download/\([^/"]*\)/.*|\1|p' | head -n 1)
    case "$_tag" in
        [0-9][0-9][0-9][0-9].[0-9]*.[0-9]*)
            printf '%s\n' "$_tag"
            return 0
            ;;
    esac
    return 1
}

# script_version - version marker of the scripts installed on this router.
script_version() {
    cat "$SCRIPT_FILE" 2>/dev/null
}

# published_script_version - version marker currently published in the repo.
# curl only: the Entware wget builds ignore their own timeout against an
# unreachable host and would freeze status for minutes. The marker sits near the
# top of the file, so only the first 4 KB are requested; a server that ignores
# the range answers with the whole file and the same sed still finds the marker.
published_script_version() {
    [ -n "$CURL" ] || return 1
    "$CURL" -fsSL -r 0-4095 --connect-timeout 3 --max-time 5 "$SCRIPT_URL" 2>/dev/null |
        sed -n 's/^SCRIPT_VERSION="\(.*\)"$/\1/p' | head -n 1
}

# download_script <path> <expected marker> - fetch the published installer and
# verify it before anything executes it.
download_script() {
    [ -n "$CURL" ] || return 1
    "$CURL" -fsSL --connect-timeout 5 --max-time 30 -o "$1" "$SCRIPT_URL" 2>/dev/null || return 1
    grep -q "^SCRIPT_VERSION=\"$2\"\$" "$1" 2>/dev/null || { rm -f "$1"; return 1; }
    sh -n "$1" 2>/dev/null || { rm -f "$1"; return 1; }
    return 0
}

# scripts_update [now] - apply the published scripts when their marker differs
# from the installed one. An equal marker returns at once, so the daily run does
# nothing unless the repository actually changed. Without "now" the installer
# runs detached, because it stops the service and would otherwise kill the
# caller mid-run.
scripts_update() {
    _pub=$(published_script_version 2>/dev/null)
    [ -n "$_pub" ] || return 1
    _cur=$(script_version)
    # Same rule as the binary: apply only when the published scripts are newer.
    _ver_gt "$_pub" "$_cur" || return 1
    echo "[*] Scripts: ${_cur:-unknown} -> $_pub, updating..."
    if ! download_script /tmp/cloudflared-installer.sh "$_pub"; then
        echo "[!] Could not fetch the new scripts, keeping the installed ones."
        return 1
    fi
    # The installer stops the service and rewrites this service file, so it has
    # to run detached when the caller is the service itself.
    if [ "$1" = now ]; then
        SKIP_BINARY=1 exec sh /tmp/cloudflared-installer.sh "$TOKEN"
    fi
    (
        sleep 2
        SKIP_BINARY=1 sh /tmp/cloudflared-installer.sh "$TOKEN"
        rm -f /tmp/cloudflared-installer.sh
        # The installer stops the service before it rewrites it; if it fails
        # halfway the tunnel would stay down, so make sure it is up again.
        manager_alive || /opt/etc/init.d/S99cloudflared start
    ) >> "$LOG" 2>&1 &
    return 0
}

# fmt_duration <seconds> - compact age, e.g. "2h 14m".
fmt_duration() {
    _d=$(( $1 / 86400 ))
    _h=$(( ($1 % 86400) / 3600 ))
    _m=$(( ($1 % 3600) / 60 ))
    if [ "$_d" -gt 0 ]; then
        echo "${_d}d ${_h}h"
    elif [ "$_h" -gt 0 ]; then
        echo "${_h}h ${_m}m"
    elif [ "$_m" -gt 0 ]; then
        echo "${_m}m"
    else
        echo "$1s"
    fi
}

# proc_uptime <pid> - how long the process has been running, empty when unknown.
proc_uptime() {
    _up=$(awk '{print int($1)}' /proc/uptime 2>/dev/null)
    # Field 22 of /proc/<pid>/stat is the start time in clock ticks. The comm
    # field may contain spaces or parentheses, so the prefix up to the last ")"
    # is stripped before counting fields.
    _st=$(sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | awk '{print $20}')
    [ -n "$_up" ] && [ -n "$_st" ] || return 1
    _age=$((_up - _st / 100))
    [ "$_age" -ge 0 ] || _age=0
    fmt_duration "$_age"
}

# proc_rss <pid> - resident memory of the process, empty when unknown.
proc_rss() {
    _kb=$(awk '/^VmRSS:/ {print $2}' "/proc/$1/status" 2>/dev/null)
    [ -n "$_kb" ] || return 1
    awk -v k="$_kb" 'BEGIN { printf "%d MB", (k + 512) / 1024 }'
}

# log_housekeeping - keep one log file and drop the lines older than LOG_DAYS.
# cloudflared timestamps every line in ISO-8601 UTC, so a plain string compare
# against the cutoff is enough. The file is rewritten in place instead of being
# renamed, because the tunnel holds it open with O_APPEND.
log_housekeeping() {
    [ -s "$LOG" ] || return 0
    _cut=$(date -u -d @$(( $(date -u +%s) - LOG_DAYS * 86400 )) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
    [ -n "$_cut" ] || return 0
    _tmp="$LOG.trim"
    awk -v c="$_cut" 'substr($0, 1, 1) != "2" || substr($0, 1, 20) >= c' "$LOG" > "$_tmp" 2>/dev/null ||
        { rm -f "$_tmp"; return 0; }
    if [ "$(wc -c < "$_tmp")" -lt "$(wc -c < "$LOG")" ]; then
        cat "$_tmp" > "$LOG"
    fi
    rm -f "$_tmp"
}

# manager_alive - true when the PID file points at our supervisor process.
manager_alive() {
    _p=$(cat "$PIDFILE" 2>/dev/null)
    [ -n "$_p" ] || return 1
    [ -r "/proc/$_p/cmdline" ] || return 1
    tr '\0' ' ' < "/proc/$_p/cmdline" | grep -q S99cloudflared
}

# _ver_gt <latest> <installed> - true when the first version is newer. Groups are
# compared left to right as numbers, so 2026.10.0 beats 2026.9.30 and
# 2026.11.17.1 beats 2026.11.17; missing trailing groups count as zero, which is
# how semver treats 2026.12.0 and 2026.12.0.0 as the same release.
# ponytail: digits and dots only. A suffix such as -rc1 would never compare as
# newer; the CI tag regex allows exactly three groups, so add suffix handling
# only if pre-release tags are ever published.
_ver_gt() {
    [ -n "$1" ] || return 1
    [ -n "$2" ] || return 0
    [ "$1" = "$2" ] && return 1
    _gt=$(awk -v a="$1" -v b="$2" 'BEGIN {
        na = split(a, x, "."); nb = split(b, y, ".")
        n = (na > nb) ? na : nb
        for (i = 1; i <= n; i++) {
            xi = (i <= na) ? x[i] + 0 : 0
            yi = (i <= nb) ? y[i] + 0 : 0
            if (xi > yi) { print 1; exit }
            if (xi < yi) { print 0; exit }
        }
        print 0
    }')
    [ "$_gt" = 1 ]
}

# _freshness <installed> <latest> - one word for the version block.
_freshness() {
    if [ -z "$2" ]; then
        echo "check failed"
    elif [ -z "$1" ]; then
        echo "unknown"
    elif _ver_gt "$2" "$1"; then
        echo "update available: $2"
    else
        echo "up to date"
    fi
}

# process_report - process block of the status command. Returns 0 while the
# tunnel is up, 1 when nothing runs.
process_report() {
    _sup=$(cat "$PIDFILE" 2>/dev/null)
    _tun=$(tunnel_pid 2>/dev/null)
    echo "Process status"
    if manager_alive; then
        echo "  service      running"
        _line="  supervisor   pid $_sup"
        _u=$(proc_uptime "$_sup" 2>/dev/null)
        [ -n "$_u" ] && _line="$_line, up $_u"
        echo "$_line"
        if [ -n "$_tun" ]; then
            _line="  tunnel       pid $_tun"
            _u=$(proc_uptime "$_tun" 2>/dev/null)
            [ -n "$_u" ] && _line="$_line, up $_u"
            _r=$(proc_rss "$_tun" 2>/dev/null)
            [ -n "$_r" ] && _line="$_line, $_r"
            echo "$_line"
        else
            echo "  tunnel       down, the watchdog is restarting it"
        fi
        return 0
    fi
    if [ -n "$_tun" ]; then
        echo "  service      running (started by hand, no supervisor)"
        echo "  supervisor   -"
        _line="  tunnel       pid $_tun"
        _u=$(proc_uptime "$_tun" 2>/dev/null)
        [ -n "$_u" ] && _line="$_line, up $_u"
        _r=$(proc_rss "$_tun" 2>/dev/null)
        [ -n "$_r" ] && _line="$_line, $_r"
        echo "$_line"
        return 0
    fi
    echo "  service      stopped"
    echo "  supervisor   -"
    echo "  tunnel       -"
    return 1
}

# version_report [latest tag] - version block of the status command. The
# argument lets the caller reuse a tag it already fetched.
version_report() {
    _bin=$(cat "$VERSION_FILE" 2>/dev/null)
    _sc=$(script_version)
    _new=$1
    [ -n "$_new" ] || _new=$(latest_tag 2>/dev/null)
    _pub=$(published_script_version 2>/dev/null)
    _bv=$(_freshness "$_bin" "$_new")
    _sv=$(_freshness "$_sc" "$_pub")
    echo "Version status"
    printf '  %-14s %-12s %s\n' "tunnel binary" "${_bin:-unknown}" "$_bv"
    printf '  %-14s %-12s %s\n' "scripts" "${_sc:-unknown}" "$_sv"
    case "$_bv$_sv" in
        *update*) echo "                                run: cloudflared update" ;;
    esac
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
    _bcur=$(cat "$VERSION_FILE" 2>/dev/null)
    # Only a strictly newer tag replaces the binary: a router that already runs
    # a newer build must not be downgraded to whatever the feed reports.
    _ver_gt "$_new" "$_bcur" || return 1
    echo "[*] Binary: ${_bcur:-unknown} -> $_new, downloading..."
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

# daily_tasks [now] - the work the background checker does once a day. The marker
# lives in /opt/etc so it survives a reboot; without "now" the tasks are skipped
# when the marker already holds today's date. A start passes "now", so the router
# also checks once on every boot instead of waiting a full day.
daily_tasks() {
    _today=$(date -u +%Y-%m-%d)
    [ -n "$_today" ] || return 1
    if [ "$1" != "now" ]; then
        [ "$(cat "$LASTRUN" 2>/dev/null)" = "$_today" ] && return 1
    fi
    log_housekeeping
    auto_update >> "$LOG" 2>&1
    scripts_update >> "$LOG" 2>&1
    printf '%s\n' "$_today" > "$LASTRUN" 2>/dev/null
    return 0
}
HLP

sed -i "s|__ASSET_URL__|$ASSET_URL|" "$HELPERS"
. "$HELPERS"

# --- binary -----------------------------------------------------------------
# SKIP_BINARY=1 is set by `cloudflared update` when only the scripts are out of
# date, so the ~30 MB asset is not fetched again right after it was updated.
if [ -n "$SKIP_BINARY" ] && [ -x "$BIN" ]; then
    echo "[=] Keeping the installed binary."
else
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
        rm -rf /opt/etc/cloudflared
        rm -f /opt/var/log/cloudflared.log
        rm -f /opt/var/run/cloudflared.pid
        rm -f /opt/var/run/cloudflared.stop
        rm -f /opt/var/run/cloudflared.checker.pid
        rm -f /opt/var/run/cloudflared.wait
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
# trims the log once a day, swaps in a newer binary and applies newer scripts.
# --no-autoupdate is a global flag on this build, so it has to be passed before
# the subcommand.
cat << EOD > "$SERVICE"
#!/bin/sh
# Generated by install_cloudflared.sh.
TOKEN="$TOKEN"
PIDFILE="/opt/var/run/cloudflared.pid"
STOPFLAG="/opt/var/run/cloudflared.stop"
CHECKPID="/opt/var/run/cloudflared.checker.pid"
. "$ETC_DIR/helpers.sh"

check_loop() {
    # The wait is a shell builtin reading an empty FIFO: it spawns no child, so
    # stopping the checker cannot leave a sleep process behind.
    [ -p "\$WAITFIFO" ] || mkfifo "\$WAITFIFO" 2>/dev/null
    exec 3<>"\$WAITFIFO"
    # Once on every start, so a router that reboots daily still checks instead of
    # postponing the work by another 24 hours.
    [ -f "\$STOPFLAG" ] || daily_tasks now
    while [ ! -f "\$STOPFLAG" ]; do
        read -t 86400 -r _ <&3
        [ -f "\$STOPFLAG" ] && return 0
        daily_tasks
    done
}

case "\$1" in
    start)
        if manager_alive; then
            echo "already running (pid \$(cat "\$PIDFILE"))"
            exit 0
        fi
        rm -f "\$PIDFILE" "\$STOPFLAG" "\$CHECKPID" "\$WAITFIFO"
        killall cloudflared cloudflared-bin 2>/dev/null || true
        mkfifo "\$WAITFIFO" 2>/dev/null
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
        # The tunnel exits asynchronously, so a status issued right after stop
        # would still see it. Wait for it to disappear.
        _n=0
        while [ -n "\$(tunnel_pid)" ] && [ "\$_n" -lt 5 ]; do
            sleep 1
            _n=\$((_n + 1))
        done
        rm -f "\$PIDFILE" "\$STOPFLAG" "\$CHECKPID" "\$WAITFIFO"
        echo "stopped"
        ;;
    restart)
        "\$0" stop
        sleep 1
        "\$0" start
        ;;
    status)
        process_report
        _rc=\$?
        echo ""
        version_report
        exit \$_rc
        ;;
    update)
        _tag=\$(latest_tag 2>/dev/null)
        _rc=1
        auto_update && _rc=0
        # execs on success, so the second download of the installer is avoided.
        scripts_update now
        echo ""
        version_report "\$_tag"
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
