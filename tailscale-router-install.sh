#!/bin/sh
# OpenWrt: persistent Tailscale userspace installation. Run locally as root.
# Optional: SOCKS5_LISTEN=0.0.0.0:1055 sh tailscale-router-install.sh
# Empty SOCKS5_LISTEN disables the proxy. Default: localhost only.
set -eu
umask 077

SOCKS5_LISTEN=${SOCKS5_LISTEN-127.0.0.1:1055}
TS_AUTHKEY_FILE=${TS_AUTHKEY_FILE-/tmp/tailscale-authkey}
INIT=/etc/init.d/tailscale
CONFIG=/etc/config/tailscale
HOOK=/etc/hotplug.d/iface/95-tailscale
LOCK=/tmp/tailscale-router-install.lock
BACKUP=
CHANGED=0
COMMITTED=0

say() { printf '%s\n' "$*"; }
die() { say "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die 'Run as root.'
[ -f /etc/openwrt_release ] || die 'This script requires OpenWrt.'
for cmd in uci jsonfilter awk mktemp pidof; do
    command -v "$cmd" >/dev/null 2>&1 || die "Missing command: $cmd"
done
case "$SOCKS5_LISTEN" in
    *[!a-zA-Z0-9.:\[\]-]*) die 'Invalid SOCKS5_LISTEN address.' ;;
esac
mkdir "$LOCK" 2>/dev/null || die "Another installation is running (lock: $LOCK)."

