# OCI Physical Standby Placeholder Wizard

The wizard prompts for source and target database identity, enforces a different target `DB_UNIQUE_NAME`, generates `tnsnames.ora`, copies the Oracle password file from source to target before connectivity testing, then runs `tnsping` in both directions.

## Interactive dry run

```bash
./standby_placeholder_wizard.sh
```

## Interactive execute

```bash
EXECUTE=true ./standby_placeholder_wizard.sh
```

## Non-interactive

```bash
cp standby_placeholder.env.example standby_placeholder.env
vi standby_placeholder.env
source standby_placeholder.env
MODE=noninteractive EXECUTE=true ./standby_placeholder_wizard.sh
```

## Standard physical standby identity

Usually:

```text
SOURCE DB_NAME       = PROD
SOURCE DB_UNIQUE_NAME= PROD_PRI

TARGET DB_NAME       = PROD
TARGET DB_UNIQUE_NAME= PROD_STBY
```

The `DB_NAME` normally stays the same; `DB_UNIQUE_NAME` must differ.

## Password file

Default filesystem assumption:

```text
Source: $SOURCE_ORACLE_HOME/dbs/orapw$SOURCE_SID
Target: $TARGET_ORACLE_HOME/dbs/orapw$TARGET_SID
```

For RAC/ASM-managed password files, replace this copy with the approved `srvctl` / `asmcmd` procedure.


## Source SYS and TDE credentials

The wizard now securely prompts for:

- Source SYS password
- Source TDE wallet/keystore password

Interactive input is hidden. These passwords are **not written** to `standby_placeholder.env`, not displayed in the summary, and should never be passed as command-line arguments.

For unattended execution, inject `SOURCE_SYS_PASSWORD` and `SOURCE_TDE_PASSWORD` from the organization's approved secrets manager or protected runtime environment.

The TDE password is required only when the source database uses a password-protected TDE keystore and the selected standby build procedure needs to open/copy/configure that keystore. The actual wallet/keystore files still need to be handled according to the Oracle TDE/Data Guard procedure.


## Target password consistency

For this standby workflow:

- The target SYS password must match the source SYS password.
- The target TDE wallet/keystore password should match the source TDE password when using the same password-protected keystore workflow.
- The wizard verifies equality when both source and target secret values are supplied.
- The source Oracle password file is copied to the target before connectivity testing, which ensures the target uses the same Oracle password-file credentials.
- None of these passwords are written to the configuration file or printed in logs.


## SSH key prerequisite

Before TNS configuration, password-file copy, RMAN, ZDM, or Data Guard build activity, the wizard performs a blocking SSH-key prerequisite check.

It validates:

```text
Toolkit/control host -> Source
Toolkit/control host -> Target
Source -> Target
Target -> Source
```

The check uses `BatchMode=yes` with password and keyboard-interactive authentication disabled. Therefore a successful result confirms that non-interactive SSH key authentication is working rather than falling back to an OS password prompt.

If any required SSH direction fails, execution stops before the standby build proceeds.

Typical manual verification commands are:

```bash
ssh -o BatchMode=yes -o PasswordAuthentication=no oracle@source-host hostname
ssh -o BatchMode=yes -o PasswordAuthentication=no oracle@target-host hostname

# From source:
ssh -o BatchMode=yes -o PasswordAuthentication=no oracle@target-host hostname

# From target:
ssh -o BatchMode=yes -o PasswordAuthentication=no oracle@source-host hostname
```

Only public keys should be distributed between servers. Never copy a private SSH key from one database server to another.


## TNS prerequisite validation

The standby build now treats `tnsnames.ora` validation on both servers as a blocking prerequisite.

The following four checks must pass:

```text
Source server -> Source TNS alias
Source server -> Target TNS alias
Target server -> Source TNS alias
Target server -> Target TNS alias
```

The wizard verifies that both aliases exist in each server's effective `TNS_ADMIN/tnsnames.ora`, confirms `tnsping` is available from the selected Oracle Home, and runs `tnsping` for both aliases from both servers.

A standalone check is also included:

```bash
source standby_placeholder.env
./tns_standby_precheck.sh
```

Failure of any required TNS check blocks progression to the standby build.


## Source TDE auto-detection

Before requiring TDE-specific standby actions, the wizard checks the source database for encrypted tablespaces using `V$ENCRYPTED_TABLESPACES`.

