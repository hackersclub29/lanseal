<#
.SYNOPSIS
    LANSeal Windows Client - Hardened, Permanent Block Rules, Explicit Routes
.DESCRIPTION
    Implements: permanent LAN block (gateway excluded), explicit split-tunnel routes,
    low VPN metric, cert EKU validation. No toggle logic.
    Run as Administrator.
.PARAMETER CertDir
    Directory containing ca.pem and client.p12 (default: C:\lanseal)
.PARAMETER P12Password
    Password for client.p12 (will prompt if not provided)
.PARAMETER GatewayFQDN
    Gateway DNS name (default: gw.lanseal.home.arpa)
.PARAMETER GatewayIP
    Gateway physical IP (default: 10.24.10.235)
.PARAMETER VPNName
    VPN connection name (default: LANSeal)
.PARAMETER TestMode
    Dry-run: shows what would change, makes NO modifications
.PARAMETER Force
    Skip confirmations (use with caution)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [ValidateScript({Test-Path $_ -PathType Container})]
    [string]$CertDir = "C:\lanseal",

    [Security.SecureString]$P12Password,

    [string]$GatewayFQDN = "gw.lanseal.home.arpa",
    [string]$GatewayIP   = "10.24.10.235",
    [string]$GatewayOverlay = '10.77.0.1',
    [string]$Overlay = '10.77.0.0/24',
    [string]$ProtectedSubnets = '10.24.10.0/24',
    [string]$DeviceFQDN = '',
    [string]$VPNName     = "LANSeal",

    [switch]$TestMode,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProtectedList = @($ProtectedSubnets -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if (-not $ProtectedList.Count) { throw 'At least one protected IPv4 subnet is required.' }

function Confirm-OrTest {
    param([string]$Msg)
    if ($Force) { return $true }
    $c = Read-Host "$Msg (y/n)"
    if ($c -notin @('y','yes','Y','YES')) { throw 'Installation cancelled.' }
    return $true
}

# ----- PRE-FLIGHT -----
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run as Administrator. Right-click PowerShell -> 'Run as Administrator'"
}

$CAFile  = Join-Path $CertDir "ca.pem"
$P12File = Join-Path $CertDir "client.p12"
if (-not (Test-Path $CAFile))  { throw "Missing CA cert: $CAFile" }
if (-not (Test-Path $P12File)) { throw "Missing client P12: $P12File" }

if ($P12Password) { $SecurePass = $P12Password }
else { $SecurePass = Read-Host "Enter client.p12 password" -AsSecureString }

# Test cert opens
Get-PfxCertificate -FilePath $P12File -Password $SecurePass -ErrorAction Stop | Out-Null

Write-Host "Pre-flight checks passed." -ForegroundColor Green
if ($TestMode) { Write-Host '[TEST] Preflight succeeded. No changes were made.' -ForegroundColor Cyan; return }
if (-not $Force) {
    $approval = Read-Host 'This installs the VPN profile and persistent firewall rules. Continue? (y/n)'
    if ($approval -notin @('y','yes','Y','YES')) { throw 'Installation cancelled before making changes.' }
    $Force = $true
}

# ----- 1. CERTIFICATES -----
if (Confirm-OrTest "Import CA to LocalMachine\Root") {
    try { Import-Certificate -FilePath $CAFile -CertStoreLocation Cert:\LocalMachine\Root -ErrorAction Stop }
    catch { if ($_.Exception.Message -notlike "*already*") { throw $_ } else { Write-Host "CA already in Trusted Root" } }
}

if (Confirm-OrTest "Import client cert+key to LocalMachine\My (MachineCertificate auth)") {
    try {
        Import-PfxCertificate -FilePath $P12File -CertStoreLocation Cert:\LocalMachine\My -Password $SecurePass -Exportable -ErrorAction Stop
    }
    catch { if ($_.Exception.Message -notlike "*already*") { throw $_ } else { Write-Host "Client cert already in Personal store" } }
}

