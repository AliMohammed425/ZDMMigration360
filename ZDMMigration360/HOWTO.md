
# ZDMMigration360 Standby Manager — How To Use

This package builds and validates an Oracle physical standby using either RMAN Active Duplicate or a staged RMAN backup. It supports interactive operation, driver-file automation, individual tasks, task ranges, background jobs, checkpoints, and failed-step restart.

## 1. Extract and enter the toolkit

```bash
unzip ZDM360_Standby_Manager_v30.zip
cd ZDM360_Standby_Manager_v30
chmod 750 bin/zdm360-standby bin/zdm360-validate-package
chmod 600 conf/zdm360PH.drv
```

Run the package self-test before using it against a database:

```bash
bin/zdm360-validate-package
```

Expected result:

```text
SELFTEST PASS
PACKAGE VALIDATION PASS
```

## 2. Interactive mode — easiest way to start

Run:

```bash
bin/zdm360-standby
```

or:

```bash
bin/zdm360-standby menu
```

The main menu provides complete build, all tasks, individual tasks/ranges, production step IDs, failed-job restart, driver management, background-job management, validation operations, execution plan, and package validation.

For a first-time build, choose:

```text
1) COMPLETE BUILD - interactive inputs / driver -> standby
```

The wizard collects source database, target database, OCI platform, Oracle homes, services, RMAN method, backup staging when applicable, RAC settings, storage destinations, and synchronization settings.

Passwords are intended to be supplied at runtime rather than permanently stored in the driver file.

## 3. Driver file

The operational driver is:

```text
conf/zdm360PH.drv
```

Edit it directly:

```bash
vi conf/zdm360PH.drv
chmod 600 conf/zdm360PH.drv
```

Or use menu option:

```text
8) Driver / Input management
```

The driver supplies non-secret source/target configuration. CLI options override driver values.

Configuration precedence is:

```text
conf/standby.env < conf/zdm360PH.drv < explicit CLI switches
```

Validate the driver:

```bash
bin/zdm360-standby driver-validate conf/zdm360PH.drv
```

Show its resolved summary:

```bash
bin/zdm360-standby driver-show conf/zdm360PH.drv
```

## 4. Runtime passwords

Preferred runtime pattern:

```bash
export SOURCE_SYS_PASSWORD='source_sys_password'
export TARGET_SYS_PASSWORD='target_sys_password'
export TARGET_ADMIN_PASSWORD='oci_target_admin_password'
```

For RMAN Active Duplicate, source and target SYS password-file credentials must be compatible. Do not put passwords in shell history on shared systems.

After the run, clear them when appropriate:

```bash
unset SOURCE_SYS_PASSWORD TARGET_SYS_PASSWORD TARGET_ADMIN_PASSWORD
```

## 5. Select the standby creation method

For Active Duplicate, set in the driver:

```text
STANDBY_BUILD_METHOD=ACTIVE_DUPLICATE
```

The production sequence validates network connectivity, auxiliary listener, SYSDBA connectivity, password file, TDE requirements, Data Guard parameters, and step 069 before RMAN step 070.

For backup-based standby creation:

```text
STANDBY_BUILD_METHOD=OFFLINE_BACKUP
SOURCE_BACKUP_STAGE=/path/to/source/backup
TARGET_BACKUP_STAGE=/path/to/target/backup
BACKUP_COPY_METHOD=SCP
```

`BACKUP_COPY_METHOD` can be `SCP`, `RSYNC`, or `NFS`.

The offline path validates the backup, stages it, compares SHA-256 manifests, validates the staged backup through RMAN, and then performs the backup-location standby duplicate.

## 6. Run the complete workflow

Interactive:

```bash
bin/zdm360-standby
```

Choose menu option 1, 2, or 3.

Non-interactive background execution:

```bash
SOURCE_SYS_PASSWORD='...' \
TARGET_SYS_PASSWORD='...' \
TARGET_ADMIN_PASSWORD='...' \
bin/zdm360-standby \
  -d conf/zdm360PH.drv \
  all --background
```

Foreground:

