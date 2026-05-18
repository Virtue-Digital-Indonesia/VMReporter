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
# Helper: parse "1.00 TB" / "500.00 MB" / "220.08 MB\n" -> GB (double)
# =========================

function ConvertTo-GB($valueText) {

    if ($null -eq $valueText) { return 0.0 }

    $clean = ($valueText -replace '\r','' -replace '\n','').Trim()

    if ([string]::IsNullOrWhiteSpace($clean) -or $clean -eq '-') {
        return 0.0
    }

    # Match: number + unit (KB, MB, GB, TB, PB)
    if ($clean -match '([\d.]+)\s*(KB|MB|GB|TB|PB)') {

        $num = [double]$Matches[1]
        $unit = $Matches[2].ToUpper()

        switch ($unit) {
            'KB' { return [math]::Round($num / 1MB * 1KB, 4) }   # KB -> GB
            'MB' { return [math]::Round($num / 1024, 4) }
            'GB' { return [math]::Round($num, 4) }
            'TB' { return [math]::Round($num * 1024, 4) }
            'PB' { return [math]::Round($num * 1024 * 1024, 4) }
        }
    }

    return 0.0
}

# =========================
# Helper: parse "16 Cores" -> 16 (int)
# =========================

function ConvertTo-Cores($valueText) {

    if ($null -eq $valueText) { return 0 }

    $clean = $valueText.Trim()

    if ($clean -match '(\d+)') {
        return [int]$Matches[1]
    }

    return 0
}

# =========================
# Helper: parse "6" -> 6 (int) for CPU/Mem percent (column is bare number)
# =========================

function ConvertTo-Percent($valueText) {

    if ($null -eq $valueText) { return 0 }

    $clean = ($valueText -replace '%','').Trim()

    if ([string]::IsNullOrWhiteSpace($clean) -or $clean -eq '-') {
        return 0.0
    }

    try {
        return [double]$clean
    } catch {
        return 0.0
    }
}

# =========================
# Find latest CSV
# =========================

