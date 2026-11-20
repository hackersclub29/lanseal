# LANSeal Windows client

The Windows client uses the built-in IKEv2 VPN service, a LANSeal device certificate, an explicit overlay route, and Windows Defender Firewall blocks on physical adapters. Protected physical LAN prefixes are blocked directly; peer devices are reached through their overlay addresses. It targets Windows 11 with PowerShell 5.1+ and requires Administrator rights. Install `step.exe` (Smallstep CLI) and `openssl.exe` and make both available on `PATH` before enrollment.

## Enroll and install

On the gateway, run:

```bash
sudo lanseal enroll <device-name> windows
```

On the Windows device, clone/copy this repository, open an elevated PowerShell prompt in its root, and run the printed command. The enrollment script bootstraps CA trust using the displayed SHA-256 root fingerprint, requests the device certificate using the one-time token, creates a password-protected `client.p12`, and invokes the installer. Keep `C:\lanseal\client.p12` private; it contains the device key.

To install previously prepared files, place `ca.pem` (root certificate) and `client.p12` (client certificate and private key) in a directory, then run:

```powershell
.\clients\windows\Install-LANSealClient-Hardened.ps1 -CertDir C:\lanseal -GatewayFQDN gw.lanseal.home.arpa -GatewayIP 192.0.2.10 -GatewayOverlay 10.77.0.1 -Overlay 10.77.0.0/24 -ProtectedSubnets 192.0.2.0/24
```

Use the actual values from the gateway configuration. The installer imports the CA into `LocalMachine\Root`, the client certificate into `LocalMachine\My`, adds the all-user IKEv2 VPN and routes, and installs firewall rules. The gateway address is excluded from the physical-interface block ranges so IKE, ESP, and CA enrollment traffic can reach it. Existing LANSeal firewall rules are replaced on rerun.

The generated helpers are `C:\lanseal\LANSeal-Connect.ps1`, `LANSeal-Disconnect.ps1`, and `LANSeal-Test.ps1`. The firewall rules remain active when the tunnel disconnects. Internet traffic remains split tunneled. When the installer cannot resolve the gateway name, it adds a marked entry to the Windows hosts file; remove the `# LANSeal gateway <name>` line and its address mapping during uninstall.

## Remove

Run the repository uninstaller from an elevated PowerShell prompt. It removes the VPN profile, `LANSeal-*` firewall rules, metric task, the exact device certificate chained to the LANSeal root, managed gateway hosts entry, and local enrollment/helper files. It keeps the root CA in the machine trust store by default; pass `-RemoveRootCertificate` only if no other devices rely on that CA:

```powershell
.\clients\windows\Uninstall-LANSealClient.ps1 -DeviceFQDN win11.lanseal.home.arpa -GatewayFQDN gw.lanseal.home.arpa
```

Use `-KeepEnrollmentFiles` to preserve the PFX and CA bootstrap files. The device FQDN must match the name used during enrollment.

For manual cleanup:

```powershell
Remove-VpnConnection -Name LANSeal -AllUserConnection -Force
Get-NetFirewallRule -Name 'LANSeal-*' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
Unregister-ScheduledTask -TaskName 'LANSeal-SetVPNMetric' -Confirm:$false -ErrorAction SilentlyContinue
```

Remove only the LANSeal certificates from the machine certificate stores after verifying their thumbprints. Do not remove other CA or device certificates.

## Status

The installer is implemented but has not yet been validated against a real Windows 11 host and gateway. Windows certificate auto-renewal is not implemented; the default client certificate expires after 30 days, so plan a renewal flow before relying on this for ongoing use. Verify IKE negotiation, routes while connected, and blocked direct LAN access after disconnect before relying on it.