```bash
bin/zdm360-standby -d conf/zdm360PH.drv all --foreground
```

The shortcut using the default driver is:

```bash
bin/zdm360-standby drv-all --background
```

If the default driver is absent or incomplete, interactive mode can collect the required values.

## 7. View the production task list

```bash
bin/zdm360-standby task-list
```

Important RMAN tasks are:

```text
18  069  validate_RMAN_duplicate_method
19  070  RMAN_standby_duplicate
```

Step 070 uses either Active Duplicate or Offline Backup according to `STANDBY_BUILD_METHOD`.

A directly selected step 070 automatically enforces step 069 first if that gate is not already complete for the selected-task job.

## 8. Run one task

Example — run task 10:

```bash
bin/zdm360-standby \
  -d conf/zdm360PH.drv \
  tasks 10 --foreground
```

Background:

```bash
bin/zdm360-standby \
  -d conf/zdm360PH.drv \
  tasks 10 --background
```

## 9. Run a task range

Task 1 through task 10:

```bash
bin/zdm360-standby \
  -d conf/zdm360PH.drv \
  tasks 1,10 --background
```

Equivalent:

```bash
bin/zdm360-standby \
  -d conf/zdm360PH.drv \
  tasks 1-10 --background
```

## 10. Run selected non-contiguous tasks

Example:

```bash
bin/zdm360-standby \
  -d conf/zdm360PH.drv \
  tasks 1,4,7 --background
```

Three or more comma-separated task numbers are treated as an explicit task list.

## 11. Run by production step ID

Example:

```bash
bin/zdm360-standby \
  -d conf/zdm360PH.drv \
  steps 005,010,069,070 --background
```

This is useful when an experienced DBA wants to use the production step IDs rather than the friendly ordinal task numbers.

## 12. Background job management

List jobs:

```bash
bin/zdm360-standby jobs
```

Show a job:

```bash
bin/zdm360-standby status <job-id>
```

Read recent output:

```bash
bin/zdm360-standby logs <job-id>
```

Follow the log:

```bash
tail -f runs/<job-id>/output.log
```

Wait for completion:

```bash
bin/zdm360-standby wait <job-id>
```

Stop the process group:

```bash
bin/zdm360-standby stop <job-id>
```

Each job is stored below:

```text
runs/<job-id>/
```

Per-step state, attempts, timestamps, exit codes, and logs are stored under:

```text
runs/<job-id>/steps/
```

## 13. Restart after a failure

Check the failed job:

```bash
bin/zdm360-standby status <job-id>
```

Resume from the recorded failed task through the end:

```bash
SOURCE_SYS_PASSWORD='...' \
TARGET_SYS_PASSWORD='...' \
TARGET_ADMIN_PASSWORD='...' \
bin/zdm360-standby \
  failed-from <job-id> --background
```

Completed earlier checkpoints remain completed. The failed checkpoint is reset and execution continues forward.

You can also use the interactive menu:

```text
6) Resume from FAILED task through end
```

## 14. Production preflight only

```bash
bin/zdm360-standby \
  -d conf/zdm360PH.drv \
  preflight
```

Run this before a production change window.

## 15. Validate RMAN method before the duplicate

From the interactive menu:

```text
10) Validation / Operations
4) RMAN method validation (step 069)
```

Or run production task 18:

```bash
bin/zdm360-standby \
  -d conf/zdm360PH.drv \
  tasks 18 --foreground
```

This allows the operator to catch method-specific issues before starting the potentially long RMAN duplicate.

## 16. OCI placeholder database

The workflow creates or reuses the target placeholder in NOMOUNT before RMAN duplication.

Run only that operation when required:

```bash
bin/zdm360-standby \
  -d conf/zdm360PH.drv \
  placeholder
```

For OCI Base Database Service, the toolkit uses the Base DB Service placeholder path. Generic/self-managed OCI uses the toolkit's generic NOMOUNT path. Platform-specific lifecycle operations must match the actual target service.

## 17. TDE

The workflow detects whether source encryption requires a keystore. When encrypted data requires TDE, configure the source and target wallet/keystore paths in the driver or through CLI options.

