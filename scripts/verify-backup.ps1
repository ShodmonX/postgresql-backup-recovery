$ErrorActionPreference = "Stop"

$BarmanVm   = "barman"
$ServerName = "pg-primary"

function Invoke-VagrantCommand {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Vm,

        [Parameter(Mandatory = $true)]
        [string]$Command
    )

    $output = & vagrant ssh $Vm -c $Command -- -T

    if ($LASTEXITCODE -ne 0) {
        throw "Command failed on VM '$Vm': $Command"
    }

    return $output
}

Write-Host "==> Verifying latest Barman backup"

Write-Host "==> Checking $BarmanVm"

& vagrant ssh $BarmanVm -c "hostname" -- -T *> $null

if ($LASTEXITCODE -ne 0) {
    throw "$BarmanVm is not reachable through Vagrant."
}

Write-Host "==> Running Barman health check"

Invoke-VagrantCommand `
    -Vm $BarmanVm `
    -Command "sudo -u barman barman check $ServerName"

Write-Host "==> Finding latest backup"

$BackupIds = @(
    Invoke-VagrantCommand `
        -Vm $BarmanVm `
        -Command "sudo -u barman barman list-backups $ServerName --minimal"
)

if ($BackupIds.Count -eq 0) {
    throw "No backups found for $ServerName"
}

$BackupId = $BackupIds[0].Trim()

if ([string]::IsNullOrWhiteSpace($BackupId)) {
    throw "Unable to determine latest backup ID"
}

Write-Host "==> Latest backup: $BackupId"

Write-Host "==> Checking backup status"

$StatusCommand = "sudo -u barman barman show-backup $ServerName $BackupId | grep -Eq '^[[:space:]]*Status[[:space:]]*:[[:space:]]*DONE[[:space:]]*$'"

& vagrant ssh $BarmanVm -c $StatusCommand -- -T

if ($LASTEXITCODE -ne 0) {
    & vagrant ssh $BarmanVm `
        -c "sudo -u barman barman show-backup $ServerName $BackupId" `
        -- -T

    throw "Backup $BackupId is not in DONE state"
}

Write-Host "==> Checking backup with barman verify-backup"

Invoke-VagrantCommand `
    -Vm $BarmanVm `
    -Command "sudo -u barman barman verify-backup $ServerName $BackupId"

Write-Host "==> Backup details"

Invoke-VagrantCommand `
    -Vm $BarmanVm `
    -Command "sudo -u barman barman show-backup $ServerName $BackupId"

Write-Host ""
Write-Host "========================================="
Write-Host " BACKUP VERIFICATION: PASS"
Write-Host "========================================="
Write-Host "Server: $ServerName"
Write-Host "Backup: $BackupId"
Write-Host "Status: DONE"