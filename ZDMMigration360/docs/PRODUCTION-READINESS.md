# ZDMMigration360 Standby Manager v26 — Production Readiness

## Status

v26 is a production-candidate automation framework. Its local package validation and mocked end-to-end workflow self-test pass. A real production release still requires a site acceptance test against the exact Oracle Database release/RU, OCI database service type, storage layout, listener ownership, Grid Infrastructure topology, firewall/routing, and operational change controls.

## Oracle-validated design requirements

The implementation follows these Oracle-documented requirements:

- RMAN `DUPLICATE ... FOR STANDBY FROM ACTIVE DATABASE` requires an auxiliary instance in NOMOUNT and static listener connectivity.
- For a standby duplicate, DB_NAME remains the source DB_NAME and DB_UNIQUE_NAME must be unique.
- An open active-duplicate source must use ARCHIVELOG.
- Encrypted tablespaces require the Oracle keystore to be available at the duplicate/standby site.
- `LOG_ARCHIVE_CONFIG=DG_CONFIG=(...)` should contain every Data Guard DB_UNIQUE_NAME.
- `STANDBY_FILE_MANAGEMENT=AUTO` is used for physical standby file management.
- Standby redo logs are provisioned per redo thread; this toolkit conservatively targets online-group-count + 1 for each thread and requires OMF for automatic SRL creation.
- OCI Base Database Service uses `dbcli create-database --instanceonly` to create the standby storage/instance structure in NOMOUNT mode; the DB_NAME/admin password should match the primary while DB_UNIQUE_NAME differs.

## Production workflow

005 production_preflight
010 validate_config
020 ssh_precheck
025 remote_tool_precheck
030 source_database_prerequisites
035 source_dataguard_inventory
040 target_precheck
042 configure_tns_aliases
043 configure_static_aux_listener
044 create_or_reuse_oci_placeholder_nomount
045 prepare_password_file
046 validate_tns_matrix
047 validate_SYSDBA_connectivity
048 detect_and_stage_TDE_keystore
049 prepare_DG_CONFIG_and_deferred_transport
050 validate_offline_backup [offline only]
060 stage_and_checksum_offline_backup [offline only]
070 RMAN_standby_duplicate
080 restart_mount_and_start_redo_apply
085 enable_primary_redo_transport
090 ensure_standby_redo_logs_primary_and_standby
100 RAC_validation_and_enablement [RAC only]
110 Data_Guard_health
120 Data_Guard_sync
130 snapshot_readiness
140 switchover_readiness
150 failover_readiness
160 final_validation_report
170 final_validation_gate

## Safety controls added in v26

- Driver files are parsed as data with an explicit key allow-list; they are not sourced as shell scripts.
- The included `conf/zdm360PH.drv` is intentionally blank for environment-specific required fields, preventing accidental execution against example hosts.
- Blank password fields in a driver do not erase credentials injected through the environment.
- Background jobs use `setsid`, record PID/PGID, and can terminate the process group.
- A per-job `flock` prevents concurrent execution/resume of the same job.
- Each step records status, timestamps, exit code, and attempt count.
- Job configuration is snapshotted without passwords; a driver path is recorded for repeatability.
- Existing successful step markers are skipped on resume.
- OCI placeholder creation is idempotent when an existing NOMOUNT instance matches DB_NAME/DB_UNIQUE_NAME.
- Base DB Service `dbcli --adminpassword` is driven through `expect` with a mode-600 temporary secret file instead of placing the password on the command line.
- Generic ORAPWD creation uses an `expect` prompt with a temporary secret file instead of a password command-line parameter.
- A dedicated `LISTENER_ZDM360` auxiliary listener is used rather than overwriting the service-managed default listener definition.
- TNS changes use a bounded ZDM360-managed block and preserve a backup of the prior tnsnames.ora.
- Existing DG_CONFIG members are retained and de-duplicated; the new standby is appended.
- An unused LOG_ARCHIVE_DEST_n is selected instead of overwriting an existing destination.
- Primary redo transport is kept DEFERRED until the standby exists, then enabled.
- Reverse transport is configured on the standby for future role transition.
- Offline backup staging fixes the unsupported two-remote-endpoint rsync pattern by running rsync on the target and pulling from the source.
- Offline backup staging creates and compares SHA-256 manifests.
- Final validation requires PHYSICAL STANDBY role, no archive gap, and a managed recovery process.

## Deliberate production gates

- FORCE LOGGING is validated and must already be enabled; the toolkit does not silently enable it on a production primary.
- TDE automatic staging requires the same absolute wallet/keystore path on source and target so inherited wallet configuration is not guessed. Different-path configurations require site-specific wallet configuration.
- dbaascli-managed OCI/Exadata-family targets are detected and blocked from receiving Base DB Service `dbcli` commands.
- Automatic SRL creation requires DB_CREATE_FILE_DEST/OMF. If OMF is not configured, the toolkit stops rather than guessing file paths.
- RAC uses an existing Clusterware registration as the production-safe path. If the database is not registered, the default `RAC_CONVERSION_MODE=VALIDATE_ONLY` blocks automatic topology creation. The legacy auto-fix path is only available with explicit `RAC_CONVERSION_MODE=LEGACY_AUTOFIX` after site review.
- Switchover and failover are readiness validations only; destructive role transitions are not automatically executed by the all-tasks build.

## Validation performed on the package

Run locally:

```bash
bin/zdm360-validate-package
```

The validator performs `bash -n` against bin/lib/test shell files, checks the protected driver file, verifies that malicious/unsupported driver keys are rejected, and runs the complete step engine with mocked Oracle/SSH operations through the final validation gate.

This validates package orchestration. It does not replace a real Oracle/OCI integration test.
