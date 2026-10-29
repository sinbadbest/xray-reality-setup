# xray-reality-setup

在全新服务器上一键部署 Xray 出口：VLESS + Reality + XTLS Vision，装完直接给出 v2rayN 可粘贴的导入链接。

支持的系统（需要 systemd）：

- Debian 11+ / Ubuntu 22.04+（apt）
- Rocky Linux / AlmaLinux / CentOS Stream / RHEL 8+（dnf；fail2ban 来自 EPEL，RHEL 本体需先自行启用 EPEL）

Fedora、openSUSE、Arch、Alpine 等暂不支持。

## 安装

用 root 运行：

```bash
bash <(curl -Ls https://raw.githubusercontent.com/sinbadbest/xray-reality-setup/main/install.sh)
```

可选参数（环境变量）：

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `PORT` | 20000–60000 随机 | 监听端口 |
| `SNI` | `www.ebay.com` | Reality 伪装目标 |
| `EXTRA_IGNORE` | 空 | fail2ban 额外白名单 IP，空格分隔 |

```bash
PORT=36703 EXTRA_IGNORE="1.2.3.4" bash <(curl -Ls https://raw.githubusercontent.com/sinbadbest/xray-reality-setup/main/install.sh)
```

装完会打印客户端参数和 `vless://` 导入链接，并保存到 `/root/xray-client.txt`（最后一行就是链接，`tail -1 /root/xray-client.txt` 可再次查看）。

## 导入 v2rayN

1. 复制脚本最后输出的那一整行 `vless://...`
2. 在 v2rayN 主界面按 `Ctrl+V`（或菜单「服务器 → 从剪贴板导入分享链接」）
3. 选中新出现的节点，设为活动服务器

同一条链接也能导入 v2rayNG、Shadowrocket、NekoBox 等客户端。

## 做了什么

1. 内存不足 2 GB 且没有 swap 时建 2 GB swapfile
2. 安装 fail2ban、防火墙和自动安全更新：Debian/Ubuntu 用 ufw + unattended-upgrades，RHEL 系用 firewalld + dnf-automatic（只装安全更新）
3. 用官方 [XTLS/Xray-install](https://github.com/XTLS/Xray-install) 安装 Xray，服务以专用用户 `xray` 运行，配置文件 640 只给 `xray` 组读
4. 生成 UUID、x25519 密钥、shortId 并写入 `/usr/local/etc/xray/config.json`：
   - 不记访问日志
   - 屏蔽 BT 和内网地址，不屏蔽国内 IP
   - 只接受指定 SNI 和 shortId（不接受空值）
5. 防火墙只放行 SSH 端口和 Xray 端口
6. `/root/.ssh/authorized_keys` 里有有效公钥时改为仅密钥登录，否则保留密码登录；fail2ban 保护 sshd，并把本机公网 IP 加入白名单
7. 未启用 BBR 时启用

重复运行安全：已有配置时沿用原 UUID、密钥、shortId、端口和 SNI（此时传入的 `PORT`/`SNI` 不生效）。放好公钥后重跑一次即可关闭密码登录。

## 许可证

[MIT](LICENSE)

## 常用命令

```bash
systemctl status xray
cat /root/xray-client.txt
xray run -test -config /usr/local/etc/xray/config.json
```
