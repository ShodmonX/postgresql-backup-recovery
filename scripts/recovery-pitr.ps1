$ErrorActionPreference = "Stop"

$BarmanVm     = "barman"
$RecoveryVm   = "pg-recovery"
$ServerName   = "pg-primary"
$DbName       = "recovery_demo"
$RecoveryData = "/var/lib/postgresql/16/main"

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

function ConvertTo-LinuxBase64 {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    # Windows CRLF / CR -> Unix LF
    $Normalized = $Text -replace "`r`n", "`n"
    $Normalized = $Normalized -replace "`r", "`n"

    $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Normalized)

    return [Convert]::ToBase64String($Bytes)
}

# ------------------------------------------------------------
# Read recovery target
# ------------------------------------------------------------

if (-not (Test-Path $TargetFile)) {
    throw "$TargetFile not found. Run simulate-data-loss.ps1 first."
}

$RecoveryTarget = (Get-Content $TargetFile -Raw).Trim()

if ([string]::IsNullOrWhiteSpace($RecoveryTarget)) {
    throw "Recovery target is empty."
}

Write-Host "==> Recovery target: $RecoveryTarget"


# ------------------------------------------------------------
# Verify required VMs
# ------------------------------------------------------------

foreach ($Vm in @($BarmanVm, $RecoveryVm)) {
    Write-Host "==> Checking $Vm"

    & vagrant ssh $Vm -c "hostname" -- -T *> $null

    if ($LASTEXITCODE -ne 0) {
        throw "$Vm is not reachable through Vagrant. Run 'vagrant up' first."
    }
}


# ------------------------------------------------------------
# Process completed WAL segments
# ------------------------------------------------------------

Write-Host "==> Processing completed WAL segments on Barman"

Invoke-VagrantCommand `
    -Vm $BarmanVm `
    -Command "sudo -u barman barman archive-wal $ServerName" `
    | Out-Null


# ------------------------------------------------------------
# Select latest backup before recovery target
# ------------------------------------------------------------

Write-Host "==> Selecting latest backup before recovery target"

$BackupIds = @(
    Invoke-VagrantCommand `
        -Vm $BarmanVm `
        -Command "sudo -u barman barman list-backups $ServerName --minimal"
)

if ($BackupIds.Count -eq 0) {
    throw "No Barman backups found."
}

$TargetDate = [DateTimeOffset]::Parse($RecoveryTarget)

$BackupId = $null

foreach ($Candidate in $BackupIds) {
    $Candidate = $Candidate.Trim()

    if ($Candidate -notmatch '^\d{8}T\d{6}$') {
        continue
    }

    $CandidateDate = [DateTimeOffset]::ParseExact(
        $Candidate,
        "yyyyMMdd'T'HHmmss",
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::AssumeLocal
    )

    if ($CandidateDate -le $TargetDate) {
        $BackupId = $Candidate
        break
    }
}

if (-not $BackupId) {
    throw "No backup exists before recovery target $RecoveryTarget"
}

Write-Host "==> Selected backup: $BackupId"


# ------------------------------------------------------------
# Ensure Barman SSH key exists
# ------------------------------------------------------------

Write-Host "==> Ensuring Barman SSH key exists"

$CreateKeyCommand = @'
sudo install -d -o barman -g barman -m 700 /var/lib/barman/.ssh

if [ ! -f /var/lib/barman/.ssh/id_ed25519 ]; then
    sudo -u barman ssh-keygen \
        -q \
        -t ed25519 \
        -N '' \
        -f /var/lib/barman/.ssh/id_ed25519
fi

if [ ! -f /var/lib/barman/.ssh/id_ed25519.pub ]; then
    sudo -u barman sh -c \
        'ssh-keygen -y -f /var/lib/barman/.ssh/id_ed25519 > /var/lib/barman/.ssh/id_ed25519.pub'
fi
'@

$CreateKeyBase64 = ConvertTo-LinuxBase64 $CreateKeyCommand

Invoke-VagrantCommand `
    -Vm $BarmanVm `
    -Command "echo $CreateKeyBase64 | base64 -d | sudo bash" `
    | Out-Null


# ------------------------------------------------------------
# Retrieve public key
# ------------------------------------------------------------

Write-Host "==> Retrieving Barman SSH public key"

$PublicKeyOutput = @(
    Invoke-VagrantCommand `
        -Vm $BarmanVm `
        -Command "sudo -u barman cat /var/lib/barman/.ssh/id_ed25519.pub"
)

