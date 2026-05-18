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
# Cert trust
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
# Auth header
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
# Get cluster summary (physical capacity + cluster usage)
# =========================

$clusterInfo = Invoke-RestMethod `
    -Method GET `
    -Uri "https://${server}:9440/PrismGateway/services/rest/v2.0/cluster/" `
    -Headers $headers

# v1 cluster has stats embedded
$clusterV1 = Invoke-RestMethod `
    -Method GET `
    -Uri "https://${server}:9440/PrismGateway/services/rest/v1/cluster/" `
    -Headers $headers

$clusterStats = $clusterV1.stats
$clusterUsage = $clusterV1.usageStats

Write-Host "Cluster name : $($clusterInfo.name)"
Write-Host "AOS version  : $($clusterInfo.version)"

# =========================
# Get hosts (for total physical resources)
# =========================

$hostsResp = Invoke-RestMethod `
    -Method GET `
    -Uri "https://${server}:9440/PrismGateway/services/rest/v2.0/hosts/" `
    -Headers $headers

$hostMap         = @{}
$totalPhysicalMemBytes = 0
$totalPhysicalCpuHz    = 0

foreach ($h in $hostsResp.entities) {
    $hostMap[$h.uuid] = $h.name

    if ($h.memory_capacity_in_bytes) { $totalPhysicalMemBytes += [int64]$h.memory_capacity_in_bytes }
    if ($h.cpu_capacity_in_hz)       { $totalPhysicalCpuHz    += [int64]$h.cpu_capacity_in_hz }
}

$totalPhysicalMemGB = [math]::Round(($totalPhysicalMemBytes / 1GB), 2)
$totalPhysicalCpuGHz = [math]::Round(($totalPhysicalCpuHz / 1000000000), 2)

Write-Host "Hosts        : $($hostMap.Count)"
Write-Host "Physical RAM : $totalPhysicalMemGB GB"
Write-Host "Physical CPU : $totalPhysicalCpuGHz GHz"

# =========================
# Compute cluster-wide usage from cluster stats
# =========================

$clusterCpuPct = 0
$clusterMemPct = 0
$clusterUsedMemGB = 0

if ($clusterStats."hypervisor_cpu_usage_ppm") {
    $cpuRaw = [int64]$clusterStats."hypervisor_cpu_usage_ppm"
    if ($cpuRaw -ge 0) {
        $clusterCpuPct = [math]::Round(($cpuRaw / 10000), 2)
    }
}

if ($clusterStats."hypervisor_memory_usage_ppm") {
    $memRaw = [int64]$clusterStats."hypervisor_memory_usage_ppm"
    if ($memRaw -ge 0) {
        $clusterMemPct = [math]::Round(($memRaw / 10000), 2)
        $clusterUsedMemGB = [math]::Round(($totalPhysicalMemGB * $clusterMemPct / 100), 2)
    }
}

Write-Host "Cluster CPU  : $clusterCpuPct %"
Write-Host "Cluster Mem  : $clusterMemPct % ($clusterUsedMemGB GB)"

# =========================
# Storage usage from cluster usageStats
# =========================

$storageCapacityGB = 0
$storageUsedGB = 0

if ($clusterUsage."storage.capacity_bytes") {
    $storageCapacityGB = [math]::Round(([int64]$clusterUsage."storage.capacity_bytes" / 1GB), 2)
}
if ($clusterUsage."storage.usage_bytes") {
    $storageUsedGB = [math]::Round(([int64]$clusterUsage."storage.usage_bytes" / 1GB), 2)
}

$storagePct = if ($storageCapacityGB -gt 0) {
    [math]::Round(($storageUsedGB / $storageCapacityGB) * 100, 2)
} else { 0 }

Write-Host "Storage      : $storageUsedGB / $storageCapacityGB GB ($storagePct %)"

# =========================
# Get VMs (v2 for inventory + v1 for per-VM stats)
# =========================

$vmsV2 = Invoke-RestMethod `
    -Method GET `
    -Uri "https://${server}:9440/PrismGateway/services/rest/v2.0/vms/?include_vm_disk_config=true&include_vm_nic_config=true" `
    -Headers $headers

Write-Host "VMs found    : $($vmsV2.entities.Count)"

$vmsV1 = Invoke-RestMethod `
    -Method GET `
    -Uri "https://${server}:9440/PrismGateway/services/rest/v1/vms/" `
    -Headers $headers

$v1Map = @{}
foreach ($v1 in $vmsV1.entities) {
    $v1Map[$v1.uuid] = $v1
}

# =========================
# Build per-VM result
# =========================

$result = @()

foreach ($vm in $vmsV2.entities) {

    $vmUuid = $vm.uuid
    $hostUuid = $vm.host_uuid
    $hostName = if ($hostUuid -and $hostMap.ContainsKey($hostUuid)) { $hostMap[$hostUuid] } else { "" }

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

    $totalDiskGB = 0
    if ($vm.vm_disk_info) {
        foreach ($disk in $vm.vm_disk_info) {
            if ($disk.size) { $totalDiskGB += ($disk.size / 1GB) }
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
    }
}

# =========================
# Cleanup old files
# =========================

Get-ChildItem -Path $PSScriptRoot -Filter "nutanixinfo_*.csv" -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue

Get-ChildItem -Path $PSScriptRoot -Filter "nutanixcluster_*.csv" -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue

# =========================
# Export
# =========================

$wib = [System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId(
    (Get-Date),
    "SE Asia Standard Time"
)
$timestamp = $wib.ToString("yyyyMMdd_HHmmss")

# Per-VM CSV
$vmFile = "$PSScriptRoot\nutanixinfo_$timestamp.csv"
$result | Export-Csv $vmFile -NoTypeInformation

# Cluster-level CSV
$clusterFile = "$PSScriptRoot\nutanixcluster_$timestamp.csv"
$clusterSummary = [PSCustomObject]@{
    ClusterName         = $clusterInfo.name
    AOSVersion          = $clusterInfo.version
    HostCount           = $hostMap.Count
    TotalPhysicalCpuGHz = $totalPhysicalCpuGHz
    TotalPhysicalMemGB  = $totalPhysicalMemGB
    ClusterCpuPct       = $clusterCpuPct
    ClusterMemPct       = $clusterMemPct
    ClusterUsedMemGB    = $clusterUsedMemGB
    StorageCapacityGB   = $storageCapacityGB
    StorageUsedGB       = $storageUsedGB
    StoragePct          = $storagePct
}
$clusterSummary | Export-Csv $clusterFile -NoTypeInformation

Write-Host ""
Write-Host "======================================="
Write-Host "Export completed"
Write-Host "VM Count     : $($result.Count)"
Write-Host "VM CSV       : $vmFile"
Write-Host "Cluster CSV  : $clusterFile"
Write-Host "======================================="