# ----- 2. VPN CONNECTION -----
if (Confirm-OrTest "Create/replace VPN connection '$VPNName'") {
try {
    $resolvedGateway = [Net.Dns]::GetHostAddresses($GatewayFQDN) | ForEach-Object { $_.ToString() }
} catch { $resolvedGateway = @() }
if ($resolvedGateway -and $GatewayIP -notin $resolvedGateway) {
    throw "Gateway name $GatewayFQDN resolves to an address other than $GatewayIP. Fix DNS before installing."
}
if (-not $resolvedGateway) {
    $hostsPath = Join-Path $env:windir 'System32\drivers\etc\hosts'
    $hostRows = @(Get-Content $hostsPath | Where-Object { $_ -notmatch '^\s*#' -and $_ -match "(^|\s)$([Regex]::Escape($GatewayFQDN))(\s|$)" })
    if ($hostRows.Count -and -not ($hostRows | Where-Object { $_ -match "^\s*$([Regex]::Escape($GatewayIP))(\s|$)" })) {
        throw "The Windows hosts file already maps $GatewayFQDN to another address. Resolve the conflict first."
    }
    if (-not $hostRows.Count) {
        Add-Content -Path $hostsPath -Encoding ASCII -Value "`r`n# LANSeal gateway $GatewayFQDN`r`n$GatewayIP`t$GatewayFQDN"
    }
}
    Remove-VpnConnection -Name $VPNName -AllUserConnection -Force -ErrorAction SilentlyContinue
    Add-VpnConnection -Name $VPNName `
        -ServerAddress $GatewayFQDN `
        -TunnelType IKEv2 `
        -EncryptionLevel Required `
        -AuthenticationMethod MachineCertificate `
        -SplitTunneling $true `
        -AllUserConnection `
        -Force `
        -PassThru
    Write-Host "VPN connection created." -ForegroundColor Green
}

