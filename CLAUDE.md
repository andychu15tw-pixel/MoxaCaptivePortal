# CLAUDE.md — MoxaCaptivePortal

## 遠端設備存取

```python
from scripts.remote import RemoteBox, moxa_box, ubuntu_client

# Moxa gateway (direct)
box = moxa_box()                    # 10.90.35.42 / moxa / admin@123
out, err = box.run('hostname')
out, err = box.sudo('systemctl status chilli', pw='admin@123')

# Ubuntu LAN client (jump through Moxa)
gw  = moxa_box()
lan = ubuntu_client(gw)             # 192.168.182.2 / moxa / moxa

# Context manager (auto close)
with moxa_box() as box:
    print(box.out('uptime'))
```

| 設備 | IP | User | Password |
|------|----|------|----------|
| Moxa V2426 (gateway) | 10.90.35.42 | moxa | admin@123 |
| Ubuntu client (LAN)  | 192.168.182.2 | moxa | moxa |

sudo password = 登入密碼（兩台都一樣）

## 關鍵檔案位置（Moxa box）

| 檔案 | 用途 |
|------|------|
| `/etc/chilli.conf` | CoovaChilli 主設定 |
| `/etc/chilli/defaults` | HS_* 環境變數 |
| `/etc/chilli/www/hotspotlogin.cgi` | Portal 登入頁 |
| `/etc/freeradius/3.0/mods-enabled/sql` | RADIUS DB 連線 |
| `/opt/daloradius/` | daloRADIUS（flat 結構，無 app/子目錄） |
| `/etc/nftables.conf` | Firewall + NAT |
| `/var/log/chilli.log` | Chilli syslog |

## daloRADIUS Web UI

- URL: `https://10.90.35.42/daloradius/`
- 帳號: `administrator` / `radius`（預設，上線前改）
- 踢人頁: `https://10.90.35.42/daloradius/config-maint-disconnect-user.php?username=<user>`
- 編輯帳號: `https://10.90.35.42/daloradius/mng-edit.php?username=<user>`

## 常用指令

```bash
# chilli 狀態
systemctl status chilli
journalctl -u chilli -n 50 --no-pager

# RADIUS 測試
radtest testuser test1234 127.0.0.1 0 <secret>

# 查在線 sessions
mysql -u root radius -e "SELECT username,framedipaddress,acctstarttime FROM radacct WHERE acctstoptime IS NULL;"

# nftables
nft list ruleset

# WISPr 限速（bps）
mysql -u root radius -e "SELECT * FROM radreply WHERE username='testuser';"
```

## 專案階段

- **v0 PoC** ✅ — DHCP / redirect / RADIUS auth / accounting
- **v1 MVP** ✅ — daloRADIUS / portal 客製 / WISPr 限速 / CoA 踢人 / firewall
- **v2** 🔲 — Cellular WAN / WAN failover / 壓測 / SNMP / rsyslog
