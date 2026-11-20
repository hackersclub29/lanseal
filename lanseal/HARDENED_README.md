# LANSeal Hardened Configs

> **Legacy notes:** This document includes older hard-coded network and firewall assumptions. For the current enrollment flow and network model, see [README.md](README.md), [docs/architecture.md](docs/architecture.md), and [clients/windows/README.md](clients/windows/README.md).

## Overview
Production-ready, security-hardened configurations for LANSeal transparent LAN encryption.
Addresses all critique points: no plaintext fallback, gateway spoofing prevention, route/src IP leak fixes.

## Directory Structure
```
lanseal/
├── clients/
│   ├── linux/
│   │   ├── install.sh                 # Original installer
│   │   ├── firewall.sh                # Original firewall
│   │   ├── diagnostics.sh
│   │   ├── uninstall.sh
│   │   └── hardened/                  # NEW: Hardened configs
│   │       ├── lanseal-client.nft         # Static nftables (rt ipsec exists)
│   │       ├── 20-lanseal-routes.network  # Explicit routes with src IP
│   │       └── lanseal-client.conf        # strongSwan (trap, cacerts)
│   │
│   └── windows/
│       ├── Install-LANSealClient-Hardened.ps1  # NEW: Hardened installer
│       └── README.md                    # Windows deployment guide
│
├── server/
│   ├── templates/                       # Original templates
│   └── hardened/                        # NEW: Hardened gateway configs
│       ├── 99-lanseal-gateway.conf      # Kernel sysctl
│       ├── lanseal-gateway.nft          # NAT + filter (meta ipsec exists)
│       └── lanseal-gateway.conf         # strongSwan (dual client, trap)
│
└── pi/
    ├── lanseal-printer-forward@.service # NEW: socat forwarder (binds vIP)
    └── README.md                        # Pi connector guide
```

## Key Hardening Changes

| Issue | Fix | Location |
|-------|-----|----------|
| Gateway forward spoofing | `meta ipsec exists` on forward rules | `server/hardened/lanseal-gateway.nft` |
| Windows toggle logic | Permanent block rules + gateway exclusion | `clients/windows/Install-LANSealClient-Hardened.ps1` |
| Route/src IP leak (Linux) | Explicit routes with `src 10.77.0.16` in table 220 | `clients/linux/hardened/20-lanseal-routes.network` |
| Route/src IP leak (Windows) | `Add-VpnConnectionRoute` + low VPN metric task | `clients/windows/Install-LANSealClient-Hardened.ps1` |
| Pi binds 0.0.0.0 | `bind=10.77.0.50` in socat | `pi/lanseal-printer-forward@.service` |
| Cert trust | `cacerts = lanseal-ca.pem` + `rightca` constraints | `server/hardened/lanseal-gateway.conf`, `clients/linux/hardened/lanseal-client.conf` |
| Fail closed | `start_action = trap` everywhere | All strongSwan configs |
| Redirects | `send_redirects=0`, `rp_filter=2` | `server/hardened/99-lanseal-gateway.conf` |
| IPv6 disabled | `disable_ipv6=1` | `server/hardened/99-lanseal-gateway.conf` |
| CRL/OCSP local | `crl_uri`, `ocsp_uri` pointing to gateway | `server/hardened/lanseal-gateway.conf` |
| Windows cert EKU | Validates clientAuth+serverAuth on gateway cert | `clients/windows/Install-LANSealClient-Hardened.ps1` |

## Deployment

### Gateway (10.24.10.235)
```bash
# 1. Kernel
sudo cp server/hardened/99-lanseal-gateway.conf /etc/sysctl.d/
sudo sysctl --system

# 2. nftables
sudo cp server/hardened/lanseal-gateway.nft /etc/nftables.d/
# Add to /etc/nftables.conf: include "/etc/nftables.d/lanseal-gateway.nft"
sudo nft -f /etc/nftables.d/lanseal-gateway.nft

# 3. strongSwan
sudo cp server/hardened/lanseal-gateway.conf /etc/swanctl/conf.d/
# Copy certs to /etc/swanctl/x509/, /etc/swanctl/private/, /etc/swanctl/x509ca/
sudo swanctl --load-all
sudo systemctl reload strongswan
```