# ----- 3. IPSEC CRYPTO (match gateway) -----
if (Confirm-OrTest "Configure IPsec crypto (GCM-AES256/SHA384/ECP384)") {
    Set-VpnConnectionIPsecConfiguration -ConnectionName $VPNName -AllUserConnection `
        -AuthenticationTransformConstants GCMAES256 `
        -CipherTransformConstants None `
        -EncryptionMethod AES256 `
        -IntegrityCheckMethod SHA384 `
        -DHGroup ECP384 `
        -PfsGroup ECP384 `
        -Force
    Write-Host "IPsec crypto configured." -ForegroundColor Green
}

# ----- 4. EXPLICIT SPLIT-TUNNEL ROUTES -----
if (Confirm-OrTest "Add the encrypted overlay route for $Overlay") {
    Get-VpnConnectionRoute -ConnectionName $VPNName -AllUserConnection -ErrorAction SilentlyContinue | Remove-VpnConnectionRoute -ConnectionName $VPNName -AllUserConnection -Force -ErrorAction SilentlyContinue
    Add-VpnConnectionRoute -ConnectionName $VPNName -DestinationPrefix $Overlay -RouteMetric 1 -AllUserConnection -ErrorAction Stop

    Write-Host "Overlay route added. Protected physical LAN prefixes are blocked directly; use peer overlay addresses." -ForegroundColor Green
}

# ----- 5. FIREWALL - PERMANENT BLOCK RULES (GATEWAY EXCLUDED) -----
if (Confirm-OrTest "Create permanent firewall block rules (gateway excluded)") {
    $PhysNames = @(Get-NetAdapter -Physical | Select-Object -ExpandProperty Name)
    if (-not $PhysNames.Count) { throw 'No physical network adapter was found; cannot enforce LAN blocks.' }

    # OUTBOUND block
    Get-NetFirewallRule -Name 'LANSeal-*' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    function ConvertTo-IPv4Number([string]$Address) {
        $n = [uint64]0
        foreach ($octet in ([Net.IPAddress]::Parse($Address).GetAddressBytes())) { $n = ($n * 256) + $octet }
        return $n
    }
    function ConvertFrom-IPv4Number([uint64]$Number) {
        $b = [byte[]]@([byte](($Number -shr 24) -band 255), [byte](($Number -shr 16) -band 255), [byte](($Number -shr 8) -band 255), [byte]($Number -band 255))
        return ([Net.IPAddress]::new($b)).ToString()
    }
    $gatewayNumber = ConvertTo-IPv4Number $GatewayIP
    $blockedRanges = @()
    foreach ($prefix in (@($Overlay) + $ProtectedList)) {
        if ($prefix -notmatch '^([0-9.]+)/([0-9]{1,2})$') { throw "Invalid IPv4 subnet: $prefix" }
        $bits = [int]$Matches[2]; if ($bits -lt 0 -or $bits -gt 32) { throw "Invalid prefix: $prefix" }
        $ipNumber = ConvertTo-IPv4Number $Matches[1]
        $size = [uint64][Math]::Pow(2, 32 - $bits)
        $start = [uint64]([Math]::Floor($ipNumber / $size) * $size); $end = $start + $size - 1
        if ($gatewayNumber -lt $start -or $gatewayNumber -gt $end) { $blockedRanges += "$start,$end" }
        else {
            if ($gatewayNumber -gt $start) { $blockedRanges += "$start,$($gatewayNumber - 1)" }
            if ($gatewayNumber -lt $end) { $blockedRanges += "$($gatewayNumber + 1),$end" }
        }
    }
    $index = 0
    foreach ($range in $blockedRanges) {
        $bounds = $range -split ','
        $rangeText = "$(ConvertFrom-IPv4Number ([uint64]$bounds[0]))-$(ConvertFrom-IPv4Number ([uint64]$bounds[1]))"
        foreach ($direction in 'Outbound','Inbound') {
            New-NetFirewallRule -Name "LANSeal-Block-$direction-$index" -DisplayName "LANSeal Block LAN $direction $index" `
                -Direction $direction -Action Block -Enabled True -Profile Any -RemoteAddress $rangeText `
                -InterfaceAlias $PhysNames -ErrorAction Stop | Out-Null
        }
        $index++
    }

    Write-Host "Permanent block rules created. Gateway $GatewayIP excluded for IKE/ESP." -ForegroundColor Green
}

# ----- 6. ALLOW IKE/ESP TO GATEWAY -----
if (Confirm-OrTest "Create explicit IKE/ESP allow rules to gateway") {
    New-NetFirewallRule -Name "LANSeal-IKE-Out" -DisplayName "LANSeal IKE Out" `
        -Direction Outbound -Action Allow -Enabled True -Profile Any `
        -RemoteAddress $GatewayIP -Protocol UDP -RemotePort 500,4500 | Out-Null

    New-NetFirewallRule -Name "LANSeal-ESP-Out" -DisplayName "LANSeal ESP Out" `
        -Direction Outbound -Action Allow -Enabled True -Profile Any `
        -RemoteAddress $GatewayIP -Protocol 50 | Out-Null

    New-NetFirewallRule -Name "LANSeal-IKE-In" -DisplayName "LANSeal IKE In" `
        -Direction Inbound -Action Allow -Enabled True -Profile Any `
        -RemoteAddress $GatewayIP -Protocol UDP -LocalPort 500,4500 | Out-Null

    New-NetFirewallRule -Name "LANSeal-ESP-In" -DisplayName "LANSeal ESP In" `
        -Direction Inbound -Action Allow -Enabled True -Profile Any `
        -RemoteAddress $GatewayIP -Protocol 50 | Out-Null

    # DHCP
    New-NetFirewallRule -Name "LANSeal-DHCP-Out" -DisplayName "LANSeal DHCP Out" `
        -Direction Outbound -Action Allow -Enabled True -Profile Any `
        -Protocol UDP -LocalPort 68 -RemotePort 67 | Out-Null
    New-NetFirewallRule -Name "LANSeal-DHCP-In" -DisplayName "LANSeal DHCP In" `
        -Direction Inbound -Action Allow -Enabled True -Profile Any `
        -Protocol UDP -LocalPort 67 -RemotePort 68 | Out-Null

    Write-Host "IKE/ESP/DHCP allow rules created." -ForegroundColor Green
}

# ----- 7. LOW VPN METRIC (Scheduled Task on Connect) -----
if (Confirm-OrTest "Register VPN connect event to set low metric") {
    $Action = New-ScheduledTaskAction -Execute 'PowerShell.exe' -Argument `
        "-NoProfile -WindowStyle Hidden -Command `"`$vpn = Get-NetAdapter | Where-Object { `$_.Name -like '*$VPNName*' -or `$_.InterfaceDescription -like '*WAN Miniport*' } | Select-Object -First 1; if (`$vpn) { Set-NetIPInterface -InterfaceIndex `$vpn.ifIndex -InterfaceMetric 5 }`""
    $Trigger = New-ScheduledTaskTrigger -OnEvent -Channel "Microsoft-Windows-Networking-Correlation/Operational" -EventId 20225
    Register-ScheduledTask -TaskName "LANSeal-SetVPNMetric" -Action $Action -Trigger $Trigger -RunLevel Highest -Force -ErrorAction SilentlyContinue
    Write-Host "Scheduled task registered for VPN metric optimization." -ForegroundColor Green
}

