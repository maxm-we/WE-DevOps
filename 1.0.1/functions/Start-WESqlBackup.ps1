function Start-WESqlBackup {
    [CmdletBinding()]
    [Alias()]
    [OutputType()]
    param (
        [Parameter()]
        [string]
        $ServerInstance = $env:COMPUTERNAME,
        [Parameter()]
        $Database,
        [Parameter(Mandatory=$true)]
        [ValidateSet("FULL", "DIFF")]
        [String]
        $BackupType,
        [Parameter()]
        [String]
        $BackupFile,
        [Parameter()]
        [int]
        $PivotalID
    )
    begin {
        # Loudly check for admin
        if (-not (Test-Administrator)) { return }
    }
    process {
        $DateStamp = Get-Date -f yyyyMMdd_hhmm
        # Prompt for database selection if database isn't provided
        if (-not $Database){
            $Database = Get-SqlDatabase -ServerInstance $ServerInstance | Where-Object {$_.Name -notin ('msdb','master','model','dba_utils','tempdb','cs-cognos11','cs-audit')} | Out-GridView -PassThru -Title "Select Database to backup"
        }
        elseif ($Database -is [string]) {
            $Database = Get-SqlDatabase -ServerInstance $ServerInstance -Name $Database
        }
        # Exit if no database is selected
        if (-not $Database){
            Throw "No database selected."
        }
        if ($env:USERDOMAIN -eq "weaws"){
            $initialDir = "S:\BACKUPS"
            if ($BackupType -eq "DIFF"){
                if (-not (Test-Path "$initialDir\$ServerInstance\$($database.Name)\DIFF\")){
                    Write-Verbose "Creating $initialDir\$ServerInstance\$($database.Name)\DIFF\"
                    $null = New-Item -ItemType directory "$initialDir\$ServerInstance\$($database.Name)\DIFF\"
                }
                if (-not $BackupFile){
                    if ($PivotalID -ne 0){
                        $backupFile = "$initialDir\$ServerInstance\$($database.Name)\DIFF\$PivotalID`_$($database.name)_DIFF_$DateStamp.bak"
                    }
                    else{
                        $backupFile = "$initialDir\$ServerInstance\$($database.Name)\DIFF\$DateStamp`_$($database.name)_DIFF.bak"
                    }
                }
                Backup-SqlDatabase -ServerInstance $ServerInstance -Database $database.Name -Incremental -BackupFile $backupFile -PassThru
            }
            if ($BackupType -eq "FULL"){
                if (-not $BackupFile){
                    if ($PivotalID -ne 0){
                        $backupFile = "$initialDir\$PivotalID`_$($database.name)_FULL_$DateStamp.bak"
                    }
                    else{
                        $backupFile = "$initialDir\$DateStamp`_$($database.name)_FULL.bak"
                    }
                }
                Backup-SqlDatabase -ServerInstance $ServerInstance -Database $database.Name -CompressionOption On -BackupFile $backupFile -PassThru
            }
        }
        elseif ($env:USERDOMAIN -eq "WE") {
            $initialDir = "\\fs01.we.local\backups"
            if ($BackupType -eq "DIFF"){
                if (-not $BackupFile){
                    if ($PivotalID -ne 0){
                        $backupFile = "$initialDir\~temp\$PivotalID`_$($database.name)_DIFF_$DateStamp.bak"
                    }
                    else{
                        $backupFile = "$initialDir\~temp\$DateStamp`_$($database.name)_DIFF.bak"
                    }
                }
                Backup-SqlDatabase -ServerInstance $ServerInstance -Database $database.Name -Incremental -BackupFile $backupFile -PassThru
            }
            if ($BackupType -eq "FULL"){
                if (-not $BackupFile){
                    if ($PivotalID -ne 0){
                        $backupFile = "$initialDir\~temp\$PivotalID`_$($database.name)_FULL_$DateStamp.bak"
                    }
                    else{
                        $backupFile = "$initialDir\~temp\$DateStamp`_$($database.name)_FULL.bak"
                    }
                }
                Backup-SqlDatabase -ServerInstance $ServerInstance -Database $database.Name -CompressionOption On -BackupFile $backupFile -PassThru
            }
        }
    }
    end {
        $S3SyncTask = Get-ScheduledTask -TaskName "Nightly S3 Sync" -ErrorAction SilentlyContinue
        if ($S3SyncTask) {
            $S3SyncTask | Start-ScheduledTask
        }
    }
}