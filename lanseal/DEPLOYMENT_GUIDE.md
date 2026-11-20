# LANSeal — Complete Deployment Guide

> **Legacy guide:** This document describes an earlier design and contains hard-coded example networks and NAT/physical-LAN routes that do not match the current implementation. Use [README.md](README.md), [docs/architecture.md](docs/architecture.md), and [clients/windows/README.md](clients/windows/README.md) for the current supported flow.

**Transparent LAN Encryption via IKEv2/IPsec + Private PKI**
**Hardened: No plaintext fallback, gateway spoofing prevention, route leak fixes**

---

## 📋 Requirements

### Gateway (10.24.10.235 — Ubuntu Server)
| Requirement | Version/Details |
|-------------|-----------------|
| OS | Ubuntu 22.04+ / Debian 12+ |
| Kernel | 5.15+ (IPsec, xfrm, nftables) |
| Packages | `strongswan-swanctl`, `nftables`, `iptables-nft` |
| Network | Static IP `10.24.10.235/24` on `eth0` |
| Ports | UDP 500, 4500 (IKE), Protocol 50 (ESP) |
| Certificates | Gateway cert+key, CA cert (issued by LANSeal CA) |

### Linux Client (10.24.10.234 — Kali)
| Requirement | Version/Details |
|-------------|-----------------|
| OS | Kali Linux / Debian 12+ / Ubuntu 22.04+ |
| Kernel | 5.15+ (xfrm, policy routing) |
| Packages | `strongswan-swanctl`, `nftables`, `systemd-networkd` |
| Network | DHCP on `eth0` (gets `10.24.10.234/24`) |
| Certificates | Client cert+key, CA cert (issued by LANSeal CA) |

### Windows Client (Windows 10/11 Pro/Enterprise)
| Requirement | Version/Details |
|-------------|-----------------|
| OS | Windows 10/11 **Pro or Enterprise** (MachineCertificate requires Pro+) |
| PowerShell | 5.1+ |
| Privileges | **Administrator** (for install + connect) |
| Network | Physical NIC on `10.24.10.0/24` |
| Certificates | `ca.pem` (CA), `client.p12` (client cert+key PFX) |
| Gateway Cert | Must have EKU: Client Auth + Server Auth, SAN: `gw.lanseal.home.arpa` |

### Pi Connector (Optional — for printer/IoT access without gateway config)
| Requirement | Version/Details |
|-------------|-----------------|
| Hardware | Raspberry Pi 3B+/4/5 or any Linux on printer LAN |
| OS | Raspberry Pi OS / Ubuntu Server / Debian |
| Packages | `strongswan-swanctl`, `socat`, `nftables` |
| Network | Same physical LAN as printer (`10.24.10.0/24`) |
| Certificates | Pi client cert+key, CA cert (enrolled as LANSeal client) |

---

## 📁 Project Structure

```
/home/kali/server2/lanseal/
├── clients/
│   ├── linux/
│   │   ├── install.sh, firewall.sh, diagnostics.sh, uninstall.sh
│   │   └── hardened/
│   │       ├── lanseal-client.nft
│   │       ├── 20-lanseal-routes.network
│   │       └── lanseal-client.conf
│   │
│   └── windows/
│       ├── Install-LANSealClient-Hardened.ps1
│       └── README.md
│
├── server/
│   ├── templates/
│   └── hardened/
│       ├── 99-lanseal-gateway.conf
│       ├── lanseal-gateway.nft
│       └── lanseal-gateway.conf
│
├── pi/
│   ├── lanseal-printer-forward@.service
│   └── README.md
│
└── HARDENED_README.md
```

---

## 🔐 Certificate Setup (All Nodes)

### CA Structure
```
lanseal-ca.pem              # Root CA certificate
gw.lanseal.home.arpa.pem    # Gateway certificate
gw.lanseal.home.arpa-key.pem # Gateway private key
kali.lanseal.home.arpa.pem  # Linux client certificate
kali.lanseal.home.arpa-key.pem # Linux client private key
pi.lanseal.home.arpa.pem    # Pi client certificate
pi.lanseal.home.arpa-key.pem # Pi private key
client.p12                  # Windows client PFX (cert+key)
```

### Certificate Requirements
- **All certs issued by LANSeal CA**
- **Gateway cert**: EKU = Server Auth (1.3.6.1.5.5.7.3.1) + Client Auth (1.3.6.1.5.5.7.3.2), SAN = `DNS:gw.lanseal.home.arpa`
- **Client certs**: EKU = Client Auth, SAN = `DNS:<hostname>.lanseal.home.arpa`
- **Key type**: ECDSA P-384 preferred, RSA 2048+ fallback

