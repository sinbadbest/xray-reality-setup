#!/usr/bin/env bash
# 新服务器一键部署 xray 出口（VLESS + Reality + vision），Debian 12/13，root 运行。
# 用法：bash <(curl -Ls https://raw.githubusercontent.com/sinbadbest/xray-reality-setup/main/install.sh)
#       PORT=36703 SNI=www.ebay.com EXTRA_IGNORE="1.2.3.4" bash <(curl -Ls ...)
# 重复运行安全：已有配置时沿用原 UUID/密钥/shortId，客户端不用改。
set -euo pipefail

PORT=${PORT:-$(shuf -i 20000-60000 -n 1)}
SNI=${SNI:-www.ebay.com}
EXTRA_IGNORE=${EXTRA_IGNORE:-}   # fail2ban 额外白名单，空格分隔（如其他出口 IP）
CFG=/usr/local/etc/xray/config.json
XRAY=/usr/local/bin/xray

[[ $EUID -eq 0 ]] || { echo "请用 root 运行" >&2; exit 1; }
grep -qi debian /etc/os-release || { echo "仅支持 Debian" >&2; exit 1; }

echo "== 1/7 swap"
if [[ -z $(swapon --show) ]] && (( $(awk '/MemTotal/{print $2}' /proc/meminfo) < 2000000 )); then
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile swap swap defaults 0 0' >> /etc/fstab
fi

echo "== 2/7 软件包"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -yq curl jq openssl ufw fail2ban unattended-upgrades
printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' \
  > /etc/apt/apt.conf.d/20auto-upgrades

echo "== 3/7 安装 xray（官方 XTLS/Xray-install，服务以 nobody 运行）"
bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

echo "== 4/7 生成配置"
old_in=$(jq -c '.inbounds[]? | select(.protocol == "vless")' "$CFG" 2>/dev/null || true)
if [[ -n $old_in ]]; then
  echo "沿用已有凭据"
  UUID=$(jq -r '.settings.clients[0].id' <<<"$old_in")
  PRIV=$(jq -r '.streamSettings.realitySettings.privateKey' <<<"$old_in")
  SID=$(jq -r '.streamSettings.realitySettings.shortIds[0]' <<<"$old_in")
  PORT=$(jq -r '.port' <<<"$old_in")
  SNI=$(jq -r '.streamSettings.realitySettings.serverNames[0]' <<<"$old_in")
else
  UUID=$($XRAY uuid)
  PRIV=$($XRAY x25519 | awk -F': ' 'NR==1{print $2}')
  SID=$(openssl rand -hex 8)
fi
# 新旧版本输出都是「第 1 行私钥、第 2 行公钥」
PUB=$($XRAY x25519 -i "$PRIV" | awk -F': ' 'NR==2{print $2}')

tmp=$(mktemp --suffix=.json)   # xray 靠扩展名识别配置格式
jq -n --arg uuid "$UUID" --arg priv "$PRIV" --arg sid "$SID" --arg sni "$SNI" --argjson port "$PORT" '{
  log: {access: "none", error: "/var/log/xray/error.log", loglevel: "warning"},
  routing: {domainStrategy: "IPIfNonMatch", rules: [
    {type: "field", protocol: ["bittorrent"], outboundTag: "block"},
    {type: "field", ip: ["geoip:private"], outboundTag: "block"}
  ]},
  inbounds: [{
    tag: "vless-reality", port: $port, listen: "0.0.0.0", protocol: "vless",
    settings: {clients: [{id: $uuid, flow: "xtls-rprx-vision"}], decryption: "none"},
    streamSettings: {network: "tcp", security: "reality", realitySettings: {
      dest: "\($sni):443", serverNames: [$sni], privateKey: $priv, shortIds: [$sid]}},
    sniffing: {enabled: true, destOverride: ["http", "tls"], routeOnly: true}
  }],
  outbounds: [{tag: "direct", protocol: "freedom"}, {tag: "block", protocol: "blackhole"}]
}' > "$tmp"
$XRAY run -test -config "$tmp" | tail -1
install -m 0644 "$tmp" "$CFG" && rm -f "$tmp"
systemctl enable xray >/dev/null 2>&1
systemctl restart xray
sleep 1; systemctl is-active xray

echo "== 5/7 防火墙"
SSH_PORT=$(sshd -T | awk '/^port /{p=$2} END{print p}')
ufw allow "$SSH_PORT/tcp" >/dev/null
ufw allow "$PORT/tcp" >/dev/null
ufw --force enable

echo "== 6/7 SSH 与 fail2ban"
# 没有公钥就禁密码登录会把自己锁在外面，所以只在已放公钥时才改
if [[ -s /root/.ssh/authorized_keys ]]; then
  # 排在 50-cloud-init.conf 之前，sshd 对同一项取首个值
  cat > /etc/ssh/sshd_config.d/00-key-only.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
  sshd -t && systemctl reload ssh
else
  echo "未找到 /root/.ssh/authorized_keys，保留密码登录（放好公钥后重跑本脚本即改为仅密钥）"
fi

IP=$(curl -fsS4 --max-time 10 https://api.ipify.org || hostname -I | awk '{print $1}')
# 经本出口登录 SSH 时来源 IP 就是本机公网 IP，别把自己封了
cat > /etc/fail2ban/jail.d/10-ignore-self.local <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 $IP $EXTRA_IGNORE
banaction = nftables
banaction_allports = nftables[type=allports]

[sshd]
enabled = true
backend = systemd
EOF
systemctl restart fail2ban

echo "== 7/7 BBR"
if [[ $(sysctl -n net.ipv4.tcp_congestion_control) != bbr ]]; then
  printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' > /etc/sysctl.d/90-bbr.conf
  sysctl -q -p /etc/sysctl.d/90-bbr.conf
fi
sysctl -n net.ipv4.tcp_congestion_control

out=/root/xray-client.txt
cat > "$out" <<EOF
地址      $IP
端口      $PORT
UUID      $UUID
flow      xtls-rprx-vision
SNI       $SNI
公钥 pbk  $PUB
shortId   $SID
fp        chrome
链接      vless://$UUID@$IP:$PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$SNI&fp=chrome&pbk=$PUB&sid=$SID&type=tcp#$IP
EOF
chmod 600 "$out"
echo; cat "$out"; echo; echo "已保存到 $out"
