$Global:RawBackups = New-Object System.Collections.Generic.List[PSCustomObject]
$Global:BackupSets = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
$Global:RestoreDestinations = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))

[Hashtable]$Global:SyncHash = [Hashtable]::Synchronized(@{})
if ( -not (Get-PSDrive Z -ErrorAction SilentlyContinue) -and $env:USERDNSDOMAIN -eq "WE.LOCAL"){
    $null = New-PSDrive -Name Z -PSProvider FileSystem -Root "\\fs01.we.local\backups" -Persist
}

#===============================================================================
# Misc Functions
#===============================================================================
#region Functions
function ProcessBackupFile([string]$fileName) {
    $rows = Invoke-Sqlcmd -Query "RESTORE HEADERONLY FROM DISK = N'$fileName';"

    try {
        ForEach ($row in $rows) {
            $new_item = [PSCustomObject]@{
                FileName =            $fileName
                ServerName =          $row.ServerName
                DatabaseName =        $row.DatabaseName
                Position =            $row.Position
                FirstLSN =            $row.FirstLSN
                LastLSN =             $row.LastLSN
                CheckpointLSN =       $row.CheckpointLSN
                DatabaseBackupLSN =   $row.DatabaseBackupLSN
                BackupFinishDate =    $row.BackupFinishDate
                UserName =            $row.UserName
                CompatabilityLevel =  $row.CompatabilityLevel
                Type =                ($null,"Full","Log",$null,$null,"Diff",$null,$null,$null)[[int]$row.BackupType]
                Hash =                ""
            }

            $md5 = New-Object -TypeName System.Security.Cryptography.MD5CryptoServiceProvider
            $utf8 = New-Object -TypeName System.Text.UTF8Encoding

            $new_item.Hash = [System.BitConverter]::ToString($md5.ComputeHash($utf8.GetBytes( ($new_item | ConvertTo-Json -Compress) ))) -replace "-",""

            if (  ($null -ne $new_item) -and ($RawBackups.FindIndex({param($s) $s.Hash -eq $new_item.Hash}) -eq -1) ) {
                $RawBackups.Add($new_item)
                Write-Host "Added $fileName :: $($row.Position) :: $($RawBackups.Count) backups"
            } else {
                Write-Host "Skipped $fileName :: $($row.Position) (Already present)"
            }
        } #end foreach
    } catch {
        Write-Host "Issue processing backups from $fileName"
    } # end trycatch
}

function UpdateFileList() {
    $RawBackups.Sort({ param($x, $y) $x.BackupFinishDate.CompareTo($y.BackupFinishDate) })

    $DatabaseRestore__listFiles.ItemsSource = [Array]$RawBackups
    $DatabaseRestore__listSourceDBs.ItemsSource = [Array]($RawBackups | Where-Object { $_.Type -eq "Full" } | Select-Object ServerName, DatabaseName -Unique | Sort-Object ServerName, DatabaseName)

    if ( ($DatabaseRestore__listSourceDBs.Items | Measure-Object).Count -gt 0) {
        $DatabaseRestore__tabSource.IsEnabled = $True
        $DatabaseRestore__listDates.SelectedIndex = -1
    } else {
        $DatabaseRestore__tabSource.IsEnabled = $False
        $DatabaseRestore__tabDestination.IsEnabled = $False
        $DatabaseRestore__tabOptions.IsEnabled = $False
        $DatabaseRestore__tabVerify.IsEnabled = $False
    }

    $total_files = $RawBackups | Select-Object FileName -Unique | Measure-Object

    $DatabaseRestore__lblFilesSelected.Text = "Files: $($total_files.Count)"
}

