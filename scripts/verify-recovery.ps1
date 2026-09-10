$ErrorActionPreference = "Stop"

$RecoveryVm = "pg-recovery"
$DbName     = "recovery_demo"

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


Write-Host "==> Verifying PostgreSQL recovery result"


# ------------------------------------------------------------
# Verify recovery VM is reachable
# ------------------------------------------------------------

Write-Host "==> Checking $RecoveryVm"

& vagrant ssh $RecoveryVm -c "hostname" -- -T *> $null

if ($LASTEXITCODE -ne 0) {
    throw "$RecoveryVm is not reachable through Vagrant."
}


# ------------------------------------------------------------
# Verify PostgreSQL service
# ------------------------------------------------------------

Write-Host "==> Checking PostgreSQL service"

$ServiceState = (
    Invoke-VagrantCommand `
        -Vm $RecoveryVm `
        -Command "systemctl is-active postgresql"
).Trim()

if ($ServiceState -ne "active") {
    throw "PostgreSQL service is not active. Current state: '$ServiceState'"
}

Write-Host "==> PostgreSQL service: active"


# ------------------------------------------------------------
# Verify PostgreSQL accepts connections
# ------------------------------------------------------------

Write-Host "==> Checking PostgreSQL connectivity"

$PgReady = (
    Invoke-VagrantCommand `
        -Vm $RecoveryVm `
        -Command "pg_isready -q && echo READY"
).Trim()

if ($PgReady -ne "READY") {
    throw "PostgreSQL is not accepting connections."
}

Write-Host "==> PostgreSQL connectivity: OK"


# ------------------------------------------------------------
# Verify recovery has completed
# ------------------------------------------------------------

Write-Host "==> Checking recovery state"

$RecoveryState = (
    Invoke-VagrantCommand `
        -Vm $RecoveryVm `
        -Command "sudo -u postgres psql -Atqc 'SELECT pg_is_in_recovery();'"
).Trim()

if ($RecoveryState -ne "f") {
    throw "PostgreSQL is still in recovery mode. pg_is_in_recovery() = '$RecoveryState'"
}

Write-Host "==> Recovery state: completed"


# ------------------------------------------------------------
# Verify demo database exists
# ------------------------------------------------------------

Write-Host "==> Checking database $DbName"

$DatabaseList = @(
    Invoke-VagrantCommand `
        -Vm $RecoveryVm `
        -Command "sudo -u postgres psql -Atqc 'SELECT datname FROM pg_database;'"
)

if ($DatabaseList -notcontains $DbName) {
    throw "Database '$DbName' does not exist on $RecoveryVm."
}

Write-Host "==> Database $DbName`: found"


# ------------------------------------------------------------
# Verify expected row count
# ------------------------------------------------------------

Write-Host "==> Checking recovered row count"

$RowCount = (
    Invoke-VagrantCommand `
        -Vm $RecoveryVm `
        -Command "sudo -u postgres psql $DbName -Atqc 'SELECT count(*) FROM customer_orders;'"
).Trim()

if ($RowCount -ne "3") {
    throw "Expected 3 recovered rows, found '$RowCount'."
}

Write-Host "==> Recovered rows: $RowCount"


# ------------------------------------------------------------
# Verify exact expected demo data
# ------------------------------------------------------------

Write-Host "==> Checking expected demo records"

$ExpectedDataSql = @"
SELECT count(*)
FROM customer_orders
WHERE (customer, amount) IN (
    ('Alice', 125.50),
    ('Bob', 890.00),
    ('Charlie', 42.75)
);
"@

$ExpectedDataSql = $ExpectedDataSql -replace "`r`n", "`n"
$ExpectedDataSql = $ExpectedDataSql -replace "`r", "`n"

$ExpectedDataBase64 = [Convert]::ToBase64String(
    [System.Text.Encoding]::UTF8.GetBytes($ExpectedDataSql)
)

$ExpectedRowCount = (
    Invoke-VagrantCommand `
        -Vm $RecoveryVm `
        -Command "echo $ExpectedDataBase64 | base64 -d | sudo -u postgres psql $DbName -Atq"
).Trim()

if ($ExpectedRowCount -ne "3") {
    throw "Recovered data does not match the expected demo records."
}

Write-Host "==> Expected demo records: OK"


# ------------------------------------------------------------
# Verify instance is writable
# ------------------------------------------------------------

Write-Host "==> Checking write capability"

$WriteTestCommand = @"
sudo -u postgres psql -v ON_ERROR_STOP=1 $DbName -c '
BEGIN;
CREATE TABLE __recovery_write_probe (
    id integer
);
ROLLBACK;
'
"@

$WriteTestNormalized = $WriteTestCommand -replace "`r`n", "`n"
$WriteTestNormalized = $WriteTestNormalized -replace "`r", "`n"

$WriteTestBase64 = [Convert]::ToBase64String(
    [System.Text.Encoding]::UTF8.GetBytes($WriteTestNormalized)
)

& vagrant ssh $RecoveryVm `
    -c "echo $WriteTestBase64 | base64 -d | bash" `
    -- -T

if ($LASTEXITCODE -ne 0) {
    throw "Recovery instance is not writable."
}

Write-Host "==> Write capability: OK"


# ------------------------------------------------------------
# Display recovered data
# ------------------------------------------------------------

Write-Host "==> Recovered data"

Invoke-VagrantCommand `
    -Vm $RecoveryVm `
    -Command "sudo -u postgres psql $DbName -c 'SELECT id, customer, amount, created_at FROM customer_orders ORDER BY id;'"


# ------------------------------------------------------------
# Final result
# ------------------------------------------------------------

Write-Host ""
Write-Host "========================================="
Write-Host " RECOVERY VERIFICATION: PASS"
Write-Host "========================================="
Write-Host "Node:            $RecoveryVm"
Write-Host "PostgreSQL:      active"
Write-Host "Recovery mode:   false"
Write-Host "Database:        $DbName"
Write-Host "Recovered rows:  $RowCount"
Write-Host "Expected data:   verified"
Write-Host "Writable:        yes"