Behavior:

```text
Encrypted tablespace detected
    -> TDE ENABLED
    -> retain TDE password/keystore validation
    -> continue with TDE standby prerequisites

No encrypted tablespace detected
    -> TDE NOT ENABLED
    -> report status
    -> clear/skip TDE password requirements
    -> continue standby workflow

TDE check cannot be completed
    -> TDE status UNKNOWN
    -> warn operator
    -> require review before production build
```

The check uses source-host local OS authentication (`sqlplus / as sysdba`) so the SYS password is not exposed for the detection query.

Standalone check:

```bash
source standby_placeholder.env
./source_tde_precheck.sh
```


## Existing standby / Data Guard discovery

Before building a new standby, the wizard checks whether the source database already participates in a Data Guard configuration or has an existing remote standby archive destination.

If an existing standby is detected, the wizard does **not** fail automatically. It reports the current configuration, saves a detailed inventory, and continues so the operator can review compatibility before adding another standby.

The discovery includes:

1. **Archive log configuration**
   - `ARCHIVELOG` / `NOARCHIVELOG`
   - `FORCE LOGGING`
   - active `V$ARCHIVE_DEST` entries
   - destination target, service, DB unique name, status, and transport errors

2. **Data Guard configuration**
   - `LOG_ARCHIVE_CONFIG`
   - `LOG_ARCHIVE_DEST_n`
   - `LOG_ARCHIVE_DEST_STATE_n`
   - `FAL_SERVER` / `FAL_CLIENT`
   - `STANDBY_FILE_MANAGEMENT`
   - file-name conversion parameters
   - `REMOTE_LOGIN_PASSWORDFILE`
   - members visible in `V$DATAGUARD_CONFIG`

3. **Standby redo logs**
   - group number
   - redo thread
   - sequence
   - size
   - status
   - archived state
   - per-thread SRL count and size

4. **Online redo logs**
   - group count and size by thread
   - collected so the existing standby redo-log layout can be compared with the source online redo configuration

The main wizard writes the source inventory to:

```text
./source_dataguard_inventory.txt
```

or to the path defined by:

```bash
export DG_REPORT_LOCAL=/path/to/source_dataguard_inventory.txt
```

A standalone inventory command is also provided:

```bash
source standby_placeholder.env
./source_dataguard_precheck.sh
```

When an existing standby is detected, the toolkit should preserve the current `LOG_ARCHIVE_DEST_n` assignments and choose an unused destination number for any new standby rather than overwriting the existing Data Guard transport configuration.


## Safe new standby archive destination

For a new standby, the wizard begins by checking `LOG_ARCHIVE_DEST_10`. If it already contains a value, it checks `LOG_ARCHIVE_DEST_11`, then `12`, and continues until it finds the first unused destination through `31`.

The existing destinations are never overwritten. The wizard generates `new_standby_dataguard_append.sql` that:

```text
preserves the existing Data Guard members
        +
adds the new target DB_UNIQUE_NAME to LOG_ARCHIVE_CONFIG
        +
creates the newly selected LOG_ARCHIVE_DEST_n
        +
sets its matching LOG_ARCHIVE_DEST_STATE_n to DEFER
```

The newly generated remote destination uses the target TNS alias, `ASYNC`, `NOAFFIRM`, `VALID_FOR=(ONLINE_LOGFILES,PRIMARY_ROLE)`, and the target `DB_UNIQUE_NAME`. It is deliberately generated in the `DEFER` state so transport is not started before the new standby is ready.

## Standby redo log safety logic

The toolkit does not blindly create redo groups. It checks each source redo thread independently.

For each thread it determines:

```text
required standby redo groups = online redo groups + 1
standby redo size            = largest online redo size for that thread
first new GROUP#             = max(existing online/SRL GROUP#) + 1
```

If the existing standby redo logs already satisfy the requirement, no new SRLs are generated. If groups are missing, only the missing groups are added, with monotonically increasing unused group numbers.

The SQL is saved in:

```text
new_standby_srl_create.sql
```

Review the generated SQL before execution, especially on RAC/ASM systems where redo placement, thread ownership, multiplexing, and disk-group policy must follow the platform standard.


## DG_CONFIG existence check and setup

