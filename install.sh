#!/usr/bin/env bash
# 新服务器一键部署 xray 出口（VLESS + Reality + vision），root 运行。
# 支持：Debian / Ubuntu（apt），Rocky / AlmaLinux / CentOS Stream / RHEL 8+（dnf），需要 systemd。
# 用法：bash <(curl -Ls https://raw.githubusercontent.com/sinbadbest/xray-reality-setup/main/install.sh)
#       PORT=36703 SNI=www.ebay.com EXTRA_IGNORE="1.2.3.4" bash <(curl -Ls ...)
# 重复运行安全：已有配置时沿用原 UUID/密钥/shortId，客户端不用改。
set -euo pipefail

PORT=${PORT:-$(shuf -i 20000-60000 -n 1)}
SNI=${SNI:-www.ebay.com}
EXTRA_IGNORE=${EXTRA_IGNORE:-}   # fail2ban 额外白名单，空格分隔（如其他出口 IP）
CFG=/usr/local/etc/xray/config.json
XRAY=/usr/local/bin/xray

die() { echo "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "请用 root 运行"
[[ -d /run/systemd/system ]] || die "需要 systemd"
# shellcheck source=/dev/null
. /etc/os-release
if command -v apt-get >/dev/null; then
  OS=deb
elif command -v dnf >/dev/null && [[ " ${ID_LIKE:-} $ID " =~ [[:space:]](rhel|centos)[[:space:]] ]]; then
  OS=rhel
else
  die "不支持的系统：${PRETTY_NAME:-未知}（支持 Debian/Ubuntu 和 RHEL 系 8+）"
fi
if ! [[ $PORT =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then die "PORT 无效：$PORT"; fi

echo "== 1/7 swap"
if [[ -z $(swapon --show) ]] && (( $(awk '/MemTotal/{print $2}' /proc/meminfo) < 2000000 )); then
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile swap swap defaults 0 0' >> /etc/fstab
fi

echo "== 2/7 软件包与自动安全更新（${PRETTY_NAME:-$ID}）"
if [[ $OS == deb ]]; then
  export DEBIAN_FRONTEND=noninteractive
  # 新开机器的 unattended-upgrades 常占着 dpkg 锁，等它而不是直接失败
  APT=(apt-get -o DPkg::Lock::Timeout=600)
  "${APT[@]}" update -q
  "${APT[@]}" install -yq curl jq openssl ufw nftables fail2ban python3-systemd unattended-upgrades
  printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' \
    > /etc/apt/apt.conf.d/20auto-upgrades
else
  # fail2ban 在 EPEL；RHEL 本体没有 epel-release 包，需先按 EPEL 官方文档启用
  dnf install -y epel-release || rpm -q epel-release >/dev/null || die "无法启用 EPEL"
  # 不装 curl：最小化镜像自带 curl-minimal，装 curl 会冲突；fail2ban 元包会拉进 sendmail，只装 server
  dnf install -y jq openssl firewalld nftables fail2ban-server python3-systemd dnf-automatic
  sed -i -E 's/^upgrade_type\s*=.*/upgrade_type = security/; s/^apply_updates\s*=.*/apply_updates = yes/' /etc/dnf/automatic.conf
  systemctl enable --now dnf-automatic.timer
fi

echo "== 3/7 安装 xray（官方 XTLS/Xray-install，服务以专用用户 xray 运行）"
installer=$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh) \
  || die "下载 Xray 官方安装脚本失败"
bash -c "$installer" @ install

echo "== 4/7 生成配置"
old_in=$(jq -c 'first(.inbounds[]? | select(.protocol == "vless" and .streamSettings.security == "reality"))' \
  "$CFG" 2>/dev/null || true)
if [[ -n $old_in ]]; then
  echo "沿用已有凭据（忽略本次传入的 PORT/SNI）"
  UUID=$(jq -r '.settings.clients[0].id // empty' <<<"$old_in")
  PRIV=$(jq -r '.streamSettings.realitySettings.privateKey // empty' <<<"$old_in")
  SID=$(jq -r '.streamSettings.realitySettings.shortIds[0] // empty' <<<"$old_in")
  PORT=$(jq -r '.port' <<<"$old_in")
  SNI=$(jq -r '.streamSettings.realitySettings.serverNames[0] // empty' <<<"$old_in")
  [[ -n $UUID && -n $PRIV && -n $SID && -n $SNI ]] || die "$CFG 里的旧入站不完整，请手动处理"
else
  UUID=$($XRAY uuid)
  PRIV=$($XRAY x25519 | awk -F': ' 'NR==1{print $2}')
  SID=$(openssl rand -hex 8)
fi
# 新旧版本输出都是「第 1 行私钥、第 2 行公钥」
PUB=$($XRAY x25519 -i "$PRIV" | awk -F': ' 'NR==2{print $2}')

tmp=$(mktemp --suffix=.json)   # xray 靠扩展名识别配置格式
trap 'rm -f "$tmp"' EXIT        # 含私钥，失败退出也要删
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
install -m 640 -o 0 -g xray "$tmp" "$CFG"   # 与官方安装脚本一致：含私钥，只给 xray 组读
systemctl enable xray >/dev/null 2>&1
systemctl restart xray
sleep 1; systemctl is-active xray

echo "== 5/7 防火墙"
SSH_PORTS=$(sshd -T | awk '/^port /{print $2}')
if [[ $OS == deb ]]; then
  for p in $SSH_PORTS $PORT; do ufw allow "$p/tcp" >/dev/null; done
  ufw --force enable
else
  systemctl enable --now firewalld
  for p in $SSH_PORTS $PORT; do firewall-cmd -q --permanent --add-port="$p/tcp"; done
  firewall-cmd -q --reload
fi

echo "== 6/7 SSH 与 fail2ban"
# Debian/Ubuntu 的单元叫 ssh.service，RHEL 系叫 sshd.service；fail2ban 按单元名匹配日志
if systemctl cat ssh.service >/dev/null 2>&1; then SSH_UNIT=ssh.service; else SSH_UNIT=sshd.service; fi
# 没有公钥就禁密码登录会把自己锁在外面，所以只在已放公钥时才改
if ssh-keygen -lf /root/.ssh/authorized_keys >/dev/null 2>&1; then
  # 排在 50-cloud-init.conf 之前，sshd 对同一项取首个值；ChallengeResponse 写法新旧 OpenSSH 都认
  keyonly=/etc/ssh/sshd_config.d/00-key-only.conf
  mkdir -p /etc/ssh/sshd_config.d
  cat > "$keyonly" <<'EOF'
PasswordAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin prohibit-password
EOF
  # 配置坏了不能留着，否则下次重启 sshd 起不来
  sshd -t || { rm -f "$keyonly"; die "sshd 配置检查失败，已撤回"; }
  systemctl try-reload-or-restart "$SSH_UNIT"
  sshd -T | grep -qx 'passwordauthentication no' \
    || echo "警告：sshd_config 没有 Include sshd_config.d（如 RHEL 8），密码登录仍开着，请手动设 PasswordAuthentication no" >&2
else
  echo "/root/.ssh/authorized_keys 里没有有效公钥，保留密码登录（放好公钥后重跑本脚本即改为仅密钥）"
fi

IP=$(curl -fsS4 --max-time 10 https://api.ipify.org \
  || ip -4 route get 1.1.1.1 | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}')
# 经本出口登录 SSH 时来源 IP 就是本机公网 IP，别把自己封了
cat > /etc/fail2ban/jail.d/10-ignore-self.local <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 $IP $EXTRA_IGNORE
banaction = nftables
banaction_allports = nftables[type=allports]

[sshd]
enabled = true
backend = systemd
journalmatch = _SYSTEMD_UNIT=$SSH_UNIT + _COMM=sshd
EOF
systemctl enable fail2ban >/dev/null 2>&1
systemctl restart fail2ban

echo "== 7/7 BBR"
if [[ $(sysctl -n net.ipv4.tcp_congestion_control) != bbr ]]; then
  printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' > /etc/sysctl.d/90-bbr.conf
  sysctl -q -p /etc/sysctl.d/90-bbr.conf
fi
sysctl -n net.ipv4.tcp_congestion_control

# v2rayN / v2rayNG / Shadowrocket 等通用的 VLESS 分享链接格式；备注要 URL 编码
NAME=$(jq -rn --arg n "reality-$IP" '$n | @uri')
LINK="vless://$UUID@$IP:$PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$SNI&fp=chrome&pbk=$PUB&sid=$SID&type=tcp&headerType=none#$NAME"
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

$LINK
EOF
chmod 600 "$out"
cat <<EOF

客户端参数已保存到 $out（最后一行是导入链接，可用 tail -1 $out 再次查看）

==== v2rayN 导入：复制下面整行，在 v2rayN 主界面按 Ctrl+V（或「服务器 → 从剪贴板导入分享链接」）====
$LINK
EOF
