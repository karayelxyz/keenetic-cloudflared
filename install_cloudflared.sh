#!/bin/sh

ARCH=$(uname -m)
case "$ARCH" in
    aarch64|arm64) URL="https://github.com/karayelxyz/keenetic-cloudflared/releases/latest/download/cloudflared" ;;
    mips*)         URL="https://github.com/karayelxyz/keenetic-cloudflared/releases/latest/download/cloudflared-mipsle" ;;
    *)             echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

echo "[*] Architecture: $ARCH"
echo "[*] Downloading cloudflared..."

rm -f /opt/var/run/cloudflared.pid
killall cloudflared cloudflared-bin 2>/dev/null || true
rm -f /opt/bin/cloudflared /opt/bin/cloudflared-bin

if command -v wget >/dev/null 2>&1; then
    wget -q -O /opt/bin/cloudflared-bin "$URL"
elif command -v wget-ssl >/dev/null 2>&1; then
    wget-ssl -q -O /opt/bin/cloudflared-bin "$URL"
elif command -v curl >/dev/null 2>&1; then
    curl -sL -o /opt/bin/cloudflared-bin "$URL"
else
    echo "No downloader found."; exit 1
fi

chmod +x /opt/bin/cloudflared-bin

cat << 'WOF' > /opt/bin/cloudflared
#!/bin/sh
SVC="/opt/etc/init.d/S99cloudflared"
LOG="/opt/var/log/cloudflared.log"

case "$1" in
    start|stop|restart|status)
        exec "$SVC" "$1"
        ;;
    token)
        [ -z "$2" ] && { echo "Usage: cloudflared token <TOKEN>"; exit 1; }
        sed -i "s|^TOKEN=.*|TOKEN=\"$2\"|" "$SVC"
        echo "Token updated, restarting..."
        exec "$SVC" restart
        ;;
    logs)
        tail -f "$LOG"
        ;;
    remove)
        "$SVC" stop
        rm -f /opt/bin/cloudflared-bin
        rm -f /opt/bin/cloudflared
        rm -f /opt/etc/init.d/S99cloudflared
        rm -f /opt/var/log/cloudflared.log
        rm -f /opt/var/run/cloudflared.pid
        echo "cloudflared removed."
        ;;
    *)
        echo "Usage: cloudflared {start|stop|restart|status|token <TOKEN>|logs|remove}"
        exit 1
        ;;
esac
WOF
chmod +x /opt/bin/cloudflared

if [ -n "$1" ]; then
    TOKEN="$1"
else
    read -p "Cloudflare Tunnel Token: " TOKEN </dev/tty
    [ -z "$TOKEN" ] && echo "Token cannot be empty." && exit 1
fi

mkdir -p /opt/var/log /opt/var/run /opt/etc/init.d

cat << EOD > /opt/etc/init.d/S99cloudflared
#!/bin/sh
LOG="/opt/var/log/cloudflared.log"
TOKEN="$TOKEN"
PIDFILE="/opt/var/run/cloudflared.pid"

case "\$1" in
    start)
        if [ -f "\$PIDFILE" ]; then
            kill "\$(cat \$PIDFILE)" 2>/dev/null
            wait "\$(cat \$PIDFILE)" 2>/dev/null
            rm -f "\$PIDFILE"
        fi
        killall cloudflared cloudflared-bin 2>/dev/null || true
        /opt/bin/cloudflared-bin tunnel run --token "\$TOKEN" >> "\$LOG" 2>&1 &
        echo \$! > "\$PIDFILE"
        ;;
    stop)
        if [ -f "\$PIDFILE" ]; then
            kill "\$(cat \$PIDFILE)" 2>/dev/null
            wait "\$(cat \$PIDFILE)" 2>/dev/null
            rm -f "\$PIDFILE"
        fi
        killall cloudflared cloudflared-bin 2>/dev/null || true
        ;;
    restart)
        \$0 stop
        sleep 2
        \$0 start
        ;;
    status)
        if [ -f "\$PIDFILE" ] && kill -0 "\$(cat \$PIDFILE)" 2>/dev/null; then
            echo "running"
            exit 0
        fi
        rm -f "\$PIDFILE"
        echo "stopped"
        exit 1
        ;;
    *)
        echo "Usage: \$0 {start|stop|restart|status}"
        exit 1
        ;;
esac
EOD

chmod +x /opt/etc/init.d/S99cloudflared
/opt/etc/init.d/S99cloudflared restart

echo ""
if [ -f /opt/var/run/cloudflared.pid ] && kill -0 "$(cat /opt/var/run/cloudflared.pid)" 2>/dev/null; then
    echo "[+] cloudflared is running (PID: $(cat /opt/var/run/cloudflared.pid))"
else
    echo "[!] Check logs: /opt/var/log/cloudflared.log"
fi
