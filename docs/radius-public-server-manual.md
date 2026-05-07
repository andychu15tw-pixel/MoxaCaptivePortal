# 公網 RADIUS Server 安裝與使用手冊

> 把 FreeRADIUS + MariaDB + daloRADIUS 從 Moxa 本機搬到專屬公網 server，Moxa 只留 chilli 當 NAS。
>
> 本手冊以「直接 UDP + 防火牆白名單」最簡方案為主，不引入 VPN/RadSec。

---

## 1. 架構概述

### 拓樸

```
                                    ┌─────────────────────────────────┐
                                    │  Public RADIUS Server           │
                                    │  10.90.35.47                    │
                                    │  (Debian 12)                    │
[Wi-Fi Client] ─→ [Moxa Gateway]    │                                 │
                  10.90.35.36       │  ┌──────────────────────────┐   │
                  ┌─────────────┐   │  │ FreeRADIUS 3.x           │   │
                  │ chilli (NAS)│ ←─┤  │  - 1812/udp auth         │   │
                  │ tun0        │   │  │  - 1813/udp accounting   │   │
                  │             │ ─→│  │  - 3799/udp CoA          │   │
                  └─────────────┘   │  └──────────────────────────┘   │
                                    │  ┌──────────────────────────┐   │
                                    │  │ MariaDB                  │   │
                                    │  │  radius DB (users/acct)  │   │
                                    │  └──────────────────────────┘   │
                                    │  ┌──────────────────────────┐   │
                                    │  │ Apache + daloRADIUS      │   │
                                    │  │  https://10.90.35.47/    │   │
                                    │  └──────────────────────────┘   │
                                    │  ┌──────────────────────────┐   │
                                    │  │ nftables                 │   │
                                    │  │  whitelist Moxa IP       │   │
                                    │  └──────────────────────────┘   │
                                    └─────────────────────────────────┘
```

### 元件職責

| 元件 | 位置 | 角色 |
|------|------|------|
| CoovaChilli | Moxa (10.90.35.36) | NAS — DHCP/NAT/UAM redirect、發 RADIUS 給公網 |
| FreeRADIUS | 10.90.35.47 | 中央 AAA — 認證、授權、accounting |
| MariaDB | 10.90.35.47 | 共用 DB — radcheck / radreply / radacct / nas |
| daloRADIUS | 10.90.35.47 | Web 管理介面 — 新增 user、查 acct、踢人 (CoA) |
| nftables | 10.90.35.47 | 防火牆白名單 — 只接受 Moxa 的 RADIUS 流量 |

### 為何分離 RADIUS

- **集中管理** — 多台 Moxa Gateway 共用同一 RADIUS DB，user/acct 一份資料
- **Moxa 資源釋放** — Moxa 工業電腦資源有限，把 DB/PHP 搬走，效能更穩
- **安全隔離** — Captive portal 客流區與管理 server 切開
- **HA 路徑** — 之後可以做 RADIUS server replication / failover

---

## 2. 前置需求

### 硬體 / 網路

| 項目 | 規格 |
|------|------|
| Public RADIUS server | Linux x86_64，Debian 12，2 cores / 2 GB RAM 起跳 |
| Moxa Gateway | 已部署 v1 MVP（chilli + freeradius + daloRADIUS 本機） |
| 網路連通 | Moxa WAN ↔ RADIUS server UDP 1812/1813/3799 |
| 管理網段 | SSH + Web UI 從 admin 主機可達 RADIUS server |

### 帳號 / 密碼

| 設備 | IP | User | Password |
|------|----|------|----------|
| Moxa Gateway | 10.90.35.36 | moxa | admin@123 |
| Public RADIUS Server | 10.90.35.47 | andychu | admin@1234 |
| daloRADIUS Web | https://10.90.35.47/daloradius/ | administrator | radius (預設，上線前改) |

### Secrets（從 Moxa 拷貝過來）

```bash
# 在 Moxa 上讀取
sudo cat /etc/captive-portal/secrets.env
```

