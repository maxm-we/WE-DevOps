# Adapted from https://github.com/theznerd/PoSHPF
Function Start-WEGui{
	if ( -not (Get-PSDrive Z -ErrorAction SilentlyContinue) -and $env:USERDNSDOMAIN -eq "WE.LOCAL"){
		$null = New-PSDrive -Name Z -PSProvider FileSystem -Root "\\fs01.we.local\backups" -Persist
	}
	#region Setup
	#===============================================================================
	# Import Resources
	#===============================================================================
	$Global:resources = Get-ChildItem -Path "$PSScriptRoot\Resources\*.dll" -ErrorAction SilentlyContinue
	$Global:XAML = Get-ChildItem -Path "$PSScriptRoot\XAML\*.xaml" -ErrorAction SilentlyContinue
	$Global:wiring = $XAML | ForEach-Object { "$PSScriptRoot\XAML\$($_.BaseName).ps1" } | Where-Object { Test-Path $_ -PathType Leaf }

	# So that forms have a good root (in case of nesting)
	$Global:caller_root = $PSScriptRoot

	# Load WPF Assembly
	Add-Type -AssemblyName PresentationFramework

	# Shame, shame, shame
	Add-Type -AssemblyName System.Windows.Forms
	[void][System.Reflection.Assembly]::LoadWithPartialName('Microsoft.VisualBasic')

	# Load Resources
	foreach($dll in $resources) { [System.Reflection.Assembly]::LoadFrom("$($dll.FullName)") | out-null }

	#===============================================================================
	# Import XAML
	#===============================================================================
	$xp = '[^a-zA-Z_0-9]' # All characters that are not a-Z, 0-9, or _
	$vx = @()             # An array of XAML files loaded

	foreach($x in $XAML) {
		# Items from XAML that are known to cause issues
		# when PowerShell parses them.
		$xamlToRemove = @(
			'mc:Ignorable="d"',
			"x:Class=`"(.*?)`"",
			"xmlns:local=`"(.*?)`""
		)

		$xaml = Get-Content $x.FullName # Load XAML

		foreach($xtr in $xamlToRemove){ $xaml = $xaml -replace $xtr } # Remove items from $xamlToRemove

		# Create a new variable to store the XAML as XML
		New-Variable -Name "xaml$(($x.BaseName) -replace $xp, '_')" -Value ($xaml -as [xml]) -Force

		# Add XAML to list of XAML documents processed
		$vx += "$(($x.BaseName) -replace $xp, '_')"
	}
	#endregion Setup

	#region ThreadStuff
	#===============================================================================
	# Runspace Functions
	#===============================================================================
	$Script:JobCleanup = [Hashtable]::Synchronized(@{})
	$Script:Jobs = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList)) # hashtable to store all these runspaces

	$jobCleanup.Flag = $True # cleanup jobs
	$newRunspace = [RunspaceFactory]::CreateRunspace() # create a new runspace for this job to cleanup jobs to live
	$newRunspace.ApartmentState = "STA"
	$newRunspace.ThreadOptions = "ReuseThread"
	$newRunspace.Open()
	$newRunspace.SessionStateProxy.SetVariable("jobCleanup", $jobCleanup) # pass the jobCleanup variable to the runspace
	$newRunspace.SessionStateProxy.SetVariable("jobs", $jobs) # pass the jobs variable to the runspace
	$jobCleanup.PowerShell = [PowerShell]::Create().AddScript({
		#Routine to handle completed runspaces
		Do {
			Foreach($runspace in $jobs) {
				If ($runspace.Runspace.isCompleted) {                         # if runspace is complete
					[void]$runspace.powershell.EndInvoke($runspace.Runspace)  # then end the script
					$runspace.powershell.dispose()                            # dispose of the memory
					$runspace.Runspace = $null                                # additional garbage collection
					$runspace.powershell = $null                              # additional garbage collection
				}
			}
			#Clean out unused runspace jobs
			$temphash = $jobs.clone()
			$temphash | Where-Object { $_.runspace -eq $Null } | ForEach-Object { $jobs.remove($_) }
			Start-Sleep -Seconds 1 # lets not kill the processor here
		} while ($jobCleanup.Flag)
	})
	$jobCleanup.PowerShell.Runspace = $newRunspace
	$jobCleanup.Thread = $jobCleanup.PowerShell.BeginInvoke()

	#===============================================================================
	# Synchronized Hashtable
	#===============================================================================
	# This class allows the synchronized hashtable to be available across threads,
	# but also passes a couple of methods along with it to do GUI things via the
	# object's dispatcher.
	class SyncClass {
		#Hashtable containing all forms/windows and controls - automatically created when newing up
		[Hashtable]$SyncHash = [Hashtable]::Synchronized(@{})

		# method to close the window - pass window name
		[void]CloseWindow($windowName) {
			$this.SyncHash.$windowName.Dispatcher.Invoke([action]{$this.SyncHash.$windowName.Close()}, "Normal")
		}

		# method to update GUI - pass object name, property and value
		[void]UpdateElement($object, $property, $value) {
			$this.SyncHash.$object.Dispatcher.Invoke([action]{ $this.SyncHash.$object.$property = $value }, "Normal")
		}
	}
	$Global:SyncClass = [SyncClass]::new() # create a new instance of this SyncClass to use.

	# This function creates a new runspace for a script block to execute
	# so that you can do your long running tasks not in the UI thread.
	# Also the SyncClass is passed to this runspace so you can do UI
	# updates from this thread as well.
	function Start-BackgroundScriptBlock($scriptBlock) {
		$newRunspace = [RunspaceFactory]::CreateRunspace()
		$newRunspace.ApartmentState = "STA"
		$newRunspace.ThreadOptions = "ReuseThread"
		$newRunspace.Open()
		$newRunspace.SessionStateProxy.SetVariable("SyncClass", $SyncClass)
		$PowerShell = [PowerShell]::Create().AddScript($scriptBlock)
		$PowerShell.Runspace = $newRunspace

		# Add it to the job list so that we can make sure it is cleaned up
		[void]$Jobs.Add(
			[PSCustomObject]@{
				PowerShell = $PowerShell
				Runspace = $PowerShell.BeginInvoke()
			}
		)
	}
	#endregion ThreadStuff

	#region DynamicVariables
	#===============================================================================
	# Create forms and find controls
	#===============================================================================
	$forms = @()
	foreach($x in $vx) {
		$Reader = (New-Object System.Xml.XmlNodeReader ((Get-Variable -Name "xaml$($x)").Value)) # load the xaml we created earlier into XmlNodeReader

		New-Variable -Name "$($x)" -Value ([Windows.Markup.XamlReader]::Load($Reader)) -Force # load the xaml into XamlReader
		$forms += "$($x)" # add the form name to our array
		$SyncClass.SyncHash.Add("$($x)", (Get-Variable -Name "$($x)").Value) # add the form object to our synched hashtable
	}

	#===============================================================================
	# Create Controls (Buttons, etc)
	#===============================================================================
	$controls = @()
	$xp = '[^a-zA-Z_0-9]' # All characters that are not a-Z, 0-9, or _
	foreach($x in $vx) {
		$xaml = (Get-Variable -Name "xaml$($x)").Value # load the xaml we created earlier

		# Gonna get ugly here. First, do a namespace-unaware node lookup
		$xaml.SelectNodes("//*[@*[local-name() = 'Name']]") | ForEach-Object { # find all nodes with a "Name" attribute
			# Remove the namespace from the name
			$unaware_name = $_.Name -replace '[a-z]*:', ''
			$cname = "$($x)__$(($unaware_name -replace $xp, '_'))"
			Set-Variable -Name "$cname" -Value $SyncClass.SyncHash."$($x)".FindName($unaware_name) # create a variale to hold the control/object
			$controls += (Get-Variable -Name "$($x)__$($unaware_name)").Name # add the control name to our array
			$SyncClass.SyncHash.Add($cname, $SyncClass.SyncHash."$($x)".FindName($unaware_name)) # add the control directly to the hashtable
		}
	}

	#===============================================================================
	# Output result (if running in ISE)
	#===============================================================================
	if ($False) {
		Write-Host -ForegroundColor Cyan "The following forms were created:"
		$forms | ForEach-Object { Write-Host -ForegroundColor Yellow "  `$$_"} # output all forms to screen
		if($controls.Count -gt 0) {
			Write-Host ""
			Write-Host -ForegroundColor Cyan "The following controls were created:"
			$controls | ForEach-Object { Write-Host -ForegroundColor Yellow "  `$$_"} # output all named controls to screen
		}
	}
	#endregion DynamicVariables

	#===============================================================================
	# WIRE UP YOUR CONTROLS
	#===============================================================================



	$wiring | ForEach-Object { Invoke-Expression ". `"$($_)`"" }

	# simple example: $formMainWindowControlButton.Add_Click({ your code })
	#
	# example with BackgroundScriptBlock and UpdateElement
	# $formmainControlButton.Add_Click({
	#     $sb = {
	#         $SyncClass.UpdateElement("formmainControlProgress","Value",25)
	#     }
	#     Start-BackgroundScriptBlock $sb
	# })

	#===============================================================================
	# DISPLAY DIALOG
	#===============================================================================

	[void]$LandingForm.ShowDialog()

	#region Cleanup
	#===============================================================================
	# SCRIPT CLEANUP
	#===============================================================================
	$jobCleanup.Flag = $false                 # Stop Cleaning Jobs
	$jobCleanup.PowerShell.Runspace.Close()   # Close the runspace
	$jobCleanup.PowerShell.Dispose()          # Remove the runspace from memory
	#endregion Cleanup
}