The wizard now explicitly checks `LOG_ARCHIVE_CONFIG` before generating the new standby configuration.

If the source already has:

```text
LOG_ARCHIVE_CONFIG='DG_CONFIG=(existing_primary,existing_standby,...)'
```

the existing member list is preserved and the new standby `DB_UNIQUE_NAME` is appended only if it is not already present.

If `LOG_ARCHIVE_CONFIG` is empty or does not contain `DG_CONFIG`, the wizard initializes it with:

```text
DG_CONFIG=(<source_db_unique_name>,<new_target_db_unique_name>)
```

The generated Data Guard SQL also sets:

```sql
ALTER SYSTEM SET STANDBY_FILE_MANAGEMENT='AUTO' SCOPE=BOTH;
```

The same `DG_CONFIG` member list must ultimately be configured on both primary and standby databases. Oracle documents `LOG_ARCHIVE_CONFIG='DG_CONFIG=(...)'` as the Data Guard member list and states that it should contain the `DB_UNIQUE_NAME` of every database in the Data Guard configuration.

A standalone precheck/setup helper is included:

```bash
source standby_placeholder.env

# Review only
./dg_config_precheck_setup.sh

# Apply to source after review
EXECUTE=true ./dg_config_precheck_setup.sh
```


## DG_CONFIG append-only rule

When `LOG_ARCHIVE_CONFIG='DG_CONFIG=(...)'` already exists, the toolkit treats it as an **append-only configuration**:

```text
Existing:
DG_CONFIG=(PRIMARY1,STANDBY1,STANDBY2)

New standby:
STANDBY3

Result:
DG_CONFIG=(PRIMARY1,STANDBY1,STANDBY2,STANDBY3)
```

It must **not** become:

```text
DG_CONFIG=(PRIMARY1,STANDBY3)
```

because that would remove existing Data Guard members.

The generated SQL prints the value before and after the change so the operator can verify that no existing member was removed. If the new standby `DB_UNIQUE_NAME` is already present, it is not duplicated.


## Duplicate-value validation before DG_CONFIG update

Before the toolkit generates or applies any `LOG_ARCHIVE_CONFIG` change, it now performs a case-insensitive duplicate check on the existing `DG_CONFIG` member list.

Example:

```text
Existing:
DG_CONFIG=(PRIMARY1,STANDBY1,standby1,STANDBY2)

Normalized before update:
DG_CONFIG=(PRIMARY1,STANDBY1,STANDBY2)
```

Then the new standby is evaluated:

```text
New DB_UNIQUE_NAME already present
    -> do not append it again

New DB_UNIQUE_NAME missing
    -> append exactly once
```

A final validation is performed after append planning. If any duplicate value remains, the toolkit aborts the change rather than generating/applying an unsafe `LOG_ARCHIVE_CONFIG` update.


## LOG_ARCHIVE_DEST_n duplicate-value protection

The same no-duplicate safety rule now applies to archive destinations.

Before creating or appending any new `LOG_ARCHIVE_DEST_n`, the toolkit reads all configured `LOG_ARCHIVE_DEST_1` through `LOG_ARCHIVE_DEST_31` values and validates them case-insensitively with whitespace ignored.

Behavior:

```text
Existing duplicate LOG_ARCHIVE_DEST_n values found
    -> report the destination numbers
    -> STOP before adding anything

New standby DB_UNIQUE_NAME or SERVICE already exists
    -> report the matching LOG_ARCHIVE_DEST_n
    -> preserve it
    -> DO NOT create another destination

No existing matching standby/service
    -> scan LOG_ARCHIVE_DEST_10 through 31
    -> choose first unused destination number
    -> append exactly one new destination
```

This protects both the destination slot and the destination **value**. The toolkit will not create two remote archive destinations that point to the same standby `DB_UNIQUE_NAME` or target TNS service.

Existing unique archive destinations are never deleted or overwritten.


## Non-RAC active physical standby duplicate

The wizard now includes a build phase specifically for a **single-instance / non-RAC target**.

Before live execution it checks `CLUSTER_DATABASE`. If the target reports `TRUE`, the workflow stops because this path is not intended for RAC. If the placeholder instance is not yet available, the generated RMAN SPFILE settings explicitly set:

```text
CLUSTER_DATABASE=FALSE
DB_UNIQUE_NAME=<new standby unique name>
STANDBY_FILE_MANAGEMENT=AUTO
```