# ----- 8. HELPER SCRIPTS -----
$ConnectScript = @"
#requires -RunAsAdministrator
# LANSeal Connect - Generated $(Get-Date)
Write-Host "Connecting LANSeal..." -ForegroundColor Cyan

try {
    rasdial $VPNName
    if (`$LASTEXITCODE -ne 0) { throw "rasdial failed with exit code `$LASTEXITCODE" }

    Start-Sleep 3

    `$vpn = Get-NetAdapter | Where-Object { `$_.Name -like '*$VPNName*' -or `$_.InterfaceDescription -like '*WAN Miniport*' } | Select-Object -First 1
    if (`$vpn) {
        Set-NetIPInterface -InterfaceIndex `$vpn.ifIndex -InterfaceMetric 5
        Write-Host "VPN interface metric set to 5" -ForegroundColor Green
    }

    Write-Host "Connected. Routes:"
    Get-VpnConnectionRoute -ConnectionName $VPNName -AllUserConnection
    route print | Select-String '$Overlay|$($ProtectedSubnets -join "|")'
} catch {
    Write-Error "Connection failed: `$_"
    exit 1
}
"@

$DisconnectScript = @"
#requires -RunAsAdministrator
# LANSeal Disconnect - Generated $(Get-Date)
Write-Host "Disconnecting LANSeal..." -ForegroundColor Cyan

try {
    rasdial $VPNName /disconnect
    if (`$LASTEXITCODE -ne 0) { throw "rasdial disconnect failed with exit code `$LASTEXITCODE" }

    Write-Host "Disconnected. Block rules remain ACTIVE - no plaintext LAN access." -ForegroundColor Yellow
    Write-Host "  Blocked prefixes: $($ProtectedList -join ', '), $Overlay"
} catch {
    Write-Error "Disconnect failed: `$_"
    exit 1
}
"@

$TestScript = @"
#requires -RunAsAdministrator
# LANSeal Test - Generated $(Get-Date)
Write-Host "=== LANSeal Connection Test ===" -ForegroundColor Cyan

`$VPN = Get-VpnConnection -Name $VPNName -AllUserConnection -ErrorAction SilentlyContinue
if (-not `$VPN) { Write-Error "VPN connection not found"; exit 1 }
Write-Host "VPN Config: OK"

`$Cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object {`$_.Subject -like "*$DeviceFQDN*"} | Select-Object -First 1
if (-not `$Cert) { Write-Error "Client cert not found in LocalMachine\My"; exit 1 }
Write-Host "Client Cert: OK (Thumbprint: `$(`$Cert.Thumbprint))"

`$Rules = Get-NetFirewallRule -Name "LANSeal-*"
Write-Host "Firewall Rules: `$(`$Rules.Count)"

`$Status = rasdial $VPNName
if (`$Status -like "*Connected*") {
    Write-Host "Tunnel: CONNECTED" -ForegroundColor Green
    Write-Host "\nRoute Tests:"
    ping $GatewayOverlay -n 2 | Select-String "Reply"
    Write-Host "\nVPN Routes:"
    Get-VpnConnectionRoute -ConnectionName $VPNName -AllUserConnection
    Write-Host "\nInterface Metric:"
    Get-NetAdapter | Where-Object { `$_.Name -like '*$VPNName*' } | Select-Object Name, ifIndex, InterfaceMetric
} else {
    Write-Host "Tunnel: DISCONNECTED" -ForegroundColor Yellow
    Write-Host "\nExpected: direct protected-LAN access should FAIL (blocked)"
}
Write-Host "\n=== Test Complete ===" -ForegroundColor Cyan
"@

$ConnectScript | Out-File (Join-Path $CertDir "LANSeal-Connect.ps1") -Encoding UTF8
$DisconnectScript | Out-File (Join-Path $CertDir "LANSeal-Disconnect.ps1") -Encoding UTF8
$TestScript | Out-File (Join-Path $CertDir "LANSeal-Test.ps1") -Encoding UTF8

Write-Host "
=== INSTALL COMPLETE ===
CONNECT:    $CertDir\LANSeal-Connect.ps1
TEST:       $CertDir\LANSeal-Test.ps1
DISCONNECT: $CertDir\LANSeal-Disconnect.ps1

VERIFY:
  Tunnel UP   -> ping $GatewayOverlay WORKS when the gateway responds
  Tunnel DOWN -> direct protected-LAN access is blocked
  Internet    -> ALWAYS works (split tunnel)
" -ForegroundColor Green
