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
VENDOR_OK=0

# Bright ANSI colours work in ordinary SSH terminals. NO_COLOR=1 disables them.
RESET= CYAN= GREEN= RED= YELLOW=
if [ -z "${NO_COLOR-}" ]; then
    RESET=$(printf '\033[0m')
    CYAN=$(printf '\033[1;96m')
    GREEN=$(printf '\033[1;92m')
    RED=$(printf '\033[1;91m')
    YELLOW=$(printf '\033[1;93m')
fi
result_line() {
    case "$1" in
        ok) printf '%s[OK] %s%s\n' "$GREEN" "$2" "$RESET" ;;
        fail) printf '%s[ОШИБКА] %s%s\n' "$RED" "$2" "$RESET"; failed=$((failed + 1)) ;;
        warn) printf '%s[НЕ ПРОВЕРЕНО] %s%s\n' "$YELLOW" "$2" "$RESET"; warnings=$((warnings + 1)) ;;
    esac
}
installation_result() {
    install_rc=$1
    failed=0
    warnings=0
    printf '\n%s==================================================\n' "$CYAN"
    printf '             ИТОГ УСТАНОВКИ TS MINI\n'
    printf '==================================================%s\n' "$RESET"

    version=$(tailscale version 2>/dev/null | head -n 1)
    if [ "$VENDOR_OK" = 1 ] && [ -n "$version" ] && command -v tailscaled >/dev/null 2>&1; then
        result_line ok "TS mini установлен — версия $version"
    else
        result_line fail 'Установка TS mini не подтверждена'
    fi

    pids=$(pidof tailscaled 2>/dev/null)
    if [ -n "$pids" ]; then
        result_line ok 'Служба Tailscale запущена'
    else
        result_line fail 'Служба Tailscale не запущена'
    fi
    active_userspace=0
    for daemon_pid in $pids; do
        if [ -r "/proc/$daemon_pid/cmdline" ] &&
           tr '\000' '\n' < "/proc/$daemon_pid/cmdline" | grep -qx -- '--tun=userspace-networking'; then
            active_userspace=1
        fi
    done
    if [ "$active_userspace" = 1 ]; then
        result_line ok 'Режим userspace активен'
    else
        result_line fail 'Режим userspace у работающего процесса не подтверждён'
    fi

    final_state=unknown
    if tailscale status --json > "$LOCK/status.json" 2>/dev/null; then
        final_state=$(jsonfilter -i "$LOCK/status.json" -e '@.BackendState' 2>/dev/null)
    fi
    if [ "$final_state" = Running ]; then
        result_line ok 'Авторизация завершена — состояние Running'
    else
        result_line fail "Подключение не завершено — состояние ${final_state:-unknown}"
    fi
    final_ip=$(tailscale ip -4 2>/dev/null)
    if [ "$final_state" = Running ] && [ -n "$final_ip" ]; then
        result_line ok "Tailscale IPv4: $final_ip"
    else
        result_line fail 'Tailscale IPv4 не получен'
    fi
    if "$INIT" enabled >/dev/null 2>&1; then
        result_line ok 'Автозапуск Tailscale включён'
    else
        result_line fail 'Автозапуск Tailscale не включён'
    fi
    if [ -s /etc/tailscale/tailscaled.state ]; then
        result_line ok 'Файл состояния Tailscale сохранён'
    else
        result_line fail 'Файл состояния Tailscale не найден или пуст'
    fi

    hook=/etc/hotplug.d/iface/95-tailscale
    if [ -f "$hook" ] && [ -x "$hook" ] && sh -n "$hook" 2>/dev/null &&
       grep -Fq '[ "$ACTION" = "ifup" ]' "$hook" &&
       grep -Fq '[ "$INTERFACE" = "wan" ]' "$hook" &&
       grep -Fq '[ "$INTERFACE" = "wan6" ]' "$hook" &&
       grep -Fq '/etc/init.d/tailscale restart' "$hook"; then
        result_line ok 'Hotplug создан, исполняемый — перезапуск при WAN/WAN6'
    else
        result_line fail 'Hotplug отсутствует или не прошёл проверку'
    fi

    prefs=$(tailscale debug prefs 2>/dev/null)
    if [ -n "$prefs" ]; then
        pref_dns=$(printf '%s\n' "$prefs" | jsonfilter -e '@.CorpDNS' 2>/dev/null)
        pref_fw=$(printf '%s\n' "$prefs" | jsonfilter -e '@.NetfilterMode' 2>/dev/null)
        pref_routes=$(printf '%s\n' "$prefs" | jsonfilter -e '@.RouteAll' 2>/dev/null)
        if [ "$pref_dns" = false ] && [ "$pref_fw" = 0 ] && [ "$pref_routes" = false ]; then
            result_line ok 'Настройки применены — DNS, netfilter и приём маршрутов отключены'
        elif [ -n "$pref_dns" ] && [ -n "$pref_fw" ] && [ -n "$pref_routes" ]; then
            result_line fail 'Фактические настройки DNS/netfilter/маршрутов отличаются от ожидаемых'
        else
            result_line warn 'Сборка не вернула все поля настроек для проверки'
        fi
    else
        result_line warn 'Сборка не предоставила debug prefs для проверки настроек'
    fi

    if [ "$install_rc" -eq 0 ] && [ "$failed" -eq 0 ]; then
        if [ "$warnings" -eq 0 ]; then
            printf '\n%sSUCCESS: УСТАНОВКА ПРОШЛА УСПЕШНО%s\n' "$GREEN" "$RESET"
        else
            printf '\n%sSUCCESS: установка завершена; не все проверки доступны%s\n' "$YELLOW" "$RESET"
        fi
    else
        printf '\n%sУСТАНОВКА НЕ ПОДТВЕРЖДЕНА: ошибок проверок — %s; код установки — %s%s\n' "$RED" "$failed" "$install_rc" "$RESET"
    fi
    printf '%s==================================================%s\n' "$CYAN" "$RESET"
    say 'Удалённый SSH, отсутствие Ephemeral и восстановление после перезагрузки проверяются отдельно.'
    if [ -n "${BACKUP-}" ]; then say "Резервная копия конфигурации: $BACKUP"; fi
    [ "$failed" -eq 0 ]
}

mkdir "$LOCK" 2>/dev/null || die "Installer is already running (lock: $LOCK)."
cleanup() {
    rc=$?
    trap - EXIT HUP INT TERM
    # A failed diagnostic must not interrupt the report or leave the lock behind.
    set +e
    installation_result "$rc"
    report_rc=$?
    rm -f "$LOCK/vendor.sh" "$LOCK/init.new" "$LOCK/status.json"
    rmdir "$LOCK" 2>/dev/null || :
    if [ "$rc" -eq 0 ] && [ "$report_rc" -ne 0 ]; then rc=1; fi
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
VENDOR_OK=1
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
# The EXIT handler prints the verified installation report and releases the lock.