Example:

```bash
--source-tde-wallet /path/source/wallet \
--target-tde-wallet /path/target/wallet
```

Do not proceed with an encrypted standby build until the keystore validation passes.

## 18. RAC target

Set:

```text
TARGET_RAC_ENABLED=YES
```

and supply the RAC/GI inputs required by the driver.

The default production posture is validation-first. Do not enable topology-changing RAC automation until instance naming, redo threads, undo tablespaces, Grid Infrastructure registration, listeners/SCAN, ASM storage, and password-file placement have been reviewed for the actual environment.

## 19. Data Guard validation

Health:

```bash
bin/zdm360-standby -d conf/zdm360PH.drv dg-validate
```

Synchronization:

```bash
bin/zdm360-standby -d conf/zdm360PH.drv sync
```

The complete workflow also performs health, synchronization, readiness checks, a final report, and a final validation gate.

## 20. Recommended production sequence

Use this operating pattern:

```text
1. Extract toolkit
2. Run bin/zdm360-validate-package
3. Configure conf/zdm360PH.drv
4. chmod 600 conf/zdm360PH.drv
5. Export runtime credentials
6. Run production preflight
7. Review task plan
8. Run step 069 / RMAN method validation
9. Submit all tasks in background
10. Monitor job status and logs
11. If failure occurs, correct the cause
12. Use failed-from <job-id>
13. Confirm steps 110/120 Data Guard health and synchronization
14. Review step 160 final report
15. Require step 170 final gate to pass
```

Useful commands:

```bash
bin/zdm360-standby plan
bin/zdm360-standby task-list
bin/zdm360-standby jobs
bin/zdm360-standby status <job-id>
```

## 21. Dry operational example — Active Duplicate

```bash
export SOURCE_SYS_PASSWORD='...'
export TARGET_SYS_PASSWORD='...'
export TARGET_ADMIN_PASSWORD='...'

bin/zdm360-validate-package

bin/zdm360-standby \
  -d conf/zdm360PH.drv \
  preflight

bin/zdm360-standby \
  -d conf/zdm360PH.drv \
  tasks 18 --foreground

bin/zdm360-standby \
  -d conf/zdm360PH.drv \
  all --background

bin/zdm360-standby jobs
bin/zdm360-standby status <job-id>
bin/zdm360-standby logs <job-id>
```

## 22. Operational example — Offline Backup

Set the driver:

```text
STANDBY_BUILD_METHOD=OFFLINE_BACKUP
SOURCE_BACKUP_STAGE=/backup/source
TARGET_BACKUP_STAGE=/backup/standby
BACKUP_COPY_METHOD=RSYNC
```

Then:

```bash
export TARGET_SYS_PASSWORD='...'

bin/zdm360-standby \
  -d conf/zdm360PH.drv \
  preflight

bin/zdm360-standby \
  -d conf/zdm360PH.drv \
  tasks 16-19 --foreground
```

Tasks 16-19 correspond to backup validation, backup staging/checksum, RMAN method validation, and RMAN standby duplicate.

For the normal production run, use:

```bash
bin/zdm360-standby \
  -d conf/zdm360PH.drv \
  all --background
```

## 23. Troubleshooting

If a task fails:

```bash
bin/zdm360-standby status <job-id>
bin/zdm360-standby logs <job-id>
```

Inspect the specific step log:

```bash
ls -l runs/<job-id>/steps/
less runs/<job-id>/steps/<step>_<name>.log
```

Correct the underlying Oracle, network, storage, listener, password-file, TDE, RMAN, RAC, or Data Guard issue, then run:

```bash
bin/zdm360-standby failed-from <job-id> --background
```

Do not delete completed step markers merely to force a rerun unless you understand the effect of repeating that operation.

## 24. Important production boundary

The toolkit includes production-oriented validation and checkpointing, but it cannot certify an Oracle environment by itself. Before a live production run, validate the package against the exact Oracle Database release/RU, OCI database service, Grid Infrastructure/RAC topology, ASM/storage design, network/listener configuration, TDE wallet design, and organizational change controls.

