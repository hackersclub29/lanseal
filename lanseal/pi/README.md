# LANSeal Pi Connector

## Purpose
Provides encrypted access to LAN-only devices (printers, IoT, routers) **without gateway configuration**.

The Pi acts as a LANSeal client on the same physical LAN as the target devices. It forwards specific ports over the encrypted tunnel.

```
[Windows/Linux Client] ──ESP (LANSeal)──▶ [Pi: 10.77.0.50] ──plain LAN──▶ [Printer: 10.24.10.50]
       🔒 encrypted                              🔓 local (trusted)
```

## Files
| File | Purpose |
|------|---------|
| `lanseal-printer-forward@.service` | systemd template for socat port forwarding |

## Prerequisites
- Raspberry Pi (or any Linux) on **same physical LAN** as printer (10.24.10.0/24)
- Pi enrolled as LANSeal client (gets virtual IP, e.g., `10.77.0.50`)
- Printer has **static IP** or DHCP reservation (e.g., `10.24.10.50`)
- `socat` installed: `sudo apt install socat`

## Setup

### 1. Enroll Pi as LANSeal Client
Use the same Linux client configs:
- `/etc/swanctl/conf.d/lanseal-client.conf` (with Pi's cert CN: `pi.lanseal.home.arpa`)
- Certs in `/etc/swanctl/x509/`, `/etc/swanctl/private/`, `/etc/swanctl/x509ca/`

### 2. Reserve Fixed Virtual IP (Gateway Side)
In gateway `swanctl.conf` pool or via identity:
```ini
pools {
    lanseal-pool {
        addrs = 10.77.0.10-10.77.0.200
        # Pi gets 10.77.0.50 via cert identity
    }
}
```

### 3. Install Forwarder Service
```bash
# Copy service file
sudo cp lanseal-printer-forward@.service /etc/systemd/system/

# Edit virtual IP if different from 10.77.0.50
sudo sed -i 's/10.77.0.50/<YOUR_PI_VIRTUAL_IP>/g' /etc/systemd/system/lanseal-printer-forward@.service

# Install socat
sudo apt install -y socat

# Enable ports
sudo systemctl daemon-reload
sudo systemctl enable --now lanseal-printer-forward@9100   # Raw printing (JetDirect)
sudo systemctl enable --now lanseal-printer-forward@631    # IPP
sudo systemctl enable --now lanseal-printer-forward@80     # Web UI HTTP
sudo systemctl enable --now lanseal-printer-forward@443    # Web UI HTTPS
sudo systemctl enable --now lanseal-printer-forward@161    # SNMP (optional)

# Verify
ss -ltnp | grep 10.77.0.50
# Should show LISTEN on 10.77.0.50:<ports> (NOT 0.0.0.0)
```

### 4. Client Printer Configuration

**Linux (CUPS):**
```bash
lpadmin -p "LANSeal-Printer" -v "socket://10.77.0.50:9100" -E
# Or IPP: ipp://10.77.0.50:631/ipp/print
```

**Windows (PowerShell Admin):**
```powershell
Add-PrinterPort -Name "LANSeal-Printer-Port" -PrinterHostAddress "10.77.0.50" -PortNumber 9100
Add-Printer -Name "LANSeal-Printer" -PortName "LANSeal-Printer-Port" -DriverName "Generic / Text Only"
```

## Ports Forwarded
| Port | Protocol | Service |
|------|----------|---------|
| 9100 | TCP | Raw printing (JetDirect) |
| 631 | TCP | IPP (Internet Printing Protocol) |
| 80 | TCP | Printer web UI (HTTP) |
| 443 | TCP | Printer web UI (HTTPS) |
| 161 | UDP | SNMP (monitoring/discovery) |

## Security Notes

### What This Protects
- Client ↔ Pi: **Fully encrypted** (LANSeal ESP)
- Pi ↔ Printer: **Plaintext on local LAN** (unavoidable unless printer speaks IPsec)
- No gateway config required
- Only specified ports exposed (not entire LAN)

### Limitations
- **Last-hop plaintext**: Pi → printer is unencrypted on local LAN
- **No mDNS/Bonjour**: Discovery protocols don't cross tunnel (configure by IP)
- **TCP + UDP only**: socat forwards both, but some printer features may need other protocols
- **Pi must stay on LAN**: If Pi moves, local printer access lost (tunnel still works)

### Hardening
- Service binds **only to virtual IP** (`bind=10.77.0.50`) — not `0.0.0.0`
- Runs as `nobody:nogroup` with minimal capabilities
- `systemd` sandboxing: `PrivateTmp`, `ProtectSystem`, `ProtectHome`

## Troubleshooting

### "Connection refused" from client
```bash
# On Pi: check service status
systemctl status lanseal-printer-forward@9100

# Check socat listening on vIP
ss -ltnp | grep 10.77.0.50

# Test locally on Pi
nc -vz 10.24.10.50 9100
```

### Printer not found via tunnel
- Verify Pi's virtual IP: `ip addr show | grep 10.77`
- Verify printer IP reachable from Pi: `ping 10.24.10.50`
- Check gateway allows hairpin: `10.77.0.0/24 ↔ 10.77.0.0/24` in forward chain

### Performance
- socat is single-threaded per connection; fine for printing
- For high-volume, consider `nginx` stream proxy or `haproxy`

## Alternative: Gateway NAT (If You Control Gateway)
If you **can** configure the gateway, use gateway NAT instead:
- Gateway `local_ts = 10.77.0.0/24, 10.24.10.0/24`
- Gateway NAT: `ip saddr 10.77.0.0/24 ip daddr 10.24.10.0/24 masquerade`
- All clients access printer directly via tunnel (no Pi needed)

**Pi connector is for when gateway is locked down (ISP router, no admin access).**