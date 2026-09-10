$ErrorActionPreference = "Stop"

$BarmanVm = "barman"
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

function ConvertTo-LinuxBase64 {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $Normalized = $Text -replace "`r`n", "`n"
    $Normalized = $Normalized -replace "`r", "`n"

    $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Normalized)

    return [Convert]::ToBase64String($Bytes)
}

function Invoke-BarmanSql {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Sql
    )

    $SqlBase64 = ConvertTo-LinuxBase64 $Sql

    $Command = "echo $SqlBase64 | base64 -d | sudo -u barman psql 'host=pg-primary port=5432 user=barman dbname=postgres' -v ON_ERROR_STOP=1 -Atq"

    Invoke-VagrantCommand `
        -Vm $BarmanVm `
        -Command $Command
}

Write-Host "==> Starting PostgreSQL backup workflow"


# ------------------------------------------------------------
# Verify Barman VM is reachable
# ------------------------------------------------------------

Write-Host "==> Checking $BarmanVm"

& vagrant ssh $BarmanVm -c "hostname" -- -T *> $null

if ($LASTEXITCODE -ne 0) {
    throw "$BarmanVm is not reachable through Vagrant. Run 'vagrant up' first."
}


# ------------------------------------------------------------
# Verify PostgreSQL management connectivity
# ------------------------------------------------------------

Write-Host "==> Checking PostgreSQL connectivity from Barman"

Invoke-VagrantCommand `
    -Vm $BarmanVm `
    -Command "sudo -u barman psql 'host=pg-primary port=5432 user=barman dbname=postgres' -Atc 'SELECT 1;' >/dev/null"


# ------------------------------------------------------------
# Verify receive-wal process
# ------------------------------------------------------------

Write-Host "==> Checking Barman receive-wal"

Invoke-VagrantCommand `
    -Vm $BarmanVm `
    -Command "pgrep -u barman -f 'receive-wal $ServerName' >/dev/null"


# ------------------------------------------------------------
# Generate and archive a complete WAL segment
# ------------------------------------------------------------

Write-Host "==> Preparing WAL archive"

# Close the segment that receive-wal may have joined partially.
Invoke-BarmanSql -Sql @'
SELECT pg_switch_wal();
'@ | Out-Null

# Generate WAL activity in the new segment.
Invoke-BarmanSql -Sql @'
SELECT pg_create_restore_point('backup_workflow');
'@ | Out-Null

# Close the fully streamed segment.
Invoke-BarmanSql -Sql @'
SELECT pg_switch_wal();
'@ | Out-Null


# ------------------------------------------------------------
# Archive WAL
# ------------------------------------------------------------

Write-Host "==> Archiving WAL"

Invoke-VagrantCommand `
    -Vm $BarmanVm `
    -Command "sudo -u barman barman archive-wal $ServerName"


# ------------------------------------------------------------
# Verify Barman health after WAL pipeline is initialized
# ------------------------------------------------------------

Write-Host "==> Checking Barman"

Invoke-VagrantCommand `
    -Vm $BarmanVm `
    -Command "sudo -u barman barman check $ServerName"


# ------------------------------------------------------------
# Run backup
# ------------------------------------------------------------

Write-Host "==> Starting Barman backup"

Invoke-VagrantCommand `
    -Vm $BarmanVm `
    -Command "sudo -u barman barman backup --wait $ServerName"


# ------------------------------------------------------------
# Get latest backup ID
# ------------------------------------------------------------

$BackupIds = @(
    Invoke-VagrantCommand `
        -Vm $BarmanVm `
        -Command "sudo -u barman barman list-backups $ServerName --minimal"
)

if ($BackupIds.Count -eq 0) {
    throw "Unable to determine backup ID"
}

$BackupId = $BackupIds[0].Trim()

Write-Host "==> Backup ID: $BackupId"


# ------------------------------------------------------------
# Verify backup status
# ------------------------------------------------------------

Write-Host "==> Verifying backup"

$VerifyCommand = "sudo -u barman barman show-backup $ServerName $BackupId | grep -Eq '^[[:space:]]*Status[[:space:]]*:[[:space:]]*DONE[[:space:]]*$'"

& vagrant ssh $BarmanVm -c $VerifyCommand -- -T

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Backup $BackupId is not in DONE state"

    & vagrant ssh $BarmanVm `
        -c "sudo -u barman barman show-backup $ServerName $BackupId" `
        -- -T

    throw "Backup verification failed"
}


# ------------------------------------------------------------
# Display backup
# ------------------------------------------------------------

Invoke-VagrantCommand `
    -Vm $BarmanVm `
    -Command "sudo -u barman barman show-backup $ServerName $BackupId"


Write-Host ""
Write-Host "========================================="
Write-Host " BACKUP WORKFLOW: PASS"
Write-Host "========================================="
Write-Host "Server: $ServerName"
Write-Host "Backup: $BackupId"
Write-Host "Status: DONE"