關鍵欄位：
- `RADIUS_DB_PASS` — MariaDB radius user 密碼
- `CHILLI_RADIUS_SECRET` — chilli ↔ FreeRADIUS shared secret
- `CHILLI_UAM_SECRET` — chilli ↔ HotspotLogin.cgi shared secret

> 公網 server 沿用同樣 secrets，避免雙改容易出錯。

---

## 3. 公網 Server 安裝

### 3.1 OS 套件

SSH 登入：
```bash
ssh andychu@10.90.35.47   # password: admin@1234
```

安裝套件：
```bash
sudo apt update
sudo apt install -y \
  freeradius freeradius-mysql freeradius-utils \
  mariadb-server \
  apache2 php php-mysql php-mbstring php-gd php-curl php-xml php-db php-pear \
  nftables curl wget unzip
```

### 3.2 MariaDB

預設 root 用 unix socket，無需密碼即可進。

建 DB + user（密碼用 Moxa 的 `RADIUS_DB_PASS`）：
```bash
RADIUS_DB_PASS="<從 Moxa secrets.env 拷>"

sudo mariadb -u root <<EOF
CREATE DATABASE IF NOT EXISTS radius;
CREATE USER IF NOT EXISTS 'radius'@'localhost' IDENTIFIED BY '${RADIUS_DB_PASS}';
GRANT ALL ON radius.* TO 'radius'@'localhost';
FLUSH PRIVILEGES;
EOF
```

### 3.3 從 Moxa 遷移 radius DB

**Moxa 上 dump：**
```bash
sudo mysqldump -u root --single-transaction --lock-tables=false radius > /tmp/radius-dump.sql
```

**傳到公網 server：**
```bash
scp /tmp/radius-dump.sql andychu@10.90.35.47:/tmp/
```

**公網 server 還原：**
```bash
sudo mariadb -u root radius < /tmp/radius-dump.sql

# 驗證
sudo mariadb -u root radius -e "SHOW TABLES;"
sudo mariadb -u root radius -e "SELECT username FROM radcheck;"
sudo mariadb -u root radius -e "SELECT COUNT(*) FROM radacct;"
```

**清 nas 表的舊 chilli 紀錄，更新成 Moxa IP：**
```bash
sudo mariadb -u root radius <<EOF
DELETE FROM nas WHERE id > 1;
UPDATE nas SET nasname='10.90.35.36',
               shortname='moxa-chilli',
               description='Moxa CoovaChilli (remote gateway)'
       WHERE id=1;
EOF
```

### 3.4 FreeRADIUS

**SQL 連線設定 — 寫 `/etc/freeradius/3.0/mods-available/sql`：**

```bash
sudo tee /etc/freeradius/3.0/mods-available/sql > /dev/null <<'EOF'
sql {
    driver  = "rlm_sql_mysql"
    dialect = "mysql"
    server      = "localhost"
    port        = 3306
    login       = "radius"
    password    = "<同 Moxa 的 RADIUS_DB_PASS>"
    radius_db   = "radius"
    read_clients = yes
    client_table = "nas"
    accounting_table   = "radacct"
    acct_table1        = "radacct"
    acct_table2        = "radacct"
    postauth_table     = "radpostauth"
    authcheck_table    = "radcheck"
    authreply_table    = "radreply"
    groupcheck_table   = "radgroupcheck"
    groupreply_table   = "radgroupreply"
    usergroup_table    = "radusergroup"
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
    $INCLUDE ${modconfdir}/${.:name}/main/${dialect}/queries.conf
}
EOF

sudo chown root:freerad /etc/freeradius/3.0/mods-available/sql
sudo chmod 640 /etc/freeradius/3.0/mods-available/sql
sudo ln -sf ../mods-available/sql /etc/freeradius/3.0/mods-enabled/sql
```

**註冊 Moxa 為 RADIUS client — 寫 `/etc/freeradius/3.0/clients.d/moxa.conf`：**

