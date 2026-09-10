# Failure Scenarios

## Primary unavailable during provisioning

Replica or Barman provisioning waits for `pg-primary` and fails explicitly if PostgreSQL does not become available within the configured timeout.

## Replica base backup failure

Replica initialization retries `pg_basebackup`. Re-provisioning an existing standby detects `standby.signal` and skips destructive re-initialization.

## Missing replication slot

`pg_replica_slot` is created for the standby and `barman_wal_slot` for Barman. The smoke test checks both slots.

## Barman management connection failure

Provisioning validates Barman's PostgreSQL management connection. Typical causes include wrong credentials, missing `pg_hba.conf` rules, network/name-resolution problems, or primary unavailability.

## Barman receive-wal not running

Provisioning starts Barman background processing and verifies the WAL receiver process. The smoke test independently checks receive-wal health.

## Backup incomplete or invalid

`backup.*` requires the backup to reach `DONE`. `verify-backup.*` independently runs the Barman verification path backed by `pg_verifybackup`.

Do not intentionally simulate data loss before backup verification succeeds.

## Required WAL unavailable

PITR cannot reach the requested target if the required WAL chain is incomplete. The recovery workflow times out and surfaces PostgreSQL logs instead of silently succeeding.

## Recovery pauses at target

When `target-action = pause` is used, this state is expected:

```sql
pg_is_in_recovery() = true
pg_is_wal_replay_paused() = true
```

The workflow verifies recovered rows while paused, then resumes replay.

## Recovered data is incorrect

The recovery and independent verification workflows assert that all three expected demo records are present.

## Recovery node remains read-only

`verify-recovery.*` checks `pg_is_in_recovery()` and performs a transactional write probe which is rolled back.

## Configuration files absent from base backup

Ubuntu/Debian PostgreSQL configuration files are outside `PGDATA`, so Barman warns they were not part of the base backup. Production designs should back up configuration separately.

## Windows PowerShell Vagrant SSH hangs

PowerShell output capture can hang when a pseudo-TTY is allocated. Windows scripts use:

```text
-- -T
```

to disable pseudo-TTY allocation.

## CRLF breaks remote Bash

Multiline commands sent from PowerShell normalize CRLF to LF before Base64 transport to Linux guests, preventing `$'\r': command not found` errors.

## Smoke-test scope

The infrastructure smoke test intentionally does not require an existing backup or successful PITR. Backup integrity is handled by `verify-backup.*`; recovered data is handled by `verify-recovery.*`.
