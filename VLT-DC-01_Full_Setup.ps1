# ============================================================
# VLT-DC-01 — Full Setup Script
# Scenario: EX-2026-04-IS01 · OPERATION IRON STORM
# Role: AD DS root DC for voltana.local
# ============================================================
# IMPORTANT: Run everything in PowerShell as Administrator
# IMPORTANT: Do NOT read 03_Assessment_and_TE_Handoff.md
# ============================================================


# ============================================================
# STEP 1 — Rename computer
# ============================================================

Rename-Computer -NewName "VLT-DC-01" -Force
Restart-Computer

# --- After reboot, open PowerShell as Administrator and continue ---


# ============================================================
# STEP 2 — Static IP
# Confirm gateway IP in OPNsense → Interfaces before running
# ============================================================

$i = (Get-NetAdapter -Physical | Select-Object -First 1).ifIndex

# Remove existing IP and routes if any
Remove-NetIPAddress -InterfaceIndex $i -Confirm:$false -ErrorAction SilentlyContinue
Remove-NetRoute -InterfaceIndex $i -Confirm:$false -ErrorAction SilentlyContinue

# Set static IP
New-NetIPAddress -InterfaceIndex $i -IPAddress 10.10.20.10 -PrefixLength 24 -DefaultGateway 10.10.20.1

# Point DNS to itself (after AD DS promotion)
Set-DnsClientServerAddress -InterfaceIndex $i -ServerAddresses 127.0.0.1

# Verification
Get-NetIPAddress -InterfaceIndex $i -AddressFamily IPv4 | Select-Object IPAddress, PrefixLength


# ============================================================
# STEP 3 — Time sync
# ============================================================

Set-TimeZone -Id "UTC"

w32tm /config /manualpeerlist:"0.pool.ntp.org 1.pool.ntp.org" /syncfromflags:manual /reliable:YES /update
Restart-Service W32Time
w32tm /resync /force

# Verification — Stratum should not be 0
w32tm /query /status


# ============================================================
# STEP 4 — Install AD DS and DNS roles
# ============================================================

Install-WindowsFeature -Name AD-Domain-Services, DNS -IncludeManagementTools -IncludeAllSubFeature

# Verification
Get-WindowsFeature AD-Domain-Services, DNS | Select-Object Name, Installed


# ============================================================
# STEP 5 — Promote to new forest
# ============================================================

$dsrmPass = ConvertTo-SecureString "DSRM_P@ssword2026!" -AsPlainText -Force

Install-ADDSForest -DomainName "voltana.local" -DomainNetbiosName "VOLTANA" -ForestMode "WinThreshold" -DomainMode "WinThreshold" -InstallDns -SafeModeAdministratorPassword $dsrmPass -Force

# Machine will reboot automatically
# After reboot login as VOLTANA\Administrator and continue


# ============================================================
# STEP 6 — Verify AD and DNS after reboot
# ============================================================

# Verify domain
Get-ADDomain | Select-Object DNSRoot, NetBIOSName, DomainMode

# Verify DNS
Resolve-DnsName voltana.local

# Verify SYSVOL and NETLOGON
Test-Path "\\voltana.local\SYSVOL"
Test-Path "\\voltana.local\NETLOGON"

# Verify DC resolves to correct IP
Resolve-DnsName "VLT-DC-01.voltana.local"


# ============================================================
# STEP 7 — DNS forwarder and reverse lookup zone
# ============================================================

# Forwarder to OPNsense Server LAN interface
Add-DnsServerForwarder -IPAddress 10.10.20.1

# Reverse lookup zone for Server LAN
Add-DnsServerPrimaryZone -NetworkID "10.10.20.0/24" -ReplicationScope Domain

# PTR record for DC-01
Add-DnsServerResourceRecordPtr -ZoneName "20.10.10.in-addr.arpa" -Name "10" -PtrDomainName "VLT-DC-01.voltana.local"

# Verification
Get-DnsServerForwarder


# ============================================================
# STEP 8 — OU structure (11 OUs)
# ============================================================

$base = "DC=voltana,DC=local"

$ous = @(
    "Executive",
    "Operations",
    "Engineering",
    "OT-Operations",
    "Procurement",
    "IT",
    "HR",
    "Finance",
    "Legal",
    "Reception",
    "ServiceAccounts"
)

foreach ($ou in $ous) {
    New-ADOrganizationalUnit -Name $ou -Path $base -ProtectedFromAccidentalDeletion $true
    Write-Host "Created: OU=$ou"
}

# Verification — expect 11 OUs (Domain Controllers is system, not counted)
Get-ADOrganizationalUnit -Filter * | Select-Object Name


# ============================================================
# STEP 9 — Security groups
# ============================================================

$base = "DC=voltana,DC=local"

New-ADGroup -Name "VOLTANA-OT-Jump-Users" -GroupScope Global -GroupCategory Security -Path "OU=OT-Operations,$base" -Description "Authorized users of OT Jump Host"
New-ADGroup -Name "VOLTANA-Procurement-Staff" -GroupScope Global -GroupCategory Security -Path "OU=Procurement,$base"
New-ADGroup -Name "VOLTANA-Engineering-Staff" -GroupScope Global -GroupCategory Security -Path "OU=Engineering,$base"

