$ErrorActionPreference = "Stop"

$VmName = "pg-primary"
$DbName = "recovery_demo"

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

Write-Host "==> Setting up PITR demo data on $VmName"

# ------------------------------------------------------------
# Verify VM is reachable
# ------------------------------------------------------------

Write-Host "==> Checking $VmName"

& vagrant ssh $VmName -c "hostname" -- -T *> $null

if ($LASTEXITCODE -ne 0) {
    throw "$VmName is not reachable through Vagrant. Run 'vagrant up' first."
}

# ------------------------------------------------------------
# Create demo database if it does not exist
# ------------------------------------------------------------

Write-Host "==> Ensuring database $DbName exists"

$DbListCommand = "sudo -u postgres psql -Atqc 'SELECT datname FROM pg_database;'"

$DatabaseList = @(
    Invoke-VagrantCommand `
        -Vm $VmName `
        -Command $DbListCommand
)

if ($DatabaseList -notcontains $DbName) {
    Write-Host "==> Creating database $DbName"

    Invoke-VagrantCommand `
        -Vm $VmName `
        -Command "sudo -u postgres createdb $DbName" `
        | Out-Null
}

# ------------------------------------------------------------
# Create deterministic demo data
# ------------------------------------------------------------

Write-Host "==> Creating demo table and data"

$SetupSql = @"
CREATE TABLE IF NOT EXISTS customer_orders (
    id bigserial PRIMARY KEY,
    customer text NOT NULL,
    amount numeric(12,2) NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

TRUNCATE TABLE customer_orders RESTART IDENTITY;

INSERT INTO customer_orders (customer, amount)
VALUES
    ('Alice', 125.50),
    ('Bob', 890.00),
    ('Charlie', 42.75);

SELECT * FROM customer_orders ORDER BY id;
"@

$SqlBytes = [System.Text.Encoding]::UTF8.GetBytes($SetupSql)
$SqlBase64 = [Convert]::ToBase64String($SqlBytes)

$SetupCommand = "echo $SqlBase64 | base64 -d | sudo -u postgres psql -v ON_ERROR_STOP=1 $DbName"

Invoke-VagrantCommand `
    -Vm $VmName `
    -Command $SetupCommand

# ------------------------------------------------------------
# Verify expected row count
# ------------------------------------------------------------

$CountCommand = "sudo -u postgres psql $DbName -Atqc 'SELECT count(*) FROM customer_orders;'"

$RowCount = (
    Invoke-VagrantCommand `
        -Vm $VmName `
        -Command $CountCommand
).Trim()

if ($RowCount -ne "3") {
    throw "Expected 3 demo rows, found '$RowCount'"
}

Write-Host ""
Write-Host "========================================="
Write-Host " DEMO SETUP: PASS"
Write-Host "========================================="
Write-Host "Database: $DbName"
Write-Host "Table: customer_orders"
Write-Host "Rows: $RowCount"