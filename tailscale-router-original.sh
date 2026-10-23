#!/bin/sh

echo " Tailscale installation and configuration"

echo "[1/6] Установка Tailscale..."
apk update
apk add tailscale

echo "[2/6] Создание конфигурации..."
cat > /etc/config/tailscale << 'EOF'
config settings 'settings'
  option log_stdout '0'
  option log_stderr '0'
  option port '41641'
  option state_file '/etc/tailscale/tailscaled.state'
  option fw_mode 'none'
EOF

echo "[3/6] Настройка init-скрипта..."
sed -i 's/procd_append_param command --state "\$state_file"/procd_append_param command --state "$state_file"\n  procd_append_param command --no-logs-no-support\n  procd_append_param command --tun=userspace-networking\n  procd_append_param command --socks5-server=0.0.0.0:1055/' /etc/init.d/tailscale

echo "[4/6] Включение автозапуска..."
/etc/init.d/tailscale enable

echo "[5/6] Запуск Tailscale..."
/etc/init.d/tailscale start

sleep 3

echo "[6/6] Настройка Tailscale..."
tailscale up \
  --accept-dns=false \
  --netfilter-mode=off \
  --accept-routes=false

echo "[7/7] Создание hotplug..."
mkdir -p /etc/hotplug.d/iface

cat > /etc/hotplug.d/iface/95-tailscale << 'EOF'
#!/bin/sh

if [ "$ACTION" = "ifup" ] && {
    [ "$INTERFACE" = "wan" ] || [ "$INTERFACE" = "wan6" ];
}; then
    logger -t tailscale-hotplug "WAN interface $INTERFACE up, restarting Tailscale..."
    /etc/init.d/tailscale restart
fi
EOF

chmod +x /etc/hotplug.d/iface/95-tailscale

echo " Tailscale установлен и настроен"