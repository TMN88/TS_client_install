#!/bin/sh
# OpenWrt only. Never source this file; run: sh tailscale-router-quiet.sh
set +x
set +v
set -eu
umask 077
# BusyBox ash on OpenWrt supports disabling core dumps.
# shellcheck disable=SC3045
ulimit -c 0 2>/dev/null || :
unset TS_AUTHKEY TS_AUTH_KEY TS_AUTHKEY_FILE
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

RESET='' CYAN='' GREEN='' RED=''
if [ -z "${NO_COLOR-}" ]; then
    RESET=$(printf '\033[0m'); CYAN=$(printf '\033[1;96m')
    GREEN=$(printf '\033[1;92m'); RED=$(printf '\033[1;91m')
fi
say() { printf '%s\n' "$*"; }
die() { printf '%sОШИБКА: %s%s\n' "$RED" "$*" "$RESET" >&2; exit 1; }
WORK='' LOCKED='' TTY_STATE='' CHILD=''
cleanup() {
    rc=$?
    trap - EXIT HUP INT TERM
    set +e
    if [ -n "$CHILD" ]; then kill "$CHILD" 2>/dev/null; wait "$CHILD" 2>/dev/null; fi
    unset key auth_message
    if [ -n "$TTY_STATE" ]; then stty "$TTY_STATE" <&3; fi
    if [ -n "$WORK" ]; then
        rm -f "$WORK/status.json" "$WORK/prefs.json" "$WORK/vendor.sh" "$WORK/init.new"
        rmdir "$WORK"
    fi
    if [ -n "$LOCKED" ]; then rmdir /tmp/TS_client_install_auto.lock; fi
    if [ "$rc" -eq 0 ]; then result='успешно'; colour=$GREEN
    else result="ошибка, код $rc"; colour=$RED; fi
    printf '\n%s========== КОНЕЦ: %s ==========%s\n' "$colour" "$result" "$RESET"
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
printf '%s========== НАЧАЛО: Tailscale AUTO ==========%s\n' "$CYAN" "$RESET"
[ "$#" -eq 0 ] || die 'Аргументы не принимаются. Ключ вводится только в терминале.'
[ "$(id -u)" = 0 ] || die 'Запустите от root.'
[ -f /etc/openwrt_release ] || die 'Требуется OpenWrt.'
for cmd in awk wget pidof; do
    command -v "$cmd" >/dev/null 2>&1 || die "Не найдена базовая команда OpenWrt: $cmd"
done
mkdir /tmp/TS_client_install_auto.lock 2>/dev/null ||
    die 'Другой запуск активен или осталась блокировка /tmp/TS_client_install_auto.lock. Проверьте процессы перед её ручным удалением.'
LOCKED=1
packages=''
for requirement in stty:coreutils-stty timeout:coreutils-timeout mktemp:coreutils-mktemp sha256sum:coreutils-sha256sum jsonfilter:jsonfilter; do
    dependency=${requirement%%:*}
    package=${requirement#*:}
    if ! command -v "$dependency" >/dev/null 2>&1; then
        packages="$packages $package"
    fi
done
if [ -n "$packages" ]; then
    say "Установка недостающих зависимостей:$packages"
    # Package names come only from the fixed list above; split them into arguments.
    # shellcheck disable=SC2086
    set -- $packages
    if command -v apk >/dev/null 2>&1; then
        apk update || die 'Не удалось обновить списки apk.'
        apk add "$@" || die 'Не удалось установить зависимости через apk.'
    elif command -v opkg >/dev/null 2>&1; then
        opkg update || die 'Не удалось обновить списки opkg.'
        opkg install "$@" || die 'Не удалось установить зависимости через opkg.'
    else
        die 'Для установки зависимостей нужен apk или opkg.'
    fi
fi
for dependency in stty timeout mktemp sha256sum jsonfilter; do
    command -v "$dependency" >/dev/null 2>&1 || die "После установки не найдена команда: $dependency"
done
# Require RAM-backed temporary diagnostics; the auth key uses a pipe only.
awk '$2 == "/tmp" && $3 == "tmpfs" { ok=1 } END { exit !ok }' /proc/mounts ||
    die '/tmp должен быть отдельным tmpfs (хранение ключа только в ОЗУ).'
WORK=$(mktemp -d /tmp/TS_client_install_auto.XXXXXX) || die 'Не удалось создать временный каталог.'

mkdir -p /etc/tailscale

if ! command -v tailscale >/dev/null 2>&1 || ! command -v tailscaled >/dev/null 2>&1; then
    say 'Установка TS mini (GuNanOvO, постоянная установка)...'
    wget -T 30 -O "$WORK/vendor.sh" 'https://raw.githubusercontent.com/GuNanOvO/openwrt-tailscale/7a0e4bb0f025fe33a7731ac0130d2fbc34734fb5/install_en.sh' >/dev/null 2>&1 || die 'Ошибка загрузки установщика.'
    printf '%s  %s\n' '8a73271d0651fcd7fed012bc9a72181eab4dba242636f8f11f0c09ea0d3a16ec' "$WORK/vendor.sh" | sha256sum -c - >/dev/null 2>&1 || die 'Контрольная сумма установщика не совпала.'
    sh -n "$WORK/vendor.sh" || die 'Ошибка синтаксиса установщика.'
    cp "$WORK/vendor.sh" /usr/sbin/install.sh
    chmod 755 /usr/sbin/install.sh
    vendor_rc=0
    /usr/sbin/install.sh --persistent-install --yes >/dev/null 2>&1 || vendor_rc=$?
    if [ "$vendor_rc" -ne 0 ]; then
        # A package can be installed while the vendor's default daemon start fails.
        # Continue only when the installed payload and init are verifiably present;
        # our userspace service and readiness checks below must still succeed.
        if command -v tailscale >/dev/null 2>&1 &&
           command -v tailscaled >/dev/null 2>&1 &&
           tailscale version >/dev/null 2>&1 && [ -x /etc/init.d/tailscale ]; then
            say 'Пакет установлен; стандартный запуск не прошёл. Проверяю запуск userspace.'
        else
            die 'Ошибка установки TS mini: исполняемые файлы или init не подтверждены.'
        fi
    fi
fi
if ! command -v tailscale >/dev/null 2>&1 || ! command -v tailscaled >/dev/null 2>&1; then
    die 'Установка исполняемых файлов не подтверждена.'
fi
tailscale version >/dev/null 2>&1 || die 'Команда tailscale version не работает.'
[ -x /etc/init.d/tailscale ] || die 'Не найдена служба Tailscale.'
say 'Применение настроек TS mini: userspace, SOCKS5 и hotplug WAN/WAN6...'
awk '
    /^[ \t]*procd_append_param env TS_FORCE_NOISE_443=true[ \t]*$/ { next }
    /^[ \t]*procd_append_param command --no-logs-no-support[ \t]*$/ { next }
    /^[ \t]*procd_append_param command --tun=userspace-networking[ \t]*$/ { next }
    /^[ \t]*procd_append_param command --socks5-server=[^ \t]+[ \t]*$/ { next }
    /--tun|--socks5-server|--no-logs-no-support/ { bad=1 }
    { print }
    /^[ \t]*procd_append_param command --state "\$state_file"[ \t]*$/ {
        anchors++
        print "  procd_append_param env TS_FORCE_NOISE_443=true"
        print "  procd_append_param command --no-logs-no-support"
        print "  procd_append_param command --tun=userspace-networking"
        print "  procd_append_param command --socks5-server=0.0.0.0:1055"
    }
    END { if (anchors != 1 || bad) exit 1 }
' /etc/init.d/tailscale > "$WORK/init.new" || die 'Неизвестный формат init. Конфигурация не применена.'
sh -n "$WORK/init.new" || die 'Ошибка синтаксиса службы.'
cat > /etc/config/tailscale <<'CONFIG'
config settings 'settings'
  option log_stdout '0'
  option log_stderr '0'
  option port '41641'
  option state_file '/etc/tailscale/tailscaled.state'
  option fw_mode 'none'
CONFIG
cp "$WORK/init.new" /etc/init.d/tailscale
chmod 755 /etc/init.d/tailscale
mkdir -p /etc/hotplug.d/iface
cat > /etc/hotplug.d/iface/95-tailscale <<'HOTPLUG'
#!/bin/sh
if [ "$ACTION" = "ifup" ] && {
    [ "$INTERFACE" = "wan" ] || [ "$INTERFACE" = "wan6" ];
}; then
    /etc/init.d/tailscale restart
fi
HOTPLUG
chmod 755 /etc/hotplug.d/iface/95-tailscale
/etc/init.d/tailscale enable >/dev/null 2>&1 || die 'Не удалось включить автозапуск.'
/etc/init.d/tailscale restart >/dev/null 2>&1 || die 'Не удалось перезапустить службу.'
state() {
    backend=
    if timeout 5 tailscale status --json > "$WORK/status.json" 2>/dev/null; then
        backend=$(jsonfilter -i "$WORK/status.json" -e '@.BackendState' 2>/dev/null) || return 1
        [ -n "$backend" ]
    else return 1; fi
}
attempt=0
until state; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 15 ] || die 'Служба не отвечает. Проверьте её состояние и системное время.'
    sleep 1
done
timeout 5 tailscale debug prefs > "$WORK/prefs.json" 2>/dev/null || die 'Не удалось проверить сервер управления.'
server=$(jsonfilter -i "$WORK/prefs.json" -e '@.ControlURL' 2>/dev/null) || die 'Ошибка чтения настроек.'
case "$server" in
    ''|https://login.tailscale.com|https://login.tailscale.com/|https://controlplane.tailscale.com|https://controlplane.tailscale.com/) ;;
    *) die 'Настроен сторонний сервер. Автоматическое переключение запрещено; проверьте подключение вручную.' ;;