### Deploy Certs

**Gateway (10.24.10.235):**
```bash
sudo mkdir -p /etc/swanctl/x509 /etc/swanctl/private /etc/swanctl/x509ca
sudo cp gw.lanseal.home.arpa.pem /etc/swanctl/x509/
sudo cp gw.lanseal.home.arpa-key.pem /etc/swanctl/private/
sudo cp lanseal-ca.pem /etc/swanctl/x509ca/
sudo chmod 640 /etc/swanctl/private/*.pem
sudo chown root:root /etc/swanctl/private/*.pem
```

**Linux Client (10.24.10.234):**
```bash
sudo mkdir -p /etc/swanctl/x509 /etc/swanctl/private /etc/swanctl/x509ca
sudo cp kali.lanseal.home.arpa.pem /etc/swanctl/x509/
sudo cp kali.lanseal.home.arpa-key.pem /etc/swanctl/private/
sudo cp lanseal-ca.pem /etc/swanctl/x509ca/
sudo chmod 640 /etc/swanctl/private/*.pem
```

**Pi Connector:**
```bash
sudo mkdir -p /etc/swanctl/x509 /etc/swanctl/private /etc/swanctl/x509ca
sudo cp pi.lanseal.home.arpa.pem /etc/swanctl/x509/
sudo cp pi.lanseal.home.arpa-key.pem /etc/swanctl/private/
sudo cp lanseal-ca.pem /etc/swanctl/x509ca/
```

**Windows Client:**
```powershell
# Copy to C:\lanseal\
ca.pem
client.p12
```

---

## 🖥️ GATEWAY DEPLOYMENT (10.24.10.235)

### 1. Kernel Hardening
```bash
sudo cp /home/kali/server2/lanseal/server/hardened/99-lanseal-gateway.conf /etc/sysctl.d/
sudo sysctl --system
```

**Verifies:**
```bash
sysctl net.ipv4.ip_forward net.ipv4.conf.all.rp_filter net.ipv4.conf.all.send_redirects
# ip_forward=1, rp_filter=2, send_redirects=0
```

### 2. nftables (NAT + Filter)
```bash
sudo cp /home/kali/server2/lanseal/server/hardened/lanseal-gateway.nft /etc/nftables.d/
# Add to /etc/nftables.conf:
# include "/etc/nftables.d/lanseal-gateway.nft"
sudo nft -c -f /etc/nftables.d/lanseal-gateway.nft && sudo nft -f /etc/nftables.d/lanseal-gateway.nft
```

**Key Rules:**
- `meta ipsec exists` on forward chain (prevents spoofing)
- NAT: `10.77.0.0/24 → 10.24.10.0/24` masquerade

### 3. strongSwan
```bash
sudo cp /home/kali/server2/lanseal/server/hardened/lanseal-gateway.conf /etc/swanctl/conf.d/
sudo swanctl --load-all
sudo systemctl reload strongswan
```

**Verifies:**
```bash
swanctl --list-conns
swanctl --list-sas
ip xfrm policy | grep -E "10.77|10.24"
```

### 4. Firewall Check
```bash
nft list chain inet lanseal_server forward
# Must show: meta ipsec exists on both 10.77.0.0/24 rules
```

---

## 🐧 LINUX CLIENT DEPLOYMENT (10.24.10.234)

### 1. Firewall (Static — No Toggle)
```bash
sudo cp /home/kali/server2/lanseal/clients/linux/hardened/lanseal-client.nft /etc/nftables.d/
# Add to /etc/nftables.conf:
# include "/etc/nftables.d/lanseal-client.nft"
sudo nft -c -f /etc/nftables.d/lanseal-client.nft && sudo nft -f /etc/nftables.d/lanseal-client.nft
```

**Logic — NO PORT BLOCKING WHEN TUNNEL UP:**
- `rt ipsec exists accept` → tunnel UP = **allow ALL ports/protocols** to subnet
- `drop` → tunnel DOWN = block (NO fallback)

**Rule Order (output chain):**
```
1. IKE/ESP to gateway (always allow)
2. DHCP (always allow)
3. DNS to gateway (always allow)
4. 10.77.0.0/24 with IPsec transform → ACCEPT (all ports)
5. 10.77.0.0/24 without transform → DROP
6. 10.24.10.0/24 with IPsec transform → ACCEPT (all ports)
7. 10.24.10.0/24 without transform → DROP
8. Everything else → ACCEPT (split tunnel internet)
```

