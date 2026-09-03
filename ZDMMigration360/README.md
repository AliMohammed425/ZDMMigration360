# ZDMMigration360

Enterprise-oriented Oracle physical standby and migration automation using native RMAN/Data Guard or Oracle Zero Downtime Migration (ZDM).

**Release:** v34 GitHub Edition  
**Toolkit user:** `ops`  
**Oracle software owner / SSH user:** `oracle`

## Purpose

ZDMMigration360 provides one repeatable operator interface for building, validating, monitoring, and restarting Oracle physical standby and physical migration workflows.

It provides two execution paths:

- **Native RMAN / Data Guard:** RMAN Active Duplicate or staged RMAN backup, followed by Data Guard configuration, redo apply, health, synchronization, and final validation.
- **Oracle ZDM:** target-side ZDM detection plus `ONLINE_PHYSICAL` and `OFFLINE_PHYSICAL` execution, ZDM evaluation/phase inspection, controlled online standby pause, and ZDM job management.

The goal is to give DBAs explicit checkpoints and resumable automation rather than a single opaque build script.

## Key capabilities

| Area | Capability |
|---|---|
| Interface | Interactive menu + CLI |
| Execution | Foreground or tracked background |
| Restart | Resume from failed task |
| Task selection | Individual, range, selected, all, production step IDs |
| Native online | RMAN Active Duplicate |
| Native staged | RMAN backup using NFS/SCP/RSYNC staging |
| Target | OCI placeholder/NOMOUNT preparation |
| Connectivity | SSH, TNS, listener, SYSDBA validation |
| Security | `ops` launcher, `oracle` owner, runtime secrets |
| TDE | Detection and keystore staging controls |
| Data Guard | DG_CONFIG, archive destinations, SRLs, MRP, health/sync |
| RAC | Validation-first RAC target path |
| ZDM online | `ONLINE_PHYSICAL` and controlled standby pause |
| ZDM offline | `OFFLINE_PHYSICAL` backup/restore migration |
| ZDM jobs | Query/resume/suspend/abort |
| Validation | Final report + final gate |

## Architecture

```text
Toolkit host (ops)
       |
       +---- SSH oracle@SOURCE (PRIMARY)
       |
       +---- SSH oracle@TARGET (NOMOUNT / PHYSICAL STANDBY)
                         ^
                         |
             RMAN / Data Guard or ZDM
```

## Repository layout

```text
ZDMMigration360/
├── bin/                 Main launcher and validator
├── lib/                 Workflow modules
├── conf/                Driver configuration
├── docs/                Operator/runbook documentation
├── tests/               Package self-test
├── runs/                Runtime checkpoint state (ignored)
├── logs/                Runtime logs (ignored)
├── reports/             Reports
├── README.md
├── HOWTO.md
├── CHANGELOG.md
├── SECURITY.md
├── CONTRIBUTING.md
├── LICENSE
└── SHA256SUMS
```

## Quick start

```bash
git clone <repository-url>
cd ZDMMigration360
chmod 750 bin/zdm360-standby bin/zdm360-validate-package
chmod 600 conf/zdm360PH.drv
bin/zdm360-validate-package
bin/zdm360-standby
```

## Access model

Run as `ops`. The default policy expects:

```text
ops -> sudo -n -u oracle
ops -> ssh oracle@source
ops -> ssh oracle@target
```

Validate:

```bash
bin/zdm360-standby -d conf/zdm360PH.drv access-check
```

## Configuration

Configure the local driver:

```text
conf/zdm360PH.drv
```

Do not commit real passwords, SSH private keys, TDE wallets, OCI credentials, RMAN backups, or sensitive production logs.

Prefer runtime credentials:

```bash
export SOURCE_SYS_PASSWORD='...'
export TARGET_SYS_PASSWORD='...'
export TARGET_ADMIN_PASSWORD='...'
```

## Native RMAN/Data Guard

For Active Duplicate:

```text
STANDBY_BUILD_METHOD=ACTIVE_DUPLICATE
```

For staged backup:

```text
STANDBY_BUILD_METHOD=OFFLINE_BACKUP
SOURCE_BACKUP_STAGE=/backup/source
TARGET_BACKUP_STAGE=/backup/target
BACKUP_COPY_METHOD=NFS
```

Validate:

```bash
bin/zdm360-standby -d conf/zdm360PH.drv preflight
bin/zdm360-standby task-list
bin/zdm360-standby plan
```

Run all in background:

```bash
bin/zdm360-standby -d conf/zdm360PH.drv all --background
```

Run through the RMAN method gate before the duplicate:

```bash
bin/zdm360-standby -d conf/zdm360PH.drv tasks 1-18 --foreground
```

