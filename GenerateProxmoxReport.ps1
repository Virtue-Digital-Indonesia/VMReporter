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
# Read cluster list
# =========================

if (-not $env:CLUSTERS) {
    Write-Error "Missing CLUSTERS in .env"
    exit 1
}

$clusters = $env:CLUSTERS -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }

# =========================
# Helper: stats from VM list
# =========================

function Get-ClusterStats($vmList) {

    $totalVMs       = $vmList.Count
    $runningVMs     = ($vmList | Where-Object { $_.Status -eq 'running' }).Count
    $stoppedVMs     = $totalVMs - $runningVMs

    $totalCpu       = ($vmList | Measure-Object -Property CPUs -Sum).Sum
    $totalMemGB     = [math]::Round(($vmList | Measure-Object -Property MaxMemoryGB -Sum).Sum, 2)
    $usedMemGB      = [math]::Round(($vmList | Measure-Object -Property UsedMemoryGB -Sum).Sum, 2)

    $runningVMList  = $vmList | Where-Object { $_.Status -eq 'running' }

    if ($runningVMList.Count -gt 0) {
        $avgCpuUsage = [math]::Round(
            ($runningVMList | Measure-Object -Property CPUUsagePct -Average).Average,
            2
        )
    } else {
        $avgCpuUsage = 0
    }

    $memUtilization = if ($totalMemGB -gt 0) {
        [math]::Round(($usedMemGB / $totalMemGB) * 100, 2)
    } else { 0 }

    return @{
        TotalVMs       = $totalVMs
        RunningVMs     = $runningVMs
        StoppedVMs     = $stoppedVMs
        TotalCpu       = $totalCpu
        TotalMemGB     = $totalMemGB
        UsedMemGB      = $usedMemGB
        MemUtilization = $memUtilization
        AvgCpuUsage    = $avgCpuUsage
    }
}

# =========================
# Telegram config (shared)
# =========================

$botToken = $env:TELEGRAM_BOT_TOKEN
$chatId   = $env:TELEGRAM_CHAT_ID

# =========================
# Process each cluster
# =========================

foreach ($cluster in $clusters) {

    Write-Output ""
    Write-Output "#######################################"
    Write-Output "Building report for cluster: $cluster"
    Write-Output "#######################################"

    $csvFiles = Get-ChildItem `
        -Path $PSScriptRoot `
        -Filter "pveinfo_${cluster}_*.csv" `
        -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending

    if ($csvFiles.Count -eq 0) {
        Write-Warning "No pveinfo_${cluster}_*.csv found, skipping"
        continue
    }

    $latestCsv = $csvFiles[0].FullName
    $vms = Import-Csv $latestCsv

    if ($vms.Count -eq 0) {
        Write-Warning "CSV for cluster '$cluster' is empty, skipping"
        continue
    }

    $vms = $vms | ForEach-Object {
        $_.CPUs         = [int]$_.CPUs
        $_.CPUUsagePct  = [double]$_.CPUUsagePct
        $_.MaxMemoryGB  = [double]$_.MaxMemoryGB
        $_.UsedMemoryGB = [double]$_.UsedMemoryGB
        $_
    }

    # =========================
    # Parse timestamp from filename
    # =========================

    $match = [regex]::Match(
        $csvFiles[0].Name,
        "pveinfo_${cluster}_(\d{8})_(\d{6})\.csv"
    )

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

    $stats = Get-ClusterStats $vms

    $clusterLabel = $cluster.ToUpper()

    # =========================
    # Build Telegram message (HTML)
    # =========================

    $tgReport = @()
    $tgReport += "<b>Proxmox Report - $clusterLabel</b>"
    $tgReport += "$formattedDate, $formattedTime WIB"
    $tgReport += ""
    $tgReport += "<pre>"
    $tgReport += "Total VMs       : $($stats.TotalVMs.ToString('N0'))"
    $tgReport += "  Running       : $($stats.RunningVMs)"
    $tgReport += "  Stopped       : $($stats.StoppedVMs)"
    $tgReport += "Total vCPUs     : $($stats.TotalCpu.ToString('N0'))"
    $tgReport += "Total Memory    : $($stats.TotalMemGB.ToString('N2')) GB"
    $tgReport += "Used Memory     : $($stats.UsedMemGB.ToString('N2')) GB"
    $tgReport += "Memory Usage    : $($stats.MemUtilization.ToString('N2'))%"
    $tgReport += "Avg CPU Usage   : $($stats.AvgCpuUsage.ToString('N2'))%"
    $tgReport += "</pre>"

    $reportText = $tgReport -join "`n"

    # =========================
    # Build plain text (for .txt file)
    # =========================

    $plainReport = @()
    $plainReport += "Proxmox Report - $clusterLabel"
    $plainReport += "$formattedDate, $formattedTime WIB"
    $plainReport += ""
    $plainReport += "Total VMs       : $($stats.TotalVMs.ToString('N0'))"
    $plainReport += "  Running       : $($stats.RunningVMs)"
    $plainReport += "  Stopped       : $($stats.StoppedVMs)"
    $plainReport += "Total vCPUs     : $($stats.TotalCpu.ToString('N0'))"
    $plainReport += "Total Memory    : $($stats.TotalMemGB.ToString('N2')) GB"
    $plainReport += "Used Memory     : $($stats.UsedMemGB.ToString('N2')) GB"
    $plainReport += "Memory Usage    : $($stats.MemUtilization.ToString('N2'))%"
    $plainReport += "Avg CPU Usage   : $($stats.AvgCpuUsage.ToString('N2'))%"

    $plainText = $plainReport -join "`n"

    Write-Output $plainText

    # Save plain text version to file
    $reportFile = Join-Path $PSScriptRoot "report_pve_${cluster}_${dateStr}_${timeStr}.txt"
    $plainText | Out-File -FilePath $reportFile -Encoding UTF8
    Write-Output ""
    Write-Output "Report saved to: $reportFile"

    # =========================
    # Send to Telegram (HTML mode)
    # =========================

    if ($botToken -and $chatId) {

        $uri = "https://api.telegram.org/bot$botToken/sendMessage"

        $body = @{
            chat_id    = $chatId
            text       = $reportText
            parse_mode = "HTML"
        }

        try {
            Invoke-RestMethod -Uri $uri -Method Post -Body $body | Out-Null
            Write-Output "Report for '$cluster' sent to Telegram."
        }
        catch {
            Write-Warning "Failed to send Telegram message for '$cluster': $_"
        }
    }
    else {
        Write-Warning "TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID not set, skipping Telegram for '$cluster'."
    }
}

Write-Output ""
Write-Output "======================================="
Write-Output "All cluster reports done"
Write-Output "======================================="