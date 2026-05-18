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
    if ($_ -match '^\s*([^#][^=]+)=(.*)$') {
        [System.Environment]::SetEnvironmentVariable($Matches[1].Trim(), $Matches[2].Trim())
    }
}

# =========================
# Find latest cluster CSV (primary source)
# =========================

$clusterCsvFiles = Get-ChildItem `
    -Path $PSScriptRoot `
    -Filter "nutanixcluster_*.csv" `
    -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending

if ($clusterCsvFiles.Count -eq 0) {
    Write-Error "No nutanixcluster_*.csv found"
    exit 1
}

$clusterCsv = Import-Csv $clusterCsvFiles[0].FullName | Select-Object -First 1

# =========================
# Find latest VM CSV (for VM count breakdown)
# =========================

$vmCsvFiles = Get-ChildItem `
    -Path $PSScriptRoot `
    -Filter "nutanixinfo_*.csv" `
    -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending

if ($vmCsvFiles.Count -eq 0) {
    Write-Error "No nutanixinfo_*.csv found"
    exit 1
}

$vms = Import-Csv $vmCsvFiles[0].FullName

# Cast numeric columns for VM CSV
$vms = $vms | ForEach-Object {
    $_.CPUs           = [int]$_.CPUs
    $_.MemoryGB       = [double]$_.MemoryGB
    $_.DiskGB         = [double]$_.DiskGB
    $_
}

# =========================
# Parse timestamp from cluster file
# =========================

$match = [regex]::Match($clusterCsvFiles[0].Name, "nutanixcluster_(\d{8})_(\d{6})\.csv")
$dateStr = $match.Groups[1].Value
$timeStr = $match.Groups[2].Value

$reportDateTime = [datetime]::ParseExact(
    "${dateStr}_${timeStr}",
    "yyyyMMdd_HHmmss",
    $null
)

$idCulture = [System.Globalization.CultureInfo]::new("id-ID")
$formattedDate = $reportDateTime.ToString("dd MMMM yyyy", $idCulture)
$formattedTime = $reportDateTime.ToString("HH:mm")

# =========================
# Stats
# =========================

# VM counts from per-VM CSV
$totalVMs   = $vms.Count
$runningVMs = ($vms | Where-Object { $_.Status -eq 'running' }).Count
$stoppedVMs = $totalVMs - $runningVMs

# Allocated resources (sum across VMs)
$totalVCpus      = ($vms | Measure-Object -Property CPUs -Sum).Sum
$totalAllocMemGB = [math]::Round(($vms | Measure-Object -Property MemoryGB -Sum).Sum, 2)
$totalAllocDiskGB = [math]::Round(($vms | Measure-Object -Property DiskGB -Sum).Sum, 2)

# Cluster physical capacity + actual usage from cluster CSV
$clusterName       = $clusterCsv.ClusterName
$physicalCpuGHz    = [double]$clusterCsv.TotalPhysicalCpuGHz
$physicalMemGB     = [double]$clusterCsv.TotalPhysicalMemGB
$cpuUsagePct       = [double]$clusterCsv.ClusterCpuPct
$memUsagePct       = [double]$clusterCsv.ClusterMemPct
$memUsedGB         = [double]$clusterCsv.ClusterUsedMemGB
$storageCapGB      = [double]$clusterCsv.StorageCapacityGB
$storageUsedGB     = [double]$clusterCsv.StorageUsedGB
$storagePct        = [double]$clusterCsv.StoragePct

# =========================
# Build report (HTML for Telegram)
# =========================

