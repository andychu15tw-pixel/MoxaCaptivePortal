# Lessons Learned — Captive Portal Deployment

What broke during the first end-to-end deploy and the root cause for each. Prevents repeating mistakes.

---

## 1. Build-time

### 1.1 `coova-chilli` removed from Debian after stretch
**Symptom**: `apt install coova-chilli` → `Unable to locate package`.
**Why**: Maintenance dropped, package removed from Debian 10+.
**Fix**: Build from upstream `https://github.com/coova/coova-chilli.git` tag `1.6`. See `00b-build-chilli.sh`.

### 1.2 `--with-curl` configure fails despite `libcurl4-openssl-dev` installed
**Symptom**: `configure: error: --with-curl was given, but test for curl failed`.
**Why**: Some Moxa apt mirrors ship `.pc` files but the linkable `.so` is in a different package or not at all. `pkg-config` reports OK but `ld -lcurl` fails.
**Fix**: Build with `--without-curl`. CoovaChilli's `chilliredir` (the only curl consumer) is unused in our flow — Apache + `hotspotlogin.cgi` handle redirects.

### 1.3 `cmdline.patch: Hunk #1 FAILED at 1902`
**Symptom**: `make` aborts early.
**Why**: Coova's source ships a patch against gengetopt 2.22-era `cmdline.c` output. Newer gengetopt produces different line numbers.
**Fix**: Truncate `src/cmdline.patch` to a no-op before `make`. Lost feature: a small upstream cosmetic fix to `--help` output. Acceptable.

### 1.4 chilli source `make install` drops a SysV init script with empty `Default-Start`
**Symptom**: `update-rc.d: error: chilli Default-Start contains no runlevels, aborting`.
**Why**: Stale init script syntax incompatible with current Debian's update-rc.d.
**Fix**: Delete `/etc/init.d/chilli` after build. Use the systemd unit shipped by `00b-build-chilli.sh`.

---

## 2. Configuration

### 2.1 sed against multi-dialect FreeRADIUS `mods-available/sql` corrupted MongoDB section
**Symptom**: `Failed parsing configuration item "ca_file"`.
**Why**: Greedy regex matching `^[[:space:]]*#?[[:space:]]*server = ".*"` hit the MongoDB subsection's `# server = "mongodb://..."` lines and stripped indentation.
**Fix**: Drop sed entirely. Render a minimal MySQL-only template (`sql-mysql.conf.tmpl`) over the upstream file. See `02-freeradius.sh`.

### 2.2 `envsubst` ate FreeRADIUS variables like `${.:name}`, `${modconfdir}`
**Symptom**: `Parse error after ".:name": unexpected token "}"`.
**Why**: `envsubst` substitutes ANY `${...}` it sees, including FreeRADIUS's own template syntax. Same with `$configValues` in PHP.
**Fix**: Pass a whitelist of vars to `envsubst`: `envsubst '$VAR1 $VAR2' < src > dst`. See `lib.sh:render_template`.

### 2.3 Default `client localhost` in clients.conf conflicts with chilli on 127.0.0.1
**Symptom**: `Failed to add duplicate client chilli`.
**Why**: FreeRADIUS rejects two clients on the same IP. Default ships `client localhost { ipaddr=127.0.0.1; secret=testing123 }`; we add another at the same IP.
**Fix**: awk-comment the default `client localhost { ... }` block before adding ours. See `02-freeradius.sh`.

### 2.4 daloRADIUS minimal config caused "Undefined index: USERINFO_TABLE / FREERADIUS_VERSION" → SQL syntax errors
**Symptom**: dashboard works but Users Listing throws DB error with `, .firstname, .lastname` (table-qualified empty).
**Why**: Custom hand-written `daloradius.conf.php` template missed half the keys daloRADIUS expects.
**Fix**: Copy `library/daloradius.conf.php.sample` (ships in tarball) and `sed`-patch only the DB credential lines. All other keys preserved.

### 2.5 daloRADIUS 1.3 needs `php-db` (PEAR DB)
**Symptom**: `Class 'DB' not found in opendb.php:86`.
**Fix**: Add `php-db` and `php-pear` to apt list. Already in `00-base.sh`.

### 2.6 daloRADIUS at `/var/www/...` 403 from Apache
**Symptom**: `Symbolic link not allowed or link target not accessible: /var/www`.
**Why**: Moxa thingspro ships `/var/www -> /var/thingspro/www/`, restricted dir.
**Fix**: Install daloRADIUS at `/opt/daloradius`. Apache vhost aliases `/daloradius` → `/opt/daloradius`. See `05-daloradius.sh`.

---

## 3. Runtime / network

### 3.1 nftables locked out remote SSH on first deploy
**Symptom**: `connection refused` on port 22 after `06-nftables.sh` ran. Box reachable via ICMP.
**Why**: Initial rules only allowed SSH from `@lan_ifaces` (tun0) — the admin SSH from WAN got dropped.
**Recovery**: Console (HDMI/serial), `nft flush ruleset; systemctl stop nftables`.
**Permanent fix**: `MGMT_NET` defaults to `0.0.0.0/0` for first deploy. Tighten to internal CIDR after verification.

### 3.2 nftables flooded serial console with NetBIOS broadcast drops
**Symptom**: Serial console unreadable due to constant `[fw-input-drop] ... DPT=137/138 ...`.
**Fix**: Silently drop `pkttype { broadcast, multicast }` BEFORE the log+drop catchall. Also `kernel.printk = 1 4 1 7` keeps INFO-level logs off console (still go to /var/log/firewall.log).