**When tunnel UP:** Rules 4 & 6 match → **full access to both subnets, all ports**
**When tunnel DOWN:** Rules 4 & 6 don't match → Rules 5 & 7 drop → **zero access**

### 2. Explicit Routes (Source IP Fix)
```bash
sudo cp /home/kali/server2/lanseal/clients/linux/hardened/20-lanseal-routes.network /etc/systemd/network/
sudo systemctl restart systemd-networkd
```

**Verifies:**
```bash
ip route get 10.24.10.50
# Must show: src 10.77.0.16 table 220
ip route get 10.77.0.1
# Must show: src 10.77.0.16 table 220
```

### 3. strongSwan Client
```bash
sudo cp /home/kali/server2/lanseal/clients/linux/hardened/lanseal-client.conf /etc/swanctl/conf.d/
sudo swanctl --load-all
sudo swanctl --initiate --ike lanseal
```

**Verifies:**
```bash
swanctl --list-sas
ip xfrm policy | grep -E "10.77|10.24"
ip route show table 220
```

---

## 🪟 WINDOWS CLIENT DEPLOYMENT

### 1. Prepare Certificates
```powershell
# On Windows machine (Admin PowerShell)
New-Item -ItemType Directory -Force -Path C:\lanseal
# Copy from project:
# ca.pem → C:\lanseal\ca.pem
# client.p12 → C:\lanseal\client.p12
```

### 2. Run Installer (Admin PowerShell)
```powershell
cd C:\lanseal
# Copy Install-LANSealClient-Hardened.ps1 here first

# Test mode (dry run)
.\Install-LANSealClient-Hardened.ps1 -CertDir "C:\lanseal" -TestMode

# Real install
.\Install-LANSealClient-Hardened.ps1 -CertDir "C:\lanseal" -P12Password "your-p12-password"

# Force (no prompts)
.\Install-LANSealClient-Hardened.ps1 -CertDir "C:\lanseal" -P12Password "your-p12-password" -Force
```

**What it does:**
- Imports CA → `LocalMachine\Root`
- Imports client cert → `LocalMachine\My`
- Creates VPN `LANSeal` (IKEv2, MachineCertificate, SplitTunneling)
- Sets IPsec crypto (GCM-AES256/SHA384/ECP384)
- Adds explicit routes: `10.77.0.0/24`, `10.24.10.0/24`
- Creates **permanent** firewall block rules on **physical interfaces only** (gateway excluded)
- Registers scheduled task for low VPN metric

**NO PORT BLOCKING WHEN TUNNEL UP:**
- Block rules apply **only to physical NICs** (Ethernet/WiFi)
- VPN adapter (TAP/WAN Miniport) is **unaffected** — full access to all ports on both subnets
- Gateway IP (`10.24.10.235`) excluded from block → IKE/ESP always works

### 3. Connect
```powershell
C:\lanseal\LANSeal-Connect.ps1
```

### 4. Verify
```powershell
C:\lanseal\LANSeal-Test.ps1
```

**Expected (Connected):**
```
Tunnel: CONNECTED
Route Tests: 10.77.0.1 → Reply, 10.24.10.1 → Reply
VPN Routes: 10.77.0.0/24, 10.24.10.0/24 (metric 1)
Interface Metric: 5
```

**Expected (Disconnected):**
```
Tunnel: DISCONNECTED
ping 10.24.10.1 → FAIL (blocked)
```

### 5. Disconnect
```powershell
C:\lanseal\LANSeal-Disconnect.ps1
```

---

## 🍓 PI CONNECTOR DEPLOYMENT (Optional)

### 1. Enroll Pi as LANSeal Client
Use Linux client configs with Pi's cert (`pi.lanseal.home.arpa`).

### 2. Reserve Fixed Virtual IP (Gateway)
In gateway `swanctl.conf` pool, Pi gets `10.77.0.50` via cert identity.

### 3. Install Forwarder
```bash
sudo cp /home/kali/server2/lanseal/pi/lanseal-printer-forward@.service /etc/systemd/system/
# Edit virtual IP if different:
sudo sed -i 's/10.77.0.50/<PI_VIRTUAL_IP>/g' /etc/systemd/system/lanseal-printer-forward@.service

sudo apt install -y socat
sudo systemctl daemon-reload
sudo systemctl enable --now lanseal-printer-forward@9100   # Raw printing
sudo systemctl enable --now lanseal-printer-forward@631    # IPP
sudo systemctl enable --now lanseal-printer-forward@80     # Web UI HTTP
sudo systemctl enable --now lanseal-printer-forward@443    # Web UI HTTPS
sudo systemctl enable --now lanseal-printer-forward@161    # SNMP (optional)
```