function GetDestinationDBs() {
    $dbQuery = "
        SELECT name AS DatabaseName,
	           recovery_model_desc AS RecoveryModel,
	           suser_sname( owner_sid ) AS Owner,
	           CASE compatibility_level
	               WHEN '100' THEN '2008'
		           WHEN '110' THEN '2012'
		           WHEN '120' THEN '2014'
		           WHEN '130' THEN '2016'
		           WHEN '140' THEN '2017'
		           WHEN '150' THEN '2019'
		           END as Compatability
        FROM [master].sys.databases
        WHERE name not in ('master', 'tempdb', 'model', 'msdb', 'dba_utils')
          AND name not like 'cs-cognos%'
          AND name not like 'cs_cognos%'
          AND name not like 'cs-audit%'
          AND name not like 'cs_audit%';
    "

    $domain = (Get-WmiObject Win32_ComputerSystem).Domain

    if ($domain -eq "we.local") {
        $servers = @('SQL1.we.local', 'SQL2.we.local', 'SQL3.we.local', 'SQL4.we.local', 'SQL5.we.local')
    } else {
        $servers = @('localhost')
    }

    foreach ($server in $servers) {
        $rows = Invoke-Sqlcmd -Query $dbQuery -ServerInstance $server

        $rows | ForEach-Object { $RestoreDestinations.Add([PSCustomObject]@{
            ServerName =    $server
            DatabaseName =  $_.DatabaseName
            RecoveryModel = $_.RecoveryModel
            Owner =         $_.Owner
            Compatability = $_.Compatability
        }) }
    }

    $DatabaseRestore__listDestinationDBs.ItemsSource = [Array]$RestoreDestinations
}

function RestoreFormBusy($message) {
    $SyncClass.UpdateElement("DatabaseRestore__txtBusy", "Text", $message)
    $SyncClass.UpdateElement("DatabaseRestore__pnlBusy", "Visibility", "Visible")
}

function RestoreFormReady() {
    $SyncClass.UpdateElement("DatabaseRestore__pnlBusy", "Visibility", "Collapsed")
}

function GetChains([PSCustomObject]$BackupFile, [System.Collections.ArrayList]$files = [System.Collections.ArrayList]@()) {
    $files.Add($BackupFile)

    if ($BackupFile.Type -eq "Full") {
        $viable = $RawBackups | Where-Object {($_.Type -eq "Diff" -and $_.DatabaseBackupLSN -eq $BackupFile.FirstLSN ) -or ( $_.Type -eq "Log" -and $_.FirstLSN -lt $BackupFile.LastLSN -and $_.LastLSN -gt $BackupFile.LastLSN -and $_.DatabaseBackupLSN -eq $BackupFile.FirstLSN )}
    } else {
        $viable = $RawBackups | Where-Object { $_.Type -eq "Log" -and $_.FirstLSN -eq $BackupFile.LastLSN -and $_.DatabaseBackupLSN -eq $BackupFile.DatabaseBackupLSN }
    }

    $BackupSets.Add([PSCustomObject]@{
        BackupFinishDate = $BackupFile.BackupFinishDate
        Files =            [Array]$files
    })

    $viable | ForEach-Object { GetChains $_ $files.Clone() }
}

