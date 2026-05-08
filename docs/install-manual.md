# Captive Portal Gateway — 從零手動安裝手冊

> **架構假設：RADIUS server 在公網（獨立 server），Moxa 只跑 chilli。**
>
> 本手冊：在 **兩台** 空白 Debian 12 機器上，**完全用手** 把整套 Captive Portal Gateway 架起來：
> - **Server A — Moxa Gateway**：CoovaChilli + Portal CGI + nftables (NAS only)
> - **Server B — Public RADIUS Server**：MariaDB + FreeRADIUS + daloRADIUS (中央 AAA)
>
> 兩台之間用 UDP RADIUS (1812/1813/3799) 通訊，加 SSH wrapper 解決 CoA 限制。
>
> 適用：理解原理、客製化部署、debug、出貨前 review、多 site 架構。
>
> 自動化腳本仍在 `install/`；本手冊把每個 phase 的實際指令拆解出來，加上設計動機與設定說明。

---

## 目錄

1. [系統架構與元件](#1-系統架構與元件)
2. [硬體 / 網路 / OS 前置](#2-硬體--網路--os-前置)
3. [Server B Phase 1 — Base + MariaDB](#3-server-b-phase-1--base--mariadb)
4. [Server B Phase 2 — FreeRADIUS](#4-server-b-phase-2--freeradius)
5. [Server B Phase 3 — daloRADIUS Web](#5-server-b-phase-3--daloradius-web)
6. [Server B Phase 4 — nftables 白名單](#6-server-b-phase-4--nftables-白名單)
7. [Server A Phase 1 — Base OS Prep](#7-server-a-phase-1--base-os-prep)
8. [Server A Phase 2 — Build CoovaChilli](#8-server-a-phase-2--build-coovachilli)
9. [Server A Phase 3 — chilli 設定 + dnsmasq](#9-server-a-phase-3--chilli-設定--dnsmasq)
10. [Server A Phase 4 — Portal 客製](#10-server-a-phase-4--portal-客製)
11. [Server A Phase 5 — nftables Gateway](#11-server-a-phase-5--nftables-gateway)
12. [Server A Phase 6 — Logging + Healthcheck](#12-server-a-phase-6--logging--healthcheck)
13. [SSH Wrapper for CoA Disconnect](#13-ssh-wrapper-for-coa-disconnect)
14. [完整驗證 End-to-End](#14-完整驗證-end-to-end)
15. [疑難排解](#15-疑難排解)
16. [對照表 → 自動化腳本](#16-對照表--自動化腳本)
17. [變體：Moxa-only All-in-One](#17-變體moxa-only-all-in-one)

---

## 1. 系統架構與元件

### 拓樸（雙 server 架構）

```
+---------------------------------+              +---------------------------+
|  Server A — Moxa Gateway        |              |  Server B — Public RADIUS |
|  10.90.35.36 (DHCP) WAN         |              |  10.90.35.47              |
|  Debian 12 x86_64               |              |  Debian 12 x86_64         |
|                                 |              |                           |
|  +---------------------------+  |              |  +---------------------+  |
|  | CoovaChilli (NAS)         |  | UDP 1812 →   |  | FreeRADIUS 3.x      |  |
|  |  - DHCP / DNS proxy       |  | UDP 1813 →   |  |  - SQL backend      |  |
|  |  - UAM redirect           |  | UDP 3799 ←   |  +---------------------+  |
|  |  - tun0 192.168.182.1/24  |  | (CoA)        |  +---------------------+  |
|  +---------------------------+  |              |  | MariaDB             |  |
|  +---------------------------+  |  TCP 22 →    |  |  radius DB          |  |
|  | Apache (port 80) +        |  | (SSH wrapper |  +---------------------+  |
|  | hotspotlogin.cgi          |  |  for CoA)    |  +---------------------+  |
|  | + condown hook            |  |              |  | Apache + daloRADIUS |  |
|  +---------------------------+  |              |  |  https://10.90.35.47|  |
|  +---------------------------+  |              |  +---------------------+  |
|  | nftables (FW + NAT)       |  |              |  +---------------------+  |
|  +---------------------------+  |              |  | nftables (whitelist |  |
|                                 |              |  |  Moxa for RADIUS)   |  |
|  [Wi-Fi AP] ← eth1              |              |  +---------------------+  |
|  [Internet] ← eth0              |              |                           |
+---------------------------------+              +---------------------------+
```

### 元件分配

| Server | 元件 | 職責 |
|--------|------|------|
| **A (Moxa)** | CoovaChilli | NAS — DHCP、UAM redirect、RADIUS client、L3 ACL |
| A | Apache + hotspotlogin.cgi | Portal HTML 表單、CHAP 計算 |
| A | dnsmasq (tun0) | LAN 端 DNS proxy |
| A | nftables | INPUT 防火牆 + WAN MASQUERADE NAT |
| A | rsyslog + healthcheck | 在地 log 與自動恢復 |
| **B (Public)** | MariaDB | 中央 radius DB (radcheck / radreply / radacct / nas) |
| B | FreeRADIUS | 認證、授權、accounting |
| B | Apache + PHP + daloRADIUS | Web 管理介面 (user / group / acct / CoA 觸發) |
| B | nftables | 白名單只開 Moxa IP for RADIUS |

### 為何分離

| 理由 | 說明 |
|------|------|
| **集中管理** | 多台 Moxa 共用一個 daloRADIUS / radius DB |
| **資源釋放** | Moxa 工業電腦資源有限，PHP/MySQL 搬到雲機 |
| **HA 路徑** | RADIUS server 可做 replication / failover |
| **安全隔離** | 客流區 (Moxa) 與管理區 (RADIUS) 切開 |

### 為何不直接踢人 (CoA path quirk)

chilli 1.6 對 CoA Disconnect-Request 有 source IP 限制，**只接受 loopback (127.0.0.1)**。從 Server B 直接送 CoA 到 Server A 會 silent drop（即使加 `coanoipcheck=1` + Message-Authenticator）。

**解法**：daloRADIUS PHP 改用 SSH 呼叫 Moxa 端 wrapper，wrapper 在 Moxa 本機跑 `radclient 127.0.0.1:3799`。詳見 §13。

---

## 2. 硬體 / 網路 / OS 前置

### 兩台 server 規格

| Server | 用途 | CPU | RAM | 儲存 | 網卡 |
|--------|------|-----|-----|------|------|
| A — Moxa Gateway | NAS | x86_64 dual | 2GB | 16GB+ | 2 (WAN+LAN) |
| B — Public RADIUS | AAA | x86_64 dual | 2GB | 32GB+ | 1 |

### 網路規劃

| 標的 | IP 範例 | 用途 |
|------|---------|------|
| Server A WAN (eth0) | 10.90.35.36 (DHCP 或 static) | 對外 + 連 Server B |
| Server A LAN (eth1) | (no IP, chilli 接管) | 接 Wi-Fi AP |
| Server A tun0 | 192.168.182.1/24 | chilli 虛擬 LAN |
| Server B | 10.90.35.47 (建議 static) | RADIUS / Web UI |
| Client subnet | 192.168.182.0/24 | DHCP from chilli |
| Management subnet | 10.90.0.0/16 (例) | admin SSH/Web 來源 |

### 必須連通

| From | To | Port | Protocol | 用途 |
|------|------|------|----------|------|
| Server A | Server B | 1812, 1813 | UDP | RADIUS auth + acct |
| Server B | Server A | 3799 | UDP | CoA (但實測 silent drop, 用 SSH 取代) |
| Server B | Server A | 22 | TCP | SSH for CoA wrapper |
| Mgmt subnet | Server A | 22 | TCP | admin SSH |
| Mgmt subnet | Server B | 22, 80, 443 | TCP | admin SSH + daloRADIUS Web |

### OS 安裝

兩台都裝 Debian 12 (bookworm) **netinst** server 模式。

```bash
sudo apt update
sudo apt install -y openssh-server
sudo systemctl enable --now ssh
```

### 確認介面（Server A）

```bash
ip link show
# eth0 = WAN, eth1 = LAN
```

如果介面名不同，把後面 `eth0` / `eth1` 替換成實際名稱。

---

## 3. Server B Phase 1 — Base + MariaDB

> **先架 Server B**（RADIUS 端）— Server A chilli 啟動時要連這個 RADIUS。

### 3.1 安裝套件

```bash
ssh admin@10.90.35.47

sudo apt update
sudo DEBIAN_FRONTEND=noninteractive apt install -y --no-install-recommends \
  freeradius freeradius-mysql freeradius-utils \
  mariadb-server \
  apache2 \
  php php-mysql php-mbstring php-gd php-curl php-xml php-zip \
  php-db php-pear \
  libapache2-mod-php \
  nftables \
  conntrack \
  openssl ca-certificates \
  curl wget \
  rsyslog logrotate
```

### 3.2 建 secrets

```bash
sudo mkdir -p /etc/captive-portal

RADIUS_DB_PASS=$(openssl rand -hex 24)
CHILLI_RADIUS_SECRET=$(openssl rand -hex 24)
CHILLI_UAM_SECRET=$(openssl rand -hex 24)

sudo tee /etc/captive-portal/secrets.env > /dev/null <<EOF
RADIUS_DB_PASS=${RADIUS_DB_PASS}
CHILLI_RADIUS_SECRET=${CHILLI_RADIUS_SECRET}
CHILLI_UAM_SECRET=${CHILLI_UAM_SECRET}
EOF
sudo chmod 600 /etc/captive-portal/secrets.env
```

> **重要：之後要 `scp` 同一份 secrets.env 到 Server A**。兩台必須有相同 `CHILLI_RADIUS_SECRET`（chilli ↔ FreeRADIUS）與 `CHILLI_UAM_SECRET`（chilli ↔ portal CGI）。

### 3.3 MariaDB 啟用

```bash
sudo systemctl enable --now mariadb

# 等 socket
for i in {1..10}; do
  sudo mariadb -e "SELECT 1" >/dev/null 2>&1 && break
  sleep 1
done

sudo mariadb <<'SQL'
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.db WHERE Db='test' OR Db='test\_%';
DROP DATABASE IF EXISTS test;
FLUSH PRIVILEGES;
SQL
```

### 3.4 建 radius DB + user

```bash
sudo mariadb <<SQL
CREATE DATABASE IF NOT EXISTS \`radius\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'radius'@'localhost' IDENTIFIED BY '$RADIUS_DB_PASS';
ALTER USER 'radius'@'localhost' IDENTIFIED BY '$RADIUS_DB_PASS';
GRANT ALL PRIVILEGES ON \`radius\`.* TO 'radius'@'localhost';
FLUSH PRIVILEGES;
SQL
```

### 3.5 寫 db.env

```bash
sudo tee /etc/captive-portal/db.env > /dev/null <<EOF
RADIUS_DB_NAME=radius
RADIUS_DB_USER=radius
RADIUS_DB_HOST=localhost
EOF
```

---

## 4. Server B Phase 2 — FreeRADIUS

### 4.1 匯入 schema

```bash
sudo mariadb radius < /etc/freeradius/3.0/mods-config/sql/main/mysql/schema.sql

sudo mariadb radius -e "SHOW TABLES;"
# radacct radcheck radreply radgroupcheck radgroupreply radusergroup radpostauth nas
```

### 4.2 替換 sql module

```bash
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
        start = 1
        min   = 1
        max   = 8
        spare = 1
        retry_delay = 30
        idle_timeout = 60
        connect_timeout = 5
    }

    \$INCLUDE \${modconfdir}/\${.:name}/main/\${dialect}/queries.conf
}
EOF

sudo chown root:freerad /etc/freeradius/3.0/mods-available/sql
sudo chmod 640 /etc/freeradius/3.0/mods-available/sql
sudo ln -sf ../mods-available/sql /etc/freeradius/3.0/mods-enabled/sql
```

### 4.3 啟用 sql 在 sites

```bash
for site in default inner-tunnel; do
  f="/etc/freeradius/3.0/sites-available/$site"
  [ -f "$f" ] || continue
  sudo cp "$f" "$f.orig"
  sudo sed -i 's|^\([[:space:]]*\)#[[:space:]]*sql$|\1sql|g' "$f"
  sudo ln -sf "$f" "/etc/freeradius/3.0/sites-enabled/$site"
done
```

### 4.4 註冊 Moxa 為 RADIUS client

預設 `client localhost { secret = testing123 }` 衝突，先注釋：

```bash
sudo cp /etc/freeradius/3.0/clients.conf /etc/freeradius/3.0/clients.conf.orig

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

加 Moxa client：

```bash
MOXA_WAN_IP="10.90.35.36"   # 改成實際 Moxa WAN IP

sudo mkdir -p /etc/freeradius/3.0/clients.d

sudo tee /etc/freeradius/3.0/clients.d/moxa.conf > /dev/null <<EOF
# Moxa CoovaChilli — RADIUS NAS client
client moxa-gateway {
    ipaddr     = ${MOXA_WAN_IP}
    proto      = udp
    secret     = ${CHILLI_RADIUS_SECRET}
    require_message_authenticator = no
    nas_type   = other
    shortname  = moxa-chilli
}
EOF

sudo chown root:freerad /etc/freeradius/3.0/clients.d/moxa.conf
sudo chmod 640 /etc/freeradius/3.0/clients.d/moxa.conf

# 確認 include
sudo grep -qF '$INCLUDE clients.d/' /etc/freeradius/3.0/clients.conf || \
  echo '$INCLUDE clients.d/' | sudo tee -a /etc/freeradius/3.0/clients.conf
```

> 多台 Moxa 各加一筆，shortname 不能重複。

### 4.5 種測試 user + 預設 group

```bash
sudo mariadb radius <<'SQL'
INSERT IGNORE INTO radcheck (username, attribute, op, value)
    VALUES ('testuser', 'Cleartext-Password', ':=', 'test1234');

-- default group with WISPr defaults
INSERT IGNORE INTO radgroupreply (groupname,attribute,op,value) VALUES
  ('default','Session-Timeout',':=','3600'),
  ('default','Idle-Timeout',':=','600'),
  ('default','WISPr-Bandwidth-Max-Down',':=','5000000'),
  ('default','WISPr-Bandwidth-Max-Up',':=','5000000');

INSERT IGNORE INTO radusergroup (username,groupname,priority)
  VALUES ('testuser','default',1);
SQL
```

### 4.6 啟動 + smoke test

```bash
sudo systemctl enable freeradius
sudo systemctl restart freeradius
sleep 2
sudo systemctl is-active freeradius   # active

# 本機 self-test（127.0.0.1 不在 clients.d 中，會 reject — normal）
# 真正 smoke test 等 Server A 起來後從 Moxa 跑

# Confirm listening
sudo ss -ulnp | grep -E ':1812|:1813'
```

---

## 5. Server B Phase 3 — daloRADIUS Web

### 5.1 下載 daloRADIUS

```bash
DALO_TAG=$(curl -s https://api.github.com/repos/lirantal/daloradius/releases/latest \
  | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name":[[:space:]]*"([^"]+)".*/\1/')

cd /tmp
wget "https://github.com/lirantal/daloradius/archive/refs/tags/${DALO_TAG}.tar.gz" -O dalo.tgz
sudo tar xzf dalo.tgz
sudo mv "daloradius-${DALO_TAG}" /opt/daloradius
sudo chown -R www-data:www-data /opt/daloradius
```

### 5.2 匯入 daloRADIUS schema

```bash
for f in /opt/daloradius/contrib/db/mysql-daloradius.sql \
         /opt/daloradius/contrib/db/fr3-mysql-daloradius-and-freeradius.sql; do
  [ -f "$f" ] && sudo mariadb radius < "$f"
done
```

### 5.3 設定 daloradius.conf.php

```bash
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

### 5.4 自簽 cert

```bash
sudo openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
  -keyout /etc/ssl/private/captive-portal.key \
  -out /etc/ssl/certs/captive-portal.crt \
  -subj "/CN=10.90.35.47/O=Captive Portal Public RADIUS"
sudo chmod 600 /etc/ssl/private/captive-portal.key
```

### 5.5 Apache vhost

```bash
sudo a2enmod ssl rewrite headers cgi alias

sudo tee /etc/apache2/sites-available/dalo.conf > /dev/null <<'EOF'
<VirtualHost *:80>
    ServerName 10.90.35.47
    RewriteEngine On
    RewriteRule ^/(.*)$ https://%{HTTP_HOST}/$1 [R=301,L]
</VirtualHost>

<VirtualHost *:443>
    ServerName 10.90.35.47
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

### 5.6 註冊 chilli NAS in daloRADIUS DB

```bash
sudo mariadb radius <<SQL
INSERT IGNORE INTO nas (nasname, shortname, type, ports, secret, server, community, description)
    VALUES ('${MOXA_WAN_IP}', 'moxa-chilli', 'coovachilli', NULL,
            '$CHILLI_RADIUS_SECRET', NULL, NULL, 'Moxa CoovaChilli (remote gateway)');
SQL
```

### 5.7 登入 daloRADIUS

URL：`https://10.90.35.47/daloradius/login.php`
帳號：`administrator` / `radius`（**上線必改**）

---

## 6. Server B Phase 4 — nftables 白名單

只開白名單給 Moxa（RADIUS）+ 管理子網（SSH/Web）：

```bash
sudo tee /etc/nftables.conf > /dev/null <<'EOF'
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
    chain input {
        type filter hook input priority filter; policy drop;

        iif lo accept
        ct state established,related accept
        ct state invalid drop
        ip protocol icmp limit rate 50/second accept
        ip6 nexthdr icmpv6 accept

        # SSH from management subnet
        ip saddr 10.0.0.0/8 tcp dport 22 accept comment "ssh from MGMT"

        # RADIUS auth + accounting + CoA from Moxa only
        ip saddr 10.90.35.36 udp dport { 1812, 1813, 3799 } accept comment "RADIUS from Moxa"

        # daloRADIUS Web UI from management subnet
        ip saddr 10.0.0.0/8 tcp dport { 80, 443 } accept comment "Web admin from MGMT"

        pkttype { broadcast, multicast } counter drop
        log prefix "[fw-drop] " level info limit rate 5/second
        counter drop
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}
EOF

sudo nft -c -f /etc/nftables.conf
sudo systemctl enable --now nftables
sudo systemctl restart nftables
sudo nft list ruleset | head -30
```

> 上線把 `10.0.0.0/8` 縮到實際管理子網。多台 Moxa：`ip saddr { 10.90.35.36, 10.90.35.40 }`。

**Server B 完工**。下面開始 Server A。

---

## 7. Server A Phase 1 — Base OS Prep

### 7.1 SSH 進 Moxa

```bash
ssh moxa@10.90.35.36
```

### 7.2 安裝套件

```bash
sudo apt update
sudo DEBIAN_FRONTEND=noninteractive apt install -y --no-install-recommends \
  nftables \
  freeradius-utils \
  apache2 \
  php php-cgi \
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

> 注意：**沒裝 `freeradius`、`mariadb-server`、`daloradius`、`php-mysql`** —— 那些都在 Server B。Moxa 只需要：
> - `freeradius-utils`：給 `radclient` 用（CoA wrapper）
> - `apache2 + php`：portal CGI host
> - 其他基礎工具

### 7.3 sysctl

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

### 7.4 寫 `/etc/network/interfaces`

```bash
sudo cp /etc/network/interfaces /etc/network/interfaces.orig

sudo tee /etc/network/interfaces > /dev/null <<'EOF'
auto eth0
iface eth0 inet dhcp

auto eth1
iface eth1 inet manual
    up ip link set $IFACE up
    down ip link set $IFACE down
EOF
```

### 7.5 從 Server B 拷貝 secrets.env

**重要**：兩台必須有同份 secrets。

```bash
# 在 Server B
ssh admin@10.90.35.47 "sudo cat /etc/captive-portal/secrets.env" \
  | sudo tee /tmp/secrets.env > /dev/null

# 或 scp
scp admin@10.90.35.47:/etc/captive-portal/secrets.env /tmp/secrets.env

# 在 Server A
sudo mkdir -p /etc/captive-portal
sudo mv /tmp/secrets.env /etc/captive-portal/secrets.env
sudo chmod 600 /etc/captive-portal/secrets.env
sudo chown root:root /etc/captive-portal/secrets.env
```

寫 interfaces.env：

```bash
sudo tee /etc/captive-portal/interfaces.env > /dev/null <<EOF
WAN_IF=eth0
LAN_IF=eth1
EOF
```

### 7.6 停 NetworkManager

```bash
if systemctl is-enabled NetworkManager >/dev/null 2>&1; then
    sudo systemctl disable --now NetworkManager
fi
```

> 介面 rename 後重開機。

---

## 8. Server A Phase 2 — Build CoovaChilli

Debian 12 沒 `coova-chilli` package，自己 build。

### 8.1 Clone

```bash
sudo git clone https://github.com/coova/coova-chilli.git /usr/local/src/coova-chilli
cd /usr/local/src/coova-chilli
sudo git fetch --tags --force
sudo git checkout 1.6
```

### 8.2 修 gengetopt 不相容

```bash
[ -f src/cmdline.patch ] && sudo truncate -s 0 src/cmdline.patch
```

### 8.3 Bootstrap + configure

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

### 8.4 Build + install

```bash
sudo make           # 不要 -j
sudo make install
```

### 8.5 systemd unit

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
ldd /usr/sbin/chilli | grep -i "not found"   # 應無
```

---

## 9. Server A Phase 3 — chilli 設定 + dnsmasq

### 9.1 寫 `/etc/chilli.conf` — 指向公網 RADIUS

```bash
LAN_IF=$(sudo grep ^LAN_IF= /etc/captive-portal/interfaces.env | cut -d= -f2-)
CHILLI_RADIUS_SECRET=$(sudo grep ^CHILLI_RADIUS_SECRET= /etc/captive-portal/secrets.env | cut -d= -f2-)
CHILLI_UAM_SECRET=$(sudo grep ^CHILLI_UAM_SECRET= /etc/captive-portal/secrets.env | cut -d= -f2-)
RADIUS_SERVER="10.90.35.47"   # Server B IP

sudo tee /etc/chilli.conf > /dev/null <<EOF
# /etc/chilli.conf — point to public RADIUS server
dhcpif    ${LAN_IF}
tundev    tun0

net       192.168.182.0/24
uamlisten 192.168.182.1
uamport   3990

dns1 192.168.182.1
dns2 192.168.182.1

# Public RADIUS server (Server B). Optional fallback to 127.0.0.1 if you
# keep a local freeradius for resilience (see §17).
radiusserver1 ${RADIUS_SERVER}
radiusserver2 ${RADIUS_SERVER}
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
defbandwidthmaxdown 5000000
defbandwidthmaxup   5000000

logfacility 3

coaport 3799
coanoipcheck 1
nasmac
swapoctets

# CoA / disconnect hook → flush conntrack
condown /etc/chilli/condown.sh
EOF

sudo chmod 600 /etc/chilli.conf
```

### 9.2 寫 `/etc/chilli/defaults`

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

HS_RADIUS=${RADIUS_SERVER}
HS_RADIUS2=${RADIUS_SERVER}
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

### 9.3 啟用 + 移除 SysV init

```bash
[ -f /etc/default/chilli ] && \
  sudo sed -i 's/^START_CHILLI=.*/START_CHILLI=1/' /etc/default/chilli

[ -f /etc/init.d/chilli ] && {
  sudo rm -f /etc/init.d/chilli
  sudo update-rc.d -f chilli remove >/dev/null 2>&1 || true
}

sudo modprobe tun
sudo systemctl enable chilli
sudo systemctl restart chilli

# 等 tun0
for i in {1..15}; do
  ip link show tun0 >/dev/null 2>&1 && { echo "tun0 up"; break; }
  sleep 1
done
ip -4 addr show tun0
```

### 9.4 captive-dnsmasq

```bash
sudo tee /etc/systemd/system/captive-dnsmasq.service > /dev/null <<'EOF'
[Unit]
Description=Captive portal DNS (dnsmasq on tun0)
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
ss -tunlp | grep '192.168.182.1:53'
```

### 9.5 condown hook（auto flush conntrack）

```bash
sudo tee /etc/chilli/condown.sh > /dev/null <<'EOF'
#!/bin/sh
# Runs on chilli session end (CoA, idle/session timeout, NAS-Reboot).
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

### 9.6 Smoke test：Moxa → 公網 RADIUS

```bash
SECRET=$(sudo grep ^CHILLI_RADIUS_SECRET= /etc/captive-portal/secrets.env | cut -d= -f2-)
echo 'User-Name=testuser,User-Password=test1234' | \
  radclient -x ${RADIUS_SERVER}:1812 auth "$SECRET" 2>&1 | grep Access-
# Received Access-Accept
```

---

## 10. Server A Phase 4 — Portal 客製

```bash
# 客製 logo / css
# 把 my-logo.svg 放上去
sudo cp my-company-logo.svg /etc/chilli/www/logo.svg

# wrapper for haserl
sudo tee /etc/chilli/www/hotspotlogin.cgi > /dev/null <<'EOF'
#!/bin/bash
exec /usr/bin/haserl --shell=sh /etc/chilli/www/login.chi
EOF
sudo chmod 755 /etc/chilli/www/hotspotlogin.cgi
```

Apache vhost on Server A — port 80 only（portal CGI），無 daloRADIUS：

```bash
sudo a2enmod cgi alias rewrite

sudo tee /etc/apache2/sites-available/portal.conf > /dev/null <<'EOF'
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

    ErrorLog  ${APACHE_LOG_DIR}/portal-error.log
    CustomLog ${APACHE_LOG_DIR}/portal-access.log combined
</VirtualHost>
EOF

sudo a2dissite 000-default 2>/dev/null || true
sudo a2ensite portal
sudo apache2ctl configtest
sudo systemctl enable apache2
sudo systemctl restart apache2
```

> 若 Moxa ThingsPro nginx 占 80：改 8080 + chilli.conf `uamserver` 改 `:8080`。

---

## 11. Server A Phase 5 — nftables Gateway

```bash
WAN_IF=$(sudo grep ^WAN_IF= /etc/captive-portal/interfaces.env | cut -d= -f2-)
RADIUS_SERVER="10.90.35.47"
MGMT_NET="${MGMT_NET:-0.0.0.0/0}"

sudo tee /etc/nftables.conf > /dev/null <<EOF
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
    set wan_ifaces { type ifname; elements = { "${WAN_IF}", "wwan0" } }
    set lan_ifaces { type ifname; elements = { "tun0" } }

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

        # CoA from public RADIUS (Server B → Moxa)
        ip saddr ${RADIUS_SERVER} udp dport 3799 accept comment "CoA from public RADIUS"

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
    set wan_ifaces { type ifname; elements = { "${WAN_IF}", "wwan0" } }
    chain prerouting { type nat hook prerouting priority dstnat; policy accept; }
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        oifname @wan_ifaces masquerade
    }
}
EOF

sudo nft -c -f /etc/nftables.conf
sudo systemctl enable --now nftables
sudo systemctl restart nftables
```

---

## 12. Server A Phase 6 — Logging + Healthcheck

### 12.1 rsyslog routes

```bash
sudo tee /etc/rsyslog.d/30-captive-portal.conf > /dev/null <<'EOF'
local3.*    /var/log/chilli.log
:msg, contains, "[fw-input-drop]"  /var/log/firewall.log
:msg, contains, "[fw-fwd-drop]"    /var/log/firewall.log
& stop
EOF

sudo touch /var/log/chilli.log /var/log/firewall.log
sudo chown syslog:adm /var/log/chilli.log /var/log/firewall.log 2>/dev/null || \
  sudo chown root:adm /var/log/chilli.log /var/log/firewall.log
sudo chmod 640 /var/log/chilli.log /var/log/firewall.log

sudo tee /etc/logrotate.d/captive-portal > /dev/null <<'EOF'
/var/log/chilli.log /var/log/firewall.log {
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

sudo systemctl restart rsyslog
```

### 12.2 SNMPv3

```bash
SNMP_AUTH_PASS=$(openssl rand -hex 16)
SNMP_PRIV_PASS=$(openssl rand -hex 16)

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
```

### 12.3 Healthcheck

```bash
sudo tee /usr/local/sbin/captive-healthcheck.sh > /dev/null <<'EOF'
#!/bin/bash
set -u
URL="http://192.168.182.1/cgi-bin/hotspotlogin.cgi"
while true; do
    if ! curl -sS -m 5 -o /dev/null "$URL"; then
        logger -t healthcheck "portal cgi unreachable — restarting chilli"
        systemctl restart chilli
        sleep 30
    fi
    sleep 60
done
EOF
sudo chmod 755 /usr/local/sbin/captive-healthcheck.sh

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

# Restart=always for critical services
for svc in chilli apache2; do
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

## 13. SSH Wrapper for CoA Disconnect

> **背景**：chilli 1.6 silent-drops CoA Disconnect-Request 從非 loopback source。daloRADIUS 跑在 Server B，直接送 CoA 到 Server A 不會 ACK。**解法**：用 SSH 把 radclient 動作搬回 Moxa 本機跑。

### 13.1 Server B — 給 www-data 產 SSH key

```bash
ssh admin@10.90.35.47

sudo mkdir -p /var/www/.ssh
sudo chown www-data:www-data /var/www/.ssh
sudo chmod 700 /var/www/.ssh

sudo -u www-data ssh-keygen -t ed25519 -N '' \
  -f /var/www/.ssh/id_ed25519 -C daloradius-coa

sudo cat /var/www/.ssh/id_ed25519.pub
# 複製 pubkey → 下一步用
```

### 13.2 Server A — 安裝 wrapper script + sudoers

```bash
ssh moxa@10.90.35.36

# Wrapper script
sudo tee /usr/local/sbin/coa-disconnect.sh > /dev/null <<'EOF'
#!/bin/bash
# Called via SSH forced-command from public RADIUS server.
set -eu
USER_NAME="${1:-}"
[[ -z "$USER_NAME" ]] && { echo "missing username" >&2; exit 1; }
[[ ! "$USER_NAME" =~ ^[A-Za-z0-9_.@-]+$ ]] && { echo "invalid username: $USER_NAME" >&2; exit 1; }

SECRET=$(sudo cat /etc/captive-portal/secrets.env | grep ^CHILLI_RADIUS_SECRET= | cut -d= -f2-)
[[ -z "$SECRET" ]] && { echo "no secret" >&2; exit 1; }

echo "User-Name=$USER_NAME" | sudo /usr/bin/radclient -t 3 -r 1 127.0.0.1:3799 disconnect "$SECRET"
EOF
sudo chmod 755 /usr/local/sbin/coa-disconnect.sh

# sudoers — moxa user can radclient + read secrets
sudo tee /etc/sudoers.d/coa-disconnect > /dev/null <<'EOF'
moxa ALL=(root) NOPASSWD: /usr/bin/radclient, /bin/cat /etc/captive-portal/secrets.env
EOF
sudo chmod 440 /etc/sudoers.d/coa-disconnect
sudo visudo -c -f /etc/sudoers.d/coa-disconnect
```

### 13.3 Server A — 加 authorized_keys

把 Server B 的 pubkey 黏進 Moxa 的 `/home/moxa/.ssh/authorized_keys`：

```bash
PUBKEY="ssh-ed25519 AAAAC3NzaC1...daloradius-coa"   # paste from §13.1

sudo mkdir -p /home/moxa/.ssh
echo "command=\"/usr/local/sbin/coa-disconnect.sh \${SSH_ORIGINAL_COMMAND}\",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty $PUBKEY" \
  | sudo tee -a /home/moxa/.ssh/authorized_keys

sudo chown -R moxa:moxa /home/moxa/.ssh
sudo chmod 700 /home/moxa/.ssh
sudo chmod 600 /home/moxa/.ssh/authorized_keys
```

### 13.4 Server B — patch daloRADIUS PHP

`/opt/daloradius/library/exten-maint-radclient.php` 內 `user_disconnect()` 函式，把產 `$cmd` 那行改成 SSH wrapper。

找：
```php
$cmd = "echo \"".escapeshellcmd($query)."\" | $radclient $radclient_options $args 2>&1";
```

改成：
```php
$cmd = "ssh -i /var/www/.ssh/id_ed25519 -o StrictHostKeyChecking=no \\
  -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=5 \\
  moxa@10.90.35.36 ".$user." 2>&1";
```

只改 `user_disconnect` 函式內，**不要動** `user_auth`（那個還是用 radclient 對 RADIUS 做 auth test）。

### 13.5 驗證 SSH wrapper

```bash
# Server B
sudo -u www-data ssh -i /var/www/.ssh/id_ed25519 \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  moxa@10.90.35.36 testuser
# Disconnect-ACK from 127.0.0.1:3799
```

---

## 14. 完整驗證 End-to-End

### 14.1 服務（兩台都要）

**Server B：**
```bash
for s in mariadb freeradius apache2 nftables; do
    printf '%-15s ' "$s"
    sudo systemctl is-active "$s"
done
```

**Server A：**
```bash
for s in chilli captive-dnsmasq apache2 nftables snmpd captive-healthcheck; do
    printf '%-25s ' "$s"
    sudo systemctl is-active "$s"
done
```

### 14.2 Listener 檢查

| Server | Port | 應 |
|--------|------|----|
| B | 1812/udp | freeradius (auth) |
| B | 1813/udp | freeradius (acct) |
| B | 443/tcp | apache (daloRADIUS) |
| B | 3306/tcp | mariadb (localhost only) |
| A | 80/tcp | apache (portal) |
| A | 53/udp on 192.168.182.1 | dnsmasq |
| A | 3799/udp | chilli (CoA) |
| A | 3990/tcp | chilli UAM |

### 14.3 RADIUS auth path

```bash
# Server A
SECRET=$(sudo grep ^CHILLI_RADIUS_SECRET= /etc/captive-portal/secrets.env | cut -d= -f2-)
echo 'User-Name=testuser,User-Password=test1234' | \
  radclient -x 10.90.35.47:1812 auth "$SECRET" 2>&1 | grep -E "Access-|Session-Timeout|WISPr"
# Access-Accept + Session-Timeout=3600 + WISPr-Bandwidth-Max-*=5000000
```

### 14.4 Client 端

接 client 進 LAN：

| 項 | 應 |
|---|---|
| DHCP | 192.168.182.x IP |
| 開 `http://example.com` | 跳 portal |
| 輸入 `testuser/test1234` | 登入成功 |
| 通網 | OK |
| Server B daloRADIUS `Active Sessions` | 看到該 client |
| Server B `radacct` | 寫入 acct row, nasipaddress=Moxa IP |

### 14.5 CoA 踢人（Web）

daloRADIUS Web → Users → testuser → **Disconnect User**：

| 應 | 證 |
|---|---|
| daloRADIUS UI 顯示 success | 有 |
| Server A `journalctl -t chilli-condown` | `flushed=N->0` |
| Server B radacct | `acctterminatecause=Admin-Reset` |
| Client | 新連線跳 portal（舊已建立的 UDP 短期內 timeout） |

### 14.6 防火牆 scoping

```bash
# 從非白名單 IP 試送 RADIUS
# 應 timeout / no reply
```

---

## 15. 疑難排解

### 15.1 Moxa → Server B RADIUS 失敗

| 症狀 | 解 |
|------|----|
| `Access-Reject` | clients.d/moxa.conf secret 不符 chilli `radiussecret` |
| 無 reply | Server B fw 沒開白名單 / network unreachable |
| FreeRADIUS 起不來 | 跑 `sudo freeradius -CX 2>&1 \| tail -50` 看錯誤；常見：default `client localhost` 沒注釋、`-sql` 變 `?sql` |

### 15.2 daloRADIUS 500

```bash
sudo tail /var/log/apache2/dalo-error.log
```
- `Class "DB" not found` → 缺 `php-pear php-db`
- DB 連不上 → daloradius.conf.php 密碼錯
- 權限 → `/opt/daloradius` ownership www-data

### 15.3 CoA 踢人沒效

| 症狀 | 排查 |
|------|------|
| Web `Disconnect User` 顯示 success 但無感 | SSH wrapper 沒裝 / pubkey 沒 install / sudoers 沒設 |
| condown 沒 fire | `chilli.conf` 漏 `condown /etc/chilli/condown.sh`；script 沒 +x |
| 踢後 phone 仍上網 | Conntrack 沒 flush（裝 `conntrack` 套件、確認 condown 執行）|
| 踢成功但 Web 顯示 "No reply" | chilli ACK 但 reply 路徑被擋（無傷，DB 已寫 Admin-Reset） |

### 15.4 Phone Wi-Fi 還連著（ICON 亮但無網）

- 正常。chilli 是 L3，AP 端 802.11 association 不歸 chilli 管
- 真斷需要 AP 廠牌 API（vendor-specific deauth frame）
- 用戶體驗：開新網頁 → 跳 portal 重登

### 15.5 chilli 起不來

```bash
sudo journalctl -u chilli -n 50
sudo /usr/sbin/chilli -fd      # foreground debug
```
- LAN 介面被佔 → 確認 NetworkManager disabled
- tun module 未 load → `sudo modprobe tun`
- /etc/chilli.conf 語法錯

### 15.6 Portal 不跳出

```bash
# Client
curl -v http://example.com 2>&1 | head -20
# 應 302 to 192.168.182.1
```
- chilli 沒 forward → 看 `/var/log/chilli.log`
- DNS 失敗 → captive-dnsmasq 沒 running
- HSTS 站點不可攔（normal 行為）

---

## 16. 對照表 → 自動化腳本

本手冊章節對應 `install/*.sh`：

| 手冊章節 | install script | Server | 備註 |
|---------|---------------|--------|------|
| §3 Server B Base+MariaDB | `01-mariadb.sh` | B | |
| §4 Server B FreeRADIUS | `02-freeradius.sh` | B | clients.d 改用 Moxa IP |
| §5 Server B daloRADIUS | `05-daloradius.sh` | B | |
| §6 Server B nftables | `06-nftables.sh` | B | 白名單 only Moxa IP |
| §7 Server A Base | `00-base.sh` | A | 套件清單少 freeradius/mariadb |
| §8 Server A Build chilli | `00b-build-chilli.sh` | A | |
| §9 Server A chilli config | `03-chilli.sh` | A | radiusserver 指公網 |
| §10 Server A Portal | `04-portal-branding.sh` | A | |
| §11 Server A nftables | `06-nftables.sh` | A | gateway 規則 |
| §12 Server A Logging | `07-services.sh` | A | |
| §13 SSH Wrapper | (自動腳本未涵蓋) | A+B | 手動部署 |

> 自動化腳本目前是 Moxa-only all-in-one 設計。雙 server 部署建議先跑各自 server 對應 phase，再手動加 SSH wrapper。

---

## 17. 變體：Moxa-only All-in-One

不想搞兩台機器？所有元件都裝在 Moxa 上：

1. 跑 §3 + §4 + §5（Server B 步驟）但**全在 Moxa 上跑**
2. `/etc/chilli.conf` `radiusserver1 127.0.0.1`（不是公網 IP）
3. `clients.d/moxa.conf` ipaddr 改 `127.0.0.1` shortname `chilli`
4. daloRADIUS Web URL 變 `https://<moxa-ip>/daloradius/`
5. **不用 SSH wrapper**（Web → CoA 直接走 loopback）
6. **不用** §6 firewall 白名單（只一台）

優：簡單、CoA 原生通、無 SSH key 管理。
劣：管理多台 Moxa 時各自獨立 user pool、無 HA。

PoC、單站、低需求用 all-in-one；多站、企業用雙 server。

---

## 18. License 與商品散佈注意

主要元件 license：
- **CoovaChilli** — GPLv2（強 copyleft）
- **FreeRADIUS** — GPLv2
- **daloRADIUS** — GPLv2
- **MariaDB Server** — GPLv2（server-only，網路使用不感染）
- Apache HTTPD / PHP — permissive

散佈成 appliance product：
- 必附 source 或 written offer
- 改過的 chilli `login.chi` / `hotspotlogin.cgi` 屬衍生作品 → 須 GPL 開源
- 你的 install scripts、配置檔、品牌 logo、SSH wrapper script 可保持 proprietary

詳見 `docs/radius-public-server-manual.md` license 章節。
