[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^\d{1,3}(\.\d{1,3}){3}$')][string]$GatewayIP,
    [Parameter(Mandatory)][string]$GatewayName,
    [Parameter(Mandatory)][string]$GatewayOverlay,
    [ValidateRange(1,65535)][int]$CaPort = 9000,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{64}$')][string]$Fingerprint,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9]([a-z0-9-]{0,28}[a-z0-9])?$')][string]$Name,
    [Parameter(Mandatory)][string]$Token,
    [Parameter(Mandatory)][string]$Overlay,
    [Parameter(Mandatory)][string]$Protected,
    [string]$CertDir = 'C:\lanseal'
)

$ErrorActionPreference = 'Stop'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run PowerShell as Administrator.'
}
foreach ($tool in 'step', 'openssl') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "$tool.exe must be installed and available on PATH." }
}
$fqdn = "$Name.$($GatewayName.Substring($GatewayName.IndexOf('.') + 1))"
if ($GatewayName -notmatch '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$') { throw 'GatewayName must be a DNS FQDN.' }
New-Item -ItemType Directory -Path $CertDir -Force | Out-Null
$env:STEPPATH = Join-Path $CertDir 'step'
$caUrl = "https://$GatewayIP`:$CaPort"
$root = Join-Path $env:STEPPATH 'certs\root_ca.crt'
$crt = Join-Path $CertDir 'client.crt'
$key = Join-Path $CertDir 'client.key'
$p12 = Join-Path $CertDir 'client.p12'

if (-not (Test-Path $root)) {
    & step ca bootstrap --ca-url $caUrl --fingerprint $Fingerprint --force
    if ($LASTEXITCODE) { throw 'CA bootstrap failed. Check gateway reachability and fingerprint.' }
}
$actualFingerprint = (& step certificate fingerprint $root).Trim().ToLowerInvariant()
if ($LASTEXITCODE -or $actualFingerprint -ne $Fingerprint.ToLowerInvariant()) {
    throw 'The installed LANSeal root fingerprint does not match the gateway-provided fingerprint.'
}
Copy-Item $root (Join-Path $CertDir 'ca.pem') -Force
& step ca certificate $fqdn $crt $key --token $Token --kty RSA --size 3072 --force
if ($LASTEXITCODE) { throw 'Certificate enrollment failed.' }
$serialLine = (& openssl x509 -in $crt -serial -noout)
if ($LASTEXITCODE) { throw 'Could not read the issued certificate serial.' }
$serial = ($serialLine -replace '^serial=', '').Replace(':', '').ToLowerInvariant()
$p12Password = Read-Host 'Choose a password to protect client.p12' -AsSecureString
$p12Plain = [Net.NetworkCredential]::new('', $p12Password).Password
try {
    $env:LANSEAL_P12_PASSWORD = $p12Plain
    & openssl pkcs12 -export -inkey $key -in $crt -certfile $root -out $p12 -passout env:LANSEAL_P12_PASSWORD
    if ($LASTEXITCODE) { throw 'PFX export failed.' }
} finally { Remove-Item Env:\LANSEAL_P12_PASSWORD -ErrorAction SilentlyContinue; $p12Plain = $null }
Remove-Item $key -Force
$installer = Join-Path $PSScriptRoot 'Install-LANSealClient-Hardened.ps1'
& $installer -CertDir $CertDir -P12Password $p12Password -GatewayFQDN $GatewayName -GatewayIP $GatewayIP -GatewayOverlay $GatewayOverlay -Overlay $Overlay -ProtectedSubnets $Protected -DeviceFQDN $fqdn
if ($LASTEXITCODE) { throw 'Windows client configuration failed. Certificates remain in CertDir for retry.' }
Write-Host "Enrollment complete for $fqdn. Certificate private key was removed after PFX creation; keep client.p12 protected."
Write-Host "On the gateway, record the serial for revocation: sudo lanseal set-serial $Name $serial"