> 本手冊用 DB 端 `nas` 表管理 client（FreeRADIUS 開了 `read_clients = yes`），daloRADIUS 可直接增減 NAS。額外的檔案版本適合「靜態固定」的 client，但會跟 DB 衝突，**用其中一種即可**。

如果完全靠 DB（推薦），就不需要建 `clients.d/moxa.conf`，直接在 daloRADIUS 介面加 NAS 條目即可。

如果要靜態檔案，請刪除 DB 中重複條目並建立：
```bash
sudo mkdir -p /etc/freeradius/3.0/clients.d
sudo tee /etc/freeradius/3.0/clients.d/moxa.conf > /dev/null <<EOF
client moxa-gateway {
    ipaddr     = 10.90.35.36
    proto      = udp
    secret     = <同 Moxa 的 CHILLI_RADIUS_SECRET>
    require_message_authenticator = no
    nas_type   = other
    shortname  = moxa-chilli
}
EOF

# clients.conf 加 include
echo '$INCLUDE clients.d/' | sudo tee -a /etc/freeradius/3.0/clients.conf
```

**註：** Debian 12 的 `clients.conf` 預設啟用 `client localhost { secret = testing123 }`，
因為 DB nas 表也有 `127.0.0.1` 的條目，會撞 shortname。請二擇一：
- 註解掉預設 `client localhost { ... }` 整段
- 或從 DB 刪除 127.0.0.1 條目

**啟用 sites — `default` 與 `inner-tunnel` 啟用 sql：**

預設這兩個 site 在 authorize/accounting/session/post-auth 段裡 sql 是 `-sql`（軟失敗）。改為 `sql`：

```bash
sudo sed -i 's/^\([[:space:]]*\)-sql$/\1sql/' /etc/freeradius/3.0/sites-enabled/default
sudo sed -i 's/^\([[:space:]]*\)-sql$/\1sql/' /etc/freeradius/3.0/sites-enabled/inner-tunnel
```

**啟動：**
```bash
sudo systemctl enable --now freeradius
sudo systemctl status freeradius
```

如果起不來，先跑 `sudo freeradius -CX 2>&1 | tail -50` 看錯誤。

### 3.5 daloRADIUS

**部署檔案到 `/opt/daloradius`：**

從 Moxa 拷貝（已存在的版本最相容）：
```bash
# Moxa 上 tar
sudo tar czf /tmp/daloradius.tar.gz -C /opt daloradius
scp /tmp/daloradius.tar.gz andychu@10.90.35.47:/tmp/

# Public server 解壓
sudo tar xzf /tmp/daloradius.tar.gz -C /opt
sudo chown -R www-data:www-data /opt/daloradius
```

或從 GitHub 下載 release：
```bash
cd /opt
sudo wget https://github.com/lirantal/daloradius/archive/refs/tags/1.3.tar.gz
sudo tar xzf 1.3.tar.gz && sudo mv daloradius-1.3 daloradius
sudo chown -R www-data:www-data /opt/daloradius

# 匯入額外 schema
sudo mariadb -u root radius < /opt/daloradius/contrib/db/mysql-daloradius.sql
sudo mariadb -u root radius < /opt/daloradius/contrib/db/fr3-mysql-daloradius-and-freeradius.sql
```

**設定 DB 連線 — 編 `/opt/daloradius/library/daloradius.conf.php`：**
```php
$configValues['CONFIG_DB_HOST'] = 'localhost';
$configValues['CONFIG_DB_USER'] = 'radius';
$configValues['CONFIG_DB_PASS'] = '<同 Moxa 的 RADIUS_DB_PASS>';
$configValues['CONFIG_DB_NAME'] = 'radius';
```

**Apache vhost — `/etc/apache2/sites-available/dalo.conf`：**

```bash
# 自簽憑證
sudo openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
  -keyout /etc/ssl/private/captive-portal.key \
  -out /etc/ssl/certs/captive-portal.crt \
  -subj "/CN=10.90.35.47/O=Captive Portal Public RADIUS"

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

sudo a2enmod ssl rewrite headers
sudo a2dissite 000-default
sudo a2ensite dalo
sudo systemctl restart apache2
```

