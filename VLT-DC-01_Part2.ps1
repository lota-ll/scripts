# ============================================================
# VLT-DC-01 — Setup Script PART 2 of 2
# Run this AFTER reboot following forest promotion
# ============================================================
# Login as: VOLTANA\rangeadmin
# Run as: Administrator
# ============================================================


# ============================================================
# STEP 1 — Fix static IP with correct gateway
# ============================================================

$i = (Get-NetAdapter -Physical | Select-Object -First 1).ifIndex

Remove-NetIPAddress -InterfaceIndex $i -Confirm:$false -ErrorAction SilentlyContinue
Remove-NetRoute -InterfaceIndex $i -Confirm:$false -ErrorAction SilentlyContinue

New-NetIPAddress -InterfaceIndex $i -IPAddress 10.10.20.10 -PrefixLength 24 -DefaultGateway 10.10.20.254
Set-DnsClientServerAddress -InterfaceIndex $i -ServerAddresses 127.0.0.1

ping 8.8.8.8 -n 2


# ============================================================
# STEP 2 — Wait for AD services to start
# ============================================================

Write-Host "Waiting for AD services..." -ForegroundColor Yellow
Start-Sleep -Seconds 30

Start-Service adws, ntds, netlogon, dns -ErrorAction SilentlyContinue

Get-Service adws, ntds, netlogon, dns | Select-Object Name, Status


# ============================================================
# STEP 3 — Add rangeadmin to Domain Admins
# ============================================================

Add-ADGroupMember -Identity "Domain Admins" -Members "rangeadmin"

Get-ADGroupMember "Domain Admins" | Select-Object SamAccountName


# ============================================================
# STEP 4 — Verify AD and DNS
# ============================================================

Get-ADDomain | Select-Object DNSRoot, NetBIOSName, DomainMode

Write-Host "SYSVOL:" $(Test-Path "\\voltana.local\SYSVOL")
Write-Host "NETLOGON:" $(Test-Path "\\voltana.local\NETLOGON")


# ============================================================
# STEP 5 — DNS forwarder and reverse lookup zone
# ============================================================

Add-DnsServerForwarder -IPAddress 10.10.20.254

Add-DnsServerPrimaryZone -NetworkID "10.10.20.0/24" -ReplicationScope Domain

Add-DnsServerResourceRecordPtr `
    -ZoneName      "20.10.10.in-addr.arpa" `
    -Name          "10" `
    -PtrDomainName "VLT-DC-01.voltana.local"

Get-DnsServerForwarder


# ============================================================
# STEP 6 — OU structure (11 OUs)
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

Get-ADOrganizationalUnit -Filter * | Select-Object Name


# ============================================================
# STEP 7 — Security groups
# ============================================================

$base = "DC=voltana,DC=local"

New-ADGroup `
    -Name          "VOLTANA-OT-Jump-Users" `
    -GroupScope    Global `
    -GroupCategory Security `
    -Path          "OU=OT-Operations,$base" `
    -Description   "Authorized users of OT Jump Host"

New-ADGroup `
    -Name          "VOLTANA-Procurement-Staff" `
    -GroupScope    Global `
    -GroupCategory Security `
    -Path          "OU=Procurement,$base"

New-ADGroup `
    -Name          "VOLTANA-Engineering-Staff" `
    -GroupScope    Global `
    -GroupCategory Security `
    -Path          "OU=Engineering,$base"

Get-ADGroup -Filter { Name -like "VOLTANA-*" } | Select-Object Name


# ============================================================
# STEP 8 — Service accounts
# NOTE: svc-historia-voltana - NO SPN, TE team sets post-handoff
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
        -SamAccountName       $sa.Sam `
        -UserPrincipalName    "$($sa.Sam)@voltana.local" `
        -Name                 $sa.CN `
        -DisplayName          $sa.Sam `
        -Path                 $saPath `
        -AccountPassword      $pwd `
        -PasswordNeverExpires $true `
        -CannotChangePassword $true `
        -Enabled              $true `
        -Description          $sa.Desc
    Write-Host "Created: $($sa.Sam)"
}

Get-ADUser -Filter { SamAccountName -like "svc-*" } | Select-Object SamAccountName


# ============================================================
# STEP 9 — Embodied personas
# PER-VLT-001 dsilva - phish landing point on WS-01
# PER-VLT-002 achen  - OT pivot vehicle on WS-02
# ============================================================

$base = "DC=voltana,DC=local"
$pwd  = ConvertTo-SecureString "P@ssw0rd_2026!" -AsPlainText -Force

New-ADUser `
    -SamAccountName       "dsilva" `
    -GivenName            "Daniela" `
    -Surname              "Silva" `
    -UserPrincipalName    "dsilva@voltana.local" `
    -EmailAddress         "dsilva@voltana.example" `
    -Name                 "Daniela Silva" `
    -Path                 "OU=Procurement,$base" `
    -Title                "Procurement Officer" `
    -Department           "Procurement" `
    -AccountPassword      $pwd `
    -PasswordNeverExpires $true `
    -Enabled              $true

New-ADUser `
    -SamAccountName       "achen" `
    -GivenName            "Anders" `
    -Surname              "Chen" `
    -UserPrincipalName    "achen@voltana.local" `
    -EmailAddress         "achen@voltana.example" `
    -Name                 "Anders Chen" `
    -Path                 "OU=OT-Operations,$base" `
    -Title                "SCADA Engineer" `
    -Department           "OT-Operations" `
    -AccountPassword      $pwd `
    -PasswordNeverExpires $true `
    -Enabled              $true

Get-ADUser -Filter * | Where-Object { $_.SamAccountName -in "dsilva","achen" } | Select-Object SamAccountName, Enabled


# ============================================================
# STEP 10 — Remaining 30 non-interactive users
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
        -SamAccountName       $u.Sam `
        -GivenName            $u.First `
        -Surname              $u.Last `
        -UserPrincipalName    "$($u.Sam)@voltana.local" `
        -EmailAddress         "$($u.Sam)@voltana.example" `
        -Name                 "$($u.First) $($u.Last)" `
        -Path                 "OU=$($u.OU),$base" `
        -Title                $u.Title `
        -Department           $u.OU `
        -AccountPassword      $pwd `
        -PasswordNeverExpires $true `
        -Enabled              $true
    Write-Host "Created: $($u.Sam)"
}


