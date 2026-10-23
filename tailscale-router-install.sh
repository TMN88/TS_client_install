#!/bin/sh
# Tailscale from GuNanOvO/openwrt-tailscale, persistent package installation.
# Based on the user's original userspace configuration. Run through local SSH.
set -eu
umask 077
unset TS_AUTHKEY TS_AUTH_KEY TS_AUTHKEY_FILE

say() { printf '%s\n' "$*"; }
die() { say "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die 'Run as root.'
[ -f /etc/openwrt_release ] || die 'OpenWrt is required.'
[ "$#" -eq 0 ] || die 'This installer takes no arguments.'
for cmd in wget awk jsonfilter mktemp pidof; do
    command -v "$cmd" >/dev/null 2>&1 || die "Missing command: $cmd"
done
INIT=/etc/init.d/tailscale
LOCK=/tmp/tailscale-router-mini.lock
mkdir "$LOCK" 2>/dev/null || die "Installer is already running (lock: $LOCK)."
cleanup() {
    rc=$?
    trap - EXIT HUP INT TERM
    rm -f "$LOCK/vendor.sh" "$LOCK/init.new" "$LOCK/status.json"
    rmdir "$LOCK" 2>/dev/null || :
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

say '[1/6] Installing Tailscale mini from GuNanOvO (persistent mode)...'
# Save existing files before the upstream installer can replace them.
mkdir -p /etc/tailscale
BACKUP=$(mktemp -d /etc/tailscale/mini-backup-XXXXXX)
for file in /etc/config/tailscale /etc/init.d/tailscale /etc/hotplug.d/iface/95-tailscale; do
    if [ -f "$file" ]; then
        case "$file" in
            /etc/config/*) cp -p "$file" "$BACKUP/config" ;;
            /etc/init.d/*) cp -p "$file" "$BACKUP/init" ;;
            *) cp -p "$file" "$BACKUP/hotplug" ;;
        esac
    fi
done
say "Configuration backup: $BACKUP"
wget -T 30 -O "$LOCK/vendor.sh" \
    'https://raw.githubusercontent.com/GuNanOvO/openwrt-tailscale/main/install_en.sh'
[ -s "$LOCK/vendor.sh" ] || die 'Downloaded upstream installer is empty.'
sh -n "$LOCK/vendor.sh" || die 'Downloaded upstream installer has invalid shell syntax.'
cp "$LOCK/vendor.sh" /usr/sbin/install.sh
chmod 755 /usr/sbin/install.sh
/usr/sbin/install.sh --persistent-install --yes
command -v tailscale >/dev/null 2>&1 || die 'Upstream installer did not provide tailscale.'
command -v tailscaled >/dev/null 2>&1 || die 'Upstream installer did not provide tailscaled.'
[ -f "$INIT" ] || die 'Upstream installer did not provide a service.'

say '[2/6] Applying the original userspace service settings...'
# Same three daemon flags as the original; replace recognised old flags once.
awk '
    /^[ \t]*procd_append_param command --no-logs-no-support[ \t]*$/ { next }
    /^[ \t]*procd_append_param command --tun=userspace-networking[ \t]*$/ { next }
    /^[ \t]*procd_append_param command --socks5-server=[a-zA-Z0-9.:\[\]-]+[ \t]*$/ { next }
    /--tun|--socks5-server|--no-logs-no-support/ { bad=1 }
    { print }
    /^[ \t]*procd_append_param command --state "\$state_file"[ \t]*$/ {
        anchors++
        print "  procd_append_param command --no-logs-no-support"
        print "  procd_append_param command --tun=userspace-networking"
        print "  procd_append_param command --socks5-server=0.0.0.0:1055"
    }
    END { if (anchors != 1 || bad) exit 1 }
' "$INIT" > "$LOCK/init.new" || die 'Unsupported upstream init format; custom settings were not applied.'
sh -n "$LOCK/init.new"
cat > /etc/config/tailscale <<'CONFIG'
config settings 'settings'
  option log_stdout '0'
  option log_stderr '0'
  option port '41641'
  option state_file '/etc/tailscale/tailscaled.state'
  option fw_mode 'none'
CONFIG
cp "$LOCK/init.new" "$INIT"
chmod 755 "$INIT"

say '[3/6] Installing WAN/WAN6 restart hook...'
mkdir -p /etc/hotplug.d/iface
cat > /etc/hotplug.d/iface/95-tailscale <<'HOTPLUG'
#!/bin/sh
if [ "$ACTION" = "ifup" ] && {
    [ "$INTERFACE" = "wan" ] || [ "$INTERFACE" = "wan6" ];
}; then
    logger -t tailscale-hotplug "WAN interface $INTERFACE up, restarting Tailscale..."
    /etc/init.d/tailscale restart
fi
HOTPLUG
chmod 755 /etc/hotplug.d/iface/95-tailscale

say '[4/6] Enabling autostart and restarting Tailscale...'
"$INIT" enable
"$INIT" restart
say '[5/6] Waiting for daemon (up to 30 seconds)...'
ready=0
attempt=0
while [ "$attempt" -lt 30 ]; do
    if tailscale status --json > "$LOCK/status.json" 2>/dev/null &&
       jsonfilter -i "$LOCK/status.json" -e '@.BackendState' | grep -q .; then
        ready=1
        break
    fi
    attempt=$((attempt + 1))
    sleep 1
done
[ "$ready" = 1 ] || die 'Daemon did not become available. Run: logread -e tailscale'

say '[6/6] Connecting Tailscale (browser login, up to 5 minutes)...'
backend=$(jsonfilter -i "$LOCK/status.json" -e '@.BackendState')
if [ "$backend" = Running ]; then
    tailscale set --accept-dns=false --netfilter-mode=off --accept-routes=false
else
    if ! tailscale up --accept-dns=false --netfilter-mode=off --accept-routes=false --timeout=300s; then
        say 'NOT CONNECTED: complete browser login and inspect tailscale status.' >&2
        exit 2
    fi
fi
tailscale status --json > "$LOCK/status.json"
backend=$(jsonfilter -i "$LOCK/status.json" -e '@.BackendState')
[ "$backend" = Running ] || die "Tailscale is not Running: $backend"
say 'SUCCESS: Tailscale is Running. IPv4 address:'
tailscale ip -4
say 'Check SSH from another tailnet device and confirm there is no Ephemeral badge.'
