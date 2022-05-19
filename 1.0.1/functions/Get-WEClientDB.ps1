function Get-WEClientDB {
    [CmdletBinding()]
    param (
        [Alias('Profile')]
        [string]
        $Client
    )
    process {
        $s3Buckets = (aws s3 ls --profile $Client | Where-Object {$PSItem -notmatch "cf-templates|waf|internal|dr"}).Substring(20)
        $s3Bucket = if ($s3Buckets.count -gt 1) { $s3Buckets | Out-GridView -PassThru } else { $s3Buckets }
        $clientDbs = (aws s3 ls s3://$s3Bucket/SQLBackups/ --profile $Client | Where-Object{$_ -match "/$"}).Substring(31) -replace "/" | Where-Object { $_ -notin ('msdb','master','model','dba_utils','tempdb','cs-cognos11','cs-audit')}
        $clientDbs | Select-Object @{n="Database";e={$_}}
    }
}