esac
rm -f "$WORK/prefs.json"
if [ "$backend" = Running ]; then
    say 'Подключение уже активно. Повторная авторизация не требуется.'
    timeout 15 tailscale set --accept-dns=false --netfilter-mode=off --accept-routes=false >/dev/null 2>&1 || die 'Не удалось применить настройки TS mini.'
else
    # Open the controlling terminal, independently of stdin (including piped scripts).
    exec 3<>/dev/tty || die 'Нет интерактивного терминала. Запустите через SSH с TTY.'
    TTY_STATE=$(stty -g <&3) || die 'Не удалось прочитать настройки терминала.'
    stty -echo <&3 || die 'Не удалось отключить эхо.'
    printf 'Введите заранее созданный auth key (ввод скрыт): ' >&3
    key=
    if ! IFS= read -r key <&3; then die 'Ввод ключа прерван.'; fi
    stty "$TTY_STATE" <&3 || die 'Не удалось восстановить терминал.'
    TTY_STATE=
    printf '\n' >&3
    case "$key" in tskey-auth-?*) ;; *) die 'Ожидается auth key с префиксом tskey-auth-.' ;; esac
    case "$key" in *[!a-zA-Z0-9_-]*) die 'Недопустимые символы в ключе.' ;; esac
    # The secret travels through a pipe, never argv, environment or a key file.
    say 'Авторизация: HTTPS/443, ключ через stdin, до 90 секунд...'
    auth_rc=0
    auth_message=$(printf '%s' "$key" | timeout -k 5 90 tailscale up \
        --login-server=https://login.tailscale.com \
        --auth-key=file:/dev/stdin --accept-dns=false --netfilter-mode=off \
        --accept-routes=false --timeout=75s 2>&1) || auth_rc=$?
    unset key
    if [ "$auth_rc" -ne 0 ]; then
        printf '%s\n' "$auth_message" | sed 's/tskey-auth-[[:alnum:]_-]*/[REDACTED]/g' >&2
    fi
    unset auth_message
    [ "$auth_rc" -eq 0 ] || die "Вход не завершён (код $auth_rc); ключ повторно вслепую не отправляется."
fi
if ! state || [ "$backend" != Running ]; then die 'Состояние Running не подтверждено.'; fi
ip=$(timeout 5 tailscale ip -4 2>/dev/null) || die 'Не удалось получить Tailscale IPv4.'
printf '%s\n' "$ip" | awk -F. '
    NF == 4 && $1 == 100 && $2 >= 64 && $2 <= 127 && $3 <= 255 && $4 <= 255 &&
    $0 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { n++ }
    END { exit !(NR == 1 && n == 1) }' || die 'Некорректный Tailscale IPv4.'
/etc/init.d/tailscale enabled >/dev/null 2>&1 || die 'Автозапуск не подтверждён.'
pidof tailscaled >/dev/null 2>&1 || die 'Процесс tailscaled не найден.'
[ -s /etc/tailscale/tailscaled.state ] || die 'Постоянный файл состояния не найден.'
say 'Установка проверена. Состояние: Running. Автозапуск включён.'
say "Tailscale IPv4: $ip"
