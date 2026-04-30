# Deployment Runbook

Hands-on deploy steps for **CoovaChilli + FreeRADIUS + daloRADIUS Captive Portal Gateway** on Moxa industrial hardware running Debian 11 (bullseye) or Debian 12 (bookworm).

This runbook is what to actually do. For overview see `README.md`. For functional verification see `verification.md`.

---

## 0. Hardware reality check

PRD targets Moxa V2400 / V3400 (x86). The reference deployment used **i.MX 8M Plus (aarch64)** — the install scripts work on both architectures. ARM differences:

| Item | x86 | aarch64 |
|------|-----|---------|
| `coova-chilli` build | builds clean from source | builds clean (no apt package on either) |
| Performance | higher throughput | sufficient for ≤ 100 clients |
| Cellular module driver | varies | varies |

The scripts auto-detect interfaces but not architecture — no special action.

---

## 1. Pre-flight on target box

```bash
# As root or with sudo
ip -br addr                                  # confirm WAN/LAN names (eth0/eth1, eno1/eno2…)
cat /etc/os-release                          # confirm Debian 11 or 12
ip route                                     # confirm default route via WAN
ping -c 2 deb.debian.org                     # confirm apt reachable
```

If interfaces are NOT `eth0` (WAN) and `eth1` (LAN), prepare to override:
```bash
export WAN_IF=eno1
export LAN_IF=eno2
```

---

## 2. Copy repo to box

From dev machine:
```bash
scp -r MoxaCaptivePortal moxa@<gw-ip>:/home/moxa/
```

Or if `/var/www` etc. is restricted by Moxa thingspro symlink, use `/home/moxa/`.

---

## 3. Run phases (idempotent, safe to re-run)

**Each phase prints `[OK]` lines on success and `[X]` on fatal error. Read output carefully — don't assume success.**

```bash
cd /home/moxa/MoxaCaptivePortal/install
sudo ./00-base.sh             # apt packages + sysctl + interfaces
sudo ./00b-build-chilli.sh    # build CoovaChilli 1.6 from upstream (no Debian pkg)
sudo ./01-mariadb.sh          # MariaDB + DB creation
sudo ./02-freeradius.sh       # FreeRADIUS schema + sql module + chilli NAS + test user
sudo ./03-chilli.sh           # chilli config + start + captive-dnsmasq for DNS proxy
sudo ./04-portal-branding.sh  # logo + css + login.html + index.php + hotspotlogin.cgi
sudo ./05-daloradius.sh       # daloRADIUS at /opt/daloradius + Apache HTTPS vhost
sudo ./06-nftables.sh         # firewall + NAT (default MGMT_NET=0.0.0.0/0 — lock down later)
sudo ./07-services.sh         # rsyslog + snmpd + healthcheck + Restart=always
```

**Total time on i.MX 8M Plus**: ~10-15 min including chilli build (~3 min).

---

## 4. Platform-specific traps to watch

### 4.1 `coova-chilli` not in apt
Debian removed `coova-chilli` after stretch (Debian 9). `00b-build-chilli.sh` clones the upstream tag 1.6 from GitHub and builds. Build flags include `--without-curl` (works around `libcurl-dev` link issues on some Moxa repos; chilliredir is unused anyway).

### 4.2 `cmdline.patch` fails during build
gengetopt 2.23+ output doesn't match the patch shipped in coova source. `00b-build-chilli.sh` truncates `src/cmdline.patch` to a no-op before running `make`.

### 4.3 NetworkManager owns dnsmasq but won't spawn it
On boxes where eth0 is configured via `/etc/network/interfaces` (ifupdown), NM has no upstream DNS source and refuses to start its dnsmasq subprocess. We deploy a **separate** `captive-dnsmasq.service` on `tun0:53` instead.

### 4.4 dnsmasq + RFC1918 source IP loop
`--bind-interfaces --listen-address=192.168.182.1` makes dnsmasq use 192.168.182.1 as outbound source IP for upstream DNS queries → reply never returns. Use `--bind-dynamic --interface=tun0` so kernel picks egress source IP normally.

### 4.5 Corporate firewall blocks public DNS
On many internal networks UDP 53 to 8.8.8.8 / 1.1.1.1 is blocked. `captive-dnsmasq.service` uses `--resolv-file=/etc/resolv.conf` to inherit upstream DNS from the box (which already works on the corporate net).

### 4.6 `/var/www` is a symlink on Moxa thingspro
`/var/www -> /var/thingspro/www/` has restrictive perms. daloRADIUS is installed at `/opt/daloradius` instead — Apache vhost aliases `/daloradius` → `/opt/daloradius`.

### 4.7 chilli + Apache port 80 conflict
chilli's UAM redirects unauth clients to `http://uamlisten/?loginurl=<URL>` expecting its own miniweb. Apache owns `:80`. `index.php` decodes the query param and 302s onward.

### 4.8 `login.chi` (haserl miniportal) doesn't work via Apache
The `.chi` flow is tightly coupled to chilli's port-3990 miniweb (POSTs to `/www/error.chi` etc.). We replaced it with a self-contained **Perl** `hotspotlogin.cgi` that implements the standard Coova UAM CHAP formula.

### 4.9 nftables broadcast log spam
NetBIOS / mDNS broadcasts on the management LAN flood the firewall log. nftables silently drops `pkttype { broadcast, multicast }` before logging. `kernel.printk = 1 4 1 7` keeps INFO-level logs off the serial console.

