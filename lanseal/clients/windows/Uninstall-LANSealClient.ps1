[CmdletBinding()]
param(
    [string]$CertDir = 'C:\lanseal',
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9]([a-z0-9-]{0,28}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$')][string]$DeviceFQDN,
    [string]$GatewayFQDN = 'gw.lanseal.home.arpa',
    [string]$VPNName = 'LANSeal',
    [switch]$KeepEnrollmentFiles,
    [switch]$RemoveRootCertificate
)

$ErrorActionPreference = 'Stop'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run PowerShell as Administrator.'
}

# Disconnect before removing the profile and its fail-closed rules.
& rasdial $VPNName /disconnect *> $null
Remove-VpnConnection -Name $VPNName -AllUserConnection -Force -ErrorAction SilentlyContinue
Get-NetFirewallRule -Name 'LANSeal-*' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
Unregister-ScheduledTask -TaskName 'LANSeal-SetVPNMetric' -Confirm:$false -ErrorAction SilentlyContinue

# Remove only the exact device identity issued to this client and chained to this LANSeal root.
$caPath = Join-Path $CertDir 'ca.pem'
$caThumbprint = $null
if (Test-Path $caPath) {
    $ca = [Security.Cryptography.X509Certificates.X509Certificate2]::new($caPath)
    $caThumbprint = $ca.Thumbprint
    $ca.Dispose()
}
$subject = "CN=$DeviceFQDN"
$clientCerts = @(Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Subject -eq $subject })
foreach ($cert in $clientCerts) {
    $belongsToLANSeal = $false
    if ($caThumbprint) {
        $chain = [Security.Cryptography.X509Certificates.X509Chain]::new()
        try {
            if ($chain.Build($cert)) {
                $belongsToLANSeal = @($chain.ChainElements | Where-Object { $_.Certificate.Thumbprint -eq $caThumbprint }).Count -gt 0
            }
        } finally { $chain.Dispose() }
    }
    if ($belongsToLANSeal) {
        Remove-Item -LiteralPath "Cert:\LocalMachine\My\$($cert.Thumbprint)" -Force
        Write-Host "Removed device certificate $($cert.Thumbprint)."
    }
}
if ($caThumbprint -and $RemoveRootCertificate) {
    Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Thumbprint -eq $caThumbprint } |
        Remove-Item -Force
    Write-Host 'Removed the LANSeal root certificate, if it was installed.'
} elseif ($caThumbprint) {
    Write-Host 'Kept the LANSeal root certificate in the machine trust store. Use -RemoveRootCertificate only if no other devices rely on this CA.'
}

# The installer adds this marked hosts entry only when the gateway name does not resolve in DNS.
$hostsPath = Join-Path $env:windir 'System32\drivers\etc\hosts'
if (Test-Path $hostsPath) {
    $lines = @(Get-Content -LiteralPath $hostsPath)
    $kept = [Collections.Generic.List[string]]::new()
    $skipGatewayMapping = $false
    foreach ($line in $lines) {
        if ($line -eq "# LANSeal gateway $GatewayFQDN") {
            $skipGatewayMapping = $true
            continue
        }
        if ($skipGatewayMapping) {
            $skipGatewayMapping = $false
            if ($line -match "^\s*\d{1,3}(?:\.\d{1,3}){3}\s+$([Regex]::Escape($GatewayFQDN))(?:\s|$)") { continue }
        }
        $kept.Add($line)
    }
    if ($kept.Count -ne $lines.Count) {
        [IO.File]::WriteAllLines($hostsPath, $kept.ToArray(), [Text.Encoding]::ASCII)
        Write-Host "Removed the managed hosts entry for $GatewayFQDN."
    }
}

if (-not $KeepEnrollmentFiles) {
    foreach ($file in 'client.p12', 'client.crt', 'client.key', 'ca.pem') {
        $path = Join-Path $CertDir $file
        if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
    }
    $stepDir = Join-Path $CertDir 'step'
    if (Test-Path -LiteralPath $stepDir -PathType Container) { Remove-Item -LiteralPath $stepDir -Recurse -Force }
    Write-Host 'Removed LANSeal enrollment files.'
} else {
    Write-Host "Kept enrollment files in $CertDir as requested."
}

foreach ($helper in 'LANSeal-Connect.ps1', 'LANSeal-Disconnect.ps1', 'LANSeal-Test.ps1') {
    $path = Join-Path $CertDir $helper
    if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
}
Write-Host "LANSeal Windows client '$VPNName' has been uninstalled."