Always test the workflow against a representative non-production environment before the production change window.


## ZDM physical migration option on the target

The manager now checks whether Oracle Zero Downtime Migration is installed on the target host. It checks `ZDM_TARGET_HOME` first and then common ZDM locations. You can test detection with:

```bash
bin/zdm360-standby -d conf/zdm360PH.drv zdm-check
```

If ZDM is detected, the interactive main menu exposes:

```text
11) ZDM physical migration / standby (if ZDM installed on target)
```

Configure these driver values:

```text
ZDM_TARGET_HOME=
ZDM_RSP_FILE=/path/on/target/physical_migration.rsp
ZDM_SOURCE_SSH_KEY=/path/on/target/source_ssh_key
SOURCE_SUDO_LOCATION=/usr/bin/sudo
ZDM_PHYSICAL_METHOD=ONLINE_PHYSICAL
ZDM_PAUSE_AFTER_STANDBY=YES
```

`ZDM_RSP_FILE` is intentionally not generated blindly by this toolkit. Physical migration response files are platform- and transfer-medium-specific; use the Oracle ZDM 26.1 template appropriate for the actual source/target topology and validate it with ZDM evaluation first.

Recommended ZDM sequence:

```bash
bin/zdm360-standby -d conf/zdm360PH.drv zdm-check
bin/zdm360-standby -d conf/zdm360PH.drv zdm-phases
bin/zdm360-standby -d conf/zdm360PH.drv zdm-eval
```

To use ZDM online physical migration to create/configure the target standby and pause before ZDM's switchover:

```bash
bin/zdm360-standby -d conf/zdm360PH.drv zdm-online-standby
```

The manager first verifies that `ZDM_CONFIGURE_DG_SRC` appears in the job's `-listphases` output. Only then does it submit the migration with:

```text
-pauseafter ZDM_CONFIGURE_DG_SRC
```

This gives the operator a controlled checkpoint after Data Guard configuration instead of automatically proceeding into the switchover portion of the online migration workflow.

To intentionally run the complete online physical migration, including ZDM's later switchover phases:

```bash
bin/zdm360-standby -d conf/zdm360PH.drv zdm-online-full
```

To run ZDM offline physical backup/restore migration:

```bash
bin/zdm360-standby -d conf/zdm360PH.drv zdm-offline
```

Important: `OFFLINE_PHYSICAL` is a backup/restore migration method. It does not leave the target as a continuously applying Data Guard physical standby.

ZDM job operations:

```bash
bin/zdm360-standby zdm-query
bin/zdm360-standby zdm-query <job-id>
bin/zdm360-standby zdm-resume <job-id>
bin/zdm360-standby zdm-suspend <job-id>
bin/zdm360-standby zdm-abort <job-id>
```

The ZDM submenu requires explicit confirmation before starting online-full or offline execution.


## Operator account and Oracle SSH policy

All toolkit commands are designed to be launched by the operating-system account:

```text
ops
```

The default policy is:

```text
TOOLKIT_OS_USER=ops
ORACLE_OS_USER=oracle
SOURCE_OS_USER=oracle
TARGET_OS_USER=oracle
REQUIRE_LOCAL_SUDO_ORACLE=YES
REQUIRE_TARGET_ORACLE_SSH=YES
REQUIRE_SOURCE_ORACLE_SSH=YES
```

Before a production workflow, validate access:

```bash
bin/zdm360-standby -d conf/zdm360PH.drv access-check
```

The access check requires:

```text
ops runs the toolkit locally
ops -> sudo -n -u oracle works locally
ops -> ssh oracle@target works passwordlessly
ops -> ssh oracle@source works passwordlessly
oracle@target can access TARGET_ORACLE_HOME/sqlplus, rman and orapwd
oracle@source can access SOURCE_ORACLE_HOME/sqlplus and rman
```

Example validation outside the toolkit:

```bash
id -un
sudo -n -u oracle id
ssh -o BatchMode=yes oracle@target-host id
ssh -o BatchMode=yes oracle@source-host id
```

Expected identities:

