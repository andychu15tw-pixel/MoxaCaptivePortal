# 📄 PRD.md  
## Product: LAN Computer (Captive Portal Gateway)

---

## 1. 📌 Product Overview

### 1.1 產品定位
LAN Computer（Captive Portal Gateway）是一台部署於邊緣網路的控制節點，負責：

- 使用者網路接入控制（Network Access Control, NAC）
- Captive Portal 認證導流
- 流量管控與策略執行
- 與遠端 AAA / Accounting Server 整合

---

### 1.2 使用場景

- 公共 Wi-Fi（車站、飯店、商場）
- 工業場域訪客網路（OT/IT 隔離）
- 車載系統（列車 Wi-Fi）
- 臨時網路（活動、展場）
- 4G/5G Edge Gateway

---

## 2. 🎯 Product Goals

### 2.1 功能目標
- 提供穩定 Captive Portal 認證機制
- 支援 AAA（RADIUS）整合
- 支援多 WAN（Cellular / Ethernet）

### 2.2 非功能目標

- 可遠端管理( Web UI）
- 工業等級穩定性（24/7）

---

## 3. 🧩 System Architecture
[Wi-Fi AP] --- L2 --- [Captive Portal Gateway (Local Services (DNS/DHCP/Web))] --- WAN --- [AAA Server]


---

## 4. 🔧 Functional Requirements

### 4.1 Network Management

#### 4.1.1 Interface Support
- LAN (bridge mode)
- WAN:
  - Ethernet
  - Cellular (4G/5G)

#### 4.1.2 IP Management
- DHCP Server
- Static lease binding (IP ↔ MAC)
- IPv4 / IPv6 support

---

### 4.2 Captive Portal

#### 4.2.1 Portal Behavior
- HTTP redirect (302)
- DNS hijacking（未認證狀態）
- OS detection support（Apple CNA / Android）

#### 4.2.2 Login Methods
- Username / Password
- Voucher / Token
- MAC-based authentication（白名單）
- OAuth（optional）

#### 4.2.3 Session Control
- Session timeout
- Idle timeout
- Max concurrent sessions


---

### 4.3 AAA Integration

#### 4.3.1 Protocol
- RADIUS (Authentication / Accounting)

#### 4.3.2 Accounting Events
- Start
- Interim Update（可設定 interval）
- Stop

#### 4.3.3 Attributes Support
- Bandwidth limit
- Session timeout
---

### 4.4 Firewall & Traffic Control

#### 4.4.1 Pre-auth Rules
- Allow:
  - DNS (53)
  - HTTP/HTTPS（redirect）
- Block all others

#### 4.4.2 Post-auth Rules
- Full access or policy-based routing

#### 4.4.3 QoS
- Per-user bandwidth control
- Traffic shaping（HTB / fq_codel）

---

### 4.5 NAT & Routing

- Source NAT (Masquerade)

---

### 4.6 DNS & Redirection

- DNS Proxy / Cache
- DNS hijack（未登入）
- Domain whitelist（OS 檢測與內部服務）

---

### 4.7 Logging & Monitoring

#### 4.7.1 Logs
- Authentication logs
- Session logs
- Firewall logs

#### 4.7.2 Metrics
- Active users
- Throughput
- CPU / Memory usage

#### 4.7.3 Export
- Syslog
- SNMP v3

---

### 4.8 Management Interface

#### 4.8.1 Web UI
- Dashboard（即時連線數）
- User/session management
- Policy configuration
- 可以上傳、修改、刪除 Captive Portal的logo

#### 4.8.2 CLI
- Linux shell
- Config via CLI tools

#### 4.8.3 API
- RESTful API
- JSON-based config

---

### 4.9 Security

- HTTPS portal（TLS 1.2+）
- Admin RBAC
- Firewall default deny
---

## 5. ⚙️ Non-Functional Requirements

### 5.1 Performance

| Item | Requirement |
|------|------------|
| Max Clients | ≥ 100 |
| Throughput | ≥ 1 Gbps |
| Concurrent Sessions | ≥ 50 |

---

### 5.2 Reliability

- Watchdog
- Auto-restart services

---



### 5.4 Scalability

- Horizontal scaling（多 gateway + central AAA）
- Cloud AAA integration

---

## 6. 🧪 Testing Requirements

### 6.1 Functional Test
- Portal redirect correctness
- AAA authentication flow
- Session timeout behavior

### 6.2 Performance Test
- 100 clients concurrent login
- Throughput test（iperf）

### 6.3 Stability Test
- 72 小時壓力測試
- WAN failover 測試

---

## 7. 🧱 Suggested Software Stack

### OS
- Linux（Debian )

### Network
- nftables
- dnsmasq（DHCP + DNS）

### Captive Portal
- CoovaChilli
- Nodogsplash
- Custom implementation（iptables + nginx）

### AAA Client
- radcli / freeradius-client

### Web
- nginx / lighttpd
- Flask / Node.js

---

## 8. 🚀 Future Enhancements

- AI-based traffic analysis
- User behavior analytics
- Edge AI integration


---
