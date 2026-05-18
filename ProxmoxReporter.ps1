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

# =========================
# Read cluster list
# =========================

if (-not $env:CLUSTERS) {
    Write-Error "Missing CLUSTERS in .env (e.g. CLUSTERS=prod,dev,staging)"
    exit 1
}

$clusters = $env:CLUSTERS -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }

Write-Host "Clusters detected: $($clusters -join ', ')"

# =========================
# TLS 1.2
# =========================

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# =========================
# Ignore self-signed certs
# =========================

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

[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy

# =========================
# Cleanup old CSVs
# =========================

Get-ChildItem `
    -Path $PSScriptRoot `
    -Filter "pveinfo_*.csv" `
    -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue

# =========================
# Timestamp (shared across clusters)
# =========================

$wib = [System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId(
    (Get-Date),
    "SE Asia Standard Time"
)

$timestamp = $wib.ToString("yyyyMMdd_HHmmss")

# =========================
# Process each cluster
# =========================

foreach ($cluster in $clusters) {

    Write-Host ""
    Write-Host "#######################################"
    Write-Host "Processing cluster: $cluster"
    Write-Host "#######################################"

    $prefix = $cluster.ToUpper()

    $server   = [Environment]::GetEnvironmentVariable("${prefix}_SERVER")
    $user     = [Environment]::GetEnvironmentVariable("${prefix}_USER")
    $password = [Environment]::GetEnvironmentVariable("${prefix}_PASSWORD")

    if (-not $server -or -not $user -or -not $password) {
        Write-Warning "Skipping '$cluster' - missing ${prefix}_SERVER / ${prefix}_USER / ${prefix}_PASSWORD"
        continue
    }

    Write-Host "Server: $server"
    Write-Host "User: $user"

    try {

        # =========================
        # Login
        # =========================

        $loginBody = @{
            username = $user
            password = $password
        }

        $login = Invoke-RestMethod `
            -Method POST `
            -Uri "https://${server}:8006/api2/json/access/ticket" `
            -Body $loginBody `
            -ContentType "application/x-www-form-urlencoded"

        $ticket    = $login.data.ticket
        $csrfToken = $login.data.CSRFPreventionToken

        Write-Host "Successfully authenticated"

        # =========================
        # Build WebSession with Cookie
        # =========================

        $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession

        $cookie = New-Object System.Net.Cookie
        $cookie.Name   = "PVEAuthCookie"
        $cookie.Value  = $ticket
        $cookie.Domain = $server
        $cookie.Path   = "/"

        $session.Cookies.Add($cookie)

        $headers = @{
            "CSRFPreventionToken" = $csrfToken
        }

        # =========================
        # Get Nodes
        # =========================

        $nodes = Invoke-RestMethod `
            -Method GET `
            -Uri "https://${server}:8006/api2/json/nodes" `
            -Headers $headers `
            -WebSession $session

        $result = @()

        foreach ($node in $nodes.data) {

            $nodeName = $node.node

            Write-Host ""
            Write-Host "Processing node: $nodeName"

            # =========================
            # Get QEMU VMs
            # =========================

            $vms = Invoke-RestMethod `
                -Method GET `
                -Uri "https://${server}:8006/api2/json/nodes/$nodeName/qemu" `
                -Headers $headers `
                -WebSession $session

            foreach ($vm in $vms.data) {

                $vmid = $vm.vmid

                Write-Host "Collecting VM: $($vm.name)"

                # =========================
                # VM Current Status
                # =========================

                $status = Invoke-RestMethod `
                    -Method GET `
                    -Uri "https://${server}:8006/api2/json/nodes/$nodeName/qemu/$vmid/status/current" `
                    -Headers $headers `
                    -WebSession $session

                $data = $status.data

                $result += [PSCustomObject]@{
                    Cluster       = $cluster
                    Node          = $nodeName
                    VMID          = $vmid
                    Name          = $data.name
                    Status        = $data.status

                    CPUs          = $data.cpus
                    CPUUsagePct   = [math]::Round(($data.cpu * 100), 2)

                    MaxMemoryGB   = [math]::Round(($data.maxmem / 1GB), 2)
                    UsedMemoryGB  = [math]::Round(($data.mem / 1GB), 2)

                    MaxDiskGB     = [math]::Round(($data.maxdisk / 1GB), 2)
                    UsedDiskGB    = [math]::Round(($data.disk / 1GB), 2)

                    UptimeSeconds = $data.uptime
                }
            }
        }

        # =========================
        # Export CSV per cluster
        # =========================

        $outputFile = "$PSScriptRoot\pveinfo_${cluster}_${timestamp}.csv"

        $result | Export-Csv $outputFile -NoTypeInformation

        Write-Host ""
        Write-Host "---------------------------------------"
        Write-Host "Cluster '$cluster' done"
        Write-Host "VM Count : $($result.Count)"
        Write-Host "Output   : $outputFile"
        Write-Host "---------------------------------------"

    } catch {

        Write-Warning "Failed processing cluster '$cluster': $($_.Exception.Message)"
        continue
    }
}

Write-Host ""
Write-Host "======================================="
Write-Host "All clusters processed"
Write-Host "======================================="