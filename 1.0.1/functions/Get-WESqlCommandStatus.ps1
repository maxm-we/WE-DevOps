function Get-WESqlCommandStatus {
    [CmdletBinding()]
    [Alias()]
    [OutputType()]
    param (
        [Parameter()]
        [string]
        $ServerInstance = $env:COMPUTERNAME,
        [ValidateSet("RESTORE", "BACKUP", "SELECT", "ALL")]
        [String]
        $Command = "ALL"
    )
    process {
        # Loudly check for admin
        if(-not (Test-Administrator)) { return }

        if ($Command -eq "ALL"){
            $SqlCommand = "%"
        }
        else {
            $SqlCommand = $Command
        }
        $sql = "SELECT r.session_id,r.command,CONVERT(NUMERIC(6,2),r.percent_complete)
        AS [Percent_Complete],r.start_time,CONVERT(VARCHAR(20),DATEADD(ms,r.estimated_completion_time,GetDate()),20) AS [ETA_Completion_Time],
        CONVERT(NUMERIC(10,2),r.total_elapsed_time/1000.0/60.0) AS [Elapsed_Min],
        CONVERT(NUMERIC(10,2),r.estimated_completion_time/1000.0/60.0) AS [ETA_Min],
        CONVERT(NUMERIC(10,2),r.estimated_completion_time/1000.0/60.0/60.0) AS [ETA_Hours],
        CONVERT(VARCHAR(1000),(SELECT SUBSTRING(text,r.statement_start_offset/2,
        CASE WHEN r.statement_end_offset = -1 THEN 1000 ELSE (r.statement_end_offset-r.statement_start_offset)/2 END)
        FROM sys.dm_exec_sql_text(sql_handle))) AS [SQL]
        FROM sys.dm_exec_requests r WHERE command like '$SqlCommand%'"
        Invoke-Sqlcmd -ServerInstance $ServerInstance -Query $sql
    }
}
