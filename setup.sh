#!/bin/bash
# Setup script for VMReporter on Ubuntu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Check if PowerShell is installed
if ! command -v pwsh &> /dev/null; then
    echo "PowerShell not found. Installing..."
    sudo apt-get update
    sudo apt-get install -y wget apt-transport-https software-properties-common
    wget -q "https://packages.microsoft.com/config/ubuntu/$(lsb_release -rs)/packages-microsoft-prod.deb"
    sudo dpkg -i packages-microsoft-prod.deb
    rm packages-microsoft-prod.deb
    sudo apt-get update
    sudo apt-get install -y powershell
fi

# Install VMware PowerCLI if not present
pwsh -Command "if (-not (Get-Module -ListAvailable VMware.PowerCLI)) { Install-Module VMware.PowerCLI -Force -Scope CurrentUser -AllowClobber }"

# Set PowerCLI to ignore invalid certificates (common for self-signed vCenter certs)
pwsh -Command "Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:\$false"

# Install cron job for 8:00 AM WIB (UTC+7 = 01:00 UTC)
CRON_CMD="0 1 * * * /usr/bin/pwsh -File $SCRIPT_DIR/VMReporter.ps1 >> $SCRIPT_DIR/vmreporter.log 2>> $SCRIPT_DIR/vmreporter_error.log"

PVE_CRON="5 1 * * * /usr/bin/pwsh -File $SCRIPT_DIR/ProxmoxReporter.ps1 >> $SCRIPT_DIR/proxmoxreporter.log 2>> $SCRIPT_DIR/proxmoxreporter_error.log"

# Check if cron job already exists
(crontab -l 2>/dev/null | grep -v "VMReporter.ps1" | grep -v "ProxmoxReporter.ps1"; echo "$CRON_CMD"; echo "$PVE_CRON") | crontab -

echo "Setup complete!"
echo "Cron job installed: runs daily at 08:00 WIB (01:00 UTC)"
echo ""
echo "Make sure to edit .env with your credentials:"
echo "  $SCRIPT_DIR/.env"
echo ""
echo "To test manually:"
echo "  pwsh -File $SCRIPT_DIR/VMReporter.ps1"
echo ""
echo "To check cron:"
echo "  crontab -l"
