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
# Find latest CSV
# =========================

$csvFiles = Get-ChildItem `
    -Path $PSScriptRoot `
    -Filter "nutanixinfo_*.csv" `
    -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending

if ($csvFiles.Count -eq 0) {
    Write-Error "No nutanixinfo_*.csv found"
    exit 1
}

$latestCsv = $csvFiles[0].FullName
$vms = Import-Csv $latestCsv

if ($vms.Count -eq 0) {
    Write-Error "CSV is empty"
    exit 1
}

# Cast numeric columns
$vms = $vms | ForEach-Object {
    $_.CPUs           = [int]$_.CPUs
    $_.CPUUsagePct    = [double]$_.CPUUsagePct
    $_.MemoryGB       = [double]$_.MemoryGB
    $_.MemoryUsagePct = [double]$_.MemoryUsagePct
    $_.DiskGB         = [double]$_.DiskGB
    $_
}

# =========================
# Parse timestamp
# =========================

$match = [regex]::Match($csvFiles[0].Name, "nutanixinfo_(\d{8})_(\d{6})\.csv")
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
# Compute stats
# =========================

$totalVMs   = $vms.Count
$runningVMs = ($vms | Where-Object { $_.Status -eq 'running' }).Count
$stoppedVMs = $totalVMs - $runningVMs

$totalCpu    = ($vms | Measure-Object -Property CPUs -Sum).Sum
$totalMemGB  = [math]::Round(($vms | Measure-Object -Property MemoryGB -Sum).Sum, 2)
$totalDiskGB = [math]::Round(($vms | Measure-Object -Property DiskGB -Sum).Sum, 2)

# Memory used = sum(memory * usage%) across running VMs
$runningVMList = $vms | Where-Object { $_.Status -eq 'running' }

$usedMemGB = 0

foreach ($vm in $runningVMList) {
    $usedMemGB += ($vm.MemoryGB * $vm.MemoryUsagePct / 100)
}

$usedMemGB = [math]::Round($usedMemGB, 2)

$memUtilization = if ($totalMemGB -gt 0) {
    [math]::Round(($usedMemGB / $totalMemGB) * 100, 2)
} else { 0 }

# CPU avg across running VMs
if ($runningVMList.Count -gt 0) {
    $avgCpuUsage = [math]::Round(
        ($runningVMList | Measure-Object -Property CPUUsagePct -Average).Average,
        2
    )
} else {
    $avgCpuUsage = 0
}

# =========================
# Build Telegram (HTML)
# =========================

$tgReport = @()
$tgReport += "<b>Nutanix AHV Report</b>"
$tgReport += "$formattedDate, $formattedTime WIB"
$tgReport += ""
$tgReport += "<pre>"
$tgReport += "Total VMs       : $($totalVMs.ToString('N0'))"
$tgReport += "  Running       : $runningVMs"
$tgReport += "  Stopped       : $stoppedVMs"
$tgReport += "Total vCPUs     : $($totalCpu.ToString('N0'))"
$tgReport += "Total Memory    : $($totalMemGB.ToString('N2')) GB"
$tgReport += "Used Memory     : $($usedMemGB.ToString('N2')) GB"
$tgReport += "Memory Usage    : $($memUtilization.ToString('N2'))%"
$tgReport += "Avg CPU Usage   : $($avgCpuUsage.ToString('N2'))%"
$tgReport += "Total Disk      : $($totalDiskGB.ToString('N2')) GB"
$tgReport += "</pre>"

$reportText = $tgReport -join "`n"

# =========================
# Plain text (for .txt file)
# =========================

$plainReport = @()
$plainReport += "Nutanix AHV Report"
$plainReport += "$formattedDate, $formattedTime WIB"
$plainReport += ""
$plainReport += "Total VMs       : $($totalVMs.ToString('N0'))"
$plainReport += "  Running       : $runningVMs"
$plainReport += "  Stopped       : $stoppedVMs"
$plainReport += "Total vCPUs     : $($totalCpu.ToString('N0'))"
$plainReport += "Total Memory    : $($totalMemGB.ToString('N2')) GB"
$plainReport += "Used Memory     : $($usedMemGB.ToString('N2')) GB"
$plainReport += "Memory Usage    : $($memUtilization.ToString('N2'))%"
$plainReport += "Avg CPU Usage   : $($avgCpuUsage.ToString('N2'))%"
$plainReport += "Total Disk      : $($totalDiskGB.ToString('N2')) GB"

$plainText = $plainReport -join "`n"

Write-Output $plainText

$reportFile = Join-Path $PSScriptRoot "report_nutanix_${dateStr}_${timeStr}.txt"
$plainText | Out-File -FilePath $reportFile -Encoding UTF8

Write-Output ""
Write-Output "Report saved to: $reportFile"

# =========================
# Send Telegram
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