### 3.3 NetworkManager's bundled dnsmasq won't bind tun0
**Symptom**: drop `99-captive-portal.conf` in `/etc/NetworkManager/dnsmasq.d/`, restart NM, dnsmasq doesn't respawn at all.
**Why**: NM only spawns dnsmasq if it manages a connection providing upstream DNS. Box's eth0 is configured via ifupdown (NM doesn't know about it), so NM has no upstream → no dnsmasq.
**Fix**: Standalone `captive-dnsmasq.service`. Independent lifecycle, doesn't depend on NM connection state.

### 3.4 dnsmasq received queries but client got timeout (RFC1918 source IP loop)
**Symptom**: `journalctl -u captive-dnsmasq` shows `query[A] example.com from 192.168.182.2` and `forwarded example.com to 1.1.1.1`, but no reply ever arrives. Client `dig` times out.
**Why**: `--bind-interfaces --listen-address=192.168.182.1` makes dnsmasq use 192.168.182.1 as the source IP for upstream queries. Reply from 8.8.8.8 → 192.168.182.1 (RFC1918) is not routable on the public internet.
**Fix**: `--bind-dynamic --interface=tun0`. dnsmasq tracks the interface, binds to its address dynamically, and outbound queries use kernel's normal source-IP selection (egress IP, e.g., 10.90.35.42).

### 3.5 Corporate firewall blocks UDP 53 to 8.8.8.8 / 1.1.1.1
**Symptom**: After fixing 3.4, dnsmasq still gets no upstream replies. `dig @8.8.8.8 example.com` directly from box also times out.
**Why**: Corporate egress filter only allows DNS to internal resolvers.
**Fix**: dnsmasq option `--resolv-file=/etc/resolv.conf`. Inherits the box's working internal DNS (`10.123.x.x`, `10.124.x.x`).

### 3.6 chilli's `radiusnasip` is invalid in 1.6
**Symptom**: chilli logs `invalid option radiusnasip`, fails to start.
**Fix**: Remove from `chilli.conf`. chilli auto-binds.

### 3.7 chilli 1.6 has NO built-in DNS proxy on tun0
**Symptom**: With `dns1=8.8.8.8` advertised in DHCP, clients pointing at chilli's own IP get connection refused on UDP 53. Even when chilli would intercept HTTP, DNS goes nowhere.
**Why**: 1.6 doesn't run a DNS server on tun0 itself — it relies on either upstream DNS being directly reachable from the client, OR an external DNS proxy on the gateway IP.
**Fix**: Standalone `captive-dnsmasq` listening on `192.168.182.1:53`, and `dns1=192.168.182.1` advertised in DHCP.

### 3.8 chilli's UAM redirect targets `/?loginurl=...` on port 80 — Apache 403
**Symptom**: Browser detects captive portal, follows redirect, gets 403 from Apache.
**Why**: chilli sends client to `http://uamlisten/?loginurl=<encoded URL>` expecting its own miniweb to handle. Apache owns port 80 and has no DirectoryIndex for `/etc/chilli/www`.
**Fix**: Add `index.php` that decodes the `loginurl` param and 302-redirects.

### 3.9 `login.chi` (haserl miniportal) auto-POSTs to `/www/error.chi`
**Symptom**: After Apache fix, `hotspotlogin.cgi` returns a 440-byte page that immediately POSTs to `/www/error.chi` → 404.
**Why**: `login.chi` is part of CoovaChilli's miniportal — designed to run inside chilli's port-3990 miniweb that serves `/etc/chilli/www/` rooted at `/www`. Errors POST to `/www/error.chi`. Apache serves CGI under `/cgi-bin/`, not `/www/`, so the recovery path 404s and login can never proceed.
**Fix**: Replace the haserl wrapper with a standalone Perl `hotspotlogin.cgi` that implements the standard Coova UAM CHAP flow. Self-contained, no `/www/` path dependency.

### 3.10 Wrong CHAP formula in custom hotspotlogin.cgi
**Symptom**: chilli rejects login with `res=failed&reason=reject` BEFORE forwarding to RADIUS (no RADIUS log entries).
**Why**: First implementation used `password XOR md5(challenge+secret)`. Coova UAM actually uses `md5("\0" + password + md5(challenge+secret))`.
**Fix**: Use the documented Coova formula:
```perl
my $hexchal = pack('H32', $challenge);
my $newchal = pack('H*', md5_hex($hexchal . $uamsecret));
my $response = md5_hex("\0" . $password . $newchal);
```

---

## 4. Lessons distilled

1. **Don't sed-edit upstream multi-section configs**. Render fresh from a vendor-supplied sample/template.
2. **`envsubst` needs a whitelist** when the source contains `${...}` patterns from another templating system (FreeRADIUS, Apache, PHP, …).
3. **Always include MGMT_NET (or equivalent) in the first firewall rule deploy**. Default-deny to your own SSH = trip to the lab.
4. **dnsmasq `--bind-interfaces` ≠ `--bind-dynamic`**. If outbound queries need normal kernel routing, use `--bind-dynamic`.
5. **Never assume public DNS reachable** on corporate / industrial nets. Inherit from `/etc/resolv.conf`.
6. **Check architecture early** — PRD says x86, hardware says aarch64. Source-built tools are portable; binary packages may not be.
7. **CoovaChilli 1.6 is the last upstream release (2017-ish)**. Its miniportal flow assumes its own miniweb. Mixing with Apache means writing a small CGI; don't try to bridge `.chi` through Apache.
8. **Don't put working files in `/tmp`** on industrial appliances — many use ramdisk-based `/tmp` that clears on reboot, and you'll lose work between sessions.
