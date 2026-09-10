$ErrorActionPreference = "Stop"

$PrimaryVm      = "pg-primary"
$ReplicaVm      = "pg-replica"
$BarmanVm       = "barman"
$RecoveryVm     = "pg-recovery"
$ServerName     = "pg-primary"

$ReplicaUser    = "replicator"
$ReplicaAddress = "192.168.167.202"
$ReplicaSlot    = "pg_replica_slot"
$BarmanSlot     = "barman_wal_slot"

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

function Invoke-PsqlQuery {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Vm,

        [Parameter(Mandatory = $true)]
        [string]$Sql,

        [string]$Database = "postgres"
    )

    $SqlBase64 = ConvertTo-LinuxBase64 $Sql
    $Command = "echo $SqlBase64 | base64 -d | sudo -u postgres psql -v ON_ERROR_STOP=1 -d $Database -Atq"

    return Invoke-VagrantCommand -Vm $Vm -Command $Command
}

function Test-VmReachable {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Vm
    )

    & vagrant ssh $Vm -c "hostname" -- -T *> $null

    if ($LASTEXITCODE -ne 0) {
        throw "VM '$Vm' is not reachable through Vagrant."
    }

    Write-Host "    $Vm`: OK"
}

Write-Host ""
Write-Host "========================================="
Write-Host " INFRASTRUCTURE SMOKE TEST"
Write-Host "========================================="

# ------------------------------------------------------------
# 1. VM reachability
# ------------------------------------------------------------

Write-Host ""
Write-Host "==> [1/6] Checking VM reachability"

Test-VmReachable $PrimaryVm
Test-VmReachable $ReplicaVm
Test-VmReachable $BarmanVm
Test-VmReachable $RecoveryVm

# ------------------------------------------------------------
# 2. Primary PostgreSQL
# ------------------------------------------------------------

Write-Host ""
Write-Host "==> [2/6] Checking PostgreSQL primary"

$PrimaryReady = (
    Invoke-VagrantCommand `
        -Vm $PrimaryVm `
        -Command "pg_isready -q && echo READY"
).Trim()

if ($PrimaryReady -ne "READY") {
    throw "PostgreSQL primary is not accepting connections."
}

$PrimaryRecoveryState = (
    Invoke-PsqlQuery `
        -Vm $PrimaryVm `
        -Sql "SELECT pg_is_in_recovery();"
).Trim()

if ($PrimaryRecoveryState -ne "f") {
    throw "$PrimaryVm is unexpectedly in recovery mode."
}

Write-Host "    PostgreSQL: ready"
Write-Host "    Role: primary"

# ------------------------------------------------------------
# 3. Replica PostgreSQL
# ------------------------------------------------------------

Write-Host ""
Write-Host "==> [3/6] Checking PostgreSQL replica"

$ReplicaReady = (
    Invoke-VagrantCommand `
        -Vm $ReplicaVm `
        -Command "pg_isready -q && echo READY"
).Trim()

if ($ReplicaReady -ne "READY") {
    throw "PostgreSQL replica is not accepting connections."
}

$ReplicaRecoveryState = (
    Invoke-PsqlQuery `
        -Vm $ReplicaVm `
        -Sql "SELECT pg_is_in_recovery();"
).Trim()

if ($ReplicaRecoveryState -ne "t") {
    throw "$ReplicaVm is not operating as a standby."
}

Write-Host "    PostgreSQL: ready"
Write-Host "    Recovery mode: true"

# ------------------------------------------------------------
# 4. Streaming replication
# ------------------------------------------------------------

Write-Host ""
Write-Host "==> [4/6] Checking streaming replication"

$StreamingSql = @"
SELECT count(*)
FROM pg_stat_replication
WHERE usename = '$ReplicaUser'
  AND client_addr = inet '$ReplicaAddress'
  AND state = 'streaming';
"@

$StreamingReplicaCount = (
    Invoke-PsqlQuery `
        -Vm $PrimaryVm `
        -Sql $StreamingSql
).Trim()

if ($StreamingReplicaCount -ne "1") {
    throw "Expected one streaming replica from $ReplicaAddress using user '$ReplicaUser', found '$StreamingReplicaCount'."
}

$SyncStateSql = @"
SELECT sync_state
FROM pg_stat_replication
WHERE usename = '$ReplicaUser'
  AND client_addr = inet '$ReplicaAddress'
