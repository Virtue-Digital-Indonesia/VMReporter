$ErrorActionPreference = "Stop"

# Load .env file
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

$server   = $env:VCENTER_SERVER
$user     = $env:VCENTER_USER
$password  = $env:VCENTER_PASSWORD

if (-not $server -or -not $user -or -not $password) {
    Write-Error "Missing VCENTER_SERVER, VCENTER_USER, or VCENTER_PASSWORD in .env"
    exit 1
}

# Connect to vCenter
$secPass = ConvertTo-SecureString $password -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential($user, $secPass)
Connect-VIServer -Server $server -Credential $cred

# Gather VM stats
$vms = Get-VM | Where-Object { $_.PowerState -eq "PoweredOn" }
$stats = Get-Stat -Entity $vms -Stat mem.active.average -MaxSamples 1 -Realtime

$result = foreach ($vm in $vms) {
    $activeMem = ($stats | Where-Object { $_.Entity.Name -eq $vm.Name }).Value
    [PSCustomObject]@{
        Name           = $vm.Name
        PowerState     = $vm.PowerState
        NumCpu         = $vm.NumCpu
        MemoryGB       = $vm.MemoryGB
        ActiveMemoryKB = $activeMem
    }
}

# Remove old CSV and report files
Get-ChildItem -Path $PSScriptRoot -Filter "vminfo_*.csv" | Remove-Item -Force
Get-ChildItem -Path $PSScriptRoot -Filter "report_*.txt" | Remove-Item -Force

# Export to CSV
$wib = [System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId((Get-Date), "SE Asia Standard Time")
$timestamp = $wib.ToString("yyyyMMdd_HHmmss")
$outputDir = $PSScriptRoot
$result | Export-Csv "$outputDir/vminfo_$timestamp.csv" -NoTypeInformation

Write-Output "Exported $($result.Count) VMs to $outputDir/vminfo_$timestamp.csv"

# Disconnect
Disconnect-VIServer -Confirm:$false

# Generate report
& "$PSScriptRoot/GenerateReport.ps1"