訪問：https://10.90.35.47/daloradius/login.php
- 預設帳號：`administrator` / `radius`
- **上線前一定要改！**

### 3.6 nftables 防火牆

**寫 `/etc/nftables.conf`：**

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
        ip saddr 10.90.0.0/16 tcp dport 22 accept comment "ssh from MGMT"

        # RADIUS auth + accounting + CoA from Moxa only
        ip saddr 10.90.35.36 udp dport { 1812, 1813, 3799 } accept comment "RADIUS from Moxa"

        # daloRADIUS Web UI from management subnet
        ip saddr 10.90.0.0/16 tcp dport { 80, 443 } accept comment "Web admin from MGMT"

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

sudo nft -f /etc/nftables.conf
sudo systemctl enable --now nftables
```

> **白名單範圍** 視環境調整：
> - 多台 Moxa：`ip saddr { 10.90.35.36, 10.90.35.40, ... }`
> - 動態 WAN：用 CIDR `/24`（風險增）或改用 dynamic DNS

---

## 4. Moxa 端設定

> **原則：保留 Moxa 既有 freeradius/daloRADIUS（可當 fallback），只改 chilli.conf 指向公網。**

### 4.0 Moxa nftables 開 CoA 入站

之前 RADIUS 在 127.0.0.1 走 loopback，不進 filter chain。改外部後，CoA (UDP 3799) 從公網入 Moxa 會被 fw 擋。加白名單：

```bash
# 即時生效
sudo nft 'add rule inet filter input ip saddr 10.90.35.47 udp dport 3799 accept comment "CoA from public RADIUS"'

# 持久化到 /etc/nftables.conf — snmp from MGMT_NET 規則之後加一行
sudo sed -i '/snmp from MGMT_NET/a\        ip saddr 10.90.35.47 udp dport 3799 accept comment "CoA from public RADIUS"' /etc/nftables.conf
```

### 4.1 改 `/etc/chilli.conf`

```bash
ssh moxa@10.90.35.36

sudo cp /etc/chilli.conf /etc/chilli.conf.before-public-radius

sudo sed -i 's|^radiusserver1 .*|radiusserver1 10.90.35.47|' /etc/chilli.conf
sudo sed -i 's|^radiusserver2 .*|radiusserver2 127.0.0.1|' /etc/chilli.conf

sudo systemctl restart chilli
sudo systemctl status chilli
```

`radiusserver2` 留 `127.0.0.1` 當公網不通時的備援。

### 4.2 驗證 chilli 改用公網

```bash
# Moxa 上抓 RADIUS secret
SECRET=$(sudo grep ^CHILLI_RADIUS_SECRET= /etc/captive-portal/secrets.env | cut -d= -f2-)

# radtest 公網
radtest testuser test1234 10.90.35.47 0 ${SECRET}
# 期待：Access-Accept
```

### 4.3 (可選) 停 Moxa 本地 freeradius

確認公網穩定後可停：
```bash
sudo systemctl disable --now freeradius
```

但建議保留，當作公網斷線時的 fallback（搭配 `radiusserver2 127.0.0.1`）。

---

## 5. 驗證測試

### 5.1 Moxa → 公網 radtest

```bash
# Moxa 上
SECRET=$(sudo grep ^CHILLI_RADIUS_SECRET= /etc/captive-portal/secrets.env | cut -d= -f2-)
radtest testuser test1234 10.90.35.47 0 ${SECRET}
```

期待：
```
Received Access-Accept Id ... from 10.90.35.47:1812
    Session-Timeout = 3600
    Idle-Timeout = 600
    WISPr-Bandwidth-Max-Down = ...