$tgReport = @()
$tgReport += "<b>Nutanix AHU Report - $clusterName</b>"
$tgReport += "$formattedDate, $formattedTime WIB"
$tgReport += ""
$tgReport += "<pre>"
$tgReport += "VM Inventory"
$tgReport += "  Total VMs       : $($totalVMs.ToString('N0'))"
$tgReport += "  Running         : $runningVMs"
$tgReport += "  Stopped         : $stoppedVMs"
$tgReport += ""
$tgReport += "Allocated to VMs"
$tgReport += "  Total vCPUs     : $($totalVCpus.ToString('N0'))"
$tgReport += "  Total Memory    : $($totalAllocMemGB.ToString('N2')) GB"
$tgReport += "  Total Disk      : $($totalAllocDiskGB.ToString('N2')) GB"
$tgReport += ""
$tgReport += "Cluster Capacity"
$tgReport += "  Physical CPU    : $($physicalCpuGHz.ToString('N2')) GHz"
$tgReport += "  Physical Memory : $($physicalMemGB.ToString('N2')) GB"
$tgReport += "  Storage         : $($storageCapGB.ToString('N2')) GB"
$tgReport += ""
$tgReport += "Cluster Utilization"
$tgReport += "  CPU Usage       : $($cpuUsagePct.ToString('N2'))%"
$tgReport += "  Memory Usage    : $($memUsedGB.ToString('N2')) GB ($($memUsagePct.ToString('N2'))%)"
$tgReport += "  Storage Usage   : $($storageUsedGB.ToString('N2')) GB ($($storagePct.ToString('N2'))%)"
$tgReport += "</pre>"

$reportText = $tgReport -join "`n"

# =========================
# Plain text version
# =========================

$plainReport = @()
$plainReport += "Nutanix AHU Report - $clusterName"
$plainReport += "$formattedDate, $formattedTime WIB"
$plainReport += ""
$plainReport += "VM Inventory"
$plainReport += "  Total VMs       : $($totalVMs.ToString('N0'))"
$plainReport += "  Running         : $runningVMs"
$plainReport += "  Stopped         : $stoppedVMs"
$plainReport += ""
$plainReport += "Allocated to VMs"
$plainReport += "  Total vCPUs     : $($totalVCpus.ToString('N0'))"
$plainReport += "  Total Memory    : $($totalAllocMemGB.ToString('N2')) GB"
$plainReport += "  Total Disk      : $($totalAllocDiskGB.ToString('N2')) GB"
$plainReport += ""
$plainReport += "Cluster Capacity"
$plainReport += "  Physical CPU    : $($physicalCpuGHz.ToString('N2')) GHz"
$plainReport += "  Physical Memory : $($physicalMemGB.ToString('N2')) GB"
$plainReport += "  Storage         : $($storageCapGB.ToString('N2')) GB"
$plainReport += ""
$plainReport += "Cluster Utilization"
$plainReport += "  CPU Usage       : $($cpuUsagePct.ToString('N2'))%"
$plainReport += "  Memory Usage    : $($memUsedGB.ToString('N2')) GB ($($memUsagePct.ToString('N2'))%)"
$plainReport += "  Storage Usage   : $($storageUsedGB.ToString('N2')) GB ($($storagePct.ToString('N2'))%)"

$plainText = $plainReport -join "`n"

Write-Output $plainText

$reportFile = Join-Path $PSScriptRoot "report_nutanix_${dateStr}_${timeStr}.txt"
$plainText | Out-File -FilePath $reportFile -Encoding UTF8

Write-Output ""
Write-Output "Report saved to: $reportFile"

# =========================
# Telegram
# =========================

$botToken = $env:TELEGRAM_BOT_TOKEN
$chatId   = $env:TELEGRAM_CHAT_ID

if ($botToken -and $chatId) {

    $uri = "https://api.telegram.org/bot$botToken/sendMessage"

    $body = @{
        chat_id    = $chatId
        text       = $reportText
        parse_mode = "HTML"
    }

    try {
        Invoke-RestMethod -Uri $uri -Method Post -Body $body | Out-Null
        Write-Output "Report sent to Telegram."
    }
    catch {
        Write-Warning "Failed to send Telegram message: $_"
    }
}
else {
    Write-Warning "TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID not set, skipping Telegram."
}