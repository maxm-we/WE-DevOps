function Get-WESqlStatus {
    [CmdletBinding()]
    param (
        [Parameter()]
        [String]
        $ServerInstance = $env:COMPUTERNAME
    )
    Process{
        # Loudly check for admin
        if(-not (Test-Administrator)) { return }

        $sqlRestoreInfo = "
        WITH LastRestores AS
        (
        SELECT
            DatabaseName = [d].[name] ,
            [d].[create_date] ,
            [d].[compatibility_level] ,
            [d].[collation_name] ,
            r.*,
            RowNum = ROW_NUMBER() OVER (PARTITION BY d.Name ORDER BY r.[restore_date] DESC)
        FROM master.sys.databases d
        LEFT OUTER JOIN msdb.dbo.[restorehistory] r ON r.[destination_database_name] = d.Name
        )
        SELECT *
        FROM [LastRestores]
        WHERE [RowNum] = 1
        "

        $databases = Invoke-Sqlcmd -ServerInstance $ServerInstance -Query $sqlRestoreInfo | Where-Object {$_.DatabaseName -notin ('msdb','master','model','dba_utils','tempdb','cs-cognos11','cs-audit')} | Group-Object -AsHashTable -Property DatabaseName
        $outObj = [System.Collections.ArrayList]@()
        foreach ( $db in $databases.Keys )
        {
            $sqlLastActivity = "
            SELECT MAX(last_activity_at) last_activity, MIN(clients.name) AS client
            FROM [$($databases[$db].DatabaseName)].[dbo].[users] JOIN [$($databases[$db].DatabaseName)].[dbo].[clients] ON 1 = 1
            "
            $dbActivity = Invoke-Sqlcmd -ServerInstance $ServerInstance -Query $sqlLastActivity -ErrorAction Ignore

            $sqlDBSize = "
            with fs
            as
            (
                select database_id, type, size * 8.0 / 1024 / 1024 size
                from sys.master_files
            )
            select
                name,
                (select sum(size) from fs where type = 0 and fs.database_id = db.database_id) DataFileSizeInGB,
                (select sum(size) from fs where type = 1 and fs.database_id = db.database_id) LogFileSizeInGB
            from sys.databases db where db.name = '$($databases[$db].DatabaseName)'
            "
            $dbSize = Invoke-Sqlcmd -ServerInstance $ServerInstance -Query $sqlDBSize -ErrorAction Ignore

            $null = $outObj.Add([pscustomobject] @{
            Database = $databases[$db].DatabaseName
            DB_Size_GB = ("{0:N2}" -f $dbSize.DataFileSizeInGB) -as [double]
            DB_Log_Size_GB = ("{0:N2}" -f $dbSize.LogFileSizeInGB) -as [double]
            Client = $dbActivity.client
            LastActivity = $dbActivity.last_activity
            RestoreDate = $databases[$db].restore_date
            RestoredBy = $databases[$db].user_name
            })
            $dbActivity = $null
        }
        $outObj | sort Database
    }
}