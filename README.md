# Moxa Captive Portal Gateway

Captive Portal Gateway 部署於 **Moxa 工業電腦** (PRD 目標 V2400 / V3400 x86；reference deployment 於 i.MX 8M Plus aarch64)，做 NAC、Captive Portal 認證、AAA 整合與流量管控。

實作原則：**整合現成套件，盡量不寫程式**。

---

## 軟體棧

| 層 | 套件 | 用途 |
|----|------|------|
| Captive Portal | **CoovaChilli 1.6** (build from source) | UAM redirect、DHCP、RADIUS client |
| Portal 登入頁 | 自寫 Perl `hotspotlogin.cgi` | Coova UAM CHAP flow |
| AAA | **FreeRADIUS 3** + **MariaDB** | 認證 / 授權 / Accounting |
| Admin Web UI | **daloRADIUS 1.3** | 使用者管理、報表、計費 |
| Web Server | **Apache 2.4** + PHP | daloRADIUS + cgi 主機 |
| DNS proxy | **dnsmasq** (separate instance on tun0:53) | client DNS proxy |
| Firewall / NAT | **nftables** | pre/post-auth 規則、masquerade |
| Cellular WAN (v2) | **ModemManager** + **keepalived** | 4G/5G + failover |
| Logs / SNMP | **rsyslog** + **snmpd** | logging / monitoring |

自寫程式碼總量：**~150 行 Perl** (`hotspotlogin.cgi`) + **~30 行 PHP** (`index.php` redirect helper) + **shell 部署腳本**。

---

## 目錄結構

```
.
├── PRD.md                       產品需求文件
├── README.md                    本檔
├── install/                     分段部署 shell 腳本
│   ├── lib.sh                     共用 helper（log / backup / envsubst whitelist）
│   ├── 00-base.sh                 apt 套件 + sysctl + 網路介面
│   ├── 00b-build-chilli.sh        從 source 編 CoovaChilli 1.6
│   ├── 01-mariadb.sh              MariaDB + 建 DB
│   ├── 02-freeradius.sh           FreeRADIUS schema + sql module + chilli NAS + test user
│   ├── 03-chilli.sh               chilli config + captive-dnsmasq DNS proxy
│   ├── 04-portal-branding.sh      logo / css / login.html / index.php / hotspotlogin.cgi
│   ├── 05-daloradius.sh           daloRADIUS at /opt/daloradius + Apache vhost
│   ├── 06-nftables.sh             firewall + NAT
│   ├── 07-services.sh             rsyslog + snmpd + healthcheck + Restart=always
│   └── 08-cellular.sh             v2 stub (cellular WAN)
├── configs/                     設定模板
│   ├── apache/                    daloRADIUS Apache vhost
│   ├── chilli/                    chilli.conf, defaults, www/{cgi,html,css,svg,php}
│   ├── freeradius/                clients-chilli + sql-mysql template
│   ├── network/                   /etc/network/interfaces 模板
│   ├── nftables/                  firewall ruleset
│   ├── rsyslog/                   logging routes + logrotate
│   ├── snmpd/                     SNMPv3 conf
│   ├── sysctl/                    forwarding + console log level
│   └── systemd/                   captive-dnsmasq + captive-healthcheck units
└── docs/
    ├── deployment-runbook.md      動手部署指引（hardware-specific notes）
    ├── verification.md            端對端驗證項
    └── lessons.md                 部署遇到的坑與解法（每位接手者必讀）
```

---

## 部署流程（簡版）

詳見 [docs/deployment-runbook.md](docs/deployment-runbook.md)。

```bash
# 1. scp 整個 repo 到 Moxa
scp -r MoxaCaptivePortal moxa@<gw-ip>:/home/moxa/

# 2. 在 Moxa 上依序跑（每隻 idempotent）
cd /home/moxa/MoxaCaptivePortal/install
sudo ./00-base.sh             # 套件 + sysctl + 介面
sudo ./00b-build-chilli.sh    # 編 CoovaChilli (Debian 11/12 無 apt 套件)
sudo ./01-mariadb.sh          # MariaDB
sudo ./02-freeradius.sh       # FreeRADIUS + DB schema + chilli NAS + testuser
sudo ./03-chilli.sh           # chilli + captive-dnsmasq
sudo ./04-portal-branding.sh  # portal 靜態資源 + cgi
sudo ./05-daloradius.sh       # daloRADIUS Web UI
sudo ./06-nftables.sh         # firewall
sudo ./07-services.sh         # 日誌 + 監控 + watchdog
```

時間：i.MX 8M Plus 約 10-15 分鐘（含 CoovaChilli build ~3 min）。

### 介面命名

預設 `WAN_IF=eth0` / `LAN_IF=eth1`。實機若為 `eno1` / `eno2` 等，覆蓋：

```bash
WAN_IF=eno1 LAN_IF=eno2 sudo ./00-base.sh
```

---

## 第一次登入

| 項 | URL / 帳密 |
|---|-----------|
| Admin UI | `https://<gw-ip>/daloradius/login.php` |
| Default operator | `administrator` / `radius` ← **裝完立刻改** |
| Test user (RADIUS) | `testuser` / `test1234` (DB radcheck 已 seed) |
| Secrets | `/etc/captive-portal/secrets.env` (root only) |

---

## 驗證

見 [docs/verification.md](docs/verification.md)。

關鍵 client-side 端對端測試：
```bash
# Ubuntu / Debian client 接 LAN port
sudo dhclient -r eno2 && sudo dhclient eno2          # 重拿 DHCP
nslookup example.com 192.168.182.1                   # 應回真實 IP
firefox http://neverssl.com                          # 應跳 portal
# 輸 testuser / test1234 → 「登入成功」 → 上網
```

---

## 已知差異 / 風險

| 項 | 說明 |
|---|------|
| Hardware | PRD 目標 x86 V2400/V3400；ref deployment 在 aarch64 (i.MX 8M Plus) |
| OS | Debian 11 (bullseye) on Moxa BSP；scripts 兼容 Debian 12 |
| `coova-chilli` | Debian 套件已從 10+ 移除，必從 source build |
| TLS cert | `05-daloradius.sh` 產 self-signed，production 需換 Let's Encrypt |
| `MGMT_NET` | 預設 `0.0.0.0/0` 避免首次部署鎖死，**production 收緊** |
| `8.8.8.8 / 1.1.1.1` | 公司網路常擋；`captive-dnsmasq` 用 `/etc/resolv.conf` 上游 |

詳細坑點與解法見 [docs/lessons.md](docs/lessons.md)。

---

## v2 待辦（未實作）

- Cellular WAN + WAN failover (`08-cellular.sh` 是 stub)
- 100 client 同時登入壓測 (PRD 5.1)
- 72hr 穩定性測試 (PRD 6.3)
- IPv6 完整支援
- HA / 雙機備援