```

### 5.2 Accounting 流向公網

```bash
# 任一 client 走 portal 登入後，公網 server 上：
sudo mariadb -u root radius -e "
SELECT username, framedipaddress, nasipaddress, acctstarttime
FROM radacct
WHERE acctstoptime IS NULL
ORDER BY acctstarttime DESC LIMIT 5;"
```

`nasipaddress` 應為 `10.90.35.36`（Moxa）。

### 5.3 daloRADIUS Web UI

- URL：https://10.90.35.47/daloradius/login.php
- 登入：`administrator` / `radius`
- 確認：
  - User Listing 看到所有帳號
  - Accounting → Active Sessions 看到登入中的 client
  - NAS Listing 顯示 Moxa Gateway

### 5.4 防火牆 scoping

從非白名單 IP 試：
```bash
# 應該被擋
radclient -x 10.90.35.47:1812 auth secret <<<'User-Name=test,User-Password=x'
```

公網 server 上看：
```bash
sudo journalctl -k | grep fw-drop | tail
```

---

## 6. 日常運維

### 6.1 新增 user

**daloRADIUS Web：** Management → Users → New User

**或直接 SQL：**
```bash
sudo mariadb -u root radius <<EOF
INSERT INTO radcheck (username, attribute, op, value)
VALUES ('newuser', 'Cleartext-Password', ':=', 'newpass1234');

-- 限速 1 Mbps
INSERT INTO radreply (username, attribute, op, value) VALUES
  ('newuser', 'WISPr-Bandwidth-Max-Down', ':=', '1000000'),
  ('newuser', 'WISPr-Bandwidth-Max-Up', ':=', '1000000');

-- session 30 分鐘
INSERT INTO radreply (username, attribute, op, value)
VALUES ('newuser', 'Session-Timeout', ':=', '1800');
EOF
```

### 6.2 踢人 (CoA / Disconnect)

daloRADIUS：點 user → Disconnect

或手動：
```bash
SECRET=$(sudo grep ^CHILLI_RADIUS_SECRET= /etc/captive-portal/secrets.env | cut -d= -f2-)
echo 'User-Name="testuser"' | radclient 10.90.35.36:3799 disconnect ${SECRET}
```

> **重要：chilli 1.6 CoA 行為**
> - 必須包含 `User-Name` 屬性
> - 單獨 `Acct-Session-Id` 或 `Calling-Station-Id` 會被 chilli silent drop（無回應、無 log）
> - daloRADIUS 預設送 `User-Name`，可正常運作
>
> CoA 是公網 server → Moxa 方向（端口 3799），需要 Moxa nftables 開放（見 §4.0）。
> 成功踢人後 radacct 會記錄 `acctterminatecause = Admin-Reset`。

### 6.3 查 log

| 服務 | 位置 |
|------|------|
| FreeRADIUS | `/var/log/freeradius/radius.log` 與 `journalctl -u freeradius` |
| FreeRADIUS detail | `/var/log/freeradius/radacct/<NAS-IP>/detail-*` |
| Apache | `/var/log/apache2/dalo-{error,access}.log` |
| MariaDB | `/var/log/mysql/error.log` |
| Firewall drop | `journalctl -k | grep fw-drop` |

### 6.4 備份

```bash
# 每日備份 radius DB（cron）
sudo mariadb-dump --single-transaction radius > /backup/radius-$(date +%F).sql

# 把 secrets.env、nftables.conf、daloradius.conf.php 一起備
sudo tar czf /backup/configs-$(date +%F).tgz \
  /etc/captive-portal \
  /etc/freeradius/3.0/mods-enabled/sql \
  /etc/freeradius/3.0/clients.d/ \
  /etc/freeradius/3.0/sites-enabled/ \
  /etc/apache2/sites-available/dalo.conf \
  /etc/nftables.conf \
  /opt/daloradius/library/daloradius.conf.php
```

---

## 7. 疑難排解

### 7.1 Moxa radtest 失敗 — Access-Reject 或無回應

**檢查路徑：**

1. 防火牆：`sudo journalctl -k | grep fw-drop`，看是否被擋
2. Secret 對齊：Moxa `CHILLI_RADIUS_SECRET` == 公網 server `clients.d/moxa.conf` 或 `nas` 表的 secret
3. FreeRADIUS active：`sudo systemctl is-active freeradius`
4. `radtest` 帶 `-x` 看詳細錯誤

### 7.2 FreeRADIUS 起不來

```bash
sudo freeradius -CX 2>&1 | tail -50
```

常見原因：
- `client localhost` 與 DB nas 表 127.0.0.1 衝突 → 註解掉 `client localhost { ... }`
- `clients.d/*.conf` 兩個檔同 shortname → 改名或刪一個
- `sites-enabled/inner-tunnel` 中 `?sql` 或 `\x01sql` 隱形字元 → 重寫該行為 `sql`

### 7.3 daloRADIUS 500 error

- **`Class "DB" not found`** → 缺 PEAR DB module：`sudo apt install -y php-pear php-db`，重啟 Apache
- DB host/user/pass 不對：`/opt/daloradius/library/daloradius.conf.php`
- DB user 沒權限：`SHOW GRANTS FOR 'radius'@'localhost';`
- daloRADIUS schema 沒匯：跑 `contrib/db/*.sql`
- Apache permission：`/opt/daloradius/` ownership 應為 `www-data`

查 log：`sudo tail -50 /var/log/apache2/dalo-error.log`

### 7.4 portal 登入後仍看到登入頁

- chilli 跟 RADIUS 通了但 accounting 沒寫到 → 防火牆擋 1813？或 Moxa nftables 擋 outbound？
- Session-Timeout 太短 → 改 radreply
- Stale chilli session：`curl http://192.168.182.1:3990/logoff` 後重試

### 7.5 chilli 沒切到公網

- 看 `grep radiusserver /etc/chilli.conf` 是否真的改了
- `systemctl restart chilli` 後再驗
- chilli 重啟所有 client 都要重認證（normal）

### 7.6 CoA disconnect 沒回應 (silent drop)

**症狀：** `radclient ... disconnect` 從公網或 Moxa loopback 都收不到回應，chilli journal 沒記錄。

**原因 1：Moxa nftables 沒開 3799 入站**
```bash
# Moxa 上看
sudo nft list ruleset | grep 3799
# 沒看到 → 走 §4.0 加 rule
```

**原因 2：CoA 缺 `User-Name` 屬性**
- chilli 1.6 必須用 `User-Name` 來 lookup session
- 單獨 `Acct-Session-Id` / `Calling-Station-Id` 不行

**驗證 (從 Moxa loopback 試)：**
```bash
SECRET=$(sudo grep ^CHILLI_RADIUS_SECRET= /etc/captive-portal/secrets.env | cut -d= -f2-)
echo 'User-Name=andychu' | radclient -x 127.0.0.1:3799 disconnect ${SECRET}
# 期待：Disconnect-ACK
# 確認 chilli CoA 本身通，再排查網路/firewall
```

**tcpdump 觀察封包到達：**
```bash
# Moxa
sudo tcpdump -i any -nn udp port 3799
# 公網送 CoA → 看到 In packet
# chilli 處理 → 看到 Out packet（ACK）
```

---

## 8. 安全考量

| 項目 | 說明 | 改善方向 |
|------|------|---------|
| RADIUS UDP 明文 | 只有 MD5 hash 簽章，secret 外洩可解密 | 升 RadSec (RADIUS over TLS) 或走 WireGuard |
| Shared secret | 32+ char random，避免字典字 | 用 `openssl rand -hex 24` |
| 防火牆 scoping | 嚴格白名單，不要 `0.0.0.0/0` | 多 Moxa 用 named set |
| daloRADIUS 預設密碼 | `administrator/radius` | 上線前必改！加 2FA 更安全 |
| Self-signed cert | 瀏覽器警告 | 內網 CA 簽發 / Let's Encrypt |
| MariaDB root | unix_socket，不開 TCP | 不要設 root 密碼後開 TCP |
| /etc/captive-portal/secrets.env | 600 perms，root only | 改用 vault (HashiCorp / SOPS) |

---

## 9. 回滾步驟

公網 server 故障時把 chilli 切回本地：

```bash
ssh moxa@10.90.35.36

sudo cp /etc/chilli.conf.before-public-radius /etc/chilli.conf
sudo systemctl restart chilli

# 確認 Moxa 本地 freeradius 還活著
sudo systemctl is-active freeradius
sudo systemctl is-active mariadb

# 沒活的話起來
sudo systemctl start mariadb freeradius
```

如果在 `radiusserver2 = 127.0.0.1` 設定下，公網斷掉時 chilli 會自動 fallback 到本地，不用人工切。但 acct 可能短暫流失，需要事後對帳。

---

## 10. 附錄

### 10.1 完整設定檔清單

**公網 server (10.90.35.47)：**
| 檔案 | 用途 |
|------|------|
| `/etc/freeradius/3.0/mods-enabled/sql` | DB 連線 |
| `/etc/freeradius/3.0/clients.d/moxa.conf` | Moxa NAS（或用 DB nas 表） |
| `/etc/freeradius/3.0/clients.conf` | 主 clients 設定（注意註解掉 default localhost） |
| `/etc/freeradius/3.0/sites-enabled/default` | sql 啟用 |
| `/etc/freeradius/3.0/sites-enabled/inner-tunnel` | sql 啟用 |
| `/etc/captive-portal/secrets.env` | 共享 secrets（600 perms） |
| `/opt/daloradius/library/daloradius.conf.php` | daloRADIUS DB 設定 |
| `/etc/apache2/sites-available/dalo.conf` | Apache vhost |
| `/etc/ssl/certs/captive-portal.crt` | SSL cert |
| `/etc/ssl/private/captive-portal.key` | SSL key |
| `/etc/nftables.conf` | 防火牆白名單 |

**Moxa (10.90.35.36)：**
| 檔案 | 改動 |
|------|------|
| `/etc/chilli.conf` | radiusserver1=10.90.35.47, radiusserver2=127.0.0.1 |
| `/etc/chilli.conf.before-public-radius` | 備份 |

### 10.2 常用 SQL

```sql
-- 在線使用者
SELECT username, framedipaddress, callingstationid, acctstarttime
FROM radacct WHERE acctstoptime IS NULL;

-- 今日登入次數
SELECT username, COUNT(*) AS logins
FROM radacct WHERE DATE(acctstarttime)=CURDATE()
GROUP BY username ORDER BY logins DESC;

-- 流量 top 10
SELECT username,
       SUM(acctinputoctets+acctoutputoctets)/1024/1024 AS MB
FROM radacct WHERE acctstarttime > DATE_SUB(NOW(), INTERVAL 7 DAY)
GROUP BY username ORDER BY MB DESC LIMIT 10;

-- 強制斷所有 session
UPDATE radacct SET acctstoptime=NOW() WHERE acctstoptime IS NULL;

-- NAS 列表
SELECT * FROM nas;
```

### 10.3 Schema 結構

```
radcheck       -- 認證屬性 (Cleartext-Password, Auth-Type)
radreply       -- 授權屬性 (Session-Timeout, WISPr-Bandwidth-*)
radgroupcheck  -- 群組認證屬性
radgroupreply  -- 群組授權屬性
radusergroup   -- user → group 映射
radacct        -- 連線會計 (input/output octets, session time)
radpostauth    -- 認證 log (success/fail, password attempt)
nas            -- RADIUS client (NAS) 註冊表，FreeRADIUS read_clients=yes 時讀
userinfo       -- daloRADIUS 額外的 user metadata（姓名、email 等）
```

### 10.4 後續工作（v2）

- 自動化 secrets 同步（HashiCorp Vault / SOPS）
- 升級 RadSec (RADIUS over TLS) 取代明文 UDP
- 公網 server HA：keepalived + MariaDB replication
- 多 Moxa 共用同一公網 RADIUS（已可，僅需新增 nas 條目 + 防火牆白名單）
- 監控：Prometheus radius_exporter + Grafana dashboard
- 日誌中央化：rsyslog → ELK / Loki
