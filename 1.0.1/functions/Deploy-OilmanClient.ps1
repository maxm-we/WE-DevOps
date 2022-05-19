<#
.SYNOPSIS
    Deploys and installs the required services and configuration files for Oilman server access.
.DESCRIPTION
    Prerequisites: Chocolatey for PowerShell
    Installs the required services and configuration files for Oilman server access. Takes in the Oilman Public Key and authorizes it. Deploys the necessary configuration.
.EXAMPLE
    PS C:\> Deploy-OilmanClient -PublicKey "PublicKey"
.PARAMETER PublicKey
    Specifies the the Oilman client public key from AWS Secrets Manager.
.INPUTS
    None. You cannot pipe objects to Deploy-OilmanClient
.OUTPUTS
    None
.LINK
https://chocolatey.org/

.LINK
https://devopsgit.we.aws/devin.lauderdale/oilman2_frontend

#>

function Fix-SSHPermissions {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $False)]
        [switch]$HomeFolderAndSubItemsOnly,

        [Parameter(Mandatory = $False)]
        [switch]$ProgramDataFolderAndSubItemsOnly
    )

    if ($PSVersionTable.PSEdition -ne "Desktop" -and $PSVersionTable.Platform -ne "Win32NT") {
        Write-Error "This function is only meant to fix permissions on Windows machines. Halting!"
        $global:FunctionResult = "1"
        return
    }

    if (!$HomeFolderAndSubItemsOnly) {
        if (Test-Path "$env:ProgramData\ssh") {
            $sshdir = "$env:ProgramData\ssh"
        }
        elseif (Test-Path "$env:ProgramFiles\OpenSSH-Win64") {
            $sshdir = "$env:ProgramFiles\OpenSSH-Win64"
        }
        if (!$sshdir) {
            Write-Error "Unable to find ssh directory at '$env:ProgramData\ssh' or '$env:ProgramFiles\OpenSSH-Win64'! Halting!"
            $global:FunctionResult = "1"
            return
        }
    }

    if (!$(Test-Path "$env:ProgramFiles\OpenSSH-Win64\FixHostFilePermissions.ps1")) {
        $LatestPSScriptsUriBase = "https://raw.githubusercontent.com/PowerShell/Win32-OpenSSH/L1-Prod/contrib/win32/openssh"
        $ScriptsToDownload = @(
            "FixHostFilePermissions.ps1"
            "FixUserFilePermissions.ps1"
            #"OpenSSHCommonUtils"
            "OpenSSHUtils.psm1"
        )

        $NewFolderInDownloadDir = NewUniqueString -ArrayOfStrings $(Get-ChildItem "$HOME\Downloads" -Directory).Name -PossibleNewUniqueString "OpenSSH_PowerShell_Utils"

        $null = New-Item -ItemType Directory -Path "$HOME\Downloads\$NewFolderInDownloadDir"

        [System.Collections.ArrayList]$FailedDownloads = @()
        foreach ($ScriptFile in $ScriptsToDownload) {
            $OutFilePath = "$HOME\Downloads\$NewFolderInDownloadDir\$ScriptFile"
            Invoke-WebRequest -Uri "$LatestPSScriptsUriBase/$ScriptFile" -OutFile $OutFilePath
            
            if (!$(Test-Path $OutFilePath)) {
                $null = $FailedDownloads.Add($OutFilePath)
            }
        }

        if ($FailedDownloads.Count -gt 0) {
            Write-Error "Failed to download the following OpenSSH PowerShell Utility Scripts/Modules: $($FailedDownloads -join ', ')! Halting!"
            $global:FunctionResult = "1"
            return
        }

        $OpenSSHPSUtilityScriptDir = "$HOME\Downloads\$NewFolderInDownloadDir"
    }
    else {
        $OpenSSHPSUtilityScriptDir = "$env:ProgramFiles\OpenSSH-Win64"
    }

    if ($(Get-Module).Name -contains "OpenSSHUtils") {
        Remove-Module OpenSSHUtils
    }
    <#
    if ($(Get-Module).Name -contains "OpenSSHCommonUtils") {
        Remove-Module OpenSSHCommonUtils
    }
    #>

    Import-Module "$OpenSSHPSUtilityScriptDir\OpenSSHUtils.psm1"
    #Import-Module "$OpenSSHPSUtilityScriptDir\OpenSSHCommonUtils.psm1"
    
    if ($(Get-Module).Name -notcontains "OpenSSHUtils") {
        Write-Error "Failed to import OpenSSHUtils Module! Halting!"
        $global:FunctionResult = "1"
        return
    }
    <#
    if ($(Get-Module).Name -notcontains "OpenSSHCommonUtils") {
        Write-Error "Failed to import OpenSSHCommonUtils Module! Halting!"
        $global:FunctionResult = "1"
        return
    }
    #>

    if ($(Get-Module -ListAvailable).Name -notcontains "NTFSSecurity") {
        Install-Module NTFSSecurity
    }

    try {
        if ($(Get-Module).Name -notcontains "NTFSSecurity") { Import-Module NTFSSecurity }
    }
    catch {
        if ($_.Exception.GetType().FullName -eq "System.Management.Automation.RuntimeException") {
            Write-Verbose "NTFSSecurity Module is already loaded..."
        }
        else {
            Write-Error "There was a problem loading the NTFSSecurity Module! Halting!"
            $global:FunctionResult = "1"
            return
        }
    }

    if (!$HomeFolderAndSubItemsOnly) {
        $FixHostFilePermissionsOutput = & "$OpenSSHPSUtilityScriptDir\FixHostFilePermissions.ps1" -Confirm:$false 6>&1

        if (Test-Path "$sshdir/authorized_principals") {
            $SecurityDescriptor = Get-NTFSSecurityDescriptor -Path "$sshdir/authorized_principals"
            $SecurityDescriptor | Disable-NTFSAccessInheritance -RemoveInheritedAccessRules
            $SecurityDescriptor | Clear-NTFSAccess
            $SecurityDescriptor | Add-NTFSAccess -Account "NT AUTHORITY\SYSTEM" -AccessRights "FullControl" -AppliesTo ThisFolderSubfoldersAndFiles
            $SecurityDescriptor | Add-NTFSAccess -Account "Administrators" -AccessRights "FullControl" -AppliesTo ThisFolderSubfoldersAndFiles
            $SecurityDescriptor | Set-NTFSSecurityDescriptor
        }

        # If there's a Host Key Public Cert, make sure permissions on it are set properly...This is not handled
        # by FixHostFilePermissions.ps1
        if (Test-Path "$sshdir/ssh_host_rsa_key-cert.pub") {
            $SecurityDescriptor = Get-NTFSSecurityDescriptor -Path "$sshdir/ssh_host_rsa_key-cert.pub"
            $SecurityDescriptor | Disable-NTFSAccessInheritance -RemoveInheritedAccessRules
            $SecurityDescriptor | Clear-NTFSAccess
            $SecurityDescriptor | Add-NTFSAccess -Account "NT AUTHORITY\SYSTEM" -AccessRights "FullControl" -AppliesTo ThisFolderSubfoldersAndFiles
            $SecurityDescriptor | Add-NTFSAccess -Account "Administrators" -AccessRights "FullControl" -AppliesTo ThisFolderSubfoldersAndFiles
            $SecurityDescriptor | Add-NTFSAccess -Account "NT AUTHORITY\Authenticated Users" -AccessRights "ReadAndExecute, Synchronize" -AppliesTo ThisFolderSubfoldersAndFiles
            $SecurityDescriptor | Set-NTFSSecurityDescriptor
        }
    }
    if (!$ProgramDataFolderAndSubItemsOnly) {
        $FixUserFilePermissionsOutput = & "$OpenSSHPSUtilityScriptDir\FixUserFilePermissions.ps1" -Confirm:$false 6>&1

        $SecurityDescriptor = Get-NTFSSecurityDescriptor -Path "$HOME\.ssh"
        $SecurityDescriptor | Disable-NTFSAccessInheritance -RemoveInheritedAccessRules
        $SecurityDescriptor | Clear-NTFSAccess
        $SecurityDescriptor | Add-NTFSAccess -Account "NT AUTHORITY\SYSTEM" -AccessRights "FullControl" -AppliesTo ThisFolderSubfoldersAndFiles
        $SecurityDescriptor | Add-NTFSAccess -Account "$(whoami)" -AccessRights "FullControl" -AppliesTo ThisFolderSubfoldersAndFiles
        $SecurityDescriptor | Set-NTFSSecurityDescriptor

        $UserHomeDirs = Get-ChildItem "C:\Users"
        foreach ($UserDir in $UserHomeDirs) {
            $KnownHostsPath = "$($UserDir.FullName)\.ssh\known_hosts"
            $AuthorizedKeysPath = "$($UserDir.FullName)\.ssh\authorized_keys"

            if ($(Test-Path $KnownHostsPath) -or $(Test-Path $AuthorizedKeysPath)) {
                if (Test-Path $KnownHostsPath) {
                    $SecurityDescriptor = Get-NTFSSecurityDescriptor -Path $KnownHostsPath
                    $SecurityDescriptor | Disable-NTFSAccessInheritance -RemoveInheritedAccessRules
                    $SecurityDescriptor | Clear-NTFSAccess
                    $SecurityDescriptor | Enable-NTFSAccessInheritance
                    $SecurityDescriptor | Set-NTFSSecurityDescriptor

                    # Make sure it's UTF8 Encoded
                    $FileContent = Get-Content $KnownHostsPath
                    Set-Content -Value $FileContent $KnownHostsPath -Encoding UTF8
                }
                if (Test-Path $AuthorizedKeysPath) {
                    $SecurityDescriptor = Get-NTFSSecurityDescriptor -Path $AuthorizedKeysPath
                    $SecurityDescriptor | Disable-NTFSAccessInheritance -RemoveInheritedAccessRules
                    $SecurityDescriptor | Clear-NTFSAccess
                    $SecurityDescriptor | Enable-NTFSAccessInheritance
                    $SecurityDescriptor | Set-NTFSSecurityDescriptor

                    $FileContent = Get-Content $AuthorizedKeysPath
                    Set-Content -Value $FileContent $AuthorizedKeysPath -Encoding UTF8
                }
            }
        }
    }

    try {
        Write-Host "Restarting the sshd service..."
        Restart-Service sshd
    }
    catch {
        Write-Error $_
        $global:FunctionResult = "1"
        return
    }

    [pscustomobject]@{
        FixHostFilePermissionsOutput = $FixHostFilePermissionsOutput
        FixUserFilePermissionsOutput = $FixUserFilePermissionsOutput
    }
}

