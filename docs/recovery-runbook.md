# Recovery Runbook

## Objective

Recover the demo database to a timestamp immediately before a simulated destructive transaction, using an isolated recovery node.

## Preconditions

Verify infrastructure first:

```powershell
.\tests\smoke-test.ps1
```

At least one valid base backup must exist before the recovery target.

## 1. Create deterministic demo data

Windows:

```powershell
.\scripts\setup-demo.ps1
```

Linux/macOS:

```bash
./scripts/setup-demo.sh
```

Expected rows:

```text
Alice    125.50
Bob      890.00
Charlie   42.75
```

## 2. Take a base backup

```powershell
.\scripts\backup.ps1
```

or:

```bash
./scripts/backup.sh
```

Expected final status:

```text
Status: DONE
```

## 3. Verify the backup

```powershell
.\scripts\verify-backup.ps1
```

or:

```bash
./scripts/verify-backup.sh
```

Do not continue with the destructive test if backup verification fails.

## 4. Simulate data loss

```powershell
.\scripts\simulate-data-loss.ps1
```

or:

```bash
./scripts/simulate-data-loss.sh
```

The script confirms the demo rows, records a timestamp into `.recovery-target`, waits briefly, deletes all rows, verifies zero remain, and pushes the post-incident WAL through the backup pipeline.

## 5. Optional infrastructure check after incident

```powershell
.\tests\smoke-test.ps1
```

The smoke test checks infrastructure, not demo-table contents, so it should still pass.

## 6. Run PITR

```powershell
.\scripts\recovery-pitr.ps1
```

or:

```bash
./scripts/recovery-pitr.sh
```

The validated PowerShell workflow:

1. reads `.recovery-target`;
2. validates Barman and recovery-node reachability;
3. processes completed WAL;
4. selects a usable backup from before the target;
5. establishes Barman-to-recovery SSH access;
6. stops PostgreSQL on `pg-recovery`;
7. replaces the recovery `PGDATA`;
8. runs Barman recovery to the target with pause behavior;
9. starts PostgreSQL;
10. waits for the target pause;
11. verifies the expected rows;
12. resumes WAL replay;
13. waits for recovery completion;
14. confirms the recovered node is writable.

The primary is not overwritten.

## 7. Independently verify recovery

```powershell
.\scripts\verify-recovery.ps1
```

or:

```bash
./scripts/verify-recovery.sh
```

The script validates service state, connectivity, completed recovery, database existence, expected rows, exact demo values, and write capability.

## Expected result

```text
PITR WORKFLOW: PASS
RECOVERY VERIFICATION: PASS
```

## Configuration warning

Barman may warn that `postgresql.conf`, `pg_hba.conf`, and `pg_ident.conf` were not restored because Ubuntu/Debian packages place them outside `PGDATA`.

The lab recovery VM is provisioned with PostgreSQL beforehand. A production runbook should include a separate configuration-backup/restore procedure.

## Resetting the lab

```powershell
vagrant destroy -f
vagrant up
```

Then restart from the infrastructure smoke test.
