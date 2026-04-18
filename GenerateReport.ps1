$ErrorActionPreference = "Stop"

# --- Configuration ---
# Define VM groups by name prefix
$groups = @(
    @{ Name = "Development OpenShift"; Prefix = "devocp-"; Tag = "devocp" }
    @{ Name = "Production OpenShift";  Prefix = "prdocp-"; Tag = "prdocp" }
)

# --- Find the latest CSV ---
$csvFiles = Get-ChildItem -Path $PSScriptRoot -Filter "vminfo_*.csv" | Sort-Object LastWriteTime -Descending
if ($csvFiles.Count -eq 0) {
    Write-Error "No vminfo_*.csv files found in $PSScriptRoot"
    exit 1
}
$latestCsv = $csvFiles[0].FullName
$vms = Import-Csv $latestCsv

# --- Parse timestamp from filename ---
$timestamp = [regex]::Match($csvFiles[0].Name, 'vminfo_(\d{8})_(\d{6})\.csv')
$dateStr = $timestamp.Groups[1].Value
$timeStr = $timestamp.Groups[2].Value
$reportDate = [datetime]::ParseExact($dateStr, "yyyyMMdd", $null)
$reportTime = [datetime]::ParseExact($timeStr, "HHmmss", $null)
$formattedDate = $reportDate.ToString("dd MMMM yyyy", [System.Globalization.CultureInfo]::new("id-ID"))
$formattedTime = $reportTime.ToString("HH:mm")

# --- Helper function ---
function Get-GroupStats($vmList) {
    $totalVMs = $vmList.Count
    $totalCpu = ($vmList | Measure-Object -Property NumCpu -Sum).Sum
    $totalMemGB = ($vmList | Measure-Object -Property MemoryGB -Sum).Sum
    $totalActiveKB = ($vmList | Measure-Object -Property ActiveMemoryKB -Sum).Sum
    $activeMemGB = [math]::Round($totalActiveKB / 1048576, 2)
    $utilization = if ($totalMemGB -gt 0) { [math]::Round(($activeMemGB / $totalMemGB) * 100, 2) } else { 0 }

    return @{
        TotalVMs      = $totalVMs
        TotalCpu      = $totalCpu
        TotalMemGB    = $totalMemGB
        ActiveMemGB   = $activeMemGB
        Utilization   = $utilization
    }
}

# --- Overall stats ---
$overall = Get-GroupStats $vms

# --- Build report ---
$report = @()
$report += "Berikut kami sampaikan update kondisi VMware tanggal $formattedDate Pukul $formattedTime WIB:"
$report += ""
$report += "VMware Infrastructure"
$report += "Total VMs: $($overall.TotalVMs.ToString('N0'))"
$report += "Total vCPUs: $($overall.TotalCpu.ToString('N0'))"
$report += "Total Memory: $($overall.TotalMemGB.ToString('N2')) GB"
$report += "Active Memory Usage: $($overall.ActiveMemGB.ToString('N2')) GB ($($overall.Utilization.ToString('N2'))% utilization)"

foreach ($group in $groups) {
    $groupVMs = $vms | Where-Object { $_.Name -like "$($group.Prefix)*" }
    if ($groupVMs.Count -eq 0) { continue }

    $stats = Get-GroupStats $groupVMs

    $report += ""
    $report += "$($group.Name) ($($group.Tag))"
    $report += "Total VM: $($stats.TotalVMs)"
    $report += "Total vCPU: $($stats.TotalCpu.ToString('N0'))"
    $report += "Total Memory: $($stats.TotalMemGB.ToString('N0')) GB"
    $report += "Active Memory: $($stats.ActiveMemGB.ToString('N2')) GB"
    $report += "Memory Utilization: $($stats.Utilization.ToString('N2'))%"
}

# --- Output ---
$reportText = $report -join "`n"
Write-Output $reportText

# Save to file
$reportFile = Join-Path $PSScriptRoot "report_${dateStr}_${timeStr}.txt"
$reportText | Out-File -FilePath $reportFile -Encoding UTF8
Write-Output "`nReport saved to: $reportFile"

# --- Send to Telegram ---
$envFile = Join-Path $PSScriptRoot ".env"
if (Test-Path $envFile) {
    Get-Content $envFile | ForEach-Object {
        if ($_ -match '^\s*([^#][^=]+)=(.*)$') {
            [System.Environment]::SetEnvironmentVariable($Matches[1].Trim(), $Matches[2].Trim())
        }
    }
}

$botToken = $env:TELEGRAM_BOT_TOKEN
$chatId = $env:TELEGRAM_CHAT_ID

if ($botToken -and $chatId) {
    $uri = "https://api.telegram.org/bot$botToken/sendMessage"
    $body = @{
        chat_id    = $chatId
        text       = $reportText
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
    Write-Warning "TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID not set in .env, skipping Telegram."
}