### 4.10 nftables locking out remote SSH
First-time deploy must NOT restrict SSH to LAN-only. Default `MGMT_NET=0.0.0.0/0` allows SSH from anywhere. Lock down for production:
```bash
MGMT_NET=10.90.32.0/22 sudo /home/moxa/MoxaCaptivePortal/install/06-nftables.sh
```

---

## 5. First-login changes

### 5.1 daloRADIUS admin password
Open `https://<gw-ip>/daloradius/login.php` (accept self-signed cert):
- Default: `administrator` / `radius`
- Go to **Config → Operators** → change password.

### 5.2 Replace TLS cert with proper one
v0 ships self-signed at `/etc/ssl/certs/captive-portal.crt`. For production with a public DNS name:
```bash
sudo apt install certbot python3-certbot-apache
sudo certbot --apache -d portal.your-domain.tld
```

### 5.3 Customize portal branding
Edit on the box:
- `/etc/chilli/www/logo.svg` — replace with customer logo
- `/etc/chilli/www/style.css` — change colors / fonts
- `/etc/chilli/www/hotspotlogin.cgi` — change Chinese strings if needed

These are deployed by `04-portal-branding.sh`. Re-run won't overwrite if you've already replaced (backups via `*.orig`).

---

## 6. End-to-end smoke test

From a wired client connected to the LAN port (eth1 / eno2):

```bash
# 1. DHCP
sudo dhclient -r eno2 && sudo dhclient eno2
ip -4 addr show eno2 | grep 192.168.182      # should have 192.168.182.x

# 2. DNS
nslookup example.com 192.168.182.1            # should return real IP

# 3. HTTP intercept
curl -v -m 5 http://neverssl.com 2>&1 | head -10
# Look for: Location: http://192.168.182.1:3990/...

# 4. Browser
firefox http://neverssl.com
# Should pop up captive portal notification → click → login form
# Use testuser / test1234 → "登入成功" page → can browse
```

If any step fails see **§7 troubleshooting**.

---

## 7. Troubleshooting quick reference

| Symptom | Likely cause | Where to look |
|---------|--------------|---------------|
| Client gets no DHCP | chilli not running / eth1 down | `systemctl status chilli`, `ip -br link` |
| `nslookup ... 192.168.182.1` connection refused | captive-dnsmasq not running | `systemctl status captive-dnsmasq`, `ss -tunlp \| grep ':53'` |
| `nslookup` works but `curl` times out | corporate firewall blocks public DNS | `host example.com 8.8.8.8` from box — if fails, ensure dnsmasq uses `/etc/resolv.conf` |
| Browser shows portal but login rejects all creds | uamsecret mismatch between chilli + cgi | `grep uamsecret /etc/chilli.conf /etc/chilli/defaults` — must match |
| 403 on `https://<gw>/daloradius/...` | Apache symlink path issue | confirm daloRADIUS at `/opt/daloradius` not `/var/www/...` |
| 500 on daloRADIUS dologin | missing `php-db` or stale `daloradius.conf.php` | `apt install php-db php-pear`; rerun `05-daloradius.sh` |
| nftables blocking own SSH | MGMT_NET too narrow | console-rescue: `nft flush ruleset; systemctl stop nftables` |

### Key log files

```bash
journalctl -u chilli -n 100 --no-pager
journalctl -u freeradius -n 100 --no-pager
journalctl -u captive-dnsmasq -n 50 --no-pager
journalctl -u apache2 -n 50 --no-pager
tail -f /var/log/apache2/dalo-error.log
tail -f /var/log/apache2/dalo-access.log
tail -f /var/log/freeradius/radius.log
```

### Key commands

```bash
# Active chilli sessions (use the per-pid sock)
sudo chilli_query -s /var/run/chilli.ipc list

# RADIUS auth smoke test
SECRET=$(sudo grep ^CHILLI_RADIUS_SECRET= /etc/captive-portal/secrets.env | cut -d= -f2-)
echo 'User-Name=testuser,User-Password=test1234' | radclient -x 127.0.0.1:1812 auth "$SECRET"

# Live tcpdump for client traffic
sudo tcpdump -i tun0 -nn '(udp port 53 or tcp port 80 or tcp port 3990)'
```

---

## 8. Persistent paths (do not put files in `/tmp`)

`/tmp` is volatile (cleared on reboot on most setups, and Moxa ramdisks accelerate this). Persistent locations:

| What | Path |
|------|------|
| Repo working copy | `/home/moxa/MoxaCaptivePortal/` |
| Secrets (root only) | `/etc/captive-portal/secrets.env` |
| chilli runtime | `/var/run/chilli.*` (volatile, recreated on start) |
| MariaDB data | `/var/lib/mysql/` |
| daloRADIUS logs | `/var/log/daloradius/` |
| portal www assets | `/etc/chilli/www/` |

---

## 9. Reset / rebuild

To wipe and redeploy from scratch:

```bash
# WARNING: drops the radius DB and everything in it
sudo systemctl stop chilli freeradius mariadb apache2 captive-dnsmasq captive-healthcheck
sudo apt-get purge -y mariadb-server-* freeradius freeradius-mysql apache2-* php-*
sudo rm -rf /var/lib/mysql /etc/freeradius /etc/apache2 /etc/chilli* /opt/daloradius
sudo rm -f /etc/captive-portal/secrets.env
sudo rm -f /usr/sbin/chilli /etc/systemd/system/{chilli,captive-*}.service
sudo systemctl daemon-reload

# Then re-run from §3
```
