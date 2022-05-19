function Get-WESqlBackup {
    [CmdletBinding()]
    param (
        $ServerInstance = $env:COMPUTERNAME,
        [Alias('Profile')]
        [string]
        $Client,
        [string]
        $SourceDatabase,
        [switch]
        $FullOnly,
        [switch]
        $OutputAsObject
    )
    begin {
        # Loudly check for admin
        if (-not (Test-Administrator)) { return }
    }
    process {
        $ErrorActionPreference = "SilentlyContinue"
        if ($OutputAsObject) {
            if ($Client) {

                $s3Buckets = (aws s3 ls --profile $Client | Where-Object { $PSItem -notmatch "cf-templates|waf|internal|dr|awsconfig" }).Substring(20)

                foreach ($s3bucket in $s3Buckets) {

                    $s3_csv_files += aws s3api list-objects --profile $Client --bucket $s3Bucket --prefix "SQLBackups" --query "Contents[?contains(Key, '_backupinfo.csv')]" | ConvertFrom-Json
                    
                    foreach ($s3_csv_file in $s3_csv_files.Key ) {
                        $csv += (aws s3 cp --profile $Client s3://$s3Bucket/$s3_csv_file -) | ConvertFrom-CSV
                    }
                }
            }
            else {
                Write-Error "Invalid input, requires -Client argument to retrieve S3 buckets"
                exit
            }
            return [PSCustomObject]@{
                Client    = $Client
                S3Buckets = $s3Buckets
                Backups   = $csv
            }
            break
        }
        if ($Client) {

            $s3Buckets = (aws s3 ls --profile $Client | Where-Object { $PSItem -notmatch "cf-templates|waf|internal|dr|awsconfig" }).Substring(20)
            $s3Bucket = if ($s3Buckets.count -gt 1) { $s3Buckets | Out-GridView -PassThru } else { $s3Buckets }
            $s3_csv_files = aws s3api list-objects --profile $Client --bucket $s3Bucket --prefix "SQLBackups" --query "Contents[?contains(Key, '_backupinfo.csv')]" | ConvertFrom-Json

            Foreach ($s3_csv_file in $s3_csv_files.Key ) {
                $csv += (aws s3 cp --profile $client s3://$s3Bucket/$s3_csv_file -) | ConvertFrom-CSV
            }
        }
        else {

            $s3Buckets = (aws s3 ls | Where-Object { $PSItem -notmatch "cf-templates|waf|internal|dr|awsconfig" }).Substring(20)
            $s3Bucket = if ($s3Buckets.count -gt 1) { $s3Buckets | Out-GridView -PassThru } else { $s3Buckets }
            $s3_csv_files = aws s3api list-objects --bucket $s3Bucket --prefix "SQLBackups" --query "Contents[?contains(Key, '_backupinfo.csv')]" | ConvertFrom-Json

            Foreach ($s3_csv_file in $s3_csv_files.Key ) {
                $csv += (aws s3 cp s3://$s3Bucket/$s3_csv_file -) | ConvertFrom-CSV
            }
        }
        if (-not $SourceDatabase) {
            $SourceDatabase = $csv.database_name | Where-Object { $_ -notmatch "cs-Audit|cs-cognos11|dba_utils" } | Get-Unique | Out-GridView -PassThru
        }
        $SelectedBackup = $csv | Where-Object { $_.database_name -eq $SourceDatabase } | Select-Object s3_name, backup_finish_date, type, first_lsn | Out-GridView -PassThru
        if ($SelectedBackup.type -eq 'FULL') {
            $s3FullBackup += $SelectedBackup.s3_name
        }
        if ($SelectedBackup.type -eq 'DIFF') {
            $s3DiffBackup = $SelectedBackup.s3_name
            $fullbackup = $csv | Where-Object { $_.database_name -eq $SourceDatabase -and $_.type -eq 'FULL' -and $_.backup_finish_date -like $SelectedBackup.backup_finish_date.Split(" ")[0] + "*" }
            $s3FullBackup = $fullbackup.s3_name
        }
        if ($SelectedBackup.type -eq 'LOG') {
            $fullbackup = $csv | Where-Object { $_.database_name -eq $SourceDatabase -and $_.type -eq 'FULL' -and $_.backup_finish_date -like $SelectedBackup.backup_finish_date.Split(" ")[0] + "*" }
            $logBackups = $csv | Where-Object { $_.database_name -eq $SourceDatabase -and $_.type -eq 'LOG' -and $_.checkpoint_lsn -ge $fullbackup.checkpoint_lsn -and $_.first_lsn -le $SelectedBackup.first_lsn }
            $s3FullBackup = $fullbackup.s3_name
            $s3LogBackups = @($logBackups.s3_name)
        }
        [PSCustomObject]@{
            Client         = $Client
            SourceDatabase = $SourceDatabase
            FullBackup     = $s3FullBackup
            LogBackups     = if ( ($s3LogBackups) ) { $s3LogBackups } else { $null }
            DiffBackup     = if ( ($s3DiffBackup) ) { $s3DiffBackup } else { $null }
        }
    }
}