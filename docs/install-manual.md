# Captive Portal Gateway — 從零手動安裝手冊

> 本手冊：在一台空白 Debian 12 (bookworm) x86_64 機器上，**完全用手** 把整套 Captive Portal Gateway 架起來，不依賴 `install/*.sh` 自動腳本。
>
> 適用：理解原理、客製化部署、debug、出貨前 review。
>
> 自動化腳本仍在 `install/` 目錄；本手冊把每個 phase 的實際指令拆解出來，加上設計動機與設定說明。

---

## 目錄

1. [系統架構與元件](#1-系統架構與元件)
2. [硬體 / OS 前置](#2-硬體--os-前置)
3. [Phase A — Base OS Prep](#3-phase-a--base-os-prep)
4. [Phase A.5 — 從 source build CoovaChilli](#4-phase-a5--從-source-build-coovachilli)
5. [Phase B-1 — MariaDB](#5-phase-b-1--mariadb)
6. [Phase B-2 — FreeRADIUS](#6-phase-b-2--freeradius)
7. [Phase C — CoovaChilli 設定 + dnsmasq](#7-phase-c--coovachilli-設定--dnsmasq)
8. [Phase D — Portal 客製](#8-phase-d--portal-客製)
9. [Phase E — daloRADIUS Web UI + Apache](#9-phase-e--daloradius-web-ui--apache)
10. [Phase F — nftables 防火牆 + NAT](#10-phase-f--nftables-防火牆--nat)
11. [Phase H — Logging + SNMP](#11-phase-h--logging--snmp)
12. [Phase I — Healthcheck](#12-phase-i--healthcheck)
13. [完整驗證](#13-完整驗證)
14. [疑難排解](#14-疑難排解)

---

## 1. 系統架構與元件

### 拓樸

```
                 +---------------------------+
                 |  Captive Portal Gateway   |
                 |  Debian 12 x86_64         |
                 |                           |
[Wi-Fi AP] ─── eth1 ──── tun0 ─── chilli ─── eth0 ─── [Internet]
                         192.168.182.1/24            10.x.x.x/?
                         (LAN-side virtual)          (WAN DHCP)
                         |
                 ┌───────┴────────┐
                 │ FreeRADIUS     │ ← chilli sends auth/acct/CoA here
                 │ 127.0.0.1:1812 │
                 └────────────────┘
                         │
                 ┌───────┴────────┐
                 │ MariaDB        │ ← user / acct / nas tables
                 └────────────────┘
                         │
                 ┌───────┴────────┐
                 │ daloRADIUS Web │ ← https://<gw>/daloradius/
                 │ (Apache + PHP) │
                 └────────────────┘
```

### 元件職責一覽

| 元件 | 套件 | 職責 |
|------|------|------|
| **CoovaChilli** | source build (1.6) | NAS — DHCP server、UAM redirect、RADIUS client、L3 ACL、conntrack mark |
| **FreeRADIUS** | freeradius freeradius-mysql | 認證 (PAP/CHAP/MS-CHAP)、授權 (radreply / WISPr)、accounting |
| **MariaDB** | mariadb-server | radius DB（radcheck/radreply/radacct/nas）+ daloRADIUS extras |
| **Apache + PHP** | apache2 php php-mysql php-db php-pear ... | daloRADIUS Web UI、portal CGI 容器 |
| **daloRADIUS** | github tarball at /opt/daloradius | Web 管理介面 (user/group/acct/CoA) |
| **dnsmasq** | dnsmasq-base | 在 tun0 上 listen 53，給 client DNS（chilli 自己不開 53 listener） |
| **nftables** | nftables | INPUT 防火牆 + WAN MASQUERADE NAT |
| **rsyslog** | rsyslog | 把 chilli (local3) + nft drop 路由到 dedicated log files |
| **snmpd** | snmpd | SNMPv3 監控介面 |
| **healthcheck** | systemd service | curl portal cgi 失敗 → 自動 restart chilli |
| **portal CGI** | haserl + login.chi | Captive portal 登入頁（HTML 表單 + CHAP 計算） |

### 為何這些選擇

| 決策 | 理由 |
|------|------|
| **CoovaChilli 而非 hostapd** | chilli 是純 L3 NAS，可搭配任何 AP；hostapd 強制 Moxa 自己當 AP |
| **Source build chilli** | Debian 移除 `coova-chilli` 套件後 (Debian 9 後)，只能自己 build |
| **FreeRADIUS + DB-backed users** | 工業標準，daloRADIUS 直接管 DB 即等於管 user |
| **MariaDB（非 SQLite）** | daloRADIUS 需要 MySQL 相容；多服務共享 DB |
| **daloRADIUS 非自寫 UI** | 現成、PHP 即裝、夠用 |
| **`/opt/daloradius`（非 `/var/www`）** | Moxa 工業電腦的 ThingsPro 把 `/var/www` 連到受限 path，Apache 跟 symlink 會失敗 |
| **Apache HTTP (port 80) 給 portal** | OS captive-portal probe 走 HTTP，自簽 HTTPS 會破 CNA 自動跳出 |
| **dnsmasq 獨立 service** | chilli 1.6 不在 tun0 開 53 listener；client DHCP 拿到 192.168.182.1:53 必須有人接 |
| **nftables（非 iptables）** | Debian 12 預設、語法清楚 |

---

## 2. 硬體 / OS 前置

### 硬體最低需求

| 項目 | 最低 | 推薦 |
|------|------|------|
| CPU | x86_64 dual-core | Moxa V2426 / V3401 工業電腦 |
| RAM | 2 GB | 4 GB |
| 儲存 | 16 GB | 64 GB SSD |
| 網卡 | 2 個 (WAN + LAN) | 2+ |

### 命名約定

本手冊假設：
- WAN 介面 = `eth0`（連 internet 的 DHCP 介面）
- LAN 介面 = `eth1`（chilli 接管，接 Wi-Fi AP 或直連 client）

如果你的介面名不同（例如 `enp1s0`），把後面所有 `eth0` / `eth1` 替換成你的實際名稱。

### OS 安裝

1. 裝 Debian 12 (bookworm) **netinst** 或 **DVD**，server 模式（不選 desktop）
2. 設 hostname、root 密碼、admin 帳號
3. 確認 SSH 可從管理網段連入：
   ```bash
   sudo apt install -y openssh-server
   sudo systemctl enable --now ssh
   ```

### 確認介面

```bash
ip link show
# 應看到 eth0, eth1 (或你的實際名稱)
```

---

## 3. Phase A — Base OS Prep

對應 `install/00-base.sh`。目的：裝套件、設 sysctl、寫 `/etc/network/interfaces`。

### 3.1 安裝所有套件

```bash
sudo apt update
sudo DEBIAN_FRONTEND=noninteractive apt install -y --no-install-recommends \
  nftables \
  freeradius freeradius-mysql freeradius-utils \
  mariadb-server \
  apache2 \
  php php-mysql php-mbstring php-gd php-curl php-xml php-zip \
  php-db php-pear \
  libapache2-mod-php \
  modemmanager \
  dnsmasq-base \
  iproute2 conntrack iputils-ping curl wget \
  rsyslog logrotate \
  snmpd snmp \
  keepalived \
  openssl ca-certificates \
  gettext-base \
  haserl \
  libcgi-pm-perl \
  git build-essential autoconf automake libtool pkg-config \
  libssl-dev libcurl4-openssl-dev libjson-c-dev libnl-3-dev libnl-genl-3-dev \
  gengetopt debhelper devscripts
```

> `coova-chilli` 不在這裡 — Debian 12 已不提供 .deb，下個 phase 自己 build。

### 3.2 sysctl — 啟用 forwarding 與 conntrack

寫 `/etc/sysctl.d/99-gateway.conf`：

```bash
sudo tee /etc/sysctl.d/99-gateway.conf > /dev/null <<'EOF'
net.ipv4.ip_forward=1
net.netfilter.nf_conntrack_max=131072
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.send_redirects=0
net.ipv4.conf.all.rp_filter=1
EOF

sudo sysctl --system
sudo modprobe nf_conntrack
sudo modprobe nf_nat
```

### 3.3 寫 `/etc/network/interfaces`

```bash
sudo cp /etc/network/interfaces /etc/network/interfaces.orig

sudo tee /etc/network/interfaces > /dev/null <<'EOF'
# WAN — DHCP from upstream
auto eth0
iface eth0 inet dhcp

# LAN — handed to CoovaChilli (no IP, chilli puts 192.168.182.1 on tun0)
auto eth1
iface eth1 inet manual
    up ip link set $IFACE up
    down ip link set $IFACE down
EOF
```

### 3.4 停用 NetworkManager（如有）

```bash
if systemctl is-enabled NetworkManager >/dev/null 2>&1; then
    sudo systemctl disable --now NetworkManager
fi
```

### 3.5 建立 secrets 與 env 目錄

```bash
sudo mkdir -p /etc/captive-portal
sudo tee /etc/captive-portal/interfaces.env > /dev/null <<EOF
WAN_IF=eth0
LAN_IF=eth1
EOF
```

> Phase B-1 與 Phase B-2 會在 `/etc/captive-portal/secrets.env` 寫入隨機產生的密碼與 secret。先把目錄建好。

```bash
# 產生隨機 secrets（24-byte hex）
RADIUS_DB_PASS=$(openssl rand -hex 24)
CHILLI_RADIUS_SECRET=$(openssl rand -hex 24)
CHILLI_UAM_SECRET=$(openssl rand -hex 24)

sudo tee /etc/captive-portal/secrets.env > /dev/null <<EOF
RADIUS_DB_PASS=${RADIUS_DB_PASS}
CHILLI_RADIUS_SECRET=${CHILLI_RADIUS_SECRET}
CHILLI_UAM_SECRET=${CHILLI_UAM_SECRET}
EOF
sudo chmod 600 /etc/captive-portal/secrets.env
sudo chown root:root /etc/captive-portal/secrets.env
```

**重要：把 `secrets.env` 內容備份，後面所有 phase 共用同一份 secret。**

> 介面 rename 後**重開機**比較保險。

---

## 4. Phase A.5 — 從 source build CoovaChilli

對應 `install/00b-build-chilli.sh`。Debian 12 沒 `coova-chilli` package，必須自己 build。

### 4.1 Clone repo

```bash
sudo git clone https://github.com/coova/coova-chilli.git /usr/local/src/coova-chilli
cd /usr/local/src/coova-chilli
sudo git fetch --tags --force
sudo git checkout 1.6   # 或更新 tag
```

### 4.2 處理 gengetopt 不相容 patch（重要！）

Debian 12 的 gengetopt 版本與 chilli 1.6 內附 `cmdline.patch` 不相容，會在 build 時 fail。把 patch 變空檔即可繞過：

```bash
[ -f src/cmdline.patch ] && sudo truncate -s 0 src/cmdline.patch
```

### 4.3 Bootstrap + configure

```bash
sudo ./bootstrap

sudo CFLAGS="-O2 -Wno-error" ./configure \
  --prefix=/usr \
  --sysconfdir=/etc \
  --localstatedir=/var \
  --mandir=/usr/share/man \
  --enable-largelimits \
  --enable-binstatusfile \
  --enable-statusfile \
  --enable-redir \
  --enable-chilliscript \
  --enable-uamuiport \
  --enable-miniportal \
  --enable-layer3 \
  --enable-proxyvsa \
  --enable-miniconfig \
  --enable-eapol \
  --enable-uamdomainfile \
  --with-openssl \
  --without-curl \
  --with-poll
```

> `--without-curl` 是因為 Moxa repo 的 libcurl link test 不穩；UAM portal 不需 chilliredir 的 curl。

### 4.4 Build + install

```bash
sudo make           # 不要用 -j，cmdline.c 會 race
sudo make install
```

### 4.5 寫 systemd unit

upstream 只給 SysV init，自己寫 systemd unit：

```bash
sudo tee /etc/systemd/system/chilli.service > /dev/null <<'EOF'
[Unit]
Description=CoovaChilli Captive Portal
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=/var/run/chilli.pid
EnvironmentFile=-/etc/chilli/defaults
ExecStartPre=/usr/sbin/modprobe tun
ExecStart=/usr/sbin/chilli
Restart=always
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
```

### 4.6 確認 binary

```bash
ldd /usr/sbin/chilli | grep -i "not found"   # 應無輸出
ls -la /usr/sbin/chilli                       # 應 executable
```

---

## 5. Phase B-1 — MariaDB

對應 `install/01-mariadb.sh`。

### 5.1 啟用 + lockdown

```bash
sudo systemctl enable --now mariadb

# 等 socket up
for i in {1..10}; do
  sudo mariadb -e "SELECT 1" >/dev/null 2>&1 && break
  sleep 1
done

# 移除預設 anonymous user / test DB
sudo mariadb <<'SQL'
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.db WHERE Db='test' OR Db='test\_%';
DROP DATABASE IF EXISTS test;
FLUSH PRIVILEGES;
SQL
```

### 5.2 建 radius DB + user

```bash
RADIUS_DB_PASS=$(sudo grep ^RADIUS_DB_PASS= /etc/captive-portal/secrets.env | cut -d= -f2-)

sudo mariadb <<SQL
CREATE DATABASE IF NOT EXISTS \`radius\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'radius'@'localhost' IDENTIFIED BY '$RADIUS_DB_PASS';
ALTER USER 'radius'@'localhost' IDENTIFIED BY '$RADIUS_DB_PASS';
GRANT ALL PRIVILEGES ON \`radius\`.* TO 'radius'@'localhost';
FLUSH PRIVILEGES;
SQL
```

### 5.3 寫 db.env

```bash
sudo tee /etc/captive-portal/db.env > /dev/null <<EOF
RADIUS_DB_NAME=radius
RADIUS_DB_USER=radius
RADIUS_DB_HOST=localhost
EOF
```

### 5.4 驗證

```bash
sudo mariadb -e "SHOW DATABASES;"
# 應看到 radius
sudo mariadb -u radius -p"$RADIUS_DB_PASS" radius -e "SHOW TABLES;"
# 空表正常，下個 phase 匯入 schema
```

---

## 6. Phase B-2 — FreeRADIUS

對應 `install/02-freeradius.sh`。

### 6.1 匯入 RADIUS schema

```bash
sudo mariadb radius < /etc/freeradius/3.0/mods-config/sql/main/mysql/schema.sql

# 驗證
sudo mariadb radius -e "SHOW TABLES;"
# 應看到 radacct radcheck radreply radgroupcheck radgroupreply radusergroup radpostauth nas
```

### 6.2 替換 sql module 設定

預設 `/etc/freeradius/3.0/mods-available/sql` 是多 dialect 模板，改用 minimal MySQL 版：

```bash
RADIUS_DB_PASS=$(sudo grep ^RADIUS_DB_PASS= /etc/captive-portal/secrets.env | cut -d= -f2-)

sudo cp /etc/freeradius/3.0/mods-available/sql /etc/freeradius/3.0/mods-available/sql.orig

sudo tee /etc/freeradius/3.0/mods-available/sql > /dev/null <<EOF
sql {
    driver  = "rlm_sql_mysql"
    dialect = "mysql"

    server      = "localhost"
    port        = 3306
    login       = "radius"
    password    = "${RADIUS_DB_PASS}"
    radius_db   = "radius"

    read_clients = yes
    client_table = "nas"

    accounting_table = "radacct"
    acct_table1      = "radacct"
    acct_table2      = "radacct"
    postauth_table   = "radpostauth"
    authcheck_table  = "radcheck"
    authreply_table  = "radreply"
    groupcheck_table = "radgroupcheck"
    groupreply_table = "radgroupreply"
    usergroup_table  = "radusergroup"

    read_groups          = yes
    delete_stale_sessions = yes
    group_attribute = "SQL-Group"

    pool {
        start          = 1
        min            = 1
        max            = 8
        spare          = 1
        retry_delay    = 30
        idle_timeout   = 60
        connect_timeout = 5
    }

    \$INCLUDE \${modconfdir}/\${.:name}/main/\${dialect}/queries.conf
}
EOF

sudo chown root:freerad /etc/freeradius/3.0/mods-available/sql
sudo chmod 640 /etc/freeradius/3.0/mods-available/sql
sudo ln -sf ../mods-available/sql /etc/freeradius/3.0/mods-enabled/sql
```

### 6.3 啟用 sql 在 sites — default + inner-tunnel

預設 sites 把 `sql` 行注釋掉。把 authorize / accounting / post-auth / session 段內的 `# sql` 改成 `sql`：

```bash
for site in default inner-tunnel; do
  f="/etc/freeradius/3.0/sites-available/$site"
  [ -f "$f" ] || continue
  sudo cp "$f" "$f.orig"
  sudo sed -i 's|^\([[:space:]]*\)#[[:space:]]*sql$|\1sql|g' "$f"
  sudo ln -sf "$f" "/etc/freeradius/3.0/sites-enabled/$site"
done
```

### 6.4 註冊 chilli 為 RADIUS client

預設 `clients.conf` 有個 `client localhost { ... secret = testing123 }`，與我們的 chilli 在 127.0.0.1 衝突。先把它注釋掉：

```bash
sudo cp /etc/freeradius/3.0/clients.conf /etc/freeradius/3.0/clients.conf.orig

# 用 awk 把 client localhost { ... } 整塊變註解
sudo awk '
  /^client[[:space:]]+localhost([[:space:]]|\{)/ && !in_blk {
    print "# DISABLED-BY-CAPTIVE-PORTAL"
    in_blk=1
  }
  in_blk {
    print "# " $0
    if (/^\}/) in_blk=0
    next
  }
  { print }
' /etc/freeradius/3.0/clients.conf.orig | sudo tee /etc/freeradius/3.0/clients.conf > /dev/null

sudo chown freerad:freerad /etc/freeradius/3.0/clients.conf
```

加 chilli client：

```bash
CHILLI_RADIUS_SECRET=$(sudo grep ^CHILLI_RADIUS_SECRET= /etc/captive-portal/secrets.env | cut -d= -f2-)

sudo mkdir -p /etc/freeradius/3.0/clients.d

sudo tee /etc/freeradius/3.0/clients.d/chilli.conf > /dev/null <<EOF
# CoovaChilli on this gateway
client chilli-localhost {
    ipaddr     = 127.0.0.1
    proto      = udp
    secret     = ${CHILLI_RADIUS_SECRET}
    require_message_authenticator = no
    nas_type   = other
    shortname  = chilli
}
EOF

sudo chown root:freerad /etc/freeradius/3.0/clients.d/chilli.conf
sudo chmod 640 /etc/freeradius/3.0/clients.d/chilli.conf

# 確認 clients.conf 有 include
sudo grep -qF '$INCLUDE clients.d/' /etc/freeradius/3.0/clients.conf || \
  echo '$INCLUDE clients.d/' | sudo tee -a /etc/freeradius/3.0/clients.conf
```

### 6.5 種一個測試 user

```bash
sudo mariadb radius <<'SQL'
INSERT IGNORE INTO radcheck (username, attribute, op, value)
    VALUES ('testuser', 'Cleartext-Password', ':=', 'test1234');
INSERT IGNORE INTO radreply (username, attribute, op, value)
    VALUES ('testuser', 'Session-Timeout', ':=', '3600');
INSERT IGNORE INTO radreply (username, attribute, op, value)
    VALUES ('testuser', 'Idle-Timeout', ':=', '600');
SQL
```

### 6.6 啟動 + smoke test

```bash
sudo systemctl enable freeradius
sudo systemctl restart freeradius
sleep 2
sudo systemctl is-active freeradius   # active

# Smoke test
SECRET=$(sudo grep ^CHILLI_RADIUS_SECRET= /etc/captive-portal/secrets.env | cut -d= -f2-)
echo 'User-Name=testuser,User-Password=test1234' | \
  radclient -x 127.0.0.1:1812 auth "$SECRET" 2>&1 | grep Access-
# 期待: Received Access-Accept
```

跑不起來看 log：
```bash
sudo journalctl -u freeradius -n 50
sudo freeradius -CX 2>&1 | tail -30
```

---

## 7. Phase C — CoovaChilli 設定 + dnsmasq

對應 `install/03-chilli.sh`。

### 7.1 寫 `/etc/chilli.conf`

```bash
LAN_IF=$(sudo grep ^LAN_IF= /etc/captive-portal/interfaces.env | cut -d= -f2-)
CHILLI_RADIUS_SECRET=$(sudo grep ^CHILLI_RADIUS_SECRET= /etc/captive-portal/secrets.env | cut -d= -f2-)
CHILLI_UAM_SECRET=$(sudo grep ^CHILLI_UAM_SECRET= /etc/captive-portal/secrets.env | cut -d= -f2-)

sudo tee /etc/chilli.conf > /dev/null <<EOF
# /etc/chilli.conf
dhcpif    ${LAN_IF}
tundev    tun0

net       192.168.182.0/24
uamlisten 192.168.182.1
uamport   3990

dns1 192.168.182.1
dns2 192.168.182.1

radiusserver1 127.0.0.1
radiusserver2 127.0.0.1
radiussecret  ${CHILLI_RADIUS_SECRET}
radiusnasid   moxa-cp-gw
radiusauthport 1812
radiusacctport 1813
acctupdate

uamserver  http://192.168.182.1/cgi-bin/hotspotlogin.cgi
uamhomepage http://192.168.182.1/
uamsecret  ${CHILLI_UAM_SECRET}
uamallowed 192.168.182.1

defsessiontimeout 3600
defidletimeout    600
definteriminterval 300

logfacility 3

coaport 3799
nasmac
swapoctets

# Enable condown hook for conntrack flush on session end (見 §11)
condown /etc/chilli/condown.sh
EOF

sudo chmod 600 /etc/chilli.conf
```

### 7.2 寫 `/etc/chilli/defaults`

login.chi (CGI) 從這讀環境變數：

```bash
WAN_IF=$(sudo grep ^WAN_IF= /etc/captive-portal/interfaces.env | cut -d= -f2-)

sudo tee /etc/chilli/defaults > /dev/null <<EOF
HS_WANIF=${WAN_IF}
HS_LANIF=${LAN_IF}

HS_NETWORK=192.168.182.0
HS_NETMASK=255.255.255.0
HS_UAMLISTEN=192.168.182.1
HS_UAMPORT=3990

HS_NASID=moxa-cp-gw
HS_NASIP=127.0.0.1

HS_RADIUS=127.0.0.1
HS_RADIUS2=127.0.0.1
HS_RADSECRET=${CHILLI_RADIUS_SECRET}
HS_UAMSECRET=${CHILLI_UAM_SECRET}

HS_DNS1=192.168.182.1
HS_DNS2=192.168.182.1

HS_UAMSERVER=192.168.182.1
HS_UAMFORMAT=http://\\\$HS_UAMSERVER/cgi-bin/hotspotlogin.cgi
HS_UAMHOMEPAGE=http://\\\$HS_UAMSERVER/

HS_UAMALLOW=192.168.182.1

HS_DEFSESSIONTIMEOUT=3600
HS_DEFIDLETIMEOUT=600
HS_DEFINTERIMINTERVAL=300

HS_MACAUTH=off
HS_MACAUTHDENY=off

HS_TCP_PORTS="80 443"
EOF

sudo chmod 644 /etc/chilli/defaults
```

### 7.3 啟用 + 移除 SysV init

```bash
# Debian wrapper
[ -f /etc/default/chilli ] && \
  sudo sed -i 's/^START_CHILLI=.*/START_CHILLI=1/' /etc/default/chilli

# 移除 source build 跑 make install 留下的 SysV init script（會擋 systemd）
[ -f /etc/init.d/chilli ] && {
  sudo rm -f /etc/init.d/chilli
  sudo update-rc.d -f chilli remove >/dev/null 2>&1 || true
}

sudo modprobe tun

sudo systemctl enable chilli
sudo systemctl restart chilli
```

### 7.4 等 tun0 起來

```bash
for i in {1..15}; do
  ip link show tun0 >/dev/null 2>&1 && { echo "tun0 up"; break; }
  sleep 1
done

ip -4 addr show tun0
# 應看到 inet 192.168.182.1/24 scope global tun0
```

### 7.5 部署 captive-dnsmasq

chilli 1.6 不在 tun0 開 53 listener，client 需要 DNS：

```bash
sudo tee /etc/systemd/system/captive-dnsmasq.service > /dev/null <<'EOF'
[Unit]
Description=Captive portal DNS server (dnsmasq on tun0)
After=chilli.service
Requires=chilli.service

[Service]
Type=simple
ExecStart=/usr/sbin/dnsmasq -k \
  --interface=tun0 --bind-interfaces \
  --listen-address=192.168.182.1 \
  --no-resolv \
  --server=8.8.8.8 --server=1.1.1.1 \
  --cache-size=1000 \
  --log-facility=- \
  --no-hosts
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now captive-dnsmasq
sleep 1
ss -tunlp | grep '192.168.182.1:53'   # 應看到
```

### 7.6 condown hook（自動 flush conntrack）

```bash
sudo tee /etc/chilli/condown.sh > /dev/null <<'EOF'
#!/bin/sh
# Runs on chilli session end (CoA, idle/session timeout, NAS-Reboot).
# Flush conntrack for entire LAN /24 — single AP env.
LAN_NET="192.168.182.0/24"
BEFORE=$(/usr/sbin/conntrack -L 2>/dev/null | grep -c "src=192.168.182\." || echo 0)
/usr/sbin/conntrack -D -s "$LAN_NET" >/dev/null 2>&1
/usr/sbin/conntrack -D -d "$LAN_NET" >/dev/null 2>&1
AFTER=$(/usr/sbin/conntrack -L 2>/dev/null | grep -c "src=192.168.182\." || echo 0)
logger -t chilli-condown "session ended user=${USER_NAME:-?} mac=${CALLING_STATION_ID:-?} flushed=${BEFORE}->${AFTER}"
exit 0
EOF
sudo chmod 755 /etc/chilli/condown.sh
sudo systemctl restart chilli
```

---

## 8. Phase D — Portal 客製

對應 `install/04-portal-branding.sh`。

### 8.1 客製靜態資源

`/etc/chilli/www/` 內：
- `logo.svg` — portal logo（SVG 或 PNG 都可，記得改 HTML reference）
- `style.css` — CSS
- `login.html` — landing page (optional)
- `index.php` — 首頁

直接覆寫即可：

```bash
# 範例：放自家 logo
sudo cp my-company-logo.svg /etc/chilli/www/logo.svg
sudo chmod 644 /etc/chilli/www/logo.svg
```

### 8.2 hotspotlogin.cgi wrapper

chilli 1.6 ship `login.chi` (haserl script) 但沒 `hotspotlogin.cgi`，要寫 wrapper 給 Apache CGI 容器：

```bash
sudo tee /etc/chilli/www/hotspotlogin.cgi > /dev/null <<'EOF'
#!/bin/bash
# Apache cgi-script wrapper around chilli's haserl login.chi
exec /usr/bin/haserl --shell=sh /etc/chilli/www/login.chi
EOF
sudo chmod 755 /etc/chilli/www/hotspotlogin.cgi
```

### 8.3 中文化 / 客製訊息

直接編 `/etc/chilli/www/login.chi`（haserl，HTML + 簡單 shell expression）。

> 修改 cgi 屬於衍生作品，因 chilli GPL → 你的修改也須 GPL 並提供 source。詳見 license 章節。

---

## 9. Phase E — daloRADIUS Web UI + Apache

對應 `install/05-daloradius.sh`。

### 9.1 下載 daloRADIUS

```bash
DALO_TAG=$(curl -s https://api.github.com/repos/lirantal/daloradius/releases/latest \
  | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name":[[:space:]]*"([^"]+)".*/\1/')

cd /tmp
wget "https://github.com/lirantal/daloradius/archive/refs/tags/${DALO_TAG}.tar.gz" -O dalo.tgz
sudo tar xzf dalo.tgz
sudo mv "daloradius-${DALO_TAG}" /opt/daloradius
sudo chown -R www-data:www-data /opt/daloradius
```

### 9.2 匯入 daloRADIUS schema additions

```bash
for f in /opt/daloradius/contrib/db/mysql-daloradius.sql \
         /opt/daloradius/contrib/db/fr3-mysql-daloradius-and-freeradius.sql; do
  [ -f "$f" ] && sudo mariadb radius < "$f"
done
```

### 9.3 設定 daloradius.conf.php

從 sample 複製 + sed 改 DB 連線：

```bash
RADIUS_DB_PASS=$(sudo grep ^RADIUS_DB_PASS= /etc/captive-portal/secrets.env | cut -d= -f2-)

sudo cp /opt/daloradius/library/daloradius.conf.php.sample \
        /opt/daloradius/library/daloradius.conf.php

sudo sed -i \
  -e "s|^\(\$configValues\['CONFIG_DB_ENGINE'\][[:space:]]*=[[:space:]]*\)'.*';|\1'mysqli';|" \
  -e "s|^\(\$configValues\['CONFIG_DB_HOST'\][[:space:]]*=[[:space:]]*\)'.*';|\1'localhost';|" \
  -e "s|^\(\$configValues\['CONFIG_DB_PORT'\][[:space:]]*=[[:space:]]*\)'.*';|\1'3306';|" \
  -e "s|^\(\$configValues\['CONFIG_DB_USER'\][[:space:]]*=[[:space:]]*\)'.*';|\1'radius';|" \
  -e "s|^\(\$configValues\['CONFIG_DB_PASS'\][[:space:]]*=[[:space:]]*\)'.*';|\1'$RADIUS_DB_PASS';|" \
  -e "s|^\(\$configValues\['CONFIG_DB_NAME'\][[:space:]]*=[[:space:]]*\)'.*';|\1'radius';|" \
  /opt/daloradius/library/daloradius.conf.php

sudo chown www-data:www-data /opt/daloradius/library/daloradius.conf.php
sudo chmod 640 /opt/daloradius/library/daloradius.conf.php

sudo mkdir -p /var/log/daloradius
sudo chown www-data:www-data /var/log/daloradius
```

### 9.4 自簽 TLS 憑證

```bash
sudo openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
  -keyout /etc/ssl/private/captive-portal.key \
  -out /etc/ssl/certs/captive-portal.crt \
  -subj "/CN=moxa-cp-gw"
sudo chmod 600 /etc/ssl/private/captive-portal.key
```

### 9.5 Apache modules + vhost

```bash
sudo a2enmod ssl rewrite headers cgi alias

sudo tee /etc/apache2/sites-available/dalo.conf > /dev/null <<'EOF'
<VirtualHost *:80>
    ServerName moxa-cp-gw

    DocumentRoot /etc/chilli/www
    Alias /style.css   /etc/chilli/www/style.css
    Alias /logo.svg    /etc/chilli/www/logo.svg
    Alias /login.html  /etc/chilli/www/login.html

    ScriptAlias /cgi-bin/ /etc/chilli/www/
    DirectoryIndex index.php
    <Directory "/etc/chilli/www">
        Options +ExecCGI
        AddHandler cgi-script .cgi
        Require all granted
    </Directory>

    RewriteEngine On
    RewriteRule ^/daloradius(.*)$ https://%{HTTP_HOST}/daloradius$1 [R=301,L]

    ErrorLog  ${APACHE_LOG_DIR}/dalo-error.log
    CustomLog ${APACHE_LOG_DIR}/dalo-access.log combined
</VirtualHost>

<VirtualHost *:443>
    ServerName moxa-cp-gw
    DocumentRoot /var/www/html

    SSLEngine on
    SSLCertificateFile    /etc/ssl/certs/captive-portal.crt
    SSLCertificateKeyFile /etc/ssl/private/captive-portal.key
    SSLProtocol           all -SSLv3 -TLSv1 -TLSv1.1
    SSLCipherSuite        HIGH:!aNULL:!MD5
    SSLHonorCipherOrder   on

    Header always set Strict-Transport-Security "max-age=31536000"
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set X-Content-Type-Options "nosniff"

    Alias /daloradius /opt/daloradius
    DirectoryIndex login.php index.php
    <Directory /opt/daloradius>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    Alias /style.css   /etc/chilli/www/style.css
    Alias /logo.svg    /etc/chilli/www/logo.svg
    Alias /login.html  /etc/chilli/www/login.html

    ScriptAlias /cgi-bin/ /etc/chilli/www/
    <Directory "/etc/chilli/www">
        Options +ExecCGI
        AddHandler cgi-script .cgi
        Require all granted
    </Directory>

    ErrorLog  ${APACHE_LOG_DIR}/dalo-error.log
    CustomLog ${APACHE_LOG_DIR}/dalo-access.log combined
</VirtualHost>
EOF

sudo a2dissite 000-default 2>/dev/null || true
sudo a2ensite dalo
sudo apache2ctl configtest
sudo systemctl enable apache2
sudo systemctl restart apache2
```

> 若 Moxa 機器有 ThingsPro nginx 占用 80/443，把 vhost 改成 8080/8443 即可。記得 `chilli.conf` 內 `uamserver` 也要對應改。

### 9.6 在 daloRADIUS DB 註冊 chilli NAS

```bash
CHILLI_RADIUS_SECRET=$(sudo grep ^CHILLI_RADIUS_SECRET= /etc/captive-portal/secrets.env | cut -d= -f2-)

sudo mariadb radius <<SQL
INSERT IGNORE INTO nas (nasname, shortname, type, ports, secret, server, community, description)
    VALUES ('127.0.0.1', 'chilli', 'coovachilli', NULL, '$CHILLI_RADIUS_SECRET', NULL, NULL, 'CoovaChilli on this gateway');
SQL
```

### 9.7 登入 daloRADIUS

URL：`https://<gw-ip>/daloradius/login.php`
帳號：`administrator` / `radius`（**上線前必改**）

---

## 10. Phase F — nftables 防火牆 + NAT

對應 `install/06-nftables.sh`。

```bash
WAN_IF=$(sudo grep ^WAN_IF= /etc/captive-portal/interfaces.env | cut -d= -f2-)
MGMT_NET="${MGMT_NET:-0.0.0.0/0}"   # 上線改成你的管理子網

sudo tee /etc/nftables.conf > /dev/null <<EOF
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
    set wan_ifaces {
        type ifname
        elements = { "${WAN_IF}", "wwan0" }
    }
    set lan_ifaces {
        type ifname
        elements = { "tun0" }
    }

    chain input {
        type filter hook input priority filter; policy drop;
        iif "lo" accept
        ct state established,related accept
        ct state invalid drop
        ip protocol icmp limit rate 50/second accept
        ip6 nexthdr icmpv6 accept

        iifname @lan_ifaces tcp dport 22 accept comment "ssh from LAN"
        ip saddr ${MGMT_NET} tcp dport 22 accept comment "ssh from MGMT_NET"

        iifname @lan_ifaces tcp dport { 80, 443, 3990 } accept comment "portal http(s) + UAM"
        iifname @lan_ifaces udp dport 53 accept comment "dns"
        iifname @lan_ifaces udp dport 67 accept comment "dhcp"

        ip saddr ${MGMT_NET} tcp dport { 80, 443 } accept comment "admin from MGMT_NET"
        ip saddr ${MGMT_NET} udp dport 161 accept comment "snmp from MGMT_NET"

        pkttype { broadcast, multicast } counter drop
        log prefix "[fw-input-drop] " level info limit rate 5/second
        counter drop
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
        ct state established,related accept
        ct state invalid drop
        iifname @lan_ifaces oifname @wan_ifaces accept comment "lan->wan post-auth"
        log prefix "[fw-fwd-drop] " level info limit rate 5/second
        counter drop
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}

table ip nat {
    set wan_ifaces {
        type ifname
        elements = { "${WAN_IF}", "wwan0" }
    }
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
    }
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        oifname @wan_ifaces masquerade
    }
}
EOF

sudo chmod 644 /etc/nftables.conf
sudo nft -c -f /etc/nftables.conf   # validate
sudo systemctl enable --now nftables
sudo systemctl restart nftables
sudo nft list ruleset | head -40
```

---

## 11. Phase H — Logging + SNMP

對應 `install/07-services.sh` 前半。

### 11.1 rsyslog routes

把 chilli (`local3` facility) 與 nft drops 路到專用 log file：

```bash
sudo tee /etc/rsyslog.d/30-captive-portal.conf > /dev/null <<'EOF'
# chilli logs to local3 facility (configured in /etc/chilli.conf logfacility 3)
local3.*    /var/log/chilli.log

# Firewall drops (kernel msgs prefixed [fw-...])
:msg, contains, "[fw-input-drop]"  /var/log/firewall.log
:msg, contains, "[fw-fwd-drop]"    /var/log/firewall.log
& stop
EOF

sudo touch /var/log/chilli.log /var/log/firewall.log
sudo chown syslog:adm /var/log/chilli.log /var/log/firewall.log 2>/dev/null || \
  sudo chown root:adm /var/log/chilli.log /var/log/firewall.log
sudo chmod 640 /var/log/chilli.log /var/log/firewall.log

sudo systemctl restart rsyslog
```

### 11.2 logrotate

```bash
sudo tee /etc/logrotate.d/captive-portal > /dev/null <<'EOF'
/var/log/chilli.log /var/log/firewall.log /var/log/daloradius/*.log {
    daily
    rotate 14
    compress
    missingok
    notifempty
    delaycompress
    sharedscripts
    postrotate
        systemctl reload rsyslog 2>/dev/null || true
    endscript
}
EOF
```

### 11.3 SNMPv3

```bash
SNMP_AUTH_PASS=$(openssl rand -hex 16)
SNMP_PRIV_PASS=$(openssl rand -hex 16)

# 加進 secrets.env
sudo tee -a /etc/captive-portal/secrets.env > /dev/null <<EOF
SNMP_AUTH_PASS=${SNMP_AUTH_PASS}
SNMP_PRIV_PASS=${SNMP_PRIV_PASS}
EOF

sudo systemctl stop snmpd
sudo mkdir -p /var/lib/snmp
echo "createUser moxaadmin SHA \"${SNMP_AUTH_PASS}\" AES \"${SNMP_PRIV_PASS}\"" | \
  sudo tee -a /var/lib/snmp/snmpd.conf
sudo chmod 600 /var/lib/snmp/snmpd.conf

sudo tee /etc/snmp/snmpd.conf > /dev/null <<'EOF'
agentaddress udp:161

rouser moxaadmin priv

sysLocation "Captive Portal Gateway"
sysContact  "admin@example.com"

includeAllDisks 10%
EOF

sudo systemctl enable snmpd
sudo systemctl restart snmpd

# 驗證
snmpwalk -v3 -u moxaadmin -l authPriv -a SHA -A "${SNMP_AUTH_PASS}" \
         -x AES -X "${SNMP_PRIV_PASS}" 127.0.0.1 sysDescr.0
```

---

## 12. Phase I — Healthcheck

對應 `install/07-services.sh` 後半。

### 12.1 Healthcheck script

```bash
sudo tee /usr/local/sbin/captive-healthcheck.sh > /dev/null <<'EOF'
#!/bin/bash
# Periodic check: is portal CGI responding?
# If not, restart chilli.
set -u
URL="http://192.168.182.1/cgi-bin/hotspotlogin.cgi"

while true; do
    if ! curl -sS -m 5 -o /dev/null "$URL"; then
        logger -t healthcheck "portal cgi not responding — restarting chilli"
        systemctl restart chilli
        sleep 30
    fi
    sleep 60
done
EOF
sudo chmod 755 /usr/local/sbin/captive-healthcheck.sh
```

### 12.2 systemd unit

```bash
sudo tee /etc/systemd/system/captive-healthcheck.service > /dev/null <<'EOF'
[Unit]
Description=Captive Portal Healthcheck
After=chilli.service apache2.service

[Service]
Type=simple
ExecStart=/usr/local/sbin/captive-healthcheck.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now captive-healthcheck
```

### 12.3 Restart=always 給關鍵服務

```bash
for svc in chilli freeradius apache2 mariadb; do
  sudo mkdir -p "/etc/systemd/system/${svc}.service.d"
  sudo tee "/etc/systemd/system/${svc}.service.d/restart.conf" > /dev/null <<EOF
[Service]
Restart=always
RestartSec=10s
EOF
done
sudo systemctl daemon-reload
```

---

## 13. 完整驗證

### 13.1 服務檢查

```bash
for s in mariadb freeradius chilli captive-dnsmasq apache2 nftables snmpd captive-healthcheck; do
    printf '%-25s ' "$s"
    sudo systemctl is-active "$s"
done
# 全部 active
```

### 13.2 介面與 listener

```bash
ip addr show tun0       # 192.168.182.1/24
ss -tunlp | grep -E ':1812|:1813|:3799|:3990|:53|:80|:443|:161'
# RADIUS 1812/1813、CoA 3799、UAM 3990、DNS 53@tun0、Web 80/443、SNMP 161
```

### 13.3 RADIUS auth smoke test

```bash
SECRET=$(sudo grep ^CHILLI_RADIUS_SECRET= /etc/captive-portal/secrets.env | cut -d= -f2-)
echo 'User-Name=testuser,User-Password=test1234' | \
  radclient -x 127.0.0.1:1812 auth "$SECRET" 2>&1 | grep Access-
# Received Access-Accept
```

### 13.4 端到端 client test

從 LAN 接入一台 PC / 手機：

| 項 | 應 |
|---|---|
| DHCP | 拿 192.168.182.x IP |
| DNS query (`nslookup google.com`) | 應通 |
| 開 `http://example.com` | 跳 portal hotspotlogin.cgi |
| 輸入 `testuser / test1234` | 看到「登入成功」 |
| 認證後上網 | OK |
| daloRADIUS Web → Active Sessions | 看到該 client |

### 13.5 CoA 踢人

daloRADIUS Web → User → testuser → Disconnect User
- DB radacct: `acctterminatecause = Admin-Reset`
- chilli condown 觸發：`logger -t chilli-condown ...`
- conntrack flush：`/var/log/syslog` 找 "flushed=N->0"

或 CLI：
```bash
echo 'User-Name=testuser' | radclient -t 3 -r 1 127.0.0.1:3799 disconnect "$SECRET"
# Disconnect-ACK
```

---

## 14. 疑難排解

### 14.1 chilli 起不來
```bash
sudo journalctl -u chilli -n 50
sudo /usr/sbin/chilli -fd        # foreground debug 模式
```
常見原因：
- LAN 介面不存在或被別的 service 佔用 → 檢查 `dhcpif`
- tun module 未 load → `sudo modprobe tun`
- /etc/chilli.conf 語法錯 → 看 journal

### 14.2 FreeRADIUS auth 失敗
```bash
sudo freeradius -X 2>&1 | tail -50      # foreground debug
sudo journalctl -u freeradius -n 50
sudo tail -f /var/log/freeradius/radius.log
```
常見：
- secret 不符 → `clients.d/chilli.conf` vs `chilli.conf` `radiussecret`
- DB 連不上 → mods-enabled/sql password 對不對
- duplicate client → default `client localhost` 沒注釋掉

### 14.3 daloRADIUS 500 error
```bash
sudo tail /var/log/apache2/dalo-error.log
```
常見：
- `Class "DB" not found` → 缺 `php-pear php-db`
- DB 連不上 → daloradius.conf.php 密碼錯
- 權限 → `/opt/daloradius` 應為 www-data 所有

### 14.4 Portal 不跳出
```bash
# Client 端
curl -v http://example.com 2>&1 | head -20
# 應 302 到 192.168.182.1
```
- chilli 沒 forward 到 UAM → 看 chilli log
- DNS 失敗 → captive-dnsmasq 沒 running，client 解不到主機名
- 客戶端開 HTTPS-Only → HSTS 站點不能攔（normal）

### 14.5 Conntrack 不 flush
- `condown.sh` 有沒 +x？
- `conntrack` 有沒裝？`apt install conntrack`
- chilli.conf 有沒 `condown /etc/chilli/condown.sh`？

### 14.6 Wi-Fi 「無網際網路」但仍連著
- 正常。chilli 是 L3，AP 端 802.11 association 不歸 chilli 管
- 真斷需要 AP API（vendor-specific）

---

## 15. 對照檔案 / 自動化腳本

| 手冊章節 | 對應 install script |
|---------|---------------------|
| §3 Phase A | `install/00-base.sh` |
| §4 Phase A.5 | `install/00b-build-chilli.sh` |
| §5 Phase B-1 | `install/01-mariadb.sh` |
| §6 Phase B-2 | `install/02-freeradius.sh` |
| §7 Phase C | `install/03-chilli.sh` |
| §8 Phase D | `install/04-portal-branding.sh` |
| §9 Phase E | `install/05-daloradius.sh` |
| §10 Phase F | `install/06-nftables.sh` |
| §11-§12 | `install/07-services.sh` |
| Cellular WAN (v2) | `install/08-cellular.sh` |

自動化整套：
```bash
sudo ./install/00-base.sh
sudo ./install/00b-build-chilli.sh
sudo ./install/01-mariadb.sh
sudo ./install/02-freeradius.sh
sudo ./install/03-chilli.sh
sudo ./install/04-portal-branding.sh
sudo ./install/05-daloradius.sh
sudo ./install/06-nftables.sh
sudo ./install/07-services.sh
```

---

## 16. 後續工作

| 項目 | 對應手冊 |
|------|---------|
| 把 RADIUS server 搬到公網 | [docs/radius-public-server-manual.md](radius-public-server-manual.md) |
| Cellular WAN failover | `install/08-cellular.sh`（v2） |
| 多 AP / 多 site 部署 | 同 RADIUS 公網手冊 §10.4 |
| 升級 RadSec / WireGuard | 同上 |
| 商品散佈 license 注意事項 | 主要 GPL 元件：CoovaChilli、FreeRADIUS、daloRADIUS、MariaDB — 散佈須提供 source |