### Linux Client (10.24.10.234)
```bash
# 1. Firewall
sudo cp clients/linux/hardened/lanseal-client.nft /etc/nftables.d/
# Add to /etc/nftables.conf: include "/etc/nftables.d/lanseal-client.nft"
sudo nft -f /etc/nftables.d/lanseal-client.nft

# 2. Routes
sudo cp clients/linux/hardened/20-lanseal-routes.network /etc/systemd/network/
sudo systemctl restart systemd-networkd

# 3. strongSwan
sudo cp clients/linux/hardened/lanseal-client.conf /etc/swanctl/conf.d/
# Copy certs to /etc/swanctl/x509/, /etc/swanctl/private/, /etc/swanctl/x509ca/
sudo swanctl --load-all
sudo swanctl --initiate --ike lanseal
```

### Windows Client
```powershell
# 1. Copy certs to C:\lanseal\ca.pem and C:\lanseal\client.p12
# 2. Run installer (Admin PowerShell)
.\clients\windows\Install-LANSealClient-Hardened.ps1 -CertDir "C:\lanseal" -P12Password "xxx"
# 3. Connect
C:\lanseal\LANSeal-Connect.ps1
# 4. Test
C:\lanseal\LANSeal-Test.ps1
```

### Pi Connector (Printer LAN)
```bash
# 1. Enroll Pi as LANSeal client (same as Linux client)
# 2. Copy forwarder
sudo cp pi/lanseal-printer-forward@.service /etc/systemd/system/
# Edit virtual IP if needed
sudo sed -i 's/10.77.0.50/<PI_VIRTUAL_IP>/g' /etc/systemd/system/lanseal-printer-forward@.service
# 3. Install socat & enable
sudo apt install socat
sudo systemctl daemon-reload
sudo systemctl enable --now lanseal-printer-forward@9100
sudo systemctl enable --now lanseal-printer-forward@631
sudo systemctl enable --now lanseal-printer-forward@80
sudo systemctl enable --now lanseal-printer-forward@443
```

## Verification Checklist

```bash
# Gateway
ip xfrm policy | grep -E "10.77|10.24"
nft list chain inet lanseal_server forward | grep "meta ipsec exists"

# Linux Client
ip route get 10.24.10.50    # src 10.77.0.16 table 220
tcpdump -ni eth0 host 10.24.10.1  # Only ESP when UP
systemctl stop strongswan && ping -c 2 10.24.10.1  # FAILS

# Windows Client
Get-VpnConnectionRoute -ConnectionName LANSeal
# Tunnel UP: ping 10.24.10.1 works
# Tunnel DOWN: ping 10.24.10.1 FAILS

# Pi Connector
ss -ltnp | grep 10.77.0.50  # Bound to vIP only
```

## Design Guarantees

| Scenario | 10.24.10.x (Router/Printers) | 10.77.0.x (LANSeal) | Internet |
|----------|------------------------------|---------------------|----------|
| **Tunnel UP** | ✅ Encrypted via gateway | ✅ Encrypted direct | ✅ Direct (split) |
| **Tunnel DOWN** | 🚫 **BLOCKED** | 🚫 **BLOCKED** | ✅ Direct (split) |

**No plaintext fallback ever.**

## Certificate Requirements

| Component | Files Needed |
|-----------|--------------|
| Gateway | `gw.lanseal.home.arpa.pem`, `gw.lanseal.home.arpa-key.pem` |
| Linux Client | `kali.lanseal.home.arpa.pem`, `kali.lanseal.home.arpa-key.pem` |
| Windows Client | `client.p12` (PFX with cert+key), `ca.pem` |
| Pi Client | `pi.lanseal.home.arpa.pem`, `pi.lanseal.home.arpa-key.pem` |
| All | `lanseal-ca.pem` (CA cert) |

All certs must be issued by LANSeal CA with proper EKU/SAN.

## Rollback
Each component is independent — revert by restoring previous config files and reloading the service.
