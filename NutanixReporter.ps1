$ErrorActionPreference = "Stop"

# =========================
# Load .env
# =========================

$envFile = Join-Path $PSScriptRoot ".env"

if (-not (Test-Path $envFile)) {
    Write-Error ".env file not found at $envFile"
    exit 1
}

Get-Content $envFile | ForEach-Object {

    if ($_ -and ($_ -notmatch '^#')) {

        $parts = $_ -split '=', 2

        if ($parts.Count -eq 2) {

            $key = $parts[0].Trim()
            $value = $parts[1].Trim()

            Set-Item -Path "Env:$key" -Value $value
        }
    }
}

$server   = $env:NUTANIX_SERVER
$user     = $env:NUTANIX_USER
$password = $env:NUTANIX_PASSWORD

Write-Host "Server: $server"
Write-Host "User: $user"

if (-not $server -or -not $user -or -not $password) {
    Write-Error "Missing NUTANIX_SERVER, NUTANIX_USER, or NUTANIX_PASSWORD"
    exit 1
}

# =========================
# TLS 1.2
# =========================

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# =========================
# Ignore self-signed certs (guarded)
# =========================

if (-not ("TrustAllCertsPolicy" -as [type])) {

    Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;

public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(
        ServicePoint srvPoint,
        X509Certificate certificate,
        WebRequest request,
        int certificateProblem) {
        return true;
    }
}
"@

}

[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy

# =========================
# Basic Auth header
# =========================

$pair = "${user}:${password}"
$bytes = [System.Text.Encoding]::ASCII.GetBytes($pair)
$base64 = [Convert]::ToBase64String($bytes)

$headers = @{
    Authorization = "Basic $base64"
    Accept        = "application/json"
}

Write-Host ""
Write-Host "Auth header ready"

# =========================
# Get hosts (for hostname mapping)
# =========================

$hostsResp = Invoke-RestMethod `
    -Method GET `
    -Uri "https://${server}:9440/PrismGateway/services/rest/v2.0/hosts/" `
    -Headers $headers

$hostMap = @{}

foreach ($h in $hostsResp.entities) {
    $hostMap[$h.uuid] = $h.name
}

Write-Host "Hosts collected: $($hostMap.Count)"

# =========================
# Get VMs from v2.0 (clean disk/nic structure)
# =========================

$vmsV2 = Invoke-RestMethod `
    -Method GET `
    -Uri "https://${server}:9440/PrismGateway/services/rest/v2.0/vms/?include_vm_disk_config=true&include_vm_nic_config=true" `
    -Headers $headers

Write-Host "VMs found (v2): $($vmsV2.entities.Count)"

# =========================
# Get VMs from v1 (has stats)
# =========================

$vmsV1 = Invoke-RestMethod `
    -Method GET `
    -Uri "https://${server}:9440/PrismGateway/services/rest/v1/vms/" `
    -Headers $headers

Write-Host "VMs found (v1): $($vmsV1.entities.Count)"

# Build uuid -> v1 entity map for fast lookup
$v1Map = @{}

foreach ($v1 in $vmsV1.entities) {
    $v1Map[$v1.uuid] = $v1
}

# =========================
# Build result by merging v2 + v1 stats
# =========================

$result = @()

foreach ($vm in $vmsV2.entities) {

    Write-Host "Collecting VM: $($vm.name)"

    $vmUuid = $vm.uuid
    $hostUuid = $vm.host_uuid
    $hostName = if ($hostUuid -and $hostMap.ContainsKey($hostUuid)) { $hostMap[$hostUuid] } else { "" }

    # =========================
    # Get stats from v1 entity
    # =========================

    $cpuPct = 0
    $memPct = 0

    if ($v1Map.ContainsKey($vmUuid)) {

        $v1vm = $v1Map[$vmUuid]
        $stats = $v1vm.stats

        if ($stats) {

            $cpuRaw = $stats."hypervisor_cpu_usage_ppm"
            $memRaw = $stats."hypervisor_memory_usage_ppm"

            if ($cpuRaw -and [int64]$cpuRaw -ge 0) {
                $cpuPct = [math]::Round(([int64]$cpuRaw / 10000), 2)
            }
            if ($memRaw -and [int64]$memRaw -ge 0) {
                $memPct = [math]::Round(([int64]$memRaw / 10000), 2)
            }
        }
    }

    # =========================
    # Disk totals (sum of vdisks)
    # =========================

    $totalDiskGB = 0

    if ($vm.vm_disk_info) {
        foreach ($disk in $vm.vm_disk_info) {
            if ($disk.size) {
                $totalDiskGB += ($disk.size / 1GB)
            }
        }
    }

    $totalDiskGB = [math]::Round($totalDiskGB, 2)

    $memGB = [math]::Round(($vm.memory_mb / 1024), 2)

    $statusLabel = if ($vm.power_state -eq "on") { "running" } else { "stopped" }

    $result += [PSCustomObject]@{
        Cluster        = "nutanix"
        Host           = $hostName
        VMID           = $vmUuid
        Name           = $vm.name
        Status         = $statusLabel
        PowerState     = $vm.power_state

        CPUs           = $vm.num_vcpus
        CoresPerCPU    = $vm.num_cores_per_vcpu
        CPUUsagePct    = $cpuPct

        MemoryGB       = $memGB
        MemoryUsagePct = $memPct

        DiskGB         = $totalDiskGB

        TimezoneInfo   = $vm.timezone
    }
}

# =========================
# Cleanup old CSV
# =========================

Get-ChildItem `
    -Path $PSScriptRoot `
    -Filter "nutanixinfo_*.csv" `
    -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue

# =========================
# Export CSV
# =========================

$wib = [System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId(
    (Get-Date),
    "SE Asia Standard Time"
)

$timestamp = $wib.ToString("yyyyMMdd_HHmmss")

$outputFile = "$PSScriptRoot\nutanixinfo_$timestamp.csv"

$result | Export-Csv $outputFile -NoTypeInformation

Write-Host ""
Write-Host "======================================="
Write-Host "Export completed"
Write-Host "VM Count : $($result.Count)"
Write-Host "Output   : $outputFile"
Write-Host "======================================="