function Start-WESqlRestore {
    [CmdletBinding()]
    [Alias()]
    [OutputType()]
    Param
    (
        [Parameter()]
        [string] $ServerInstance = $env:COMPUTERNAME,
        [Parameter()]
        $Database,
        [Parameter(ValueFromPipeline = $true)]
        [string] $BackupFile,
        [Parameter()]
        [string] $DiffFile,
        [Parameter(ParameterSetName = 'LogBackup')]
        [string[]] $LogBackups,
        [Parameter()]
        [bool] $Logging = $true,
        [Parameter()]
        [switch] $DeleteBackup,
        [Parameter(ParameterSetName = 'LogBackup')]
        [switch] $DeleteLogs,
        [Parameter()]
        [switch] $RemoveSchedules,
        [Parameter()]
        [switch] $OutputScriptOnly,
        [Parameter()]
        [switch] $OutputAsObject,
        [Parameter(ValueFromPipeline = $True)]
        [object] $PipedObject
    )
    Begin {

        # Loudly check for admin
        if (-not (Test-Administrator)) { return }

    }
    Process {
        Add-Type -AssemblyName System.Windows.Forms
        # Logging Function
        function LogThis ([string]$WhatToLog) {
            $DateStamp = Get-Date -Format s
            $WhatToLog = "[" + $DateStamp + "] " + $WhatToLog
            Write-Output $WhatToLog
            Out-File -FilePath $LogFile -Append -InputObject $WhatToLog
        }
        # Convert Pipe Object
        if ($PipedObject) {
            $BackupFile = $PipedObject.BackupFile
            If ($PipedObject.LogBackups) {
                $LogBackups = $PipedObject.LogBackups
            }
            if ($PipedObject.DiffFile) {
                $DiffFile = $PipedObject.DiffFile
            }
        }
        else {
            Write-Verbose "No Piped Input Detected, Continuing..."
        }

        #region Validation
        if ( (-not $BackupFile) -or (-not $Database) ) {
            Start-WEGui
            return
        }
        #endregion
        if ($Database -is [string]) {
            Try {
                $Database = Get-SqlDatabase -ServerInstance $ServerInstance -Name $Database
            }
            Catch [Microsoft.SqlServer.Management.PowerShell.SqlPowerShellObjectNotFoundException] {
                return [PSCustomObject]@{
                    Status  = "Error"
                    Message = "Unable to locate database to restore to with the name: $Database"
                }
            }
            Catch {
                return $_
            }
        }
        # Set Script and Backup Directory variables
        if ($env:USERDOMAIN -eq "weaws") {
            $ScriptDirectory = "S:\Scripts"
        }
        elseif ($env:USERDOMAIN -eq "WE") {
            $ScriptDirectory = "FileSystem::\\fs01.we.local\backups\Scripts"
        }
        #region Start Logging
        if ($Logging -eq $true) {
            # Create Log File
            $StartDateStamp = Get-Date -Format yyyyMMdd_hhmm
            $PathCheck = Test-Path -Path "$ScriptDirectory\ScriptLogs"
            if ($PathCheck -eq $false) { New-Item -Path "$ScriptDirectory\ScriptLogs" -ItemType Directory }
            $LogFile = "$ScriptDirectory\ScriptLogs\$StartDateStamp-restore-$($Database.Name).log"
            Write-Verbose "Log file: $LogFile"
            LogThis "Username: $env:USERNAME"
            LogThis "DestinationDatabase: $($Database.Name)"
            LogThis "BackupFile: $BackupFile"
        }
        #endregion
        #region Gather content and filelist information from backup
        $SqlBackupContents = "use [$($Database.Name)];
        RESTORE HEADERONLY
        FROM DISK = N'$BackupFile' ;
        GO
        "
        try {
            $BackupContents = Invoke-Sqlcmd -ServerInstance $ServerInstance -Database $Database.Name -Query $SqlBackupContents -ErrorAction Stop
        }
        catch {
            LogThis "$_"
            throw "$_"
        }
        $SqlBackupFileList = "
        use [$($Database.Name)];
        RESTORE FILELISTONLY
        FROM DISK = N'$BackupFile' ;
        GO
        "
        try {
            $BackupFileList = Invoke-Sqlcmd -ServerInstance $ServerInstance -Database $Database.Name -Query $SqlBackupFileList -ErrorAction Stop
        }
        catch {
            if ($OutputAsObject) {
                if ($logging -eq $true) {
                    LogThis "$_"
                } else {
                    return $_
                }
            }
            else {
                LogThis "$_"
                throw "$_"
            }
        }
        if ($LogBackups) {
            if ($LogBackups -match "\.trn") {
                $logfiles = $LogBackups | Where-Object { $_ -match "\.trn$" } | Sort-Object
            }
            elseif ($LogBackups -notmatch "\.trn") {
                $logfiles = Get-ChildItem -Path $LogBackups -Filter *.trn | Sort-Object | Select-Object -ExpandProperty FullName
            }
            $RestoreLogText = ""
            # Replay any logs with a write time greater than the last full backup.
            foreach ($log in $logfiles) {
                $logInfo = Invoke-Sqlcmd -ServerInstance $ServerInstance -Query "RESTORE HEADERONLY FROM DISK = '$log'"
                if ($logInfo.LastLSN -ge $BackupContents.LastLSN -and $logInfo.DatabaseName -eq $BackupContents.DatabaseName) {
                    $RestoreLogText += "
RESTORE LOG [$($Database.Name)] FROM DISK = N'$log' WITH  FILE = 1,  NORECOVERY,  NOUNLOAD,  STATS = 5
"
                }
            }
        }
        #endregion
        #region Initialize/set variables
        if ($env:USERDOMAIN -eq "weaws") {
            $DestinationDBFile = 'D:\MSSQL\DATA\{0}.mdf' -f $Database.Name
            $DestinationLogFile = 'E:\MSSQL\LOGS\{0}_log.ldf' -f $Database.Name
        }
        elseif ($env:USERDOMAIN -eq "WE") {
            $DestinationDBFile = 'D:\MSSQL\DATA\{0}.mdf' -f $Database.Name
            $DestinationLogFile = 'E:\MSSQL\trnlogs\{0}_log.ldf' -f $Database.Name
        }
        $SourceLogicalDBName = ($BackupFileList | Where-Object { $_.Type -eq 'D' }).LogicalName
        $SourceLogicalLogName = ($BackupFileList | Where-Object { $_.Type -eq 'L' }).LogicalName
        $DestinationLogicalDBName = "$($Database.Name)"
        $DestinationLogicalLogName = "$($Database.Name)_log"
        $SqlAlterLogicalNames = "
USE [$($Database.Name)]
ALTER DATABASE [$($Database.Name)] MODIFY FILE (NAME=N'$SourceLogicalDBName', NEWNAME=N'$DestinationLogicalDBName')
GO
ALTER DATABASE [$($Database.Name)] MODIFY FILE (NAME=N'$SourceLogicalLogName', NEWNAME=N'$DestinationLogicalLogName')
GO
"
        if ($logging -eq $true) {
            LogThis "DatabaseRecoveryModel: $($Database.RecoveryModel)"
        }
        $SQLAlterRecovery = "
USE [master]
ALTER DATABASE [$($Database.Name)] SET RECOVERY $($Database.RecoveryModel)
GO
"
        if ($RemoveSchedules) {
            if ($logging -eq $true) {
                LogThis "RemoveSchedules: True"
            }
            $SQLRemoveSchedules = "
USE [$($Database.Name)]
IF OBJECT_ID(N'process_schedules', N'U') IS NOT NULL
BEGIN
    update process_schedules set active = 0
END
GO
"
        }
        else {
            if ($logging -eq $true) {
                LogThis "RemoveSchedules: False"
            }

        }
        #endregion
        #region Gather SQL DB Permissions

        $SQLPermissions = "USE [$($Database.Name)]
"
        #region Drop DB Users
        $SQLPermissions += "
-- [-- DROP DB USERS --] --
"
        $DbLogins = $Database.EnumLoginMappings() | Where-Object { $_.UserName -ne "dbo" }
        foreach ($dbl in $DbLogins) {
            $DBLInfo = Invoke-Sqlcmd -ServerInstance $ServerInstance -Query "SELECT name FROM sys.server_principals WHERE name = '$($dbl.UserName)'"
            if ($DBLInfo) {
                $SQLPermissions += "IF EXISTS (SELECT [name] FROM sys.database_principals WHERE [name] =  '$($dbl.UserName)') BEGIN DROP USER  [$($dbl.UserName)] END;
"
            }
        }
        #endregion
        #region Create DB Users
        $SQLPermissions += "
-- [-- CREATE DB USERS --] --
"
        $DbLogins = $Database.EnumLoginMappings() | Where-Object { $_.UserName -ne "dbo" }
        foreach ($dbl in $DbLogins) {
            $DBLInfo = Invoke-Sqlcmd -ServerInstance $ServerInstance -Query "SELECT name FROM sys.server_principals WHERE name = '$($dbl.UserName)'"
            if ($DBLInfo) {
                $SQLPermissions += "IF NOT EXISTS (SELECT [name] FROM sys.database_principals WHERE [name] =  '$($dbl.UserName)') BEGIN CREATE USER  [$($dbl.UserName)] FOR LOGIN [$($dbl.LoginName)] WITH DEFAULT_SCHEMA = [dbo] END;
"
            }
        }
        #endregion
        #region Roles
        $DbRoles = $Database.Roles
        $rolesObj = foreach ($role in $DbRoles) {
            $RoleMembers = $role.EnumMembers() | Where-Object { $_ -ne "dbo" }
            foreach ($member in $RoleMembers) {
                [PSCustomObject] @{
                    Name   = $role.Name
                    Member = $member
                }
            }
        }
        $SQLPermissions += "
-- [-- DB ROLES --] --
"
        $SQLPermissions += "IF DATABASE_PRINCIPAL_ID('public') IS NULL CREATE ROLE [public]
"
        foreach ($ro in $rolesObj) {
            $SPInfo = Invoke-Sqlcmd -ServerInstance $ServerInstance -Query "SELECT name FROM master.sys.server_principals WHERE name = '$($ro.Member)'"
            if ($SPInfo) {
                $SQLPermissions += "IF DATABASE_PRINCIPAL_ID('$($ro.Member)') IS NOT NULL EXEC sp_addrolemember @rolename = '$($ro.Name)', @membername = '$($ro.Member)'
"
            }
        }
        #endregion
        #region DB LEVEL PERMISSIONS
        $SQLPermissions += "
-- [-- DB LEVEL PERMISSIONS --] --
"
        $DbPerms = $Database.EnumDatabasePermissions() | Where-Object { $_.Grantee -ne "dbo" }
        foreach ($dbp in $DbPerms) {
            $DBPInfo = Invoke-Sqlcmd -ServerInstance $ServerInstance -Query "SELECT name FROM master.sys.server_principals WHERE name = '$($dbp.Grantee)'"
            if ($DBPInfo) {
                $SQLPermissions += "IF DATABASE_PRINCIPAL_ID('$($dbp.Grantee)') IS NOT NULL $($dbp.PermissionState) $($dbp.PermissionType) TO [$($dbp.Grantee)]
"
            }
        }
        #endregion
        #region DB LEVEL SCHEMA PERMISSIONS
        $SQLPermissions += "
-- [-- DB LEVEL SCHEMA PERMISSIONS --] --
"
        $sqlSchemaPerms = "
SELECT pr.principal_id, 
    pr.name AS Grantee, 
	pr.type_desc,   
    pr.authentication_type_desc, 
	pe.state_desc AS PermissionState,   
    pe.permission_name AS PermissionType, 
	s.name AS ObjectSchema, 
	o.name AS ObjectName  
FROM sys.database_principals AS pr
JOIN sys.database_permissions AS pe  
    ON pe.grantee_principal_id = pr.principal_id  
JOIN sys.objects AS o  
    ON pe.major_id = o.object_id  
JOIN sys.schemas AS s  
    ON o.schema_id = s.schema_id; 
"
        $DbSchemaPerms = Invoke-Sqlcmd -ServerInstance $ServerInstance -Database $Database.Name -Query $sqlSchemaPerms
        if ($DbSchemaPerms) {
            foreach ($dbsp in $DbSchemaPerms) {
                $SQLPermissions += "$($dbsp.PermissionState) $($dbsp.PermissionType) ON [$($dbsp.ObjectSchema)].[$($dbsp.ObjectName)] TO [$($dbsp.Grantee)]
"
            }
        }
        #endregion
        #endregion
        #region RecoveryModel SIMPLE restore script
        if (-not $logfiles) {
            #region SIMPLE with Full and Diff backups in the same media
            if ($BackupContents.Count -gt 1 -and -not $DiffFile) {
                $SQLRestore = "
USE [master]
SET DEADLOCK_PRIORITY HIGH
ALTER DATABASE [$($Database.Name)] SET SINGLE_USER WITH ROLLBACK IMMEDIATE
RESTORE DATABASE [$($Database.Name)] FROM  DISK = N'$BackupFile' WITH  FILE = 1,
    MOVE N'$SourceLogicalDBName' TO N'$DestinationDBFile',
    MOVE N'$SourceLogicalLogName' TO N'$DestinationLogFile',
    NORECOVERY, NOUNLOAD,  REPLACE,  STATS = 5
RESTORE DATABASE [$($Database.Name)] FROM  DISK = N'$BackupFile' WITH  FILE = $($BackupContents.Count),  NOUNLOAD,  STATS = 5
ALTER DATABASE [$($Database.Name)] SET MULTI_USER
GO
SET DEADLOCK_PRIORITY HIGH
EXEC [$($Database.Name)].dbo.sp_changedbowner @loginame = N'$($Database.Owner)', @map = false
GO
$SqlAlterLogicalNames
$SQLAlterRecovery
$SQLRemoveSchedules
$SQLPermissions
"
            }
            #endregion
            #region SIMPLE with Full and Diff backups using separate media
            elseif ($DiffFile) {
                if ($logging -eq $true) {
                    LogThis "DiffFile: $DiffFile"
                }

                <#
                $SqlDiffContent = "
                use [$($Database.Name)];
                RESTORE HEADERONLY
                FROM DISK = N'$DiffFile' ;
                GO
                "
                try {
                    $DiffFileContents = Invoke-Sqlcmd -ServerInstance $ServerInstance -Database $Database.Name -Query $SqlDiffContent -ErrorAction Stop
                }
                catch {
                    LogThis "$_"
                    throw "$_"
                }
                if ( $DiffFileContents.DatabaseName -notmatch $BackupContents.DatabaseName ) {
                    logthis "Invalid Backup Media. DatabaseName does not match."
                    logthis "FullDatabaseName: $($BackupContents.DatabaseName)"
                    logthis "DiffDatabaseName: $($DiffFileContents.DatabaseName)"
                    Throw "Invalid Backup Media. DatabaseName does not match. FULL: $($BackupContents.DatabaseName) DIFF: $($DiffFileContents.DatabaseName)"
                }
                #>
                $SQLRestore = "
USE [master]
SET DEADLOCK_PRIORITY HIGH
ALTER DATABASE [$($Database.Name)] SET SINGLE_USER WITH ROLLBACK IMMEDIATE
RESTORE DATABASE [$($Database.Name)] FROM  DISK = N'$BackupFile' WITH  FILE = 1,
    MOVE N'$SourceLogicalDBName' TO N'$DestinationDBFile',
    MOVE N'$SourceLogicalLogName' TO N'$DestinationLogFile',
    NORECOVERY, NOUNLOAD,  REPLACE,  STATS = 5
RESTORE DATABASE [$($Database.Name)] FROM  DISK = N'$DiffFile' WITH  FILE = 1,  NOUNLOAD,  STATS = 5
ALTER DATABASE [$($Database.Name)] SET MULTI_USER
GO
SET DEADLOCK_PRIORITY HIGH
EXEC [$($Database.Name)].dbo.sp_changedbowner @loginame = N'$($Database.Owner)', @map = false
GO
$SqlAlterLogicalNames
$SQLAlterRecovery
$SQLRemoveSchedules
$SQLPermissions
"
            }
            #endregion
            #region SIMPLE with Full backup only
            else {
                $SQLRestore = "
USE [master]
SET DEADLOCK_PRIORITY HIGH
ALTER DATABASE [$($Database.Name)] SET SINGLE_USER WITH ROLLBACK IMMEDIATE
RESTORE DATABASE [$($Database.Name)] FROM  DISK = N'$BackupFile' WITH  FILE = 1,
    MOVE N'$SourceLogicalDBName' TO N'$DestinationDBFile',
    MOVE N'$SourceLogicalLogName' TO N'$DestinationLogFile',
    NOUNLOAD,  REPLACE,  STATS = 5
ALTER DATABASE [$($Database.Name)] SET MULTI_USER
GO
EXEC [$($Database.Name)].dbo.sp_changedbowner @loginame = N'$($Database.Owner)', @map = false
GO
$SqlAlterLogicalNames
$SQLAlterRecovery
$SQLRemoveSchedules
$SQLPermissions
"
            }
            #endregion
        }
        #endregion
        #region RecoveryModel FULL restore script
        elseif ($logfiles) {
            $SQLRestore = "
USE [master]
SET DEADLOCK_PRIORITY HIGH
ALTER DATABASE [$($Database.Name)] SET SINGLE_USER WITH ROLLBACK IMMEDIATE
RESTORE DATABASE [$($Database.Name)] FROM  DISK = N'$BackupFile' WITH  FILE = 1,
    MOVE N'$SourceLogicalDBName' TO N'$DestinationDBFile',
    MOVE N'$SourceLogicalLogName' TO N'$DestinationLogFile',
    NORECOVERY, NOUNLOAD,  REPLACE,  STATS = 5
$RestoreLogText
RESTORE DATABASE [$($Database.Name)] WITH RECOVERY
GO
ALTER DATABASE [$($Database.Name)] SET MULTI_USER
GO
EXEC [$($Database.Name)].dbo.sp_changedbowner @loginame = N'$($Database.Owner)', @map = false
GO
$SqlAlterLogicalNames
$SQLAlterRecovery
$SQLRemoveSchedules
$SQLPermissions
"
        }
        #endregion
        #region Run and logging of Restore script
        if ($OutputScriptOnly) {
            LogThis "--- Output Script Only ---"
            Write-Output $SQLRestore
            LogThis "--- Output Script Only ---"
            LogThis "--- No Action Taken ---"
            return
        }
        if ($Logging -eq $true) {
            logthis "Starting restore of database '$($Database.Name)' using the following settings: `n$SQLRestore"
        }
        try {
            $SQLResults = Invoke-Sqlcmd -ServerInstance $ServerInstance -Query $SQLRestore -QueryTimeout 0 -ErrorAction Stop -Verbose  4>&1
            Set-Location C:
        }
        catch {
            Write-Warning "$_"
            if ($logging -eq $true) {
                LogThis $_
            }
            return
        }
        if ($OutputAsObject) {
            $objectReturn = [PSCustomObject]@{
                restoreStatus = "Finished restore of database '$($Database.Name)' with the following results:"
                results       = "$SQLResults"
            }
        }
        if ($Logging -eq $true) {
            logthis "Finished restore of database '$($Database.Name)' with the following results:"
            foreach ($Line in $SQLResults) {
                if ($Logging -eq $true) {
                    logthis "`t$Line"
                }
            }
        }
        #endregion
        #region Post Run cleanup
        if ($DeleteBackup -eq $true) {
            Remove-Item $BackupFile -Confirm:$true
            if ($logging -eq $true -and (Test-Path $BackupFile) -eq $false) {
                logthis "Removed '$BackupFile'"
            }
            if ($DiffFile) {
                Remove-Item $DiffFile -Confirm:$true
                if ($logging -eq $true -and (Test-Path $DiffFile) -eq $false) {
                    logthis "Removed '$DiffFile'"
                }
            }
        }
        if ($LogFolder -and $DeleteLogs -eq $true) {
            Remove-Item $LogFolder -Recurse -Confirm:$true
            if ($logging -eq $true -and (Test-Path $LogFolder) -eq $false) {
                logthis "Removed '$LogFolder'"
            }
        }
        #endregion
    }
    End {
        if ($OutputAsObject) {
            return $objectReturn
        }
        Set-Location C:
    }
}

