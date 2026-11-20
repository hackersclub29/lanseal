# LANSeal — transparent LAN encryption (IKEv2/IPsec hub-and-spoke, private PKI)

Encrypts protected internal IP traffic between Linux, Windows 11 and Android 15 devices on one LAN by sending it
through authenticated IKEv2/IPsec tunnels to an Ubuntu gateway that also runs the private CA (Smallstep step-ca).
Applications keep using plain HTTP/TCP/UDP/ICMP; external traffic keeps using the normal route (no default route is installed).

> **Not end-to-end.** The Ubuntu gateway decrypts and re-encrypts traffic between clients. LANSeal protects against
> passive and active observers on the LAN, not against the gateway itself. See `docs/architecture.md`.

## Implementation status (be honest about what exists)

| Phase | Scope | Status |
|---|---|---|
| 1 | Private CA (step-ca), templates, one-time-token enrollment, device registry, CLI | **Written, statically checked, NOT yet run on a real host** |
| 2 | strongSwan gateway (swanctl), overlay address, DNS, nftables, sysctl | **Written, statically checked, NOT yet run on a real host** |
| 3 | Kali/Debian/Ubuntu client: enroll, configure, connect | **Written, statically checked, NOT yet run on a real host** |
| 6 (Linux part) | Fail-closed client firewall (nftables + blackhole route) | **Written; behaviour must be proven with `tests/leak-tests/leak-test.sh`** |
| 4 | Windows 11 native IKEv2 client | Implemented; requires Windows 11 interoperability and fail-closed verification |
| 5 | Android 15 (strongSwan app profile) | Not started |
| 7 | Renewal (Linux client done), revocation CRL sync, backup/restore, monitoring | Partial: renewal timer + gateway-side revoke only |
| 8 | Interoperability + packet-capture report | Leak test written; no results exist yet |
| — | Go CLI (`cmd/`, `internal/`) | Not started; `server/bin/lanseal` is an interim Bash tool |

The only things executed so far (in a sandbox without root, strongSwan, step or nftables): config validation (including negative
tests), device registry, table rendering, PEM splitting, `bash -n` on every script. Nothing here has negotiated a real tunnel.

## Quick start (Ubuntu gateway, then Kali client)

```bash
# Gateway (Ubuntu). Requires step-cli and step-ca installed first (see Smallstep install docs).
sudo ./server/configure.sh        # discovers interface/subnet/gateway/DNS, asks you to confirm, validates
sudo ./server/install.sh          # CA + strongSwan + DNS + firewall (60 s auto-rollback unless you type 'keep')
sudo lanseal enroll kali linux    # prints the exact client command incl. one-time token + root fingerprint

# Client (Kali): run the printed command, e.g.
sudo ./clients/linux/install.sh --gateway ... --fingerprint ... --token ...
sudo ./tests/leak-tests/leak-test.sh --iface wlan0 --target <other device's overlay IP> --peer-lan-ip <its LAN IP>
```

Move the root CA key off the gateway (the installer moves it to `/root/lanseal-ROOT-KEY-move-offline` and tells you).
Rollback: `docs/rollback.md`.
