function Restore-WESqlLastBackup {
    [CmdletBinding()]
    [Alias("RestoreFrom-WESqlLastFull","Restore-WESqlLastFull")]
    param (
        $ServerInstance = $env:COMPUTERNAME,
        [Alias('Profile')]
        [string]
        $Client = $null,
        $DestinationDatabase = $null,
        [string]
        $SourceDatabase = $null,
        [switch]
        $RemoveSchedules
    )
    begin {
        # Loudly check for admin
        if (-not (Test-Administrator)) { return }
    }
    process {
        if ($Client){
            $SourceBackup = Copy-WESqlLastBackup -Client $client -SourceDatabase $SourceDatabase
        }
        else {
            $SourceBackup = Copy-WESqlLastBackup -SourceDatabase $SourceDatabase
        }
        if ($null -eq $SourceBackup.Diff -and $null -ne $SourceBackup.LogDir){
            if ($RemoveSchedules){
                Start-WESqlRestore -Database $DestinationDatabase -BackupFile $SourceBackup.Backup -DeleteBackup -LogBackups $SourceBackup.LogDir -DeleteLogs -RemoveSchedules
            }
            else {
                Start-WESqlRestore -Database $DestinationDatabase -BackupFile $SourceBackup.Backup -DeleteBackup -LogBackups $SourceBackup.LogDir -DeleteLogs
            }
        }
        elseif ($null -ne $SourceBackup.Diff -and $null -eq $SourceBackup.LogDir) {
            if ($RemoveSchedules){
                Start-WESqlRestore -Database $DestinationDatabase -BackupFile $SourceBackup.Backup -DiffFile $SourceBackup.Diff -DeleteBackup -RemoveSchedules
            }
            else {
                Start-WESqlRestore -Database $DestinationDatabase -BackupFile $SourceBackup.Backup -DiffFile $SourceBackup.Diff -DeleteBackup
            }
        }
        elseif ($null -eq $SourceBackup.Diff -and $null -eq $SourceBackup.LogDir) {
            if ($RemoveSchedules){
                Start-WESqlRestore -Database $DestinationDatabase -BackupFile $SourceBackup.Backup -DeleteBackup -RemoveSchedules
            }
            else {
                Start-WESqlRestore -Database $DestinationDatabase -BackupFile $SourceBackup.Backup -DeleteBackup
            }
        }
    }
}