## Task execution

```bash
# one task
bin/zdm360-standby -d conf/zdm360PH.drv tasks 10 --foreground

# range 1 through 10
bin/zdm360-standby -d conf/zdm360PH.drv tasks 1,10 --background
bin/zdm360-standby -d conf/zdm360PH.drv tasks 1-10 --background

# selected tasks
bin/zdm360-standby -d conf/zdm360PH.drv tasks 1,4,7 --background

# production step IDs
bin/zdm360-standby -d conf/zdm360PH.drv steps 005,010,069,070 --background
```

## Background jobs / restart

```bash
bin/zdm360-standby jobs
bin/zdm360-standby status <job-id>
bin/zdm360-standby logs <job-id>
bin/zdm360-standby wait <job-id>
bin/zdm360-standby stop <job-id>
bin/zdm360-standby failed-from <job-id> --background
```

## Production native workflow

```text
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
069 validate_RMAN_duplicate_method
070 RMAN_standby_duplicate
080 restart_mount_and_start_redo_apply
085 enable_primary_redo_transport
090 ensure_standby_redo_logs
100 RAC_validation_and_enablement [RAC]
101 RAC_enable_and_fix [RAC]
110 Data_Guard_health
120 Data_Guard_sync
130 snapshot_readiness
140 switchover_readiness
150 failover_readiness
160 final_validation_report
170 final_validation_gate
```

## Oracle ZDM physical migration

Check ZDM on the target:

```bash
bin/zdm360-standby -d conf/zdm360PH.drv zdm-check
```

Use a response file based on the template shipped with the exact installed ZDM release.

### ONLINE_PHYSICAL

Set in the ZDM response file:

```text
MIGRATION_METHOD=ONLINE_PHYSICAL
```

Validate:

```bash
bin/zdm360-standby -d conf/zdm360PH.drv zdm-phases
bin/zdm360-standby -d conf/zdm360PH.drv zdm-eval
```

Build/configure the Data Guard standby and request the controlled pause:

```bash
bin/zdm360-standby -d conf/zdm360PH.drv zdm-online-standby
```

The toolkit first verifies that `ZDM_CONFIGURE_DG_SRC` is in the actual phase list before requesting a pause after that phase.

For an approved complete online migration:

```bash
bin/zdm360-standby -d conf/zdm360PH.drv zdm-online-full
```

### OFFLINE_PHYSICAL

Set:

```text
MIGRATION_METHOD=OFFLINE_PHYSICAL
```

Then:

```bash
bin/zdm360-standby -d conf/zdm360PH.drv zdm-phases
bin/zdm360-standby -d conf/zdm360PH.drv zdm-eval
bin/zdm360-standby -d conf/zdm360PH.drv zdm-offline
```

`OFFLINE_PHYSICAL` is backup/restore migration; it does not leave a continuously applying Data Guard standby.

### ZDM jobs

```bash
bin/zdm360-standby zdm-query
bin/zdm360-standby zdm-query <job-id>
bin/zdm360-standby zdm-resume <job-id>
bin/zdm360-standby zdm-suspend <job-id>
bin/zdm360-standby zdm-abort <job-id>
```

## Recommended production order

```text
1. Run as ops.
2. Run package validation.
3. Configure/protect the local driver.
4. Run access-check.
5. Supply runtime secrets.
6. Run preflight.
7. Choose native RMAN or ZDM.
8. Native: validate step 069 before duplicate.
9. ZDM: check -> phases -> eval.
10. Submit the selected workflow.
11. Monitor jobs/logs.
12. Correct failures before resume.
13. Validate Data Guard health/sync.
14. Review final report/gate.
15. Perform switchover/cutover only under approved change control.
```

## Documentation

- `HOWTO.md` — detailed operator guide.
- `docs/MASTER-HOWTO.md` — consolidated runbook.
- `docs/ZDM-ONLINE-OFFLINE-HOWTO.md` — ZDM physical migration guide.
- `docs/PRODUCTION-READINESS.md` — production boundaries.
- `docs/GITHUB-UPLOAD.md` — publishing steps.
- `SECURITY.md` — repository/credential safety.

## Production-readiness statement

Package self-tests are not production certification. Validate against the exact Oracle Database RU, ZDM release, OCI service, RAC/Grid Infrastructure topology, ASM/filesystem design, network/listeners, TDE configuration, backup design, and organizational change controls. Test the full workflow in a representative non-production environment first.

## License

MIT. See `LICENSE`.

## Disclaimer

This is an independent automation project and is not an Oracle product. Oracle, Oracle Database, RMAN, Data Guard, OCI, and Zero Downtime Migration are trademarks or registered trademarks of Oracle and/or its affiliates.
