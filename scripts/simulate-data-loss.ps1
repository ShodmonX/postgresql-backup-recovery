$ErrorActionPreference = "Stop"

$PrimaryVm  = "pg-primary"
$BarmanVm   = "barman"
$ServerName = "pg-primary"
$DbName     = "recovery_demo"

$RepoRoot   = Split-Path -Parent $PSScriptRoot
$TargetFile = Join-Path $RepoRoot ".recovery-target"


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


Write-Host "==> Starting data-loss simulation"


# ------------------------------------------------------------
# Verify primary is reachable
# ------------------------------------------------------------

Write-Host "==> Checking $PrimaryVm"

& vagrant ssh $PrimaryVm -c "hostname" -- -T *> $null

if ($LASTEXITCODE -ne 0) {
    throw "$PrimaryVm is not reachable through Vagrant. Run 'vagrant up' first."
}


# ------------------------------------------------------------
# Verify demo data exists
# ------------------------------------------------------------

Write-Host "==> Verifying demo data"

$RowCount = (
    Invoke-VagrantCommand `
        -Vm $PrimaryVm `
        -Command "sudo -u postgres psql $DbName -Atqc 'SELECT count(*) FROM customer_orders;'"
).Trim()

if ($RowCount -ne "3") {
    throw "Expected 3 rows before data-loss simulation, found '$RowCount'. Run setup-demo first."
}

Write-Host "==> Demo rows before data loss: $RowCount"


# ------------------------------------------------------------
# Force WAL boundary before recovery target
# ------------------------------------------------------------

Write-Host "==> Switching WAL before recovery target"

Invoke-VagrantCommand `
    -Vm $PrimaryVm `
    -Command "sudo -u postgres psql -Atqc 'SELECT pg_switch_wal();'" `
    | Out-Null


# ------------------------------------------------------------
# Record recovery target
# ------------------------------------------------------------

$RecoveryTarget = (
    Invoke-VagrantCommand `
        -Vm $PrimaryVm `
        -Command "sudo -u postgres psql $DbName -Atqc 'SELECT clock_timestamp();'"
).Trim()

if ([string]::IsNullOrWhiteSpace($RecoveryTarget)) {
    throw "Failed to obtain recovery target timestamp"
}

Set-Content `
    -Path $TargetFile `
    -Value $RecoveryTarget `
    -Encoding ASCII

Write-Host "==> Recovery target recorded:"
Write-Host $RecoveryTarget
Write-Host "==> Saved to: $TargetFile"


# ------------------------------------------------------------
# Ensure bad transaction occurs after recovery target
# ------------------------------------------------------------

Start-Sleep -Seconds 3


# ------------------------------------------------------------
# Simulate accidental data loss
# ------------------------------------------------------------

Write-Host "==> Simulating accidental data loss"

Invoke-VagrantCommand `
    -Vm $PrimaryVm `
    -Command "sudo -u postgres psql -v ON_ERROR_STOP=1 $DbName -c 'DELETE FROM customer_orders;'"


# ------------------------------------------------------------
# Verify data was deleted
# ------------------------------------------------------------

$RemainingRows = (
    Invoke-VagrantCommand `
        -Vm $PrimaryVm `
        -Command "sudo -u postgres psql $DbName -Atqc 'SELECT count(*) FROM customer_orders;'"
).Trim()

if ($RemainingRows -ne "0") {
    throw "Data-loss simulation failed. Expected 0 rows, found '$RemainingRows'"
}

Write-Host "==> Remaining rows: $RemainingRows"


# ------------------------------------------------------------
# Force WAL containing DELETE to archive
# ------------------------------------------------------------

Write-Host "==> Switching and archiving WAL after data loss"

Invoke-VagrantCommand `
    -Vm $BarmanVm `
    -Command "sudo -u barman barman switch-wal --force --archive --archive-timeout 30 $ServerName"


Write-Host ""
Write-Host "========================================="
Write-Host " DATA LOSS SIMULATION: PASS"
Write-Host "========================================="
Write-Host "Database:        $DbName"
Write-Host "Rows before:     $RowCount"
Write-Host "Rows after:      $RemainingRows"
Write-Host "Recovery target: $RecoveryTarget"