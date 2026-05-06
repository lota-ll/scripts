# ============================================================
# VLT-DC-01 — Setup Script PART 1 of 2
# Run this FIRST, before any reboots
# After this script machine will reboot automatically
# Continue with Part 2 after reboot
# ============================================================
# Login as: rangeadmin
# Run as: Administrator
# ============================================================


# ============================================================
# STEP 1 — Static IP
# Confirm gateway IP in OPNsense -> Interfaces before running
# ============================================================

$i = (Get-NetAdapter -Physical | Select-Object -First 1).ifIndex

# Remove existing IP and routes if any
Remove-NetIPAddress -InterfaceIndex $i -Confirm:$false -ErrorAction SilentlyContinue
Remove-NetRoute -InterfaceIndex $i -Confirm:$false -ErrorAction SilentlyContinue

# Set static IP
New-NetIPAddress -InterfaceIndex $i -IPAddress 10.10.20.10 -PrefixLength 24 -DefaultGateway 10.10.20.1

# Point DNS to itself
Set-DnsClientServerAddress -InterfaceIndex $i -ServerAddresses 127.0.0.1

# Verification
Get-NetIPAddress -InterfaceIndex $i -AddressFamily IPv4 | Select-Object IPAddress, PrefixLength, PrefixOrigin


# ============================================================
# STEP 2 — Time sync
# ============================================================

Set-TimeZone -Id "UTC"

w32tm /config /manualpeerlist:"0.pool.ntp.org 1.pool.ntp.org" /syncfromflags:manual /reliable:YES /update
Restart-Service W32Time
w32tm /resync /force

# Verification
w32tm /query /status


# ============================================================
# STEP 3 — Install AD DS and DNS roles
# ============================================================

Install-WindowsFeature -Name AD-Domain-Services, DNS -IncludeManagementTools -IncludeAllSubFeature

# Verification
Get-WindowsFeature AD-Domain-Services, DNS | Select-Object Name, Installed


# ============================================================
# STEP 4 — Promote to new forest
# Machine will reboot automatically after this step
# After reboot login as VOLTANA\rangeadmin and run Part 2
# ============================================================

$dsrmPass = ConvertTo-SecureString "DSRM_P@ssword2026!" -AsPlainText -Force

Install-ADDSForest `
    -DomainName                    "voltana.local" `
    -DomainNetbiosName             "VOLTANA" `
    -ForestMode                    "WinThreshold" `
    -DomainMode                    "WinThreshold" `
    -InstallDns `
    -SafeModeAdministratorPassword $dsrmPass `
    -Force

# ============================================================
# Machine reboots automatically after promotion
# Continue with VLT-DC-01_Part2.ps1 after reboot
# Login as: VOLTANA\rangeadmin
# ============================================================
