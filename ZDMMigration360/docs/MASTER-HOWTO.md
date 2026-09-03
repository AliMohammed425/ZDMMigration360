# ZDMMigration360 Complete Toolkit — Master How-To

This consolidated package contains the native RMAN/Data Guard physical standby workflow and the Oracle ZDM physical migration workflow, with interactive and CLI operation.

## Quick start

```bash
chmod 750 bin/zdm360-standby bin/zdm360-validate-package
chmod 600 conf/zdm360PH.drv
bin/zdm360-validate-package
bin/zdm360-standby
```

Run the toolkit as `ops`. The default access model is `ops -> sudo -n -u oracle`, `ops -> ssh oracle@source`, and `ops -> ssh oracle@target`.

Validate access:

```bash
bin/zdm360-standby -d conf/zdm360PH.drv access-check
```

## Interactive operation

```bash
bin/zdm360-standby
```

The menu provides complete build, foreground/background all-task execution, individual/range/selected tasks, production step IDs, failed-task restart, driver management, job management, validation, ZDM migration, plan and package validation.

## Native RMAN/Data Guard

Choose `STANDBY_BUILD_METHOD=ACTIVE_DUPLICATE` or `STANDBY_BUILD_METHOD=OFFLINE_BACKUP` in `conf/zdm360PH.drv`.

Complete background run:

```bash
bin/zdm360-standby -d conf/zdm360PH.drv all --background
```

Task controls:

```bash
bin/zdm360-standby task-list
bin/zdm360-standby -d conf/zdm360PH.drv tasks 10 --foreground
bin/zdm360-standby -d conf/zdm360PH.drv tasks 1,10 --background
bin/zdm360-standby -d conf/zdm360PH.drv tasks 1-10 --background
bin/zdm360-standby -d conf/zdm360PH.drv tasks 1,4,7 --background
bin/zdm360-standby -d conf/zdm360PH.drv tasks all --background
bin/zdm360-standby -d conf/zdm360PH.drv steps 005,010,069,070 --background
```

Step 070 automatically enforces RMAN method-validation gate 069 when required.

Restart a failed workflow:

```bash
bin/zdm360-standby status <job-id>
bin/zdm360-standby failed-from <job-id> --background
```

Track background work:

```bash
bin/zdm360-standby jobs
bin/zdm360-standby status <job-id>
bin/zdm360-standby logs <job-id>
bin/zdm360-standby wait <job-id>
bin/zdm360-standby stop <job-id>
```

## Native workflow

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
050 validate_offline_backup [offline]
060 stage_and_checksum_offline_backup [offline]
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

## Oracle ZDM

Check ZDM on the target:

```bash
bin/zdm360-standby -d conf/zdm360PH.drv zdm-check
```

Use the response-file template shipped with the installed ZDM release and set `ZDM_RSP_FILE` in the driver.

Validate phases/evaluation:

```bash
bin/zdm360-standby -d conf/zdm360PH.drv zdm-phases
bin/zdm360-standby -d conf/zdm360PH.drv zdm-eval
```

### ZDM ONLINE_PHYSICAL

Set `MIGRATION_METHOD=ONLINE_PHYSICAL` in the ZDM response file.

Build/configure standby and pause at the controlled Data Guard point:

```bash
bin/zdm360-standby -d conf/zdm360PH.drv zdm-online-standby
```

The toolkit requires `ZDM_CONFIGURE_DG_SRC` to be present in the actual ZDM phase list before applying `-pauseafter ZDM_CONFIGURE_DG_SRC`.

For a complete ZDM online migration, including later cutover/switchover phases:

```bash
bin/zdm360-standby -d conf/zdm360PH.drv zdm-online-full
```

### ZDM OFFLINE_PHYSICAL

Set `MIGRATION_METHOD=OFFLINE_PHYSICAL` in the ZDM response file.

```bash
bin/zdm360-standby -d conf/zdm360PH.drv zdm-offline
```

Offline physical is backup/restore migration and does not leave a continuously applying Data Guard standby.

ZDM jobs:

```bash
bin/zdm360-standby zdm-query
bin/zdm360-standby zdm-query <job-id>
bin/zdm360-standby zdm-resume <job-id>
bin/zdm360-standby zdm-suspend <job-id>
bin/zdm360-standby zdm-abort <job-id>
```

## Recommended production order

```text
1  Run as ops
2  Validate package
3  Configure/protect driver
4  Run access-check
5  Export runtime secrets
6  Run production preflight
7  Choose native RMAN or ZDM
8  Native: validate step 069 before duplicate
9  ZDM: run check -> phases -> eval
10 Submit foreground/background workflow
11 Monitor jobs/logs
12 Correct failures and restart from checkpoint
13 Validate Data Guard health/sync
14 Review final report and final gate
15 Perform cutover/switchover only under approved change control
```

Detailed instructions remain in `README.md`, `HOWTO.md`, and `docs/ZDM-ONLINE-OFFLINE-HOWTO.md`.

Production certification requires site acceptance testing against the exact Oracle Database RU, ZDM release, OCI service, network, storage, TDE, RAC/Grid Infrastructure topology and change controls.