# Verification
Get-ADGroup -Filter { Name -like "VOLTANA-*" } | Select-Object Name


# ============================================================
# STEP 10 — Service accounts (5 accounts)
# NOTE: svc-historia-voltana — NO SPN, TE team sets it after handoff
# NOTE: Password can be changed later via Set-ADAccountPassword
# ============================================================

$base   = "DC=voltana,DC=local"
$saPath = "OU=ServiceAccounts,$base"
$pwd    = ConvertTo-SecureString "Svc_V0ltana_2026!#Bld" -AsPlainText -Force

$serviceAccounts = @(
    @{ Sam="svc-historia-voltana"; CN="SvcHistoriaVoltana"; Desc="Historian service on HIST-01. NO SPN - TE sets post-handoff." },
    @{ Sam="svc-backup-voltana";   CN="SvcBackupVoltana";   Desc="Veeam service on BKP-01." },
    @{ Sam="svc-wsus-voltana";     CN="SvcWsusVoltana";     Desc="WSUS service." },
    @{ Sam="svc-sccm-voltana";     CN="SvcSccmVoltana";     Desc="SCCM inventory." },
    @{ Sam="svc-ad-sync";          CN="SvcAdSync";           Desc="AD to Postfix/Roundcube sync." }
)

foreach ($sa in $serviceAccounts) {
    New-ADUser `
        -SamAccountName    $sa.Sam `
        -UserPrincipalName "$($sa.Sam)@voltana.local" `
        -Name              $sa.CN `
        -DisplayName       $sa.Sam `
        -Path              $saPath `
        -AccountPassword   $pwd `
        -PasswordNeverExpires $true `
        -CannotChangePassword $true `
        -Enabled           $true `
        -Description       $sa.Desc
    Write-Host "Created: $($sa.Sam)"
}

# Verification — expect 5 accounts
Get-ADUser -Filter { SamAccountName -like "svc-*" } | Select-Object SamAccountName


# ============================================================
# STEP 11 — Embodied personas (critical for scenario)
# PER-VLT-001 dsilva — phish landing point on WS-01
# PER-VLT-002 achen  — OT pivot vehicle on WS-02
# ============================================================

$base = "DC=voltana,DC=local"
$pwd  = ConvertTo-SecureString "P@ssw0rd_2026!" -AsPlainText -Force

# PER-VLT-001 — Daniela Silva — Procurement Officer — WS-01
New-ADUser `
    -SamAccountName    "dsilva" `
    -GivenName         "Daniela" `
    -Surname           "Silva" `
    -UserPrincipalName "dsilva@voltana.local" `
    -EmailAddress      "dsilva@voltana.example" `
    -Name              "Daniela Silva" `
    -Path              "OU=Procurement,$base" `
    -Title             "Procurement Officer" `
    -Department        "Procurement" `
    -AccountPassword   $pwd `
    -PasswordNeverExpires $true `
    -Enabled           $true

# PER-VLT-002 — Anders Chen — SCADA Engineer — WS-02
New-ADUser `
    -SamAccountName    "achen" `
    -GivenName         "Anders" `
    -Surname           "Chen" `
    -UserPrincipalName "achen@voltana.local" `
    -EmailAddress      "achen@voltana.example" `
    -Name              "Anders Chen" `
    -Path              "OU=OT-Operations,$base" `
    -Title             "SCADA Engineer" `
    -Department        "OT-Operations" `
    -AccountPassword   $pwd `
    -PasswordNeverExpires $true `
    -Enabled           $true

# Verification
Get-ADUser -Filter * | Where-Object { $_.SamAccountName -in "dsilva","achen" } | Select-Object SamAccountName, Enabled


# ============================================================
# STEP 12 — Remaining 30 non-interactive users
# Full table from 02_Personas_and_Identity.md
# Use international_mixed_v1 name pool for remaining 24
# ============================================================

$base = "DC=voltana,DC=local"
$pwd  = ConvertTo-SecureString "P@ssw0rd_2026!" -AsPlainText -Force

$users = @(
    @{ Sam="edemir";    First="Elif";     Last="Demir";    OU="Procurement";   Title="Procurement Specialist" },
    @{ Sam="rkowalski"; First="Rohan";    Last="Kowalski"; OU="OT-Operations"; Title="OT Operations Lead" },
    @{ Sam="aokafor";   First="Aisha";    Last="Okafor";   OU="IT";            Title="IT Administrator" },
    @{ Sam="jmueller";  First="Jonas";    Last="Mueller";  OU="Executive";     Title="CISO" },
    @{ Sam="knovak";    First="Katarina"; Last="Novak";    OU="Engineering";   Title="Engineering Lead" },
    @{ Sam="trivera";   First="Tomas";    Last="Rivera";   OU="Operations";    Title="Operations Manager" }
    # Add remaining 24 users from international_mixed_v1 name pool here
)

