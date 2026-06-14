# Changelog

All notable changes to this project will be documented in this file.

## [v0.1.2] — 2026-06-14

### Changed

#### ServiceNow (`servicenow/`)

- `snow-deploy.sh` — DB client package is now conditional on `--db_type`:
  - `mariadb` (default) installs the `mariadb` client package
  - `postgresql` installs `postgresql15` instead

## [v0.1.1] — 2026-06-13

### Fixed

#### ServiceNow (`servicenow/`)

- `snow-deploy.sh` — multi-node deployment fixes:
  - **Auto node-role detection** (`--clean_install=auto`, now default): queries `information_schema.tables`
    on startup to determine whether the DB is empty (first node — run clean install + wait) or already
    initialised (subsequent node — join cluster directly). Log output from the detection function is
    redirected to stderr so the mode word is cleanly captured by the caller.
  - **`wait_for_db_init` idempotency**: checks `sys_upgrade_history` at entry and returns immediately
    if schema initialisation is already complete, preventing a re-run from re-entering the 9-hour wait.
  - **`insert_glide_war` idempotency**: changed `INSERT INTO` to `INSERT IGNORE INTO` so re-runs do
    not fail on a duplicate `glide.war` key in `sys_properties`.
  - **MariaDB TLS cipher fix**: removed TLS 1.3 cipher names (`TLS_AES_*`) from the `ssl-cipher`
    directive in `/etc/my.cnf.d/mariadb-client.cnf`. The `ssl-cipher` field only accepts TLS 1.2
    OpenSSL-format names; TLS 1.3 ciphers are auto-negotiated when `tls-version` includes `TLSv1.3`.
    The `ssl-cipher` line is omitted entirely when `--db_tls_min=TLSv1.3`.
  - **`--clean_install` validation**: added guard rejecting values other than `auto`, `true`, or `false`.

## [v0.1.0] — 2026-06-12

### Added

#### ServiceNow (`servicenow/`)

- `snow-deploy.sh` — full ServiceNow deployment script for RHEL 9 / Rocky Linux 9
  - Installs OS dependencies, tunes system parameters, creates `servicenow` user/group
  - JDK installation from a local tarball (auto-detects JDK major version for JVM overrides)
  - Extracts glide base and deploys one or more SNC instances via the SNC installer JAR
  - Writes `glide.db.properties`, `glide.properties`, and JDK override property files per instance
  - Systemd service unit generation, enable, and start per instance
  - Clean-install mode (`--clean_install=true`): deploys instance 1 only, polls MariaDB
    `sys_upgrade_history` until schema initialisation completes (up to 9 hours), inserts
    `glide.war` version record, then deploys remaining instances
  - Idempotent re-run support: skips JDK extraction, glide base extraction, and instance
    installation if already present
  - HAProxy and nginx reverse proxy support with 1:1 frontend-per-instance topology
  - TLS support for DB connections: configurable minimum version (`TLSv1.2` or `TLSv1.3`)
    with separate JDBC and OpenSSL cipher lists written to both the JDBC URL and
    `/etc/my.cnf.d/mariadb-client.cnf`
  - MariaDB master monitor cron job (`mdb_master_check.sh`) for HA failover detection
  - Backup cron via `sncBackup.sh`, logrotate config for SNC and HAProxy logs
- `snow-backup.sh` — ServiceNow node backup script

#### MariaDB (`mariadb/`)

- `mariadb-deploy.sh` — MariaDB deployment script
- `config/mariadb.cnf`, `server.cnf`, `mariadb-client.cnf`, `mariabackup.cnf` — server and client configuration templates
- `scripts/mariadb-backup-full.sh` — full backup script using Mariabackup
- `scripts/mariadb-backup-incr.sh` — incremental backup script
- `scripts/mariadb-cleanup.sh` — backup retention cleanup script
- `.mariadb.env.sample` — sample environment variable file

#### Utilities (`utilities/`)

- `ca-custom.sh` — custom Certificate Authority setup script
