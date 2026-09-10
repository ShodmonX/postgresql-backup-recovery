# Backup Strategy

## Purpose

The lab demonstrates PostgreSQL physical backups based on periodic base backups plus continuous WAL streaming to Barman.

A usable PITR chain requires:

```text
base backup + all required WAL up to the recovery target
```

## Barman configuration

```ini
backup_method = postgres
streaming_archiver = on
slot_name = barman_wal_slot
create_slot = auto
path_prefix = /usr/lib/postgresql/16/bin
retention_policy = REDUNDANCY 2
```

The normal standby uses the separate `pg_replica_slot`.

## Backup workflow

Windows:

```powershell
.\scripts\backup.ps1
```

Linux/macOS:

```bash
./scripts/backup.sh
```

The workflow prepares a WAL boundary, processes streamed WAL, checks Barman, runs `barman backup --wait`, obtains the resulting backup ID, verifies `Status: DONE`, and displays backup metadata.

## Backup verification

Windows:

```powershell
.\scripts\verify-backup.ps1
```

Linux/macOS:

```bash
./scripts/verify-backup.sh
```

The verification path checks the latest backup and invokes Barman verification, which uses PostgreSQL `pg_verifybackup`.

`path_prefix = /usr/lib/postgresql/16/bin` is configured so Barman can locate PostgreSQL client utilities.

## Retention policy

The current lab setting is:

```ini
retention_policy = REDUNDANCY 2
```

This is a lab default, not a production recommendation. Production retention should be derived from recovery history, RPO/RTO, database size, WAL generation, backup frequency, storage capacity, and compliance requirements.

## WAL retention considerations

Replication slots improve reliability but can also retain excessive WAL if a consumer stops advancing. Production monitoring should include slot activity, retained WAL, receive-wal health, and storage utilization.

## Configuration files outside PGDATA

Ubuntu/Debian packages store files such as:

```text
/etc/postgresql/16/main/postgresql.conf
/etc/postgresql/16/main/pg_hba.conf
/etc/postgresql/16/main/pg_ident.conf
```

outside `PGDATA`. A `pg_basebackup`-based backup therefore does not include them.

For production, configuration should be backed up separately through configuration management, version control, filesystem backup, or another controlled mechanism.

## Production extensions

Possible production extensions include scheduled backups, recovery-window retention, storage/backup-age alerts, slot-lag monitoring, off-site copies, encrypted storage, and automated restore testing.