# ============================================================
# STEP 11 — Add members to security groups
# ============================================================

Add-ADGroupMember -Identity "VOLTANA-OT-Jump-Users"     -Members "svc-historia-voltana","achen"
Add-ADGroupMember -Identity "VOLTANA-Procurement-Staff" -Members "dsilva","edemir"
Add-ADGroupMember -Identity "VOLTANA-Engineering-Staff" -Members "knovak"

Write-Host "--- VOLTANA-OT-Jump-Users ---"
Get-ADGroupMember "VOLTANA-OT-Jump-Users"     | Select-Object SamAccountName
Write-Host "--- VOLTANA-Procurement-Staff ---"
Get-ADGroupMember "VOLTANA-Procurement-Staff" | Select-Object SamAccountName
Write-Host "--- VOLTANA-Engineering-Staff ---"
Get-ADGroupMember "VOLTANA-Engineering-Staff" | Select-Object SamAccountName


# ============================================================
# STEP 12 — Final acceptance check
# ============================================================

Write-Host "=== VLT-DC-01 Acceptance Check ===" -ForegroundColor Cyan

$domain = Get-ADDomain
Write-Host "1.  Domain" $(if ($domain.DNSRoot -eq "voltana.local") {"OK"} else {"FAIL"})

$ouCount = (Get-ADOrganizationalUnit -Filter * | Where-Object { $_.Name -ne "Domain Controllers" }).Count
Write-Host "2.  OU count: $ouCount" $(if ($ouCount -eq 11) {"OK"} else {"FAIL: expected 11"})

$userCount = (Get-ADUser -Filter * | Where-Object {
    $_.SamAccountName -notmatch "^(Administrator|Guest|krbtgt)$" -and
    $_.SamAccountName -notlike "svc-*"
}).Count
Write-Host "3.  Interactive users: $userCount" $(if ($userCount -eq 32) {"OK"} else {"INFO: got $userCount of 32 (add remaining users)"})

$svcCount = (Get-ADUser -Filter { SamAccountName -like "svc-*" }).Count
Write-Host "4.  Service accounts: $svcCount" $(if ($svcCount -eq 5) {"OK"} else {"FAIL: expected 5"})

$grp = Get-ADGroup "VOLTANA-OT-Jump-Users" -ErrorAction SilentlyContinue
Write-Host "5.  VOLTANA-OT-Jump-Users group" $(if ($grp) {"OK"} else {"FAIL"})

$mem = Get-ADGroupMember "VOLTANA-OT-Jump-Users" | Where-Object { $_.SamAccountName -eq "svc-historia-voltana" }
Write-Host "6.  svc-historia-voltana in OT-Jump-Users" $(if ($mem) {"OK"} else {"FAIL"})

$spn = (Get-ADUser "svc-historia-voltana" -Properties ServicePrincipalNames).ServicePrincipalNames
Write-Host "7.  svc-historia-voltana SPN empty" $(if ($spn.Count -eq 0) {"OK"} else {"FAIL: SPN exists!"})

$ra = Get-ADGroupMember "Domain Admins" | Where-Object { $_.SamAccountName -eq "rangeadmin" }
Write-Host "8.  rangeadmin in Domain Admins" $(if ($ra) {"OK"} else {"FAIL"})

$dns = Resolve-DnsName "VLT-DC-01.voltana.local" -ErrorAction SilentlyContinue | Where-Object { $_.Type -eq "A" }
Write-Host "9.  DNS resolves to 10.10.20.10" $(if ($dns.IPAddress -eq "10.10.20.10") {"OK"} else {"FAIL: got $($dns.IPAddress)"})

Write-Host "10. SYSVOL accessible" $(if (Test-Path "\\voltana.local\SYSVOL") {"OK"} else {"FAIL"})
Write-Host "11. NETLOGON accessible" $(if (Test-Path "\\voltana.local\NETLOGON") {"OK"} else {"FAIL"})

$gw = (Get-NetRoute -AddressFamily IPv4 | Where-Object { $_.DestinationPrefix -eq "0.0.0.0/0" } | Select-Object -First 1).NextHop
Write-Host "12. Gateway" $(if ($gw -eq "10.10.20.254") {"OK: $gw"} else {"FAIL: got $gw"})

Write-Host "=== Check complete ===" -ForegroundColor Cyan
