# Changelog

All notable changes to this project will be documented in this file.

## [v0.1.6] — 2026-06-17

### Fixed

#### ServiceNow (`servicenow/`)

- `snow-deploy.sh` — PostgreSQL compatibility for DB query functions:
  - Added `db_query()` helper that dispatches to `mysql` (MariaDB) or `psql`
    (PostgreSQL) based on `--db_type`, handling SSL, credentials, and
    header-free output for each engine.
  - `wait_for_db_init`: uses `db_query()`; PostgreSQL omits the database
    prefix in the table reference (connected directly to the target DB).
  - `detect_install_mode`: uses `db_query()`; PostgreSQL counts user tables
    via `table_catalog = current_database()` instead of `table_schema =
    '<dbname>'` which is MariaDB-specific.
  - `insert_glide_war`: uses `db_query()`; PostgreSQL uses
    `ON CONFLICT DO NOTHING` instead of `INSERT IGNORE`.
  - All three functions previously hardcoded `--ssl` regardless of
    `--db_ssl`; now conditional via `db_query()`.

## [v0.1.5] — 2026-06-15

### Changed

#### ServiceNow (`servicenow/`)

- `snow-deploy.sh` — two new parameterised arguments:
  - `--svc_prefix=<prefix>` (default: `snc`) — systemd service name prefix;
    instances are named `<prefix>01`, `<prefix>02`, etc. Previously hardcoded
    to `snc-01`, `snc-02`, ...
  - `--snc_user=<user>` (default: `servicenow`) — OS user and group created
    for the SNC process. Applied to `groupadd`/`useradd`, the systemd unit
    `User=`/`Group=` directives, and all `chown` calls.

## [v0.1.4] — 2026-06-15

### Added

#### ServiceNow (`servicenow/`)

- `install-jdk.sh` — standalone JDK installation script extracted from
  `snow-deploy.sh`. Accepts `--jdk_tarball`, `--install_dir`, and
  `--media_dir` parameters. Extracts the tarball, flattens the nested
  directory, writes `JAVA_HOME` and `PATH` to `/etc/profile.d/`, and is
  idempotent (skips extraction if `bin/java` already exists). Intended for
  installing OpenJDK on extra component VMs that don't run a full SNC
  deployment.

## [v0.1.3] — 2026-06-14

### Added

#### ServiceNow (`servicenow/`)

- `haproxy-migrate.sh` — ad-hoc script to migrate an existing VM from the old
  per-instance HAProxy topology to the new single-frontend design without
  rerunning the full deployment. Auto-detects SSL, backs up the old config,
  writes and validates the new config, and does a graceful reload with automatic
  rollback on syntax error.

### Changed

#### ServiceNow (`servicenow/`)

- `snow-deploy.sh` — proxy topology redesign:
  - **HAProxy**: replaced per-instance frontends (one port per instance) with a
    single `frontend snc-frontend` on `0.0.0.0:443` backed by all instances in
    one `backend snc-backend` pool. Load balancing algorithm changed from
    `roundrobin` to `leastconn`. Added HAProxy-managed `SERVERID` cookie for
    session persistence (required by ServiceNow). Added full set of
    ServiceNow-recommended LB headers: `X-Forwarded-Host`, `X-Forwarded-Proto`,
    HSTS (`max-age=63072000; includeSubDomains`), `HttpOnly`/`Secure` flags on
    all response cookies, `Location` http→https rewrite.
  - **nginx**: same single-upstream topology — one `upstream snc_backend` block
    with `least_conn` and all instances, served by a single `server` block on
    `:443`. Added `X-Forwarded-Host/Proto`, HSTS header, `proxy_redirect`
    http→https, and `proxy_cookie_flags` for all ServiceNow cookies
    (Secure/HttpOnly) per ServiceNow nginx guidance.
  - **`glide.properties`**: added `glide.servlet.host = 127.0.0.1` so SNC
    instances bind to loopback only, with HAProxy as the sole client.
  - Removed `PROXY_PORT_START` default and `proxy_frontend_port()` helper —
    both obsolete with the single-frontend design.

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