```text
ops
uid=... oracle ...
uid=... oracle ...
uid=... oracle ...
```

The production preflight now automatically runs this operator/access validation before database work starts.

ZDM detection and execution on the target also use the configured target database software owner (`oracle`) rather than implicitly changing to `opc`. If a specific OCI lifecycle command requires another privileged account, keep that operation explicitly separated instead of silently running the entire toolkit under that account.


---

# ZDM ONLINE / OFFLINE PHYSICAL MIGRATION — HOW TO

## What the two ZDM physical modes mean

`ONLINE_PHYSICAL` is Oracle Data Guard based. ZDM instantiates the target standby, configures Data Guard, synchronizes source and target, and a complete migration eventually switches the target to primary.

`OFFLINE_PHYSICAL` is RMAN backup/restore. The target is restored from backup and has no continuing Data Guard relationship to the source. Use this for offline migration/clone-style movement, not as a permanent applying standby.

## 1. Validate the ops/oracle execution model

Run the toolkit as `ops`. The default policy requires:

```text
ops -> sudo -n -u oracle
ops -> ssh oracle@source
ops -> ssh oracle@target
```

Run:

```bash
bin/zdm360-standby -d conf/zdm360PH.drv access-check
bin/zdm360-standby -d conf/zdm360PH.drv zdm-check
```

## 2. Prepare the ZDM response file

Start with the template shipped with the installed ZDM release:

```text
$ZDM_HOME/rhp/zdm/template/zdm_template.rsp
```

Example:

```bash
mkdir -p /home/oracle/zdm_rsp
cp $ZDM_HOME/rhp/zdm/template/zdm_template.rsp /home/oracle/zdm_rsp/prod_physical.rsp
chmod 600 /home/oracle/zdm_rsp/prod_physical.rsp
```

Set the toolkit driver:

```text
ZDM_RSP_FILE=/home/oracle/zdm_rsp/prod_physical.rsp
```

Use the shipped 26.1 template to populate all platform-, storage-, cloud-, TDE-, source-, and target-specific parameters.

## 3. ONLINE_PHYSICAL

Set:

```text
MIGRATION_METHOD=ONLINE_PHYSICAL
```

Example conceptual DIRECT configuration:

```text
MIGRATION_METHOD=ONLINE_PHYSICAL
PLATFORM_TYPE=VMDB
TGT_DB_UNIQUE_NAME=<target_db_unique_name>
DATA_TRANSFER_MEDIUM=DIRECT
```

Oracle documents `DIRECT` as an online physical transfer option using RMAN active duplication or restore-from-service behavior. Other supported media depend on platform and include OSS, NFS and platform-specific options.

Validate before execution:

```bash
bin/zdm360-standby -d conf/zdm360PH.drv zdm-check
bin/zdm360-standby -d conf/zdm360PH.drv zdm-phases
bin/zdm360-standby -d conf/zdm360PH.drv zdm-eval
```

### Build/configure standby and pause before switchover

```bash
bin/zdm360-standby -d conf/zdm360PH.drv zdm-online-standby
```

The toolkit checks the actual ZDM phase list for `ZDM_CONFIGURE_DG_SRC`. When that phase is valid, it submits the job with:

```text
-pauseafter ZDM_CONFIGURE_DG_SRC
```

This is the controlled standby-build path: ZDM configures the Data Guard portion and the job pauses instead of blindly proceeding into later cutover phases. Query and validate the paused job before any resume.

### Complete online migration

```bash
bin/zdm360-standby -d conf/zdm360PH.drv zdm-online-full
```

This permits the complete ZDM online physical workflow, including later synchronization/cutover and switchover behavior. Use only during an approved migration window.

## 4. ONLINE_PHYSICAL with NFS or Object Storage

Conceptual NFS settings:

```text
MIGRATION_METHOD=ONLINE_PHYSICAL
DATA_TRANSFER_MEDIUM=NFS
BACKUP_PATH=STORAGEPATH
```

Conceptual Object Storage settings:

```text
MIGRATION_METHOD=ONLINE_PHYSICAL
DATA_TRANSFER_MEDIUM=OSS
```

