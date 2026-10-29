# xray-reality-setup

在全新的 Debian 12/13 服务器上一键部署 Xray 出口：VLESS + Reality + XTLS Vision。

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

装完会打印客户端参数和 `vless://` 链接，并保存到 `/root/xray-client.txt`。

## 做了什么

1. 内存不足 2 GB 且没有 swap 时建 2 GB swapfile
2. 安装 ufw、fail2ban、unattended-upgrades（自动安全更新）
3. 用官方 [XTLS/Xray-install](https://github.com/XTLS/Xray-install) 安装 Xray，服务以 `nobody` 运行
4. 生成 UUID、x25519 密钥、shortId 并写入 `/usr/local/etc/xray/config.json`：
   - 不记访问日志
   - 屏蔽 BT 和内网地址，不屏蔽国内 IP
   - 只接受指定 SNI 和 shortId（不接受空值）
5. ufw 只放行 SSH 端口和 Xray 端口
6. 已放 `/root/.ssh/authorized_keys` 时改为仅密钥登录，否则保留密码登录；fail2ban 保护 sshd，并把本机公网 IP 加入白名单
7. 未启用 BBR 时启用

重复运行安全：已有配置时沿用原 UUID、密钥、shortId 和端口。

## 常用命令

```bash
systemctl status xray
cat /root/xray-client.txt
xray run -test -config /usr/local/etc/xray/config.json
```