$PublicKey = (
    $PublicKeyOutput |
    Where-Object { $_ -match '^ssh-ed25519 ' } |
    Select-Object -First 1
)

if (-not $PublicKey) {
    throw "Barman SSH public key was not returned."
}

$PublicKey = $PublicKey.Trim()


# ------------------------------------------------------------
# Install key on recovery node
# ------------------------------------------------------------

Write-Host "==> Installing Barman public key on $RecoveryVm"

$InstallKeyCommand = @"
sudo install -d \
    -o postgres \
    -g postgres \
    -m 700 \
    /var/lib/postgresql/.ssh

sudo touch /var/lib/postgresql/.ssh/authorized_keys

sudo grep -qxF '$PublicKey' \
    /var/lib/postgresql/.ssh/authorized_keys \
    || echo '$PublicKey' \
    | sudo tee -a /var/lib/postgresql/.ssh/authorized_keys >/dev/null

sudo chown postgres:postgres \
    /var/lib/postgresql/.ssh/authorized_keys

sudo chmod 600 \
    /var/lib/postgresql/.ssh/authorized_keys
"@

$InstallKeyBase64 = ConvertTo-LinuxBase64 $InstallKeyCommand

Invoke-VagrantCommand `
    -Vm $RecoveryVm `
    -Command "echo $InstallKeyBase64 | base64 -d | sudo bash" `
    | Out-Null


# ------------------------------------------------------------
# Register recovery host key on Barman
# ------------------------------------------------------------

Write-Host "==> Registering $RecoveryVm SSH host key"

$KnownHostsCommand = @"
sudo -u barman touch /var/lib/barman/.ssh/known_hosts

sudo -u barman ssh-keygen \
    -R $RecoveryVm \
    -f /var/lib/barman/.ssh/known_hosts \
    >/dev/null 2>&1 || true

sudo -u barman sh -c \
    'ssh-keyscan -H $RecoveryVm >> /var/lib/barman/.ssh/known_hosts'

sudo chmod 600 /var/lib/barman/.ssh/known_hosts
"@

$KnownHostsBase64 = ConvertTo-LinuxBase64 $KnownHostsCommand

Invoke-VagrantCommand `
    -Vm $BarmanVm `
    -Command "echo $KnownHostsBase64 | base64 -d | sudo bash" `
    | Out-Null


# ------------------------------------------------------------
# Verify Barman -> recovery SSH
# ------------------------------------------------------------

Write-Host "==> Verifying Barman -> $RecoveryVm SSH"

$RemoteHostname = (
    Invoke-VagrantCommand `
        -Vm $BarmanVm `
        -Command "sudo -u barman ssh -o BatchMode=yes -o StrictHostKeyChecking=yes postgres@$RecoveryVm hostname"
).Trim()

if ($RemoteHostname -ne $RecoveryVm) {
    throw "Unexpected SSH verification response: '$RemoteHostname'"
}

Write-Host "==> SSH verification OK"


# ------------------------------------------------------------
# Prepare recovery node
# ------------------------------------------------------------

Write-Host "==> Preparing PostgreSQL recovery node"

$PrepareRecoveryCommand = @"
sudo systemctl stop postgresql

if systemctl is-active --quiet postgresql; then
    echo 'ERROR: PostgreSQL is still running'
    exit 1
fi

sudo rm -rf '$RecoveryData'

sudo install \
    -d \
    -o postgres \
    -g postgres \
    -m 700 \
    '$RecoveryData'
"@

$PrepareBase64 = ConvertTo-LinuxBase64 $PrepareRecoveryCommand

Invoke-VagrantCommand `
    -Vm $RecoveryVm `
    -Command "echo $PrepareBase64 | base64 -d | sudo bash" `
    | Out-Null


# ------------------------------------------------------------
# Perform Barman PITR
# ------------------------------------------------------------

Write-Host "==> Starting Barman PITR"

$RecoverCommand = "sudo -u barman barman recover --remote-ssh-command 'ssh -o BatchMode=yes -o StrictHostKeyChecking=yes postgres@$RecoveryVm' --target-time '$RecoveryTarget' --target-action pause --no-get-wal $ServerName '$BackupId' '$RecoveryData'"

Invoke-VagrantCommand `
    -Vm $BarmanVm `
    -Command $RecoverCommand


# ------------------------------------------------------------
# Start recovered PostgreSQL
# ------------------------------------------------------------

Write-Host "==> Starting recovered PostgreSQL"

Invoke-VagrantCommand `
    -Vm $RecoveryVm `
    -Command "sudo systemctl start postgresql" `
    | Out-Null


