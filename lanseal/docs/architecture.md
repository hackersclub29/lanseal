# Architecture and validation notes

## Planes
- **PKI control plane** — step-ca (root + intermediate; root key moved offline after init). Provisioners: `lanseal-admin`
  (JWK, operator), `lanseal-enroll` (JWK, one-time tokens, IPsec *client* template: EKU clientAuth), `lanseal-gateway`
  (JWK, *server* template: EKU serverAuth + IKE-intermediate 1.3.6.1.5.5.8.2.2). Devices generate their own key; the CA never sees it.
- **IPsec data plane** — strongSwan on the gateway (swanctl, IKEv2, certificate auth both ways, MOBIKE, PFS in every ESP proposal).
- **Application layer (optional, not part of the base)** — Caddy/mTLS for management APIs only; never a substitute for IPsec.

## Traffic model
Each device gets a static overlay address from `network.overlay_subnet` (chosen so it overlaps nothing the host actually has) and
a name `<device>.<domain>` served by dnsmasq on the gateway's overlay address. A client's child SA covers the whole overlay; the
gateway's child SA for each device uses `local_ts = overlay`, so A→B packets are decrypted from A's SA, forwarded, and
re-encrypted into B's SA (hairpin). No NAT is configured. The gateway forwards only overlay→overlay packets that arrived via IPsec
(`meta ipsec exists`), never LAN or internet traffic.

Peer identity is enforced twice: the certificate must chain to the CA **and** its SAN must match an enrolled device's
connection (`remote.id = <name>.<domain>`). Removing a device (`lanseal revoke`) takes effect immediately; CA-side revocation is passive.

Fail-closed (Linux client): nftables drops IP traffic to/from the protected LAN subnet except DHCP, IKE/ESP/CA to the gateway and DNS to the
router; overlay addresses without a tunnel hit an `unreachable` route (strongSwan's routes live in table 220 and win only while the tunnel is up).
Existing connections are *not* trusted: there is no `established` accept for LAN peers.

## What was verified from documentation (and what was not)
- step-ca: revocation is **passive** (blocks renewal; the cert stays valid until expiry). CRL generation exists in `ca.json` under `crl`
  but is documented as *experimental*; OCSP is not provided. → LANSeal does **not** claim enforced CRL checking. Gateway-side identity removal is the enforcement.
- `step ca token --not-after 30m` sets the *token* lifetime (Smallstep reference); used for `pki.enrollment_token_ttl`.
- Windows native IKEv2 requires explicit crypto settings and machine certificate placement. The current installer configures those settings and creates a locally generated client key/PFX enrollment flow; actual Windows 11 gateway interoperability and fail-closed behavior remain unverified.
- **Not verified here (needs a real host):** that step-ca accepts `unknownExtKeyUsage` in the template (the installer inspects the issued gateway cert and
  fails/warns), that `nft -c` accepts `meta ipsec exists` on your kernel/nftables version (installer dry-runs and refuses to apply otherwise),
  single-address pool ranges (`a-a`), strongSwan `swanctl` option spellings against your installed version (`swanctl --load-all` will reject errors),
  Android 15 `VpnManager`/`Ikev2VpnProfile` behaviour, and Windows 11 native IKEv2 interoperability and firewall behavior.
