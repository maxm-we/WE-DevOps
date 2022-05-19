function Copy-WESqlBackup {
    [CmdletBinding()]
    param (
        $ServerInstance = $env:COMPUTERNAME,
        [String]
        [parameter(ValueFromPipelineByPropertyName = $true)]
        $Client,
        [String]
        [parameter(ValueFromPipelineByPropertyName = $true)]
        $SourceDatabase,
        [String]
        [Alias('BackupFile')]
        [parameter(
        Mandatory         = $true,
        ValueFromPipelineByPropertyName = $true)]
        $FullBackup,
        [String]
        [parameter(ValueFromPipelineByPropertyName = $true)]
        $DiffBackup,
        [Array]
        [parameter(ValueFromPipelineByPropertyName = $true)]
        $LogBackups,
        [String]
        $Destination
    )
    begin {
        # Loudly check for admin
        if (-not (Test-Administrator)) { return }
    }
    process {
        if ($env:USERDOMAIN -eq "weaws"){
            $DBBackupPath = "S:\BACKUPS"
            $BackupDrive = Get-WmiObject -Class Win32_logicaldisk -Filter "DeviceID = 'S:'"
        }
        elseif ($env:USERDOMAIN -eq "WE") {
            $DBBackupPath = "\\fs01.we.local\backups\~temp"
            if (-not (Get-PSDrive Z -ErrorAction SilentlyContinue)){
                $null = New-PSDrive -Name Z -PSProvider FileSystem -Root "\\fs01.we.local\backups" -Persist
            }
            $BackupDrive = Get-WmiObject -Class Win32_logicaldisk -Filter "DeviceID = 'Z:'"
        }
        if ($Destination -and ((Test-Path $Destination) -eq $true)){
            $DBBackupPath = $Destination
        }
                
        if($FullBackup){
            $s3FullBackup = $FullBackup
            if ($Client){
                $s3object = get-S3Object -ProfileName $Client -BucketName ([uri]$s3FullBackup).Authority -KeyPrefix ([uri]$s3FullBackup).PathAndQuery
            }
            else {
                $s3object = get-S3Object -BucketName ([uri]$s3FullBackup).Authority -KeyPrefix ([uri]$s3FullBackup).PathAndQuery
            }
            $filename = $s3object.key.Split("/")[-1]
            $DBBackupFullName = "$DBBackupPath\$filename"
            $CopiedFullBackup = $DBBackupFullName

            if ($BackupDrive.FreeSpace -gt $s3object.Size){
                Write-Verbose "Copying Backup File: s3://$($s3object.BucketName)/$($s3object.Key)..."
                if ($Client){
                    $null = aws s3 --profile $Client cp "s3://$($s3object.BucketName)/$($s3object.Key)" $DBBackupPath
                }
                else {
                    $null = aws s3 cp "s3://$($s3object.BucketName)/$($s3object.Key)" $DBBackupPath
                }
            }
            else {
                Throw "Not enough freespace on $($BackupDrive.Name). $($s3object.Size/1GB)GB is required. Only $($BackupDrive.FreeSpace/1GB)GB is available."
            }
        }

        if($DiffBackup){
            $s3DiffBackup = $DiffBackup
            if ($Client){
                $s3object = get-S3Object -ProfileName $Client -BucketName ([uri]$s3DiffBackup).Authority -KeyPrefix ([uri]$s3DiffBackup).PathAndQuery
            }
            else{
                $s3object = get-S3Object -BucketName ([uri]$s3DiffBackup).Authority -KeyPrefix ([uri]$s3DiffBackup).PathAndQuery
            }
            $filename = $s3object.key.Split("/")[-1]
            $DBBackupDiffName = "$DBBackupPath\$filename"
            $CopiedDiffBackup = $DBBackupDiffName
            if ($BackupDrive.FreeSpace -gt $s3object.Size){
                Write-Verbose "Copying Backup File: s3://$($s3object.BucketName)/$($s3object.Key)..."
                if ($Client){
                    $null = aws s3 --profile $Client cp "s3://$($s3object.BucketName)/$($s3object.Key)" $DBBackupPath
                }
                else {
                    $null = aws s3 cp "s3://$($s3object.BucketName)/$($s3object.Key)" $DBBackupPath
                }
            }
            else {
                Throw "Not enough freespace on $($BackupDrive.Name). $($s3object.Size/1GB)GB is required. Only $($BackupDrive.FreeSpace/1GB)GB is available."
            }
        }

        if ($LogBackups) {
            $LogPath = "$DBBackupPath\$SourceDatabase-LOGS\"
            if (-not (Test-Path $LogPath)){
                Write-Verbose "Creating directory for log backups: $LogPath"
                if ($env:USERDOMAIN -eq "weaws"){
                    $null = New-Item $LogPath -ItemType Directory
                }
                elseif ($env:USERDOMAIN -eq "WE") {
                    $null = New-Item -Path "FileSystem::$LogPath" -ItemType Directory
                }
            }

            Foreach ($LogFile in $LogBackups){
                if ($Client){
                    $s3object = get-S3Object -ProfileName $Client -BucketName ([uri]$LogFile).Authority -KeyPrefix ([uri]$LogFile).PathAndQuery
                }
                else{
                    $s3object = get-S3Object -BucketName ([uri]$LogFile).Authority -KeyPrefix ([uri]$LogFile).PathAndQuery
                }
                $filename = $s3object.key.Split("/")[-1]
                $DBBackupFullName = "$DBBackupPath\$filename"
                if ($BackupDrive.FreeSpace -gt $s3object.Size){
                    Write-Verbose "Copying Backup File: s3://$($s3object.BucketName)/$($s3object.Key)..."
                    if ($Client){
                        $null = aws --profile $client s3 cp "s3://$($s3object.BucketName)/$($s3object.Key)" $LogPath
                    }
                    else {
                        $null = aws s3 cp "s3://$($s3object.BucketName)/$($s3object.Key)" $LogPath
                    }
                }
                else {
                    Throw "Not enough freespace on $($BackupDrive.Name). $($s3object.Size/1GB)GB is required. Only $($BackupDrive.FreeSpace/1GB)GB is available."
                }
            }
        }
    }
    end {
        [PSCustomObject]@{
            Database = $SourceDatabase
            BackupFile = $CopiedFullBackup
            LogBackups = if ( ($LogPath) ){ $LogPath } else{ $null }
            DiffFile = if ( ($CopiedDiffBackup) ){ $CopiedDiffBackup } else{ $null }
        }

    }
}