function UpdateVerifyText() {
    $source = $DatabaseRestore__listSourceDBs.SelectedItem
    $dest = $DatabaseRestore__listDestinationDBs.SelectedItem
    $point = $DatabaseRestore__listDates.SelectedItem
    $script_name = $DatabaseRestore__lblScriptToRun.Text

    $FileNameLengthsMax = ($point.Files | ForEach-Object { $_.FileName } | Measure-Object -Maximum -Property Length).Maximum

    $fileText = [string]::Join("`r`n", ($point.Files | ForEach-Object { ("  " + $_.FileName + " #" + $_.Position).PadRight($FileNameLengthsMax+8, " ") + "$($_.Type) backup taken by [$($_.UserName)] at [$($_.BackupFinishDate)]" }))

    $flags = ""
    $flags += If($DatabaseRestore__chkDeleteWhenDone.IsChecked) {"  Delete Backups When Done`r`n"}
    $flags += If($DatabaseRestore__chkRemoveSchedules.IsChecked) {"  Deactivate Process Schedules`r`n"}
    $flags += If($DatabaseRestore__chkRunScript.IsChecked) {"  Run SQL script after restore`r`n"}
    #region String manipulation I really need don't like but I'm pretty sure I'm stuck with because of the limitations of FolderBrowserDialog ~Isom
    if ($env:USERDNSDOMAIN -eq "WE.LOCAL"){
        $regexMatch = [regex]::Escape("Z:\")
        $regexReplace = "\\fs01.we.local\backups\"
        if ($DatabaseRestore__listDates.SelectedItem.Files.FileName.count -gt 1){
            $DBR_Full = $DatabaseRestore__listDates.SelectedItem.Files.FileName[0] -replace $regexMatch,$regexReplace
            $DBR_Diff = ($DatabaseRestore__listDates.SelectedItem.Files.FileName | Where-Object {$_ -ne $DatabaseRestore__listDates.SelectedItem.Files.FileName[0] -and $_ -notmatch "FULL|\.trn$"}) -replace $regexMatch,$regexReplace
            [string[]]$DBR_Logs += foreach ($log in ($DatabaseRestore__listDates.SelectedItem.Files.FileName | Where-Object {$_ -ne $DatabaseRestore__listDates.SelectedItem.Files.FileName[0] -and $_ -match "\.trn$"})){
                $log -replace $regexMatch,$regexReplace
            }
        }
        else {
            $DBR_Full = $DatabaseRestore__listDates.SelectedItem.Files.FileName -replace $regexMatch,$regexReplace
        }
    }
    elseif ($env:USERDNSDOMAIN -eq "WE.AWS"){
        if ($DatabaseRestore__listDates.SelectedItem.Files.FileName.count -gt 1){
            $DBR_Full = $DatabaseRestore__listDates.SelectedItem.Files.FileName[0]
            $DBR_Diff = ($DatabaseRestore__listDates.SelectedItem.Files.FileName | Where-Object {$_ -ne $DatabaseRestore__listDates.SelectedItem.Files.FileName[0] -and $_ -notmatch "FULL|\.trn$"})
            [string[]]$DBR_Logs += foreach ($log in ($DatabaseRestore__listDates.SelectedItem.Files.FileName | Where-Object {$_ -ne $DatabaseRestore__listDates.SelectedItem.Files.FileName[0] -and $_ -match "\.trn$"})){
                $log
            }
        }
        else {
            $DBR_Full = $DatabaseRestore__listDates.SelectedItem.Files.FileName
        }
    }
    $command = "  Start-WESQLRestore
      -ServerInstance $($dest.ServerName)
      -Database       $($dest.DatabaseName)"

    $command += If($DatabaseRestore__chkRunScript.IsChecked) { "`r`n      -RunScript      `"$script_name`"" }
    $command += "`r`n      -BackupFile     `"$DBR_Full`""
    if ($DBR_Diff){
        $command += "`r`n      -DiffFile    `"$DBR_Diff`""
    }
    elseif ($DBR_Logs){
        $command += "`r`n      -LogBackups     " + `
                      [string]::Join("`r`n                      ", ($DBR_Logs | ForEach-Object { "`"$_`""}))
    }
    #endregion
    $command += If($DatabaseRestore__chkDeleteWhenDone.IsChecked) { "`r`n      -DeleteBackup" }
    $command += If($DatabaseRestore__chkRemoveSchedules.IsChecked) { "`r`n      -RemoveSchedules" }

    $verify = "Verifying Restore:
``````
Command
----------------------------------------
$command

Source
----------------------------------------
  $($source.DatabaseName)
    from $($source.ServerName)
    at $($point.BackupFinishDate)

Destination
----------------------------------------
  $($dest.DatabaseName)
    on $($dest.ServerName)
"

if ($flags.length -gt 0) {
    $verify += "
Options
----------------------------------------
$flags"
}


    $verify += "
Files
----------------------------------------
$fileText
``````
@devops @wesupport Please approve
"

    $DatabaseRestore__txtVerify.Text = $verify
}

function SelectScriptToRun() {
    $FileBrowser = New-Object System.Windows.Forms.OpenFileDialog
    $FileBrowser.InitialDirectory = [Environment]::GetFolderPath('MyComputer')
    $FileBrowser.filter = "SQL Scripts | *.sql|All files (*.*)|*.*"
    $FileBrowser.Multiselect = $false
    $FileBrowser.CheckFileExists = $true

    if ($FileBrowser.ShowDialog() -eq "OK") {
        $DatabaseRestore__lblScriptToRun.Text = $FileBrowser.FileName

        UpdateVerifyText
        return $True
    } else {
        return $False
    }
}
#endregion Functions


#===============================================================================
# Event wiring
#===============================================================================
#region EventWiring
$DatabaseRestore__frmMainWindow.Add_Loaded({
    $DatabaseRestore__frmMainWindow.Icon = "$caller_root\media\logo.ico"
    GetDestinationDBs
})

$DatabaseRestore__btnAddFiles.Add_Click({
    $FileBrowser = New-Object System.Windows.Forms.OpenFileDialog
    $FileBrowser.InitialDirectory = [Environment]::GetFolderPath('MyComputer')
    $FileBrowser.filter = "SQL Backups | *.bak;*.trn;*.diff;*.dif|All files (*.*)|*.*"
    $FileBrowser.Multiselect = $true
    $FileBrowser.CheckFileExists = $true

    if ($FileBrowser.ShowDialog() -eq "OK") {
        RestoreFormBusy("Processing Backup File")

        $FileBrowser.FileNames | ForEach-Object { ProcessBackupFile $_ }
        UpdateFileList

        RestoreFormReady
    }
})

$DatabaseRestore__btnAddFolder.Add_Click({
    $FolderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
    $FolderBrowser.Description = "Select a folder"
    $FolderBrowser.rootfolder = "MyComputer"
    $FolderBrowser.SelectedPath = [Environment]::GetFolderPath('MyComputer')

    if ($FolderBrowser.ShowDialog() -eq "OK") {
        RestoreFormBusy("Processing Backup File")

        Get-ChildItem -Path $FolderBrowser.SelectedPath -Include *.bak,*.trn,*.diff,*.dif -Recurse | ForEach-Object { ProcessBackupFile $_.FullName }
        UpdateFileList

        RestoreFormReady
    }
})


$DatabaseRestore__btnRemoveFiles.Add_Click({
    $DatabaseRestore__listFiles.SelectedItems | ForEach-Object -Process {
        $fileName = $_.FileName
        $position = $_.Position

        $RawBackups.Remove($_)

        Write-Host "Removed $fileName :: $position :: $($RawBackups.Count) backups left"
    }

    UpdateFileList
})


$DatabaseRestore__btnRemoveAll.Add_Click({
    $RawBackups.Clear()

    UpdateFileList
})

$DatabaseRestore__listSourceDBs.Add_SelectionChanged({
    $BackupSets.Clear()

    $selected = $DatabaseRestore__listSourceDBs.SelectedItem
    $fullBackups = ($RawBackups | Where-Object { $_.DatabaseName -eq $selected.DatabaseName -and $_.ServerName -eq $selected.ServerName -and $_.Type -eq "Full" })

    $fullBackups | ForEach-Object { GetChains $_ }

    $DatabaseRestore__listDates.ItemsSource = [Array]($BackupSets | Sort-Object -Property BackupFinishDate)

    $DatabaseRestore__lblSourceDB.Text = "Source: $($selected.DatabaseName) on $($selected.ServerName)"
})


$DatabaseRestore__listDates.Add_SelectionChanged({
    if ($DatabaseRestore__listDates.SelectedIndex -gt -1) {
        $selected = $DatabaseRestore__listDates.SelectedItem

        $DatabaseRestore__listSourceFiles.ItemsSource = $selected.Files
        $DatabaseRestore__lblRestorePoint.Text = "At: $($selected.BackupFinishDate)"

        $DatabaseRestore__tabDestination.IsEnabled = $True
        $DatabaseRestore__listDestinationDBs.SelectedIndex = -1

        UpdateVerifyText
    } else {
        $DatabaseRestore__tabDestination.IsEnabled = $False
        $DatabaseRestore__tabOptions.IsEnabled = $False
        $DatabaseRestore__tabVerify.IsEnabled = $False
    }
})


$DatabaseRestore__listDestinationDBs.Add_SelectionChanged({
    if ($DatabaseRestore__listDates.SelectedIndex -gt -1) {
        $selected = $DatabaseRestore__listDestinationDBs.SelectedItem

        $DatabaseRestore__lblDestinationDB.Text = "Dest: $($selected.DatabaseName) on $($selected.ServerName)"

        $DatabaseRestore__tabOptions.IsEnabled = $True
        $DatabaseRestore__tabVerify.IsEnabled = $True

        UpdateVerifyText
    } else {
        $DatabaseRestore__tabOptions.IsEnabled = $False
        $DatabaseRestore__tabVerify.IsEnabled = $False
    }
})

$DatabaseRestore__txtSearchDestinations.Add_TextChanged({
    $search = $DatabaseRestore__txtSearchDestinations.Text.Trim()

    if ($search.length -lt 2) {
        $DatabaseRestore__listDestinationDBs.ItemsSource = [Array]$RestoreDestinations
    } else {
        $filtered = $RestoreDestinations | Where-Object {
            $_.DatabaseName -like "*$search*" -or
            $_.ServerName -like "*$search*" -or
            $_.Owner -like "*$search*"
        }
        $DatabaseRestore__listDestinationDBs.ItemsSource = [Array]$filtered
    }
})

$DatabaseRestore__btnClipboard.Add_Click({
    $DatabaseRestore__txtVerify.Text | Set-Clipboard
})

$DatabaseRestore__btnRun.Add_Click({
    $words = @('thing', 'noise', 'learn', 'horse', 'seven', 'world', 'about', 'again', 'heart', 'pizza', 'board', 'fifty', 'three', 'party', 'piano', 'sugar', 'dream', 'apple', 'house', 'watch')
    $word = $words[(Get-Random -Maximum 19)]

    $response = [Microsoft.VisualBasic.Interaction]::InputBox("Please type the word '$word' below to continue", "Confirm Restore", "")

    if ($response -eq $word) {
        # Isom stuff goes here
        $ServerInstance = $DatabaseRestore__listDestinationDBs.SelectedItem.ServerName
        $Database = $DatabaseRestore__listDestinationDBs.SelectedItem.DatabaseName
        if ($env:USERDNSDOMAIN -eq "WE.LOCAL"){
            $regexMatch = [regex]::Escape("Z:\")
            $regexReplace = "\\fs01.we.local\backups\"
            if ($DatabaseRestore__listDates.SelectedItem.Files.FileName.count -gt 1){
                $DBR_Full = $DatabaseRestore__listDates.SelectedItem.Files.FileName[0] -replace $regexMatch,$regexReplace
                $DBR_Diff = ($DatabaseRestore__listDates.SelectedItem.Files.FileName | Where-Object {$_ -ne $DatabaseRestore__listDates.SelectedItem.Files.FileName[0] -and $_ -notmatch "FULL|\.trn$"}) -replace $regexMatch,$regexReplace
                $DBR_Logs = New-Object -TypeName "System.Collections.ArrayList"
                foreach ($log in ($DatabaseRestore__listDates.SelectedItem.Files.FileName | Where-Object {$_ -ne $DatabaseRestore__listDates.SelectedItem.Files.FileName[0] -and $_ -match "\.trn$"})){
                    $null = $DBR_Logs.Add($($log -replace $regexMatch,$regexReplace))
                }
            }
            else{
                $DBR_Full = $DatabaseRestore__listDates.SelectedItem.Files.FileName -replace $regexMatch,$regexReplace
            }
        }
        elseif ($env:USERDNSDOMAIN -eq "WE.AWS"){
            if ($DatabaseRestore__listDates.SelectedItem.Files.FileName.count -gt 1){
                $DBR_Full = $DatabaseRestore__listDates.SelectedItem.Files.FileName[0]
                $DBR_Diff = ($DatabaseRestore__listDates.SelectedItem.Files.FileName | Where-Object {$_ -ne $DatabaseRestore__listDates.SelectedItem.Files.FileName[0] -and $_ -notmatch "FULL|\.trn$"})
                $DBR_Logs = New-Object -TypeName "System.Collections.ArrayList"
                foreach ($log in ($DatabaseRestore__listDates.SelectedItem.Files.FileName | Where-Object {$_ -ne $DatabaseRestore__listDates.SelectedItem.Files.FileName[0] -and $_ -match "\.trn$"})){
                    $null = $DBR_Logs.Add($log)
                }
            }
            else{
                $DBR_Full = $DatabaseRestore__listDates.SelectedItem.Files.FileName -replace $regexMatch,$regexReplace
            }
        }
        if ($DBR_Logs){
            [string[]]$DBR_Logs = $DBR_Logs.ToArray()
            $DBR_Logs = $DBR_Logs -join '","' -replace '^|$','"'
        }
        <#
        $RestoreArgs = @{
            ServerInstance = $ServerInstance
            Database = $Database
            BackupFile = $DBR_Full
        }
        if ($DBR_Diff){
            $RestoreArgs.DiffFile = $DBR_Diff
        }
        if ($DBR_Logs){
            $RestoreArgs.LogBackups = $DBR_Logs
        }
        if ($DatabaseRestore__chkDeleteWhenDone.IsChecked){
            $RestoreArgs.DeleteBackups = $true
        }
        if ($DBR_Logs -and $DatabaseRestore__chkDeleteWhenDone.IsChecked){
            $RestoreArgs.DeleteLogs = $true
        }
        if ($DatabaseRestore__chkRemoveSchedules.IsChecked) {
            $RestoreArgs.RemoveSchedules = $true
        }
        foreach ($key in $RestoreArgs.Keys){
            Write-Host "$key = $($RestoreArgs[$key])"
            Write-Host "$($RestoreArgs[$key].GetType())"
        }
        # Start-WESqlRestore @RestoreArgs -outputscriptonly
        #>
        if (-not $DBR_Diff -and -not $DBR_Logs -and -not ($DatabaseRestore__chkDeleteWhenDone.IsChecked) -and -not ($DatabaseRestore__chkRemoveSchedules.IsChecked)){
            Start-Process powershell.exe -ArgumentList "Start-WESqlRestore -ServerInstance $ServerInstance -Database $Database -BackupFile $DBR_Full; Start-Sleep 10" -Verb RunAs
        }
        elseif (-not $DBR_Diff -and -not $DBR_Logs -and ($DatabaseRestore__chkDeleteWhenDone.IsChecked) -and -not ($DatabaseRestore__chkRemoveSchedules.IsChecked)){
            Start-Process powershell.exe -ArgumentList "Start-WESqlRestore -ServerInstance $ServerInstance -Database $Database -BackupFile $DBR_Full -DeleteBackups; Start-Sleep 10" -Verb RunAs
        }
        elseif (-not $DBR_Diff -and -not $DBR_Logs -and -not ($DatabaseRestore__chkDeleteWhenDone.IsChecked) -and ($DatabaseRestore__chkRemoveSchedules.IsChecked)){
            Start-Process powershell.exe -ArgumentList "Start-WESqlRestore -ServerInstance $ServerInstance -Database $Database -BackupFile $DBR_Full -RemoveSchedules; Start-Sleep 10" -Verb RunAs
        }
        elseif (-not $DBR_Diff -and -not $DBR_Logs -and ($DatabaseRestore__chkDeleteWhenDone.IsChecked) -and ($DatabaseRestore__chkRemoveSchedules.IsChecked)){
            Start-Process powershell.exe -ArgumentList "Start-WESqlRestore -ServerInstance $ServerInstance -Database $Database -BackupFile $DBR_Full -DeleteBackups -RemoveSchedules; Start-Sleep 10" -Verb RunAs
        }
        elseif ($DBR_Diff -and -not $DBR_Logs -and -not ($DatabaseRestore__chkDeleteWhenDone.IsChecked) -and -not ($DatabaseRestore__chkRemoveSchedules.IsChecked)){
            Start-Process powershell.exe -ArgumentList "Start-WESqlRestore -ServerInstance $ServerInstance -Database $Database -BackupFile $DBR_Full -DiffFile $DBR_Diff; Start-Sleep 10" -Verb RunAs
        }
        elseif ($DBR_Diff -and -not $DBR_Logs -and ($DatabaseRestore__chkDeleteWhenDone.IsChecked) -and -not ($DatabaseRestore__chkRemoveSchedules.IsChecked)){
            Start-Process powershell.exe -ArgumentList "Start-WESqlRestore -ServerInstance $ServerInstance -Database $Database -BackupFile $DBR_Full -DiffFile $DBR_Diff -DeleteBackups; Start-Sleep 10" -Verb RunAs
        }
        elseif ($DBR_Diff -and -not $DBR_Logs -and -not ($DatabaseRestore__chkDeleteWhenDone.IsChecked) -and ($DatabaseRestore__chkRemoveSchedules.IsChecked)){
            Start-Process powershell.exe -ArgumentList "Start-WESqlRestore -ServerInstance $ServerInstance -Database $Database -BackupFile $DBR_Full -DiffFile $DBR_Diff -RemoveSchedules; Start-Sleep 10" -Verb RunAs
        }
        elseif ($DBR_Diff -and -not $DBR_Logs -and ($DatabaseRestore__chkDeleteWhenDone.IsChecked) -and ($DatabaseRestore__chkRemoveSchedules.IsChecked)){
            Start-Process powershell.exe -ArgumentList "Start-WESqlRestore -ServerInstance $ServerInstance -Database $Database -BackupFile $DBR_Full -DiffFile $DBR_Diff -DeleteBackups -RemoveSchedules; Start-Sleep 10" -Verb RunAs
        }
        elseif (-not $DBR_Diff -and $DBR_Logs -and -not ($DatabaseRestore__chkDeleteWhenDone.IsChecked) -and -not ($DatabaseRestore__chkRemoveSchedules.IsChecked)){
            Start-Process powershell.exe -ArgumentList "Start-WESqlRestore -ServerInstance $ServerInstance -Database $Database -BackupFile $DBR_Full -LogBackups $DBR_Logs; Start-Sleep 10" -Verb RunAs
        }
        elseif (-not $DBR_Diff -and $DBR_Logs -and ($DatabaseRestore__chkDeleteWhenDone.IsChecked) -and -not ($DatabaseRestore__chkRemoveSchedules.IsChecked)){
            Start-Process powershell.exe -ArgumentList "Start-WESqlRestore -ServerInstance $ServerInstance -Database $Database -BackupFile $DBR_Full -LogBackups $DBR_Logs -DeleteBackups -DeleteLogs; Start-Sleep 10" -Verb RunAs
        }
        elseif (-not $DBR_Diff -and $DBR_Logs -and -not ($DatabaseRestore__chkDeleteWhenDone.IsChecked) -and ($DatabaseRestore__chkRemoveSchedules.IsChecked)){
            Start-Process powershell.exe -ArgumentList "Start-WESqlRestore -ServerInstance $ServerInstance -Database $Database -BackupFile $DBR_Full -LogBackups $DBR_Logs -RemoveSchedules; Start-Sleep 10" -Verb RunAs
        }
        elseif (-not $DBR_Diff -and $DBR_Logs -and ($DatabaseRestore__chkDeleteWhenDone.IsChecked) -and ($DatabaseRestore__chkRemoveSchedules.IsChecked)){
            Start-Process powershell.exe -ArgumentList "Start-WESqlRestore -ServerInstance $ServerInstance -Database $Database -BackupFile $DBR_Full -LogBackups $DBR_Logs -DeleteBackups -DeleteLogs -RemoveSchedules; Start-Sleep 10" -Verb RunAs
        }
    }
})


$DatabaseRestore__chkDeleteWhenDone.Add_Checked({ UpdateVerifyText })
$DatabaseRestore__chkDeleteWhenDone.Add_Unchecked({ UpdateVerifyText })
$DatabaseRestore__chkRemoveSchedules.Add_Checked({ UpdateVerifyText })
$DatabaseRestore__chkRemoveSchedules.Add_Unchecked({ UpdateVerifyText })
$DatabaseRestore__chkRunScript.Add_Unchecked({ UpdateVerifyText })

$DatabaseRestore__btnSelectScriptToRun.Add_Click({ SelectScriptToRun })

$DatabaseRestore__chkRunScript.Add_Checked({
    if ($DatabaseRestore__lblScriptToRun.Text -eq "No file selected") {
        if (SelectScriptToRun) {
            UpdateVerifyText
        } else {
            $DatabaseRestore__chkRunScript.IsChecked = $False
        }
    }
})

#endregion EventWiring