function Start-JenkinsDownloadBackups {
    [CmdletBinding()]
    param (
        [string]
        [parameter(
        Mandatory         = $true,
        ValueFromPipelineByPropertyName = $true)]
        $FileList,
        [string]
        [parameter(
        Mandatory         = $true,
        ValueFromPipelineByPropertyName = $true)]
        $Bucket,
        [string]
        $Ticket
    )

    $files = $FileList.split(",");

    New-Item -ItemType Directory -Force "S:\BACKUPS\restore-$ticket-logs\" | Out-Null
    $logs_dir = "S:\BACKUPS\restore-$ticket-logs\"

    foreach($file in $files) {
        $full_path = "S:\Backups\" + $env:COMPUTERNAME + '\' + $file -replace '/','\'
        # Check if trn, if trn check if file exist locally, if it does, copy it to new logs dir, if not copy from S3 to new logs dir
        if ($full_path -Like "*.trn"){
            $log_backups = 1
            if(Test-Path -Path $full_path -PathType Leaf){
                Copy-Item $full_path -Destination $logs_dir
            }else{
                aws s3 cp "s3://$bucket/SQLBackups/$file" $logs_dir
            }
        }elseif($full_path -Like "*_DIFF*"){
            if(Test-Path -Path $full_path -PathType Leaf){
                $diff_backup_path = $full_path
            }else{
                aws s3 cp "s3://$bucket/SQLBackups/$file" S:\Backups\
                $diff_backup_filename = $full_path | Split-Path -Leaf
                $diff_backup_path = "S:\Backups\$diff_backup_filename"
            }
        }elseif($full_path -Like "*_FULL_*"){
            if(Test-Path -Path $full_path -PathType Leaf){
                $full_backup_path = $full_path
            }else{
                aws s3 cp "s3://$bucket/SQLBackups/$file" S:\Backups\
                $full_backup_filename = $full_path | Split-Path -Leaf
                $full_backup_path = "S:\Backups\$full_backup_filename"
            }
        }
    }

    if(!$log_backups){
        Remove-Item $logs_dir
    }

    if ( ($full_backup_path) ) { "FullBackup: '" + $full_backup_path + "'" } else { "FullBackup: '" + $null + "'"}
    if ( ($log_backups) ) { "LogBackups: '" + $logs_dir + "'" } else { "LogBackups: '" + $null + "'"}
    if ( ($diff_backup_path) ) { "DiffBackup: '" + $diff_backup_path + "'" } else { "DiffBackup: '" + $null + "'"}

}