$csvFiles = Get-ChildItem `
    -Path $PSScriptRoot `
    -Filter "sangforinfo_*.csv" `
    -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending

if ($csvFiles.Count -eq 0) {
    Write-Error "No sangforinfo_*.csv found"
    exit 1
}

$latestCsv = $csvFiles[0].FullName

# Import-Csv handles UTF-8 with BOM correctly
$vms = Import-Csv $latestCsv

if ($vms.Count -eq 0) {
    Write-Error "CSV is empty"
    exit 1
}

# =========================
# Parse timestamp from filename
# =========================

$match = [regex]::Match($csvFiles[0].Name, "sangforinfo_(\d{8})_(\d{6})\.csv")
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

$totalVMs    = $vms.Count
$runningVMs  = ($vms | Where-Object { $_.Status -eq 'Running' }).Count
$missingVMs  = ($vms | Where-Object { $_.Status -eq 'Missing' }).Count
$poweredOff  = ($vms | Where-Object { $_.Status -eq 'Powered off' }).Count
$alarmVMs    = ($vms | Where-Object { $_.Status -eq 'Alarm' }).Count
$stoppedVMs  = $totalVMs - $runningVMs

$totalCpuCores  = 0
$totalMemGB     = 0.0
$totalStorageGB = 0.0
$totalUsedMemGB     = 0.0
$totalUsedStorageGB = 0.0

$cpuUsageList = @()
$memUsageList = @()

foreach ($vm in $vms) {

    $cores = ConvertTo-Cores $vm.CPU
    $totalCpuCores += $cores

    $memGB     = ConvertTo-GB $vm.Memory
    $storageGB = ConvertTo-GB $vm.Storage

    $totalMemGB     += $memGB
    $totalStorageGB += $storageGB

    # Only count actual usage for running VMs
    if ($vm.Status -eq 'Running') {

        $usedMemGB     = ConvertTo-GB $vm.'Used Memory'
        $usedStorageGB = ConvertTo-GB $vm.'Used Storage'

        $totalUsedMemGB     += $usedMemGB
        $totalUsedStorageGB += $usedStorageGB

        $cpuPct = ConvertTo-Percent $vm.'CPU Usage'
        $memPct = ConvertTo-Percent $vm.'Memory Usage'

        $cpuUsageList += $cpuPct
        $memUsageList += $memPct
    }
}

$totalMemGB     = [math]::Round($totalMemGB, 2)
$totalStorageGB = [math]::Round($totalStorageGB, 2)
$totalUsedMemGB     = [math]::Round($totalUsedMemGB, 2)
$totalUsedStorageGB = [math]::Round($totalUsedStorageGB, 2)

$memUtilization = if ($totalMemGB -gt 0) {
    [math]::Round(($totalUsedMemGB / $totalMemGB) * 100, 2)
} else { 0 }

$storageUtilization = if ($totalStorageGB -gt 0) {
    [math]::Round(($totalUsedStorageGB / $totalStorageGB) * 100, 2)
} else { 0 }

# Average CPU usage across running VMs
$avgCpuUsage = if ($cpuUsageList.Count -gt 0) {
    [math]::Round(($cpuUsageList | Measure-Object -Average).Average, 2)
} else { 0 }

# =========================
# Build Telegram (HTML)
# =========================

$tgReport = @()
$tgReport += "<b>Sangfor HCI Report</b>"
$tgReport += "$formattedDate, $formattedTime WIB"
$tgReport += ""
$tgReport += "<pre>"
$tgReport += "VM Inventory"
$tgReport += "  Total VMs       : $($totalVMs.ToString('N0'))"
$tgReport += "  Running         : $runningVMs"
$tgReport += "  Powered off     : $poweredOff"
$tgReport += "  Missing         : $missingVMs"
$tgReport += "  Alarm           : $alarmVMs"
$tgReport += ""
$tgReport += "Allocated to VMs"
$tgReport += "  Total vCPUs     : $($totalCpuCores.ToString('N0'))"
$tgReport += "  Total Memory    : $($totalMemGB.ToString('N2')) GB"
$tgReport += "  Total Storage   : $($totalStorageGB.ToString('N2')) GB"
$tgReport += ""
$tgReport += "Resource Utilization"
$tgReport += "  Used Memory     : $($totalUsedMemGB.ToString('N2')) GB ($($memUtilization.ToString('N2'))%)"
$tgReport += "  Used Storage    : $($totalUsedStorageGB.ToString('N2')) GB ($($storageUtilization.ToString('N2'))%)"
$tgReport += "  Avg CPU Usage   : $($avgCpuUsage.ToString('N2'))%"
$tgReport += "</pre>"

$reportText = $tgReport -join "`n"

# =========================
# Plain text version
# =========================

$plainReport = @()
$plainReport += "Sangfor HCI Report"
$plainReport += "$formattedDate, $formattedTime WIB"
$plainReport += ""
$plainReport += "VM Inventory"
$plainReport += "  Total VMs       : $($totalVMs.ToString('N0'))"
$plainReport += "  Running         : $runningVMs"
$plainReport += "  Powered off     : $poweredOff"
$plainReport += "  Missing         : $missingVMs"
$plainReport += "  Alarm           : $alarmVMs"
$plainReport += ""
$plainReport += "Allocated to VMs"
$plainReport += "  Total vCPUs     : $($totalCpuCores.ToString('N0'))"
$plainReport += "  Total Memory    : $($totalMemGB.ToString('N2')) GB"
$plainReport += "  Total Storage   : $($totalStorageGB.ToString('N2')) GB"
$plainReport += ""
$plainReport += "Resource Utilization"
$plainReport += "  Used Memory     : $($totalUsedMemGB.ToString('N2')) GB ($($memUtilization.ToString('N2'))%)"
$plainReport += "  Used Storage    : $($totalUsedStorageGB.ToString('N2')) GB ($($storageUtilization.ToString('N2'))%)"
$plainReport += "  Avg CPU Usage   : $($avgCpuUsage.ToString('N2'))%"

$plainText = $plainReport -join "`n"

Write-Output $plainText

$reportFile = Join-Path $PSScriptRoot "report_sangfor_${dateStr}_${timeStr}.txt"
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