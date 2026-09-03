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
