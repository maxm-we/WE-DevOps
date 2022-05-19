function Copy-WESqlLastBackup {
    [CmdletBinding()]
    [Alias("Copy-WESqlLastFull")]
    param (
        $ServerInstance = $env:COMPUTERNAME,
        [Alias('Profile')]
        [string]
        $Client,
        [string]
        $SourceDatabase,
        [String]
        $Destination,
        [switch]
        $FullOnly
    )
    begin {
        # Loudly check for admin
        if (-not (Test-Administrator)) { return }
    }
    process {
        if ($Client){
            $s3Buckets = (aws s3 ls --profile $Client | Where-Object {$PSItem -notmatch "cf-templates|waf|internal|dr|awsconfig"}).Substring(20)
        }
        else {
            $s3Buckets = (aws s3 ls | Where-Object {$PSItem -notmatch "cf-templates|waf|internal|dr|awsconfig"}).Substring(20)
        }
        $s3Bucket = if ($s3Buckets.count -gt 1) { $s3Buckets | Out-GridView -PassThru } else { $s3Buckets }
        if (-not $SourceDatabase){
            if ($Client){
                $clientDbs = (aws s3 ls s3://$s3Bucket/SQLBackups/ --profile $Client | Where-Object{$_ -match "/$"}).Substring(31) -replace "/" | Where-Object { $_ -notin ('msdb','master','model','dba_utils','tempdb','cs-cognos11','cs-audit')}
            }
            else {
                $clientDbs = (aws s3 ls s3://$s3Bucket/SQLBackups/ | Where-Object{$_ -match "/$"}).Substring(31) -replace "/" | Where-Object { $_ -notin ('msdb','master','model','dba_utils','tempdb','cs-cognos11','cs-audit')}
            }
            $SourceDatabase = if ($clientDbs.count -gt 1){ $clientDbs | Out-GridView -PassThru -Title "Please select Source Database" } else { $clientDbs }
        }
        if (-not $SourceDatabase){
            Throw "No Source Database provided/selected."
        }
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
        $SourceKeyPrefix = '/SQLBackups/{0}/FULL/' -f $SourceDatabase
        $s3object = get-S3Object -BucketName $s3Bucket -KeyPrefix $SourceKeyPrefix | Sort-Object LastModified -Descending | Select-Object -First 1
        $filename = $s3object.key.Split("/")[-1]
        $DBBackupFullName = "$DBBackupPath\$filename"
        if ($BackupDrive.FreeSpace -gt $s3object.Size){
            Write-Verbose "Copying Backup File: s3://$($s3object.BucketName)/$($s3object.Key)..."
            $null = aws s3 cp "s3://$($s3object.BucketName)/$($s3object.Key)" $DBBackupPath
        }
        else {
            Throw "Not enough freespace on $($BackupDrive.Name). $($s3object.Size/1GB)GB is required. Only $($BackupDrive.FreeSpace/1GB)GB is available."
        }
        $Database = Get-SqlDatabase -ServerInstance $env:COMPUTERNAME -Name master
        $SqlBackupContents = "use [$($Database.Name)];
        RESTORE HEADERONLY
        FROM DISK = N'$DBBackupFullName' ;
        GO
        "
        $BackupContents = Invoke-Sqlcmd -ServerInstance $ServerInstance -Database $Database.Name -Query $SqlBackupContents
        if ($BackupContents.RecoveryModel -eq "SIMPLE" -and -not $FullOnly){
            $DiffPrefix = "/SQLBackups/$SourceDatabase/DIFF/"
            if ($Client){
                $DiffS3Object = Get-S3Object -BucketName $s3Bucket -KeyPrefix $DiffPrefix -ProfileName $client | Where-Object{ $_.LastModified -gt $s3object.LastModified } | Sort-Object LastModified | Select-Object -Last 1
            }
            else {
                $DiffS3Object = Get-S3Object -BucketName $s3Bucket -KeyPrefix $DiffPrefix | Where-Object{ $_.LastModified -gt $s3object.LastModified } | Sort-Object LastModified | Select-Object -Last 1
            }
            if ($DiffS3Object){
                $DiffSize = $DiffS3Object.Size | Measure-Object -Sum | Select-Object -ExpandProperty sum
                $BackupDrive = Get-WmiObject -Class Win32_logicaldisk -Filter "DeviceID = '$($BackupDrive.Name)'"
                if ($BackupDrive.FreeSpace -gt $DiffSize){
                    Write-Verbose "Copying Diff File"
                    $null = aws s3 cp s3://$s3Bucket/$($DiffS3Object.Key) $DBBackupPath
                    $DiffName = $DiffS3Object.key.Split("/")[-1]
                    $DBBackupDiffName = "$DBBackupPath\$DiffName"
                }
                else {
                    Throw "Not enough freespace on $($BackupDrive.Name). $($DiffSize/1GB)GB is required. Only $($BackupDrive.FreeSpace/1GB)GB is available."
                }
            }
        }
        if ($BackupContents.RecoveryModel -eq "FULL" -and -not $FullOnly){
            $LogPrefix = "/SQLBackups/$SourceDatabase/LOG/"
            if ($Client){
                $LogS3Objects = Get-S3Object -BucketName $s3Bucket -KeyPrefix $LogPrefix -ProfileName $client | Where-Object{ $_.LastModified -gt $s3object.LastModified }
            }
            else {
                $LogS3Objects = Get-S3Object -BucketName $s3Bucket -KeyPrefix $LogPrefix | Where-Object{ $_.LastModified -gt $s3object.LastModified }
            }
            if ($LogS3Objects){
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
            }
            $LogsSize = $LogS3Objects.Size | Measure-Object -Sum | Select-Object -ExpandProperty sum
            $BackupDrive = Get-WmiObject -Class Win32_logicaldisk -Filter "DeviceID = '$($BackupDrive.Name)'"
            if ($BackupDrive.FreeSpace -gt $LogsSize){
                Write-Verbose "Copying Log Files"
                foreach ($LogObject in $LogS3Objects){
                    $null = aws s3 cp s3://$s3Bucket/$($LogObject.Key) $LogPath
                }
            }
            else {
                Throw "Not enough freespace on $($BackupDrive.Name). $($LogsSize.Size/1GB)GB is required. Only $($BackupDrive.FreeSpace/1GB)GB is available."
            }
        }
    }
    end {
        [PSCustomObject]@{
            Backup = $DBBackupFullName
            LogDir = if ( ($LogPath) ){ $LogPath } else{ $null }
            Diff = if ( ($DBBackupDiffName) ){ $DBBackupDiffName } else{ $null }
        }

    }
}