The generated RMAN workflow uses:

```text
DUPLICATE TARGET DATABASE FOR STANDBY
FROM ACTIVE DATABASE
DORECOVER
SPFILE
```

with configurable primary and auxiliary RMAN channels.

After RMAN finishes, the toolkit verifies the target database role and then deliberately performs:

```sql
SHUTDOWN IMMEDIATE;
STARTUP MOUNT;
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE DISCONNECT FROM SESSION;
```

It then queries `V$DATAGUARD_PROCESS` to verify Data Guard activity.

Oracle documents that `DUPLICATE ... FOR STANDBY FROM ACTIVE DATABASE` copies the source database to the standby and leaves the standby mounted. Oracle Data Guard documentation also documents `STARTUP MOUNT` followed by managed standby recovery for a physical standby.

### Credential handling

The reusable `active_standby_duplicate.rman` template does **not** contain passwords. For live execution the wrapper creates a temporary mode-600 RMAN command file containing the runtime SYS credentials, transfers it to the target, runs RMAN, and removes the temporary command file immediately afterward.

The RMAN log remains on the target at `/tmp/zdm360_active_duplicate.log` for build review. The toolkit does not intentionally print SYS or TDE passwords.


## Standby build choice: offline RMAN backup or active duplicate

The wizard now prompts for the physical standby build method:

```text
ACTIVE_DUPLICATE
OFFLINE_BACKUP
```

### OFFLINE_BACKUP workflow

The operator is prompted for:

```text
Source RMAN backup stage directory
Target RMAN backup stage directory
Backup staging method: SCP / RSYNC / NFS
```

The toolkit first checks whether backup files exist in the source staging area and records the result in:

```text
offline_backup_validation_report.txt
```

When an existing backup is found, the toolkit also runs RMAN `LIST BACKUP SUMMARY` and `CROSSCHECK BACKUP` against the source RMAN inventory for validation.

If no backup exists, the result is explicitly:

```text
BACKUP NOT FOUND
```

and the standby duplicate is blocked. The operator can then either:

```text
1. Create a consistent offline RMAN backup during an approved outage.
2. Copy/stage an existing backup to the target.
3. Use an NFS/shared backup location.
4. Change the build method to ACTIVE_DUPLICATE.
```

A generated `create_offline_source_backup.rman` template performs a consistent source shutdown, starts the database MOUNT, backs up the database, standby control file, and SPFILE to the chosen stage, and then reopens the source database.

A generated `stage_offline_backup.sh` validates/copies the backup using SCP, RSYNC, or NFS and compares source/target staged file counts.

After staging, the target RMAN session catalogs/lists the staged pieces and uses a backup-based:

```text
DUPLICATE DATABASE FOR STANDBY
  BACKUP LOCATION '<target stage>'
  DORECOVER
  SPFILE ...
```

The same post-build process is used for both methods:

```text
verify PHYSICAL STANDBY
SHUTDOWN IMMEDIATE
STARTUP MOUNT
start managed redo recovery
validate Data Guard processes
```

Oracle RMAN supports standby duplication either from an active database or from pre-existing RMAN backups. For disk backup-based duplication across hosts, the backup pieces must be made accessible to the auxiliary host, such as by transfer or shared/NFS storage.


## Post-restore conversion/validation for a RAC standby target

After either `ACTIVE_DUPLICATE` or `OFFLINE_BACKUP` restore completes, the wizard can convert the restored single-instance standby into an Oracle RAC standby.

It prompts whether the target should run as RAC and, when enabled, collects the target RAC instance count, `GRID_HOME`, SCAN name, undo tablespace prefix, and redo size policy.

The post-restore validation checks:

```text
DATABASE_ROLE / OPEN_MODE
CLUSTER_DATABASE
existing RAC instances
V$THREAD
V$LOG
V$STANDBY_LOG
UNDO tablespaces
DB_CREATE_FILE_DEST / OMF availability
SRVCTL database registration
```

For every required RAC instance, the workflow validates that a dedicated undo tablespace exists. Missing undo tablespaces are generated only when an OMF/ASM-safe `DB_CREATE_FILE_DEST` is available. Oracle RAC requires an undo tablespace for each instance when automatic undo management is used.

