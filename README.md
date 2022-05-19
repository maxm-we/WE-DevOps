# WE-DevOps PowerShell Module Overview

## Start-WESqlBackup

### Full Backups

Start Full backup with prompt to select database to be backed up. Backup file will automatically be named with the following format: `<Current Date>-<Database Name>.bak` 

Example: `20200904123456-devops_test.bak`

Default backup location: `S:\Backups\`

```PowerShell
Start-WESqlBackup -BackupType FULL
```

Below are examples of specifing database and backupfile
```PowerShell
Start-WESqlBackup -BackupType FULL -Database devops_test
```

```PowerShell
Start-WESqlBackup -BackupType FULL -Database devops_test -BackupFile 'S:/Backups/devops_test.bak'
```

### Diff Backups

Start Diff backup with prompt to select database to be backed up. Script will automatically select the last Full backup as the backup location.

```PowerShell
Start-WESqlBackup -BackupType DIFF
```

Below are examples of specifing database and backupfile

```PowerShell
Start-WESqlBackup -BackupType DIFF -Database devops_test
```

```PowerShell
Start-WESqlBackup -BackupType DIFF -Database devops_test -BackupFile 'S:/Backups/devops_test.diff'
```

## Start-WESQLRestore
Start database restore with prompts for database and backup file(s). 

??? note "-DeleteBackup"
    `-DeleteBackup $true` will prompt to confirm the deletion of files after the restore is completed. 

```PowerShell
Start-WESQLRestore -DeleteBackup $true
```

Start database restore specifying database and backup media.

```PowerShell
Start-WESQLRestore -Database devops_test -BackupFile 'S:/Backups/devops_test.bak' -DeleteBackup $true
```

## RestoreFrom-WESqlLastFull
`RestoreFrom-WESqlLastFull` will download the lastest full backup of the client's database specified from AWS S3 and restore to the database specified.

Running `RestoreFrom-WESqlLastFull` without any parameters will prompt for:

- Client
- Destination Database
- Source Database

```PowerShell
RestoreFrom-WESqlLastFull
```

Example with all parameters specified.
```PowerShell
RestoreFrom-WESqlLastFull -Client DevOps-Test -DestinationDatabase devops_support -SourceDatabase devops_test
```

## Get-WEClientDB
`Get-WEClientDB` will retrieve a list of client DBs with backups that are available on AWS S3.

```PowerShell
Get-WEClientDB -Client DevOp-Test
```

## Get-WESqlCommandStatus
`Get-WESqlCommandStatus` will retrieve the status of commands running on SQL.

Accepted Commands:
- Restore
- Backup
- Select
- All (All is selected by default if a command is not given)

```PowerShell
Get-WESqlCommandStatus -Command RESTORE
```
Example Output
```
session_id          : 60
command             : RESTORE
Percent_Complete    : 11.08
start_time          : 9/3/2020 10:11:37 AM
ETA_Completion_Time : 2020-09-03 11:54:16
Elapsed_Min         : 11.70
ETA_Min             : 90.96
ETA_Hours           : 1.52
```

## Get-WESqlStatus
`Get-WESqlStatus` will retrieve the following information for all databases on the SQL Server

 - Database
 - DB_Size_GB
 - DB_Log_Size_GB
 - Client
 - LastActivity
 - RestoreDate
 - RestoredBy

```PowerShell
Get-WESqlStatus
```

Example Output
```
Database       : devops_test
DB_Size_GB     : 0.25
DB_Log_Size_GB : 0.44
Client         : Waterfield
LastActivity   : 7/21/2020 7:32:01 PM
RestoreDate    : 9/1/2020 5:27:20 PM
RestoredBy     : weaws\dev.ops
```

Output can also be formatted into a table
```PowerShell
Get-WESqlStatus | Format-Table -AutoSize
```

Example Table Output
Database | DB_Size_GB | DB_Log_Size_GB | Client | LastActivity | RestoreDate | RestoredBy
-------- | ---------- | -------------- | ------ | ------------ | ----------- | ----------
devops_test | 0.25 | 0.44 | Waterfield | 7/21/2020 7:32:01 PM | 9/1/2020 5:27:20 PM | weaws\dev.ops