LIMIT 1;
"@

$ReplicaSyncState = (
    Invoke-PsqlQuery `
        -Vm $PrimaryVm `
        -Sql $SyncStateSql
).Trim()

Write-Host "    Replica address: $ReplicaAddress"
Write-Host "    Streaming state: streaming"
Write-Host "    Sync state: $ReplicaSyncState"

# ------------------------------------------------------------
# 5. Replication slots
# ------------------------------------------------------------

Write-Host ""
Write-Host "==> [5/6] Checking replication slots"

$ReplicaSlotSql = @"
SELECT slot_type || ':' || active
FROM pg_replication_slots
WHERE slot_name = '$ReplicaSlot';
"@

$ReplicaSlotState = (
    Invoke-PsqlQuery `
        -Vm $PrimaryVm `
        -Sql $ReplicaSlotSql
).Trim()

if ($ReplicaSlotState -ne "physical:true") {
    throw "Replication slot '$ReplicaSlot' is missing, inactive, or not physical. Current state: '$ReplicaSlotState'"
}

$BarmanSlotSql = @"
SELECT slot_type || ':' || active
FROM pg_replication_slots
WHERE slot_name = '$BarmanSlot';
"@

$BarmanSlotState = (
    Invoke-PsqlQuery `
        -Vm $PrimaryVm `
        -Sql $BarmanSlotSql
).Trim()

if ($BarmanSlotState -ne "physical:true") {
    throw "Replication slot '$BarmanSlot' is missing, inactive, or not physical. Current state: '$BarmanSlotState'"
}

Write-Host "    ${ReplicaSlot}: OK (physical, active)"
Write-Host "    ${BarmanSlot}: OK (physical, active)"

# ------------------------------------------------------------
# 6. Barman + recovery-node baseline state
# ------------------------------------------------------------

Write-Host ""
Write-Host "==> [6/6] Checking Barman and recovery-node baseline"

# Verify Barman management connection to PostgreSQL
$BarmanConnection = (
    Invoke-VagrantCommand `
        -Vm $BarmanVm `
        -Command "sudo -u barman psql 'host=pg-primary port=5432 user=barman dbname=postgres' -Atc 'SELECT 1;'"
).Trim()

if ($BarmanConnection -ne "1") {
    throw "Barman cannot connect to $ServerName."
}

Write-Host "    Barman PostgreSQL connection: OK"

# Verify receive-wal process
& vagrant ssh $BarmanVm `
    -c "pgrep -u barman -f 'receive-wal $ServerName' >/dev/null" `
    -- -T

if ($LASTEXITCODE -ne 0) {
    throw "Barman receive-wal process is not running."
}

Write-Host "    Barman receive-wal: running"

# Optional informational status.
# WAL archive may legitimately be FAILED on a fresh deployment
# before the first complete WAL segment has been archived.
& vagrant ssh $BarmanVm `
    -c "sudo -u barman barman check $ServerName || true" `
    -- -T

# Check recovery-node baseline state
$RecoveryServiceState = (
    Invoke-VagrantCommand `
        -Vm $RecoveryVm `
        -Command "systemctl is-active postgresql || true"
).Trim()

if ($RecoveryServiceState -eq "active") {

    Write-Host "    Recovery PostgreSQL: active"
    Write-Host "    Note: recovery node has already been used or manually started"
}
elseif ($RecoveryServiceState -eq "inactive") {

    Write-Host "    Recovery PostgreSQL: inactive"
    Write-Host "    Baseline recovery state: ready for restore"
}
elseif ($RecoveryServiceState -eq "failed") {

    throw "PostgreSQL service is in failed state on $RecoveryVm."
}
else {

    throw "Unexpected PostgreSQL service state on $RecoveryVm`: '$RecoveryServiceState'"
}

Write-Host ""
Write-Host "========================================="
Write-Host " INFRASTRUCTURE SMOKE TEST: PASS"
Write-Host "========================================="
Write-Host "Primary:          OK"
Write-Host "Replica:          streaming ($ReplicaSyncState)"
Write-Host "Replica slot:     active"
Write-Host "Barman WAL slot:  active"
Write-Host "Barman:           ready"
Write-Host "Recovery node:    reachable"
Write-Host ""
Write-Host "Note: backup existence, WAL archival, and PITR results are"
Write-Host "      validated by backup, verify-backup, and verify-recovery workflows."