function Get-WESqlBackupStatus {
    [CmdletBinding()]
    param (
    )

    begin {
        # Loudly check for admin
        if(-not (Test-Administrator)) { return }
    }

    process {

        $sql_backups = Invoke-Sqlcmd -Query @"
SELECT  
   B.database_name,
   A.last_db_backup_date,  
   B.backup_start_date,  
   B.backup_size,  
   B.physical_device_name,   
   B.backupset_name, 
   B.recovery_model
FROM 
   ( 
   SELECT   
      CONVERT(CHAR(100), SERVERPROPERTY('Servername')) AS Server, 
      msdb.dbo.backupset.database_name,  
      MAX(msdb.dbo.backupset.backup_finish_date) AS last_db_backup_date 
   FROM 
      msdb.dbo.backupmediafamily  
      INNER JOIN msdb.dbo.backupset ON msdb.dbo.backupmediafamily.media_set_id = msdb.dbo.backupset.media_set_id  
   GROUP BY 
      msdb.dbo.backupset.database_name  
   ) AS A 
   LEFT JOIN  
   ( 
   SELECT   
      CONVERT(CHAR(100), SERVERPROPERTY('Servername')) AS Server, 
      msdb.dbo.backupset.database_name,  
      msdb.dbo.backupset.backup_start_date,  
      msdb.dbo.backupset.backup_finish_date, 
      msdb.dbo.backupset.expiration_date, 
      msdb.dbo.backupset.backup_size,  
      msdb.dbo.backupmediafamily.logical_device_name,  
      msdb.dbo.backupmediafamily.physical_device_name,   
      msdb.dbo.backupset.name AS backupset_name, 
      msdb.dbo.backupset.description,
	  msdb.dbo.backupset.recovery_model
   FROM 
      msdb.dbo.backupmediafamily  
      INNER JOIN msdb.dbo.backupset ON msdb.dbo.backupmediafamily.media_set_id = msdb.dbo.backupset.media_set_id  
   ) AS B 
   ON A.[server] = B.[server] AND A.[database_name] = B.[database_name] AND A.[last_db_backup_date] = B.[backup_finish_date] WHERE B.database_name <> 'dba_utils' AND B.database_name <> 'matador_project' AND B.database_name <> 'cs-Audit' AND B.database_name <> 'cs-cognos11'
ORDER BY  
   A.database_name 
"@

        $sql_backups | Select-Object database_name, recovery_model, last_db_backup_date, physical_device_name
    }

}