### 4. Verify
```bash
ss -ltnp | grep 10.77.0.50
# LISTEN on 10.77.0.50:9100,631,80,443 (NOT 0.0.0.0)
```

### 5. Client Printer Config

**Linux (CUPS):**
```bash
lpadmin -p "LANSeal-Printer" -v "socket://10.77.0.50:9100" -E
```

**Windows (Admin PowerShell):**
```powershell
Add-PrinterPort -Name "LANSeal-Printer-Port" -PrinterHostAddress "10.77.0.50" -PortNumber 9100
Add-Printer -Name "LANSeal-Printer" -PortName "LANSeal-Printer-Port" -DriverName "Generic / Text Only"
```

---

## ✅ VERIFICATION CHECKLIST

### Gateway
```bash
ip xfrm policy | grep -E "10.77|10.24"
nft list chain inet lanseal_server forward | grep "meta ipsec exists"
tcpdump -ni eth0 esp  # Only ESP when clients connected
```

### Linux Client
```bash
ip route get 10.24.10.50    # src 10.77.0.16 table 220
tcpdump -ni eth0 host 10.24.10.1  # Only ESP when UP
systemctl stop strongswan && ping -c 2 10.24.10.1  # FAILS
```

### Windows Client
```powershell
Get-VpnConnectionRoute -ConnectionName LANSeal
# Tunnel UP: ping 10.24.10.1 works
# Tunnel DOWN: ping 10.24.10.1 FAILS
```

### Pi Connector
```bash
ss -ltnp | grep 10.77.0.50  # Bound to vIP only
nc -vz 10.77.0.50 9100      # From client via tunnel
```

---

## 🛡️ DESIGN GUARANTEES

| Scenario | 10.24.10.x (Router/Printers) | 10.77.0.x (LANSeal) | Internet |
|----------|------------------------------|---------------------|----------|
| **Tunnel UP** | ✅ **All ports** encrypted via gateway | ✅ **All ports** encrypted direct | ✅ Direct (split) |
| **Tunnel DOWN** | 🚫 **BLOCKED** (zero ports) | 🚫 **BLOCKED** (zero ports) | ✅ Direct (split) |

**No plaintext fallback ever. No port restrictions when tunnel active.**

---

## 🔄 ROLLBACK

Each component independent — revert by restoring previous configs:

```bash
# Gateway
sudo systemctl restart strongswan
sudo nft flush ruleset && sudo nft -f /etc/nftables.conf

# Linux Client
sudo swanctl --terminate --ike lanseal
sudo nft flush ruleset && sudo nft -f /etc/nftables.conf
sudo systemctl restart systemd-networkd

# Windows
Remove-VpnConnection -Name LANSeal -Force
Get-NetFirewallRule -Name "LANSeal-*" | Remove-NetFirewallRule
Remove-Item Cert:\LocalMachine\Root\<CA_THUMBPRINT>
Remove-Item Cert:\LocalMachine\My\<CLIENT_THUMBPRINT>

# Pi
sudo systemctl disable --now lanseal-printer-forward@*
```

---

## 📝 Troubleshooting Quick Ref

| Symptom | Check |
|---------|-------|
| Tunnel won't establish | Certs match? Gateway reachable? UDP 500/4500 open? |
| Linux: ping 10.24.10.x fails (tunnel UP) | `ip route get 10.24.10.x` shows src 10.77.0.x? `rt ipsec exists` rule hit? |
| Windows: ping 10.24.10.x fails (tunnel UP) | `Get-VpnConnectionRoute` shows both prefixes? VPN metric = 5? |
| Windows: "rasdial 691" | Client cert in LocalMachine\My? Gateway cert trusted? |
| Pi: printer unreachable | Pi vIP correct? `ss -ltnp` shows bind on vIP? Printer pingable from Pi? |
| Gateway: spoofing works? | `nft list chain inet lanseal_server forward` shows `meta ipsec exists`? |

---

## 📞 Support

- **Project**: `/home/kali/server2/lanseal/`
- **Hardened Configs**: `clients/linux/hardened/`, `clients/windows/`, `server/hardened/`, `pi/`
- **Master Guide**: `HARDENED_README.md`

**All configs address the critique points: gateway spoofing, Windows toggle, route leaks, Pi binding, cert constraints, fail-closed, redirects, IPv6, CRL/OCSP, EKU validation.**