Complete the remaining parameters from the shipped template for the actual target platform.

## 5. OFFLINE_PHYSICAL

Set:

```text
MIGRATION_METHOD=OFFLINE_PHYSICAL
```

Conceptual NFS example:

```text
MIGRATION_METHOD=OFFLINE_PHYSICAL
DATA_TRANSFER_MEDIUM=NFS
BACKUP_PATH=STORAGEPATH
TGT_DB_UNIQUE_NAME=<target_db_unique_name>
PLATFORM_TYPE=<VMDB|EXACS|EXACC|NON_CLOUD>
```

Validate:

```bash
bin/zdm360-standby -d conf/zdm360PH.drv zdm-check
bin/zdm360-standby -d conf/zdm360PH.drv zdm-phases
bin/zdm360-standby -d conf/zdm360PH.drv zdm-eval
```

Execute:

```bash
bin/zdm360-standby -d conf/zdm360PH.drv zdm-offline
```

Offline physical is backup/restore. It does not leave the target continuously synchronized with the source.

## 6. Interactive menu

```bash
bin/zdm360-standby
```

Choose:

```text
11) ZDM physical migration / standby (if ZDM installed on target)
```

Then use:

```text
1) Detect ZDM and show version
2) Validate ZDM inputs / response file
3) List ZDM physical migration phases
4) Evaluate ZDM physical migration (-eval)
5) ONLINE_PHYSICAL - build/configure standby and PAUSE before switchover
6) ONLINE_PHYSICAL - execute full ZDM migration
7) OFFLINE_PHYSICAL - backup/restore migration
8) Query latest ZDM job
9) Query ZDM job ID
10) Resume ZDM job
11) Suspend ZDM job
12) Abort ZDM job
0) Back
```

Recommended standby-build sequence: `1 -> 2 -> 3 -> 4 -> 5`.

Recommended complete online migration sequence: `1 -> 2 -> 3 -> 4 -> 6`.

Recommended offline sequence: `1 -> 2 -> 3 -> 4 -> 7`.

## 7. ZDM job management

```bash
bin/zdm360-standby zdm-query
bin/zdm360-standby zdm-query <job-id>
bin/zdm360-standby zdm-resume <job-id>
bin/zdm360-standby zdm-suspend <job-id>
bin/zdm360-standby zdm-abort <job-id>
```

Always query the current phase before resuming a job intentionally paused before cutover.

## 8. Production checklist — online

```text
[ ] running as ops
[ ] sudo -n -u oracle works
[ ] oracle SSH to source and target works
[ ] ZDM detected on target
[ ] correct ZDM 26.1 response template used
[ ] source/target path supported
[ ] ONLINE_PHYSICAL selected
[ ] transfer medium supported for platform
[ ] TDE prerequisites completed
[ ] source and target hostnames differ
[ ] required source-target connectivity completed
[ ] zdm-phases reviewed
[ ] zdm-eval successful
[ ] standby-only vs full migration decision documented
[ ] cutover approval obtained before full migration
```

## 9. Production checklist — offline

```text
[ ] ops/oracle access validated
[ ] ZDM detected
[ ] correct ZDM 26.1 response template used
[ ] OFFLINE_PHYSICAL selected
[ ] supported NFS/OSS/other transfer medium selected
[ ] backup/storage access validated
[ ] TDE prerequisites completed
[ ] zdm-phases reviewed
[ ] zdm-eval successful
[ ] downtime approved
[ ] application cutover/post-restore validation prepared
```

## 10. Native RMAN vs ZDM

Use native toolkit RMAN/Data Guard when you want toolkit-controlled RMAN duplicate, individual native tasks/checkpoints, or ZDM is unavailable.

Use ZDM `ONLINE_PHYSICAL` when ZDM is installed and supported and you want Oracle ZDM to orchestrate standby initialization/Data Guard and possibly the eventual switchover.

Use ZDM `OFFLINE_PHYSICAL` when you want ZDM-orchestrated backup/restore and continuous Data Guard synchronization is not required.