It also validates redo threads. If a required thread is absent, the generated fix creates at least two online redo groups for that thread and enables the thread. Standby redo logs are validated per thread and the toolkit generates enough groups to reach:

```text
standby redo groups >= online redo groups + 1
```

using at least the largest online redo size.

Before modifying log groups, Redo Apply is stopped and `STANDBY_FILE_MANAGEMENT` is temporarily set to `MANUAL`; it is restored to `AUTO` afterward. This follows Oracle Data Guard guidance for manually changing redo/standby redo groups on a physical standby.

Finally, `CLUSTER_DATABASE=TRUE` is written to the SPFILE, the database is shut down, and the toolkit checks `srvctl config database`. If the database is already registered with Clusterware, it starts the RAC standby with SRVCTL in MOUNT mode, validates `GV$INSTANCE`, redo threads, undo, online/SRL counts, and restarts managed Redo Apply.

The workflow deliberately refuses to auto-create undo/redo files when it cannot establish an OMF/ASM-safe destination. In that case it reports the missing RAC requirements for manual placement instead of guessing filesystem or ASM paths.


## v16: Post-build Data Guard validation and DR operations

After active duplicate or offline RMAN restore, the wizard can now automatically validate and synchronize Data Guard. It also includes separate guarded utilities for snapshot standby, switchover, and failover.

### RAC standby post-restore check/fix

`post_restore_rac_validate_fix.sh` verifies the restored database is a physical standby, requires OMF/ASM-safe `DB_CREATE_FILE_DEST`, validates a dedicated undo tablespace for each requested RAC instance, validates online redo threads/groups, validates standby redo logs per thread, and generates only the missing objects. It sets `CLUSTER_DATABASE=TRUE` in the SPFILE only after the required RAC structures are present. The database is then started with `srvctl` in MOUNT mode and Redo Apply is restarted.

The helper refuses to guess file placement when OMF/ASM-safe placement is not available.

### Verify Data Guard is working

`dg_postbuild_validate.sh` produces `dg_postbuild_health_report.txt` with:

- database role/open mode and `SWITCHOVER_STATUS`
- protection mode and protection level
- archive destination status and synchronization status
- transport lag, apply lag, and apply finish time
- archive gaps
- Data Guard recovery/transport processes
- offline/inaccessible data files
- Error/Fatal Data Guard messages
- Broker `SHOW CONFIGURATION`, `VALIDATE DATABASE VERBOSE`, and network validation when Broker is enabled

### Synchronize/catch up the standby

`dg_sync_database.sh` forces `ARCHIVE LOG CURRENT` on the primary, then polls the standby until there are no archive gaps and transport/apply lag are below one minute, or until `SYNC_WAIT_SECONDS` expires.

### Snapshot standby

```bash
./dg_snapshot_standby.sh status
EXECUTE=true ./dg_snapshot_standby.sh to-snapshot
EXECUTE=true ./dg_snapshot_standby.sh to-physical
```

A snapshot standby must be converted back to physical standby and synchronized before switchover/failover testing.

### Switchover

```bash
./dg_switchover.sh precheck
EXECUTE=true ./dg_switchover.sh to-standby
EXECUTE=true ./dg_switchover.sh back-to-source
```

The switchover helper requires Data Guard Broker and uses Broker validation before the role transition. Live role changes require an explicit typed confirmation unless `AUTO_CONFIRM=YES` is intentionally configured.

### Failover / DR test

```bash
./dg_failover.sh precheck
EXECUTE=true ./dg_failover.sh to-standby
EXECUTE=true ./dg_failover.sh reinstate-source
```

The failover precheck uses `VALIDATE DATABASE ... STRICT ALL`. Failover is intended only for an approved DR exercise or an actual primary failure. If possible, shut down the failed/original primary before manual failover to avoid split-brain risk. Reinstatement depends on Broker/Flashback prerequisites; otherwise the old primary must be rebuilt.

### Recommended validation cycle

```text
BUILD STANDBY
  -> RAC validation/fix when target is RAC
  -> Data Guard health validation
  -> database synchronization/catch-up
  -> optional snapshot standby test
  -> convert snapshot back to physical
  -> synchronize again
  -> switchover precheck
  -> planned switchover
  -> validate/synchronize in new roles
  -> optional switchback
  -> failover only for approved DR testing or real outage
  -> reinstate/rebuild former primary
```