function Deploy-OilmanClient {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][string]$PublicKey
    )
    
    begin {

        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

        if (Test-Path -Path 'C:\OilmanTemp') {

            Write-Verbose "Previous Oilman temporary folder found, removing."

            Remove-Item -Force -Path 'C:\OilmanTemp' -Recurse
            
        } 

        New-Item -Path "C:\" -Name "OilmanTemp" -ItemType "directory"

        Set-Location "C:\OilmanTemp"

        # Testing if Powershell or SSHD exist on client

        if (Get-Service | Where-Object { $_.Name -Match "sshd" }) {
            Write-Verbose "OpenSSH Server already exists"
            $OpenSSHExists = $true
        }
        else {

            If (Test-Path -Path "$Env:ProgramData\chocolatey") {
                choco install openssh --pre --params "'/SSHAgentFeature /SSHServerFeature /OverWriteSSHDConf'"
                choco upgrade openssh --pre    
            }
            else {
                Write-Error "Chocolatey does not exist, please install Chocolatey and try again."
                return 1
            }

        }

        if (Test-Path "$env:ProgramFiles\Powershell\7") {
            Write-Verbose "PowerShell 7 already exists."
            $PowershellExists = $true
        }
        else {

            Write-Output "Getting Powershell package from Github."

            Invoke-WebRequest -Uri 'https://github.com/PowerShell/PowerShell/releases/download/v7.1.4/PowerShell-7.1.4-win-x64.msi' -OutFile 'PowerShell-7.1.4-win-x64.msi'

            Write-Output "Installing Powershell package."

            Start-Process 'C:\Windows\System32\msiexec.exe' -ArgumentList @('/package C:\OilmanTemp\PowerShell-7.1.4-win-x64.msi', '/Quiet', 'ADD_EXPLORER_CONTEXT_MENU_OPENPOWERSHELL=1', 'ADD_EXPLORER_CONTEXT_MENU_OPENPOWERSHELL=1', 'ADD_EXPLORER_CONTEXT_MENU_OPENPOWERSHELL=1', 'ENABLE_PSREMOTING=1', 'REGISTER_MANIFEST=1') -Wait
        }

        if (($PowershellExists) -and ($OpenSSHExists)) {
            Write-Output "Both Powershell 7 and OpenSSH server are present, skipped installation."
        }

    }
    
    process {

        #Installing Modules for Powershell 7

        Write-Output "Installing modules over PowerShell 7, please approve UAC prompt as this installs to the AllUsers scope which requires elevated privleges."

        Start-Process 'C:\Program Files\PowerShell\7\pwsh.exe' -Verb RunAs -ArgumentList '-c " If (-not (Get-Module -Name AWSPowerShell* -ListAvailable -ErrorAction Ignore)) {Install-Module -Name AWSPowerShell.NetCore -Scope AllUsers}; If ( -not (Get-Module -Name SqlServer -ListAvailable -ErrorAction Ignore) ) { Install-Module -Name SqlServer -Scope AllUsers -AllowPrerelease }" ' -Wait

        if (Test-Path 'C:\ProgramData\ssh') {
            Write-Output "Starting OpenSSH configuration"
            Set-Service sshd -StartupType Automatic
            Stop-Service sshd
            New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell -Value "C:\Program Files\PowerShell\7\pwsh.exe" -PropertyType String -Force
            Set-Location 'C:\ProgramData\ssh'
            Set-Content -Path $env:ProgramData\ssh\sshd_config -Value @"
# This is the sshd server system-wide configuration file.  See
# sshd_config(5) for more information.

# The strategy used for options in the default sshd_config shipped with
# OpenSSH is to specify options with their default value where
# possible, but leave them commented.  Uncommented options override the
# default value.

#Port 22
#AddressFamily any
#ListenAddress 0.0.0.0
#ListenAddress ::

#HostKey __PROGRAMDATA__/ssh/ssh_host_rsa_key
#HostKey __PROGRAMDATA__/ssh/ssh_host_dsa_key
#HostKey __PROGRAMDATA__/ssh/ssh_host_ecdsa_key
#HostKey __PROGRAMDATA__/ssh/ssh_host_ed25519_key

# Ciphers and keying
#RekeyLimit default none

# Logging
#SyslogFacility AUTH
#LogLevel INFO

# Authentication:

#LoginGraceTime 2m
#PermitRootLogin prohibit-password
#StrictModes yes
#MaxAuthTries 6
#MaxSessions 10

PubkeyAuthentication yes

# The default is to check both .ssh/authorized_keys and .ssh/authorized_keys2
# but this is overridden so installations will only check .ssh/authorized_keys
AuthorizedKeysFile .ssh/authorized_keys

#AuthorizedPrincipalsFile none

# For this to work you will also need host keys in %programData%/ssh/ssh_known_hosts
#HostbasedAuthentication no
# Change to yes if you don't trust ~/.ssh/known_hosts for
# HostbasedAuthentication
#IgnoreUserKnownHosts no
# Don't read the user's ~/.rhosts and ~/.shosts files
#IgnoreRhosts yes

# To disable tunneled clear text passwords, change to no here!
#PasswordAuthentication yes
#PermitEmptyPasswords no

# GSSAPI options
#GSSAPIAuthentication no

#AllowAgentForwarding yes
#AllowTcpForwarding yes
#GatewayPorts no
#PermitTTY yes
#PrintMotd yes
#PrintLastLog yes
#TCPKeepAlive yes
#UseLogin no
#PermitUserEnvironment no
#ClientAliveInterval 0
#ClientAliveCountMax 3
#UseDNS no
#PidFile /var/run/sshd.pid
#MaxStartups 10:30:100
#PermitTunnel no
#ChrootDirectory none
#VersionAddendum none

# no default banner path
#Banner none

# override default of no subsystems
Subsystem sftp sftp-server.exe
Subsystem powershell c:/progra~1/powershell/7/pwsh.exe -sshs -NoLogo

# Example of overriding settings on a per-user basis
#Match User anoncvs
#	AllowTcpForwarding no
#	PermitTTY no
#	ForceCommand cvs server

Match Group administrators
       AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys
"@
            # Add-Content -Path $env:ProgramData\ssh\sshd_config -Value "Subsystem powershell c:/progra~1/powershell/7/pwsh.exe -sshs -NoLogo"
            # Add-Content -Path $env:ProgramData\ssh\sshd_config -Value "PubkeyAuthentication yes"
            Write-Verbose "SSH Folder found, creating PublicKey: `"$PublicKey`" in C:\ProgramData\ssh\"
            Set-Content -Path .\administrators_authorized_keys -Value "ssh-ed25519 $PublicKey system@$Env:ComputerName"
            Set-Content -Path .\ssh_host_ed25519_key.pub -Value "ssh-ed25519 $PublicKey system@$Env:ComputerName"
            Stop-Service -Name ssh-agent
            Fix-SSHPermissions -Verbose
            Start-Service -Name ssh-agent
            Start-Service -name sshd
            Write-Output "Deployment complete."
            $CompletedFlag = 1
        }
        else {
            Write-Error "SSH path does not exist, install must have failed somewhere, please retry the script."
        }
        
    }
    
    end {

        
    }
}