# ------------------------------------------------------------
# Wait until PITR target is reached
# ------------------------------------------------------------

Write-Host "==> Waiting for PostgreSQL to reach PITR target"

$WaitCommand = @'
for i in $(seq 1 60); do
    state=$(sudo -u postgres psql -Atqc "SELECT pg_is_wal_replay_paused();" 2>/dev/null || true)

    if [ "$state" = "t" ]; then
        echo PITR_PAUSED
        exit 0
    fi

    sleep 1
done

echo PITR_TIMEOUT
exit 1
'@

$WaitBase64 = ConvertTo-LinuxBase64 $WaitCommand

$WaitOutput = @(
    & vagrant ssh $RecoveryVm `
        -c "echo $WaitBase64 | base64 -d | bash" `
        -- -T
)

if ($LASTEXITCODE -ne 0) {
    Write-Host "==> PostgreSQL did not reach PITR target"

    & vagrant ssh $RecoveryVm `
        -c "sudo tail -n 100 /var/log/postgresql/postgresql-16-main.log" `
        -- -T

    throw "Recovery target was not reached within timeout."
}

if ($WaitOutput -notcontains "PITR_PAUSED") {
    throw "Unexpected PITR wait result."
}

Write-Host "==> Recovery reached target and WAL replay is paused"


# ------------------------------------------------------------
# Verify recovered demo data before promotion
# ------------------------------------------------------------

Write-Host "==> Verifying recovered demo data"

$RecoveredRows = (
    Invoke-VagrantCommand `
        -Vm $RecoveryVm `
        -Command "sudo -u postgres psql $DbName -Atqc 'SELECT count(*) FROM customer_orders;'"
).Trim()

if ($RecoveredRows -ne "3") {
    Write-Host "ERROR: Expected 3 recovered rows, found '$RecoveredRows'"

    & vagrant ssh $RecoveryVm `
        -c "sudo -u postgres psql $DbName -c 'SELECT id, customer, amount, created_at FROM customer_orders ORDER BY id;'" `
        -- -T

    throw "PITR verification failed."
}

Invoke-VagrantCommand `
    -Vm $RecoveryVm `
    -Command "sudo -u postgres psql $DbName -c 'SELECT id, customer, amount, created_at FROM customer_orders ORDER BY id;'"


# ------------------------------------------------------------
# Resume replay and promote
# ------------------------------------------------------------

Write-Host "==> Resuming WAL replay"

Invoke-VagrantCommand `
    -Vm $RecoveryVm `
    -Command "sudo -u postgres psql -c 'SELECT pg_wal_replay_resume();'" `
    | Out-Null


Write-Host "==> Waiting for recovery completion"

$PromotionWaitCommand = @'
for i in $(seq 1 30); do
    state=$(sudo -u postgres psql -Atqc "SELECT pg_is_in_recovery();" 2>/dev/null || true)

    if [ "$state" = "f" ]; then
        echo PROMOTED
        exit 0
    fi

    sleep 1
done

echo PROMOTION_TIMEOUT
exit 1
'@

$PromotionBase64 = ConvertTo-LinuxBase64 $PromotionWaitCommand

$PromotionOutput = @(
    & vagrant ssh $RecoveryVm `
        -c "echo $PromotionBase64 | base64 -d | bash" `
        -- -T
)

if ($LASTEXITCODE -ne 0) {
    & vagrant ssh $RecoveryVm `
        -c "sudo tail -n 100 /var/log/postgresql/postgresql-16-main.log" `
        -- -T

    throw "Recovery node was not promoted within timeout."
}

if ($PromotionOutput -notcontains "PROMOTED") {
    throw "Unexpected promotion result."
}


# ------------------------------------------------------------
# Final verification
# ------------------------------------------------------------

$RecoveryState = (
    Invoke-VagrantCommand `
        -Vm $RecoveryVm `
        -Command "sudo -u postgres psql -Atqc 'SELECT pg_is_in_recovery();'"
).Trim()

if ($RecoveryState -ne "f") {
    throw "Recovery node is still in recovery mode."
}


Write-Host ""
Write-Host "========================================="
Write-Host " PITR WORKFLOW: PASS"
Write-Host "========================================="
Write-Host "Backup:          $BackupId"
Write-Host "Recovery target: $RecoveryTarget"
Write-Host "Recovered rows:  $RecoveredRows"
Write-Host "Recovery node:   $RecoveryVm"
Write-Host "Status:          promoted and writable"