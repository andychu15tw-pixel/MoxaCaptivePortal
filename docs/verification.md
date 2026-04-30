# Verification Runbook — v1 MVP

按 phase 順序確認。每項通過再進下一個。失敗時 log 路徑寫在右欄。

---

## 0. 部署完成度檢查

| 服務 | 命令 | 預期 |
|------|------|------|
| chilli | `systemctl is-active chilli` | `active` |
| freeradius | `systemctl is-active freeradius` | `active` |
| mariadb | `systemctl is-active mariadb` | `active` |
| apache2 | `systemctl is-active apache2` | `active` |
| nftables | `systemctl is-active nftables` | `active` |
| snmpd | `systemctl is-active snmpd` | `active` |
| captive-dnsmasq | `systemctl is-active captive-dnsmasq` | `active` |
| captive-healthcheck | `systemctl is-active captive-healthcheck` | `active` |

```bash
for s in chilli freeradius mariadb apache2 nftables snmpd captive-dnsmasq captive-healthcheck; do
    printf '%-22s %s\n' "$s" "$(systemctl is-active $s)"
done
```

---

## 1. 介面 / 路由

```bash
ip -br addr             # eth0 應有 WAN IP；tun0 應有 192.168.182.1/24
ip route                # default 走 eth0；192.168.182.0/24 走 tun0
nft list ruleset | head # 規則應載入；oifname masquerade 可見
sysctl net.ipv4.ip_forward   # = 1
```

---

## 2. RADIUS 認證

```bash
# 用 chilli 共用 secret 測 testuser
SECRET=$(grep ^CHILLI_RADIUS_SECRET= /etc/captive-portal/secrets.env | cut -d= -f2-)
echo "User-Name=testuser,User-Password=test1234" | \
    radclient -x 127.0.0.1:1812 auth "$SECRET"
```

預期：`Received Access-Accept ... Session-Timeout = 3600`

失敗 →`/var/log/freeradius/radius.log`

---

## 3. Captive Portal — Client 實測

需要：一台筆電或手機接到 LAN 介面（直接接 eth1，或經 Wi-Fi AP）。

| 項 | 步驟 | 預期 |
|----|------|------|
| DHCP | `sudo dhclient -r ethX && sudo dhclient ethX` | 拿到 192.168.182.0/24 IP，gateway = DNS = 192.168.182.1 |
| DNS proxy | `nslookup example.com 192.168.182.1` | 回 example.com 真實 IP（captive-dnsmasq 透過 `/etc/resolv.conf` 上游解析） |
| HTTP intercept | `curl -v -m 5 http://neverssl.com` | 看到 `Location: http://192.168.182.1:3990/...` (302) |
| OS captive detect | 開瀏覽器後等通知 | Firefox / GNOME 顯示「需登入網路」通知 |
| 點通知 / 開瀏覽器 | 點通知或瀏覽 `http://neverssl.com` | 跳 `http://192.168.182.1/?loginurl=...` → Apache index.php → 302 → `/cgi-bin/hotspotlogin.cgi` |
| 登入表單 | 看到繁中「使用者登入」表單 | logo + 帳密欄位 |
| 登入 | 填 `testuser` / `test1234` → 送出 | CGI 計算 CHAP → redirect chilli `/logon` → RADIUS 通過 → 「登入成功」頁 |
| 上網 | 點「繼續瀏覽」 | 一切 HTTP/HTTPS 通 |
| Accounting | 認證後查 DB | `mariadb radius -e 'SELECT username, framedipaddress, acctstarttime FROM radacct WHERE acctstoptime IS NULL;'` 應有條目 |
| Session timeout | 等 ≥3600s | 自動斷線、再瀏覽 web 即跳回 portal |

---

## 4. daloRADIUS Admin UI

1. 瀏覽器 `https://<gw-ip>/daloradius/login.php`（接受自簽憑證警告）
2. 登入：`administrator` / `radius` → **立刻在 `Config → Operators` 改密碼**
3. Dashboard 應顯示：
   - 在線使用者 ≥1（若 step 3 client 還在線）
   - NAS 列表含 `chilli`
4. **新增 user**：`Management → New User` → `wifiuser1`/`pass1234`
5. Client 用新帳號登入 → 應通過
6. **踢人**：`Reports → Online Users` → 點 disconnect → client 收到 CoA-Disconnect
   - 注意：v1 chilli 預設 coaport 3799 已開，daloRADIUS 會送 PoD 封包

---

## 5. 客製 Portal

- 替換 `/etc/chilli/www/logo.svg` → reload portal 頁應立即看到新 logo
- 替換 `/etc/chilli/www/style.css` → 同上
- 編 `hotspotlogin.cgi` 改文字（中文化）

---

## 6. Bandwidth limit

```sql
-- daloRADIUS Web UI 等同：給 testuser 加屬性
INSERT INTO radreply (username, attribute, op, value)
    VALUES ('testuser', 'WISPr-Bandwidth-Max-Down', ':=', '1000000');
```

Client 登入後 `iperf3 -c <wan-server>` 應 ≤ ~1 Mbps。chilli 自動套 tc。

---

## 7. Firewall default deny

```bash
# 從未認證 client（拿到 IP 但沒登入）
nc -vz 192.168.182.1 22       # 應被擋（只 LAN tun0 才放）
nc -vz 8.8.8.8 22             # 應 timeout（chilli 不放任何 post-auth）
```

`/var/log/firewall.log` 應出現 `[fw-fwd-drop]` 條目。

---

## 8. 日誌檢查

```bash
tail -n 50 /var/log/chilli.log            # 認證 / accounting 事件
tail -n 50 /var/log/firewall.log          # nftables drops
tail -n 50 /var/log/freeradius/radius.log # RADIUS 詳細
journalctl -u captive-healthcheck -n 30   # 自動恢復紀錄
```

---

## 9. SNMP v3

```bash
SNMP_AUTH=$(grep ^SNMP_AUTH_PASS= /etc/captive-portal/secrets.env | cut -d= -f2-)
SNMP_PRIV=$(grep ^SNMP_PRIV_PASS= /etc/captive-portal/secrets.env | cut -d= -f2-)
snmpwalk -v3 -u moxaadmin -l authPriv \
    -a SHA -A "$SNMP_AUTH" -x AES -X "$SNMP_PRIV" \
    127.0.0.1 1.3.6.1.2.1.1
```

預期：`SNMPv2-MIB::sysDescr.0 = Linux ...`

---

## 10. 已知尚未涵蓋（v2 工作）

- Cellular WAN failover（`install/08-cellular.sh` 是 stub）
- 100 client 同時登入壓測（PRD 5.1）
- 72hr 穩定性測試（PRD 6.3）
- IPv6 完整支援
- HA / 雙機備援