foreach ($u in $users) {
    New-ADUser `
        -SamAccountName    $u.Sam `
        -GivenName         $u.First `
        -Surname           $u.Last `
        -UserPrincipalName "$($u.Sam)@voltana.local" `
        -EmailAddress      "$($u.Sam)@voltana.example" `
        -Name              "$($u.First) $($u.Last)" `
        -Path              "OU=$($u.OU),$base" `
        -Title             $u.Title `
        -Department        $u.OU `
        -AccountPassword   $pwd `
        -PasswordNeverExpires $true `
        -Enabled           $true
    Write-Host "Created: $($u.Sam)"
}

# Verification — expect 32 interactive users total
(Get-ADUser -Filter * | Where-Object {
    $_.SamAccountName -notmatch "^(Administrator|Guest|krbtgt)$" -and
    $_.SamAccountName -notlike "svc-*"
}).Count


# ============================================================
# STEP 13 — Add members to security groups
# ============================================================

# VOLTANA-OT-Jump-Users
Add-ADGroupMember -Identity "VOLTANA-OT-Jump-Users" -Members "svc-historia-voltana", "achen"

# VOLTANA-Procurement-Staff
Add-ADGroupMember -Identity "VOLTANA-Procurement-Staff" -Members "dsilva", "edemir"

# VOLTANA-Engineering-Staff
Add-ADGroupMember -Identity "VOLTANA-Engineering-Staff" -Members "knovak"

# Verification
Get-ADGroupMember "VOLTANA-OT-Jump-Users"      | Select-Object SamAccountName
Get-ADGroupMember "VOLTANA-Procurement-Staff"  | Select-Object SamAccountName
Get-ADGroupMember "VOLTANA-Engineering-Staff"  | Select-Object SamAccountName


# ============================================================
# STEP 14 — Final acceptance check
# ============================================================

Write-Host "=== VLT-DC-01 Acceptance Check ===" -ForegroundColor Cyan

# 1. Domain
$domain = Get-ADDomain
Write-Host "1. Domain: $($domain.DNSRoot)" $(if ($domain.DNSRoot -eq "voltana.local") {"OK"} else {"FAIL"})

# 2. OU count (expect 11)
$ouCount = (Get-ADOrganizationalUnit -Filter * | Where-Object { $_.Name -ne "Domain Controllers" }).Count
Write-Host "2. OU count: $ouCount" $(if ($ouCount -eq 11) {"OK"} else {"FAIL — expected 11"})

# 3. Interactive users (expect 32)
$userCount = (Get-ADUser -Filter * | Where-Object {
    $_.SamAccountName -notmatch "^(Administrator|Guest|krbtgt)$" -and
    $_.SamAccountName -notlike "svc-*"
}).Count
Write-Host "3. Interactive users: $userCount" $(if ($userCount -eq 32) {"OK"} else {"FAIL — expected 32, got $userCount"})

# 4. Service accounts (expect 5)
$svcCount = (Get-ADUser -Filter { SamAccountName -like "svc-*" }).Count
Write-Host "4. Service accounts: $svcCount" $(if ($svcCount -eq 5) {"OK"} else {"FAIL — expected 5"})

# 5. VOLTANA-OT-Jump-Users exists
$grp = Get-ADGroup "VOLTANA-OT-Jump-Users" -ErrorAction SilentlyContinue
Write-Host "5. VOLTANA-OT-Jump-Users group" $(if ($grp) {"OK"} else {"FAIL"})

# 6. svc-historia-voltana in OT-Jump-Users
$mem = Get-ADGroupMember "VOLTANA-OT-Jump-Users" | Where-Object { $_.SamAccountName -eq "svc-historia-voltana" }
Write-Host "6. svc-historia-voltana in OT-Jump-Users" $(if ($mem) {"OK"} else {"FAIL"})

# 7. svc-historia-voltana has NO SPN
$spn = (Get-ADUser "svc-historia-voltana" -Properties ServicePrincipalNames).ServicePrincipalNames
Write-Host "7. svc-historia-voltana SPN empty" $(if ($spn.Count -eq 0) {"OK"} else {"FAIL — SPN exists, remove it!"})

# 8. DNS resolves correctly
$dns = Resolve-DnsName "VLT-DC-01.voltana.local" -ErrorAction SilentlyContinue | Where-Object { $_.Type -eq "A" }
Write-Host "8. DNS VLT-DC-01.voltana.local" $(if ($dns.IPAddress -eq "10.10.20.10") {"OK"} else {"FAIL — got $($dns.IPAddress)"})

# 9. SYSVOL and NETLOGON accessible
Write-Host "9. SYSVOL accessible" $(if (Test-Path "\\voltana.local\SYSVOL") {"OK"} else {"FAIL"})
Write-Host "10. NETLOGON accessible" $(if (Test-Path "\\voltana.local\NETLOGON") {"OK"} else {"FAIL"})

Write-Host "=== Check complete ===" -ForegroundColor Cyan