cleanup() {
    rc=$?
    trap - EXIT HUP INT TERM
    if [ "$rc" -ne 0 ] && [ "$CHANGED" = 1 ] && [ "$COMMITTED" = 0 ]; then
        say 'Configuration failed; restoring backed-up files.' >&2
        if ! sh "$BACKUP/rollback.sh"; then
            say "ERROR: rollback failed. Use local access and inspect $BACKUP" >&2
        fi
    fi
    rm -f "$LOCK/init.new" "$LOCK/status.json" "$LOCK/auth.key"
    rmdir "$LOCK" 2>/dev/null || :
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Pass a private file path to the CLI; never put the key in argv or logs.
# A supplied key is used only when the device is not already Running.
if [ -n "$TS_AUTHKEY_FILE" ] && [ -e "$TS_AUTHKEY_FILE" ]; then
    [ -f "$TS_AUTHKEY_FILE" ] && [ -s "$TS_AUTHKEY_FILE" ] && [ -r "$TS_AUTHKEY_FILE" ] ||
        die 'Auth key file must be a readable, nonempty regular file.'
    cp "$TS_AUTHKEY_FILE" "$LOCK/auth.key"
    chmod 600 "$LOCK/auth.key"
elif [ "$TS_AUTHKEY_FILE" != /tmp/tailscale-authkey ] && [ -n "$TS_AUTHKEY_FILE" ]; then
    die 'The specified TS_AUTHKEY_FILE does not exist.'
fi

say '[1/6] Checking/installing package...'
if ! command -v tailscale >/dev/null 2>&1 || ! command -v tailscaled >/dev/null 2>&1; then
    if command -v apk >/dev/null 2>&1; then
        apk update
        apk add tailscale
    elif command -v opkg >/dev/null 2>&1; then
        opkg update
        opkg install tailscale
    else
        die 'Neither apk nor opkg is available.'
    fi
fi
[ -f "$INIT" ] || die 'The package did not provide /etc/init.d/tailscale.'
# Keep this export unambiguous for both the daemon and its cleanup command.
grep -q 'USE_PROCD=1' "$INIT" || die 'Unsupported init script: procd is required.'

say '[2/6] Validating service configuration...'
# Remove only recognised arguments, including arguments from the old installer.
# Unknown TUN/proxy/log arguments cause an error instead of a speculative edit.
awk -v socks="$SOCKS5_LISTEN" '
    /^[ \t]*# BEGIN tailscale-router-installer$/ { next }
    /^[ \t]*# END tailscale-router-installer$/ { next }
    /^[ \t]*export TS_NO_LOGS_NO_SUPPORT=true$/ { next }
    /^[ \t]*procd_append_param command --no-logs-no-support[ \t]*$/ { next }
    /^[ \t]*procd_append_param command --tun=userspace-networking[ \t]*$/ { next }
    /^[ \t]*procd_append_param command --socks5-server=[a-zA-Z0-9.:\[\]-]+[ \t]*$/ { next }
    /--tun|--socks5-server|--no-logs-no-support/ { bad=1 }
    { print }
    /^USE_PROCD=1$/ { print "export TS_NO_LOGS_NO_SUPPORT=true" }
    /^[ \t]*procd_append_param command --state "\$state_file"[ \t]*$/ {
        anchors++
        print "  # BEGIN tailscale-router-installer"
        print "  procd_append_param command --no-logs-no-support"
        print "  procd_append_param command --tun=userspace-networking"
        if (socks != "") print "  procd_append_param command --socks5-server=" socks
        print "  # END tailscale-router-installer"
    }
    END { if (anchors != 1 || bad) exit 1 }
' "$INIT" > "$LOCK/init.new" || die 'Unsupported init script; no configuration was changed.'
sh -n "$LOCK/init.new" || die 'Generated init script has invalid syntax.'

# Only remove the known hook from the original installer.
if [ -e "$HOOK" ]; then
    grep -q 'logger -t tailscale-hotplug' "$HOOK" &&
    grep -q '/etc/init.d/tailscale restart' "$HOOK" ||
        die "Unrecognised $HOOK; review it before installing."
fi
if [ -n "$(uci -q changes tailscale || :)" ]; then
    die 'Uncommitted Tailscale UCI changes exist; commit or revert them first.'
fi

say '[3/6] Saving private backup and rollback command...'
mkdir -p /etc/tailscale/installer-backups
chmod 700 /etc/tailscale/installer-backups
BACKUP=$(mktemp -d /etc/tailscale/installer-backups/backup-XXXXXX)
cp -p "$INIT" "$BACKUP/init"
if [ -e "$CONFIG" ]; then cp -p "$CONFIG" "$BACKUP/config"; fi
if [ -e "$HOOK" ]; then cp -p "$HOOK" "$BACKUP/hook"; fi
if "$INIT" enabled >/dev/null 2>&1; then touch "$BACKUP/was-enabled"; fi
if pidof tailscaled >/dev/null 2>&1; then touch "$BACKUP/was-running"; fi
# Preserve the identity for manual recovery only; rollback must not replace live keys.
state_file=$(uci -q get tailscale.settings.state_file || :)
state_file=${state_file:-/etc/tailscale/tailscaled.state}
case "$state_file" in
    /*) if [ -f "$state_file" ]; then cp -p "$state_file" "$BACKUP/identity.state"; fi ;;
    *) die 'The configured state_file must be an absolute path.' ;;
esac
cat > "$BACKUP/rollback.sh" <<'ROLLBACK'
#!/bin/sh
set -eu
cd "$(dirname "$0")"
/etc/init.d/tailscale stop || :
uci -q revert tailscale || :
cp -p init /etc/init.d/tailscale
if [ -f config ]; then cp -p config /etc/config/tailscale; else rm -f /etc/config/tailscale; fi
if [ -f hook ]; then
    mkdir -p /etc/hotplug.d/iface
    cp -p hook /etc/hotplug.d/iface/95-tailscale
else
    rm -f /etc/hotplug.d/iface/95-tailscale
fi
if [ -f was-enabled ]; then /etc/init.d/tailscale enable; else /etc/init.d/tailscale disable; fi
if [ -f was-running ]; then /etc/init.d/tailscale start; fi
printf '%s\n' 'Previous configuration restored. Package and identity were retained.'
ROLLBACK
chmod 700 "$BACKUP/rollback.sh"
say "Backup: $BACKUP"
say "Rollback: sh $BACKUP/rollback.sh"

say '[4/6] Applying userspace configuration...'
CHANGED=1
# Modify only our options; retain other UCI settings and the existing state path.
touch "$CONFIG"
uci set tailscale.settings=settings
uci set "tailscale.settings.state_file=$state_file"
uci set tailscale.settings.log_stdout=0
uci set tailscale.settings.log_stderr=1
if ! uci -q get tailscale.settings.port >/dev/null; then
    uci set tailscale.settings.port=41641
fi
uci commit tailscale
mkdir -p "$(dirname "$state_file")"
cp "$LOCK/init.new" "$INIT"
chmod 755 "$INIT"
mkdir -p /etc/hotplug.d/iface
cat > "$HOOK" <<'HOTPLUG'
#!/bin/sh
# Deliberate recovery workaround: restart on every WAN/WAN6 ifup.
[ "$ACTION" = ifup ] || exit 0
case "$INTERFACE" in wan|wan6) ;; *) exit 0 ;; esac
# The installer itself restarts Tailscale after applying its configuration.
[ ! -d /tmp/tailscale-router-install.lock ] || exit 0
# Coalesce WAN and WAN6 events without blocking the hotplug dispatcher.
mkdir /tmp/tailscale-wan-restart.lock 2>/dev/null || exit 0
(
    trap 'rmdir /tmp/tailscale-wan-restart.lock 2>/dev/null || :' EXIT
    trap 'exit 1' HUP INT TERM
    sleep 5
    if [ ! -d /tmp/tailscale-router-install.lock ]; then
        logger -t tailscale-hotplug "WAN interface $INTERFACE up; restarting Tailscale after delay"
        if ! /etc/init.d/tailscale restart; then
            logger -t tailscale-hotplug 'ERROR: Tailscale restart failed'
        fi
    fi
) </dev/null >/dev/null 2>&1 &
exit 0
HOTPLUG
chmod 755 "$HOOK"
"$INIT" enable
"$INIT" restart

say '[5/6] Waiting for the daemon (up to 30 seconds)...'
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
[ "$ready" = 1 ] || die 'Daemon is unavailable; inspect logread -e tailscale.'
# Verify that the patched command actually runs, rather than trusting init exit codes.
verified=0
for daemon_pid in $(pidof tailscaled); do
    if tr '\000' '\n' < "/proc/$daemon_pid/cmdline" | grep -qx -- '--tun=userspace-networking'; then
        verified=1
    fi
done
[ "$verified" = 1 ] || die 'Daemon did not start in userspace mode.'
COMMITTED=1

say '[6/6] Configuring Tailscale network preferences...'
backend=$(jsonfilter -i "$LOCK/status.json" -e '@.BackendState')
if [ "$backend" = Running ]; then
    # set preserves unrelated existing preferences, including advertised routes.
    tailscale set --accept-dns=false --accept-routes=false --netfilter-mode=off
else
    set -- up --accept-dns=false --accept-routes=false --netfilter-mode=off --timeout=60s
    if [ -s "$LOCK/auth.key" ]; then
        say 'Authorizing automatically with the supplied Tailscale auth key...'
        set -- "$@" "--auth-key=file:$LOCK/auth.key"
    else
        say 'No auth key supplied. Open the login URL below. Waiting up to 60 seconds.'
    fi
    if ! tailscale "$@"; then
        say 'Installation is retained, but connection/authorization is NOT confirmed.' >&2
        say 'Check auth key validity, device approval and network access, or complete browser login.' >&2
        say 'Then rerun this installer. For diagnostics: tailscale status' >&2
        exit 2
    fi
fi
tailscale status --json > "$LOCK/status.json"
backend=$(jsonfilter -i "$LOCK/status.json" -e '@.BackendState')
[ "$backend" = Running ] || die "Installation retained, but Tailscale is not Running: $backend"
say 'Tailscale is Running. IPv4 address:'
tailscale ip -4
say "Rollback: sh $BACKUP/rollback.sh"
say 'Before closing local access: verify SSH or LuCI from another tailnet device.'
say 'A daemon check does not prove remote access or tailnet ACL permission.'
