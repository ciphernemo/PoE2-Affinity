<#
.SYNOPSIS
	Path of Exile 2 for Steam: CPU Affinity Adjustment to Automatically Add Launch Options
.DESCRIPTION
	Sets CPU affinity for the Steam-based PoE2 process. This script will perform the following:

	1. Searches system for Steam and PoE2 via registry keys, the default install location, then recursive drive search.
		If multiple locations are found, prompt user for preferred location.
	2. Determines available threads on system, ask how many threads to withhold from PoE2, then calculate affinity mask.
	3. Find the Steam localconfig.vdf and libraryfolders.vdf files.
	4. Create a single-line batch file in PoE2's folder that launches PoE2 with CPU affinity settings.
	5. Read the localconfig.vdf in a PSObject and add launch options for PoE2.
	6. Create a backup of Steam's localconfig.vdf file.
	7. Saves changes to localconfig.vdf

	* Creates a log file in the same location and of the same name as this script.
	* Requires Powershell 3+ (Windows 11, 10, 8, and Server 2025, 2022, 2019, 2016, 2012)
	* Use System.IO.File.WriteAllLines instead of Out-File to ensure UTF-8 encoding. Steam will reject UTF-16 encoded files.
	* Feel free to take and re-work this script, according to its license, for use with other Steam games.
	* Inspiration and reworked code from Steam-GetOnTop by ChiefIntegrator: https://github.com/ChiefIntegrator/Steam-GetOnTop
	* Compiled with PS2EXE-GUI [Invoke-PS2EXE] v0.5.0.30 by Ingo Karstein & Markus Scholtes: https://github.com/MScholtes/PS2EXE
.NOTES
	Version:		1.0
	Author:			cipher_nemo
	License:		GPLv3: https://www.gnu.org/licenses/gpl-3.0.en.html
	Creation Date:	12/18/2024
	Updated:		12/29/2024
	Version History:
		1.0: 12/29/2024 - Initial script and compiled executable
#>

# ____[ Compatibility ]__________________________________________________________________________________________________________

#check for compatible PowerShell version
#	Invoke-ScriptAnalyzer -Path ".\poe2_steam_set_affinity.ps1"
if (Get-Variable -Name PSVersionTable)
{
	if (!($PSVersionTable.PSVersion.Major -ge 3))
	{
		Write-Error("The version of PowerShell available may be incompatible with this script.")
		Exit 1
	}
}
else
{
	Write-Error("The version of PowerShell available may be incompatible with this script.")
	Exit 1
}

# ____[ Variables ]______________________________________________________________________________________________________________

#Steam app ID: current app id for PoE2 is 2694490 (get app id from within the Steam store page URL)
[string]$PoE2AppID = "2694490"
#Name of batch file to create within the PoE2 install folder
[string]$PoE2Batch = "PoE2.bat"
#log path to record generated output
[string]$LogFile = ".\poe2_affinity.log"
#prevent displaying errors
$ErrorActionPreference = "SilentlyContinue"
#timestamp filter for log file entries
filter TimeStamp {"$(Get-Date -Format G): $_"}

# ____[ Functions ]______________________________________________________________________________________________________________

function Write-Log
{
	param
	(
		[parameter(Mandatory = $true)]
		[string]$LogText,
		[parameter(Mandatory = $false)]
		[bool]$SaveToLog = $true
	)
	#Write-Output for production, Write-Host for debugging
	Write-Output $LogText
	if ($SaveToLog) { Add-Content -Path $LogFile -Value ($LogText | TimeStamp) }
}

#get number of total threads for the system's CPU (logical processors, not actual core count)
function Get-CPUInfo
{
	[string[]]$results = @()
	#deprecated: Get-WmiObject Win32_Processor
	$cpu = Get-CimInstance Win32_Processor
	$cpuName = ($cpu.Name).Replace("(R)", "")
	$cpuName = $cpuName.Replace("(TM)", "")
	$results += $cpuName.Replace(" CPU @", "")
	$results += $cpu.NumberOfCores
	$results += $cpu.NumberOfLogicalProcessors
	return $results
}

#calculate the CPU affinity mask, returns hexadecimal mask
function Get-CPUAffinityMask
{
	param
	(
		[parameter(Mandatory = $true)]
		[int]$ThreadCount,
		[parameter(Mandatory = $false)]
		[int]$ReserveThreads = 2
	)
	$affinity = $ThreadCount
	#subtract desired number of free threads from thread count
	if ($ThreadCount -gt $ReserveThreads)
	{
		$affinity = $ThreadCount - $ReserveThreads
	}
	#calculate mask: get mask in decimal then subtract one and convert to hex
	#$mask = $affinity | ForEach-Object -Begin { $mask = 0 } -Process { $mask += [Math]::Pow(2,$_) } -End { $mask }
	$mask = 0
	$mask = $affinity | ForEach-Object -Process { $mask += [Math]::Pow(2,$_) } -End { $mask }
	$hexMask = [Convert]::ToString(($mask - 1), 16)
	return $hexMask.ToUpper()
}

function New-RandomChars
{
	param
	(
		[parameter(Mandatory = $false)]
		[int]$CharLength = 6
	)
	$chars = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
	[string]$result = [String]::Empty
	for ($i = 0; $i -lt $CharLength - 1; $i++)
	{
		$result += $chars[(Get-Random -Maximum $chars.Length)]
	}
	return $result
}

#parses a VDF and converts it to a custom object
#	example: $vdf = ConvertFrom-VDF -source (Get-Content "C:\localconfig.vdf")
function ConvertFrom-VDF
{
	param
	(
		[parameter(Mandatory = $true)]
		[ValidateNotNullOrEmpty()]
		[System.String[]]$Source
	)
	$root = New-Object -TypeName PSObject
	$chain = [ordered]@{}
	$treeDepth = 0
	$parent = $root
	$element = $null
	$i = 0
	foreach ($line in $Source)
	{
		#make one to two matches per line of quoted sections, separate by tabs only when next to quote marks,
		#	match empty and single character quoted sections,
		#	include escaped quotes \" in matches but don't make separate matches for \"",
		#	and include leading and trailing quote marks for safety as they will be removed when converting back to VDF
		$pattern = '(?<=^|\t|{|\n)"((?:[^"\\]|\\[\\"])*)"(?=\t|\n|$|})'
		$quotedElements = (Select-String -Pattern $pattern -InputObject $line -AllMatches).Matches
		#create a new sub object
		if ($quotedElements.Count -eq 1)
		{
			$element = New-Object -TypeName PSObject
			Add-Member -InputObject $parent -MemberType NoteProperty -Name $quotedElements[0].Value -Value $element
		}
		#create a new string hash
		elseif ($quotedElements.Count -eq 2)
		{
			Add-Member -InputObject $element -MemberType NoteProperty -Name $quotedElements[0].Value -Value $quotedElements[1].Value
		}
		elseif ($line -match "{")
		{
			$chain.Add($treeDepth, $element)
			$parent = $chain.$treeDepth
			$treeDepth++
		}
		elseif ($line -match "}")
		{
			$treeDepth--
			$treeDepthLower = $treeDepth - 1
			$parent = $chain.$treeDepthLower
			$element = $parent
			$chain.Remove($treeDepth)
		}
		$i++
	}
	return $root
}

#formats a string to trim leading and trailing quote marks
function Format-MemberString
{
	param
	(
		[parameter(Mandatory = $true)]
		[string]$myMember
	)
	return (($myMember).Substring(1, $myMember.Length - 2))
}

#converts an object to a VDF file
#	example: [System.IO.File]::WriteAllLines($vdfFile, (ConvertTo-VDF -Source $vdfObject))
function ConvertTo-VDF
{
	param
	(
		[parameter(Mandatory = $true, Position = 0)]
		[PSObject]$Source,
		[parameter(Mandatory = $false, Position = 1)]
		[int]$treeDepth = 0
	)
	$output = [String]::Empty
	$members = $Source.PSObject.Members | Where-Object { $_.MemberType -eq "NoteProperty" }
	for ($i = 0; $i -lt $members.Count; $i++)
	{
		$member = $members[$i]
		if ($member.TypeNameOfValue -eq "System.String")
		{
			$tabIndent = "`t" * $treeDepth
			$m1 = Format-MemberString $member.Name
			$m2 = Format-MemberString ($Source.($member.Name))
			$output += $tabIndent + "`"" + $m1 + "`"`t`t`"" + $m2 + "`"`n"
		}
		elseif ($member.TypeNameOfValue -eq "System.Management.Automation.PSCustomObject")
		{
			$tabIndent = "`t" * $treeDepth
			$element = $Source.($member.Name)
			$output += $tabIndent + "`"" + (Format-MemberString $member.Name) + "`"`n"
			$output += $tabIndent + "{`n"
			$treeDepth++
			$output += ConvertTo-VDF -Source $element -treeDepth $treeDepth
			$treeDepth--
			$output += $tabIndent + "}"
			if ($treeDepth -gt 0)
			{
				$output += "`n"
			}
		}
	}
	return $output
}

#formats a path to replace all forward slashes with back slashes and return its proper capitalization
function Format-ProperPath
{
	param
	(
		[parameter(Mandatory = $true)]
		[string]$Path
	)
	$Path = $Path.Replace('/', '\')
	$properPath = [String]::Empty
	if (!((Test-Path $Path -PathType Leaf) -or (Test-Path $Path -PathType Container)))
	{
		return $Path
	}
	foreach ($branch in $Path.Split("\"))
	{
		if ($properPath -eq "")
		{
			$properPath = $branch.ToUpper() + "\"
			continue
		}
		$properPath = [System.IO.Directory]::GetFileSystemEntries($properPath, $branch)[0];
	}
	return $properPath;
}

#finds the Steam install path
function Get-SteamPath
{
	#search for Steam in registry keys
	[string[]]$hive = @("HKCU:", "HKLM:")
	foreach ($h in $hive)
	{
		try
		{
			$key = "$h\Software\Valve\Steam\"
			if (Test-Path -Path $key)
			{
				$steam = Format-ProperPath ((Get-ItemProperty $key).SteamPath)
				if (Test-Path -Path $steam) { return $steam }
			}
		}
		catch
		{
			continue
		}
	}
	#test for default install path
	$pfx86 = "${Env:ProgramFiles(x86)}"
	if (Test-Path -Path "$pfx86\Steam\steam.exe")
	{
		return "$pfx86\Steam\steam.exe"
	}
	#search drives for steam.exe file
	else
	{
		Write-Log "Steam client not within the Registry or default location. Searching your drives for Steam..."
		#set up system drive exclusions for search
		[string[]]$paths = @($Env:SystemRoot, $Env:ProgramData, $Env:TEMP, "$Env:SystemRoot\Temp", "$Env:SystemDrive\Recovery")
		$paths += ("$Env:USERPROFILE\GoogleDrive", "$Env:USERPROFILE\Box")
		if ($Env:OneDrive) { $paths += $Env:OneDrive }
		#get all drives on the system
		[string[]]$driveLetters = Get-PSDrive | Select-Object -ExpandProperty "Name" | Select-String -Pattern '^[a-z]$'
		[string[]]$results = @()
		foreach ($d in $driveLetters)
		{
			$d = $d + ":\"
			Write-Log "Searching $d drive..."
			#recursively search a drive and add matches to results
			if ($items = Get-ChildItem -Path $d -Filter "steam.exe" -Exclude $paths -Recurse)
			{
				foreach ($item in $items)
				{
					$results += $item.FullName
				}
			}
		}
		if ($results.Count -gt 0)
		{
			return $results
		}
		else
		{
			#no results found
			Write-Log "Steam not found on the local system. Exiting..."
			Start-Sleep -Seconds 6
			exit
		}
	}
}

#confirms that the constructed path to a Steam config file exists
function Test-SteamFile
{
	param
	(
		[parameter(Mandatory = $true)]
		[string]$SteamFilePath,
		[parameter(Mandatory = $false)]
		[string]$FileDescription = "Steam file"
	)
	if (Test-Path -Path $SteamFilePath)
	{
		Write-Log "$FileDescription found at $SteamFilePath"
	}
	else
	{
		#Steam file does not exist
		Write-Log "$FileDescription does not exist in its expected location. Exiting..."
		Start-Sleep -Seconds 6
		exit
	}
}

# ____[ Main Process ]___________________________________________________________________________________________________________

Clear-Host

#welcome message
$welcome = "`nPath of Exile 2 for Steam: CPU Affinity Adjustment to Automatically Add Launch Options"
Write-Log -LogText $welcome -SaveToLog $false
$welcomeSeparator = [String]::Empty
foreach ($char in [char[]]$welcome) { $welcomeSeparator += "_" }
Write-Log -LogText $welcomeSeparator -SaveToLog $false
Write-Log -LogText "`nGathering system info..." -SaveToLog $false

#ask for thread count reservation and calculate CPU affinity mask
$cpuInfo = Get-CPUInfo
[int]$cpuThreads = $cpuInfo[2]
Write-Log ("Your system: " + $cpuInfo[0] + " with " + $cpuInfo[1] + " cores and " + $cpuInfo[2] + " total threads available.")
[System.Management.Automation.Host.ChoiceDescription[]]$choicesThreads = @()
for ($i = 0; $i -lt $cpuThreads - 1; $i++) { $choicesThreads += "`&$i" }
$titleThreads = "`nPlease choose the number of CPU threads you want to withhold from Poe2."
$promptThreads = "It is recommended to withhold at least one of your CPU's cores (~2 threads). "
$promptThreads += "Typically there are 2 threads for every hyperthreading/SMT/performance core."
$myThreadChoice = $host.UI.PromptForChoice($titleThreads, $promptThreads, $choicesThreads, 2)
Write-Log -LogText "`n" -SaveToLog $false
Write-Log "$myThreadChoice CPU thread(s) reserved."
$myAffinityMask = Get-CPUAffinityMask -ThreadCount $cpuThreads -ReserveThreads $myThreadChoice
Write-Log "My calculated CPU affinity hexadecimal mask: $myAffinityMask"

#find Steam, and if necessary offer choice when a drive search found multiple steam.exe files
[string[]]$steamPaths = Get-SteamPath
[string]$mySteamPath = $steamPaths[0]
if ($steamPaths.Count -gt 1)
{
	[System.Management.Automation.Host.ChoiceDescription[]]$choicesSteam = @()
	$choiceTextSteam = [String]::Empty
	$i = 0
	foreach ($path in $steamPaths)
	{
		$choicesSteam += "`&$i"
		$choiceTextSteam += "$i -- $path`n"
		$i++
	}
	$titleSteam = "`nThe following possible Steam paths were found on your system:" + $choiceTextSteam
	$promptSteam = "Please choose the location of your Steam install..."
	$mySteamChoice = $host.UI.PromptForChoice($titleSteam, $promptSteam, $choicesSteam, 0)
	$mySteamPath = $steamPaths[$mySteamChoice]
	Write-Log -LogText "`n" -SaveToLog $false
}
Write-Log "Using Steam client found at $mySteamPath"

#find path of localconfig.vdf
[string[]]$steamUserIDs = Get-ChildItem -Path ($mySteamPath + "\userdata\")
[string]$mySteamUserID = $steamUserIDs[0]
if ($steamUserIDs.Count -gt 1)
{
	[System.Management.Automation.Host.ChoiceDescription[]]$choicesSteamUserID = @()
	$choiceTextSteamUserID = [String]::Empty
	$i = 0
	foreach ($userID in $steamUserIDs)
	{
		$choicesSteamUserID += "`&$i"
		$choiceTextSteamUserID += "$i -- $userID`n"
		$i++
	}
	$titleSteamUserID = "`nThe following possible Steam user ID folders were found on your system:" + $choiceTextSteamUserID
	$promptSteamUserID = "Please choose your desired local Steam user ID folder. Most users only have one user ID folder, "
	$promptSteamUserID += "but it's possible to make multiple user ID folders if you have multiple Steam accounts. "
	$promptSteamUserID += "This user ID folder is different from your Steam account user ID, "
	$promptSteamUserID += "and was automatically generated by Steam upon Steam client install and login."
	$mySteamUserIDChoice = $host.UI.PromptForChoice($titleSteamUserID, $promptSteamUserID, $choicesSteamUserID, 0)
	$mySteamUserID = $steamUserIDs[$mySteamUserIDChoice]
	Write-Log -LogText "`n" -SaveToLog $false
}
$vdfConfigPath = $mySteamPath + "\userdata\" + $mySteamUserID + "\config"
$vdfConfigFile = "$vdfConfigPath\localconfig.vdf"
Test-SteamFile $vdfConfigFile "Steam config file"

#read and parse config file
$vdfConfigSize = (Get-Item $vdfConfigFile).Length
$vdfConfigSizeKB = ([Math]::Round(($vdfConfigSize / 1KB))).ToString() + "KB"
Write-Log "Reading Steam $vdfConfigSizeKB VDF config file..."
$vdfConfigContent = Get-Content $vdfConfigFile
$vdfConfigObject = ConvertFrom-VDF -Source $vdfConfigContent

#get library path of PoE2 install
$vdfLibraryFile = $mySteamPath + "\steamapps\libraryfolders.vdf"
Test-SteamFile $vdfLibraryFile "Steam library file"
$vdfLibrarySize = (Get-Item $vdfLibraryFile).Length
$vdfLibrarySizeKB = ([Math]::Round(($vdfLibrarySize / 1KB))).ToString() + "KB"
Write-Log "Reading Steam $vdfLibrarySizeKB VDF library file..."
$vdfLibraryContent = Get-Content $vdfLibraryFile
$vdfLibraryObject = ConvertFrom-VDF -Source $vdfLibraryContent
[string[]]$libIDs = @()
[string[]]$libPaths = @()
$vdfLibraryObject.'"libraryfolders"'.PSObject.Properties | ForEach-Object { $libIDs += $_.Name }
foreach ($i in $libIDs)
{
	$thisPath = Format-MemberString ($vdfLibraryObject.'"libraryfolders"'.$i.'"path"')
	$thisPath = $thisPath.Replace("\\", "\")
	if (Test-Path "$thisPath\steamapps\common\Path of Exile 2\PathOfExileSteam.exe")
	{
		$libPaths += $thisPath
	}
}
[string]$myPoE2Path = $libPaths[0] + "\steamapps\common\Path of Exile 2"
if ($libPaths.Count -gt 1)
{
	[System.Management.Automation.Host.ChoiceDescription[]]$choicesPoE2 = @()
	$choiceTextPoE2 = [String]::Empty
	$i = 0
	foreach ($path in $libPaths)
	{
		$choicesPoE2 += "`&$i"
		$choiceTextPoE2 += "$i -- $path`n"
		$i++
	}
	$titlePoE2 = "`nThe following Path of Exile 2 install folders were found on your system:" + $choiceTextPoE2
	$promptPoE2 = "Please choose your desired PoE2 folder:"
	$myPoE2Choice = $host.UI.PromptForChoice($titlePoE2, $promptPoE2, $choicesPoE2, 0)
	$myPoE2Path = $libPaths[$myPoE2Choice] + "\steamapps\common\Path of Exile 2"
	Write-Log -LogText "`n" -SaveToLog $false
}
Write-Log "Path of Exile 2 install folder: $myPoE2Path"

#ask to choose priority class
[System.Management.Automation.Host.ChoiceDescription[]]$choicesPriority = @()
$choicesPriority += @("&Low", "&Below Normal", "&Normal", "&Above Normal", "&High", "&Real Time")
$titlePriority = "`nSet the process priority for Path of Exile 2."
$promptPriority = "Please choose your desired priority class for PoE2. "
$promptPriority += "Recommended is Normal, Above Normal, or High. Default is Normal:"
$myPriorityChoice = $host.UI.PromptForChoice($titlePriority, $promptPriority, $choicesPriority, 2)
Write-Log -LogText "`n" -SaveToLog $false
[string]$priorityClass = [String]::Empty
switch ($myPriorityChoice)
{
	0 { $priorityClass = "/low "; Write-Log "PoE2 priority set to Low." }
	1 { $priorityClass = "/belownormal "; Write-Log "PoE2 priority set to Below Normal." }
	2 { $priorityClass = "/normal "; Write-Log "PoE2 priority set to Normal." }
	3 { $priorityClass = "/abovenormal "; Write-Log "PoE2 priority set to Above Normal." }
	4 { $priorityClass = "/high "; Write-Log "PoE2 priority set to High." }
	5 { $priorityClass = "/realtime "; Write-Log "PoE2 priority set to Real Time." }
}

#generate batch file to launch PoE2
$batchCommand = '%ComSpec% /C start "" ' + $priorityClass + '/affinity '
$batchCommand += $myAffinityMask + ' "' + $myPoE2Path + '\PathOfExileSteam.exe"'
[System.IO.File]::WriteAllLines("$myPoE2Path\$PoE2Batch", $batchCommand)
if (Test-Path -Path "$myPoE2Path\$PoE2Batch") { Write-Log "Created batch file to launch PoE2 at $myPoE2Path\$PoE2Batch" }
else
{
	$err = "Unable to create batch file to launch PoE2. "
	$err += "Unable to create batch file to launch PoE2. This may be due to a permission error for the folder $myPoE2Path. "
	$err += " Please check permissions for the current user on this folder and try again."
	Write-Log $err
}

#change the launch options for PoE2 within Steam's config file (should result in PoE2Path\PoE2.bat %command%")
[string]$optPoE2 = '"' + '\"' + ($myPoE2Path.Replace("\", "\\")) + '\\' + $PoE2Batch + '\"' + ' %command%"'
[string]$appIDPoE2 = '"' + $PoE2AppID + '"'
if ($vdfConfigObject.'"UserLocalConfigStore"'.'"Software"'.'"Valve"'.'"Steam"'.'"Apps"'.$appIDPoE2.'"LaunchOptions"'.Length -gt 0)
{
	#LaunchOptions exists, so add value to call the batch file
	$vdfConfigObject.'"UserLocalConfigStore"'.'"Software"'.'"Valve"'.'"Steam"'.'"Apps"'.$appIDPoE2.'"LaunchOptions"' = $optPoE2
}
else
{
	#LaunchOptions does not exist, so add it and its value to call the batch file
	$vdfConfigObject.'"UserLocalConfigStore"'.'"Software"'.'"Valve"'.'"Steam"'.'"Apps"'.$appIDPoE2 | Add-Member -MemberType NoteProperty -Name '"LaunchOptions"' -Value $optPoE2
}

#backup config file
$vdfConfigBackup = "$vdfConfigPath\localconfig." + (New-RandomChars) + ".vdf"
Copy-Item -Path $vdfConfigFile -Destination $vdfConfigBackup
if (Test-Path -Path $vdfConfigBackup) { Write-Log "Created backup file $vdfConfigBackup" }
else { Write-Log "Unable to backup $vdfConfigFile to $vdfConfigBackup. Check file permissions." }

#save config file changes
#	use only WriteAllLines (not Out-File) to ensure UTF-8 encoding as Steam will reject UTF-16 files
Write-Log "Writing updated Steam VDF config file..."
[System.IO.File]::WriteAllLines($vdfConfigFile, (ConvertTo-VDF -Source $vdfConfigObject))
Write-Log "Complete!"

#thank you and exit message
$thanks = "`nPlease test by launching Path of Exile 2 from Steam or Steam shortcuts and checking CPU affinity.`n"
$thanks += "`nTo confirm affinity:"
$thanks += "`n`t 1.) Open Task Manager"
$thanks += "`n`t 2.) Click on the `"Details`" tab, "
$thanks += "`n`t 3.) Right click on the PathOfExileSteam.exe process"
$thanks += "`n`t 4.) Choose `"Set affinity`""
$thanks += "`n`t     The appropriate number of threads you selected should be withheld from PoE2. "
$thanks += "`n`t     The `"Base priority`" column should reflect the priority you selected. "
$thanks += "`n`nTo undo these changes:"
$thanks += "`n`t 1.) Open Steam"
$thanks += "`n`t 2.) Right click on Path of Exile 2 in your Library"
$thanks += "`n`t 3.) Click on `"Properties`""
$thanks += "`n`t 4.) Under the `"General`" tab, erase all text in the `"Launch Options`" box"
$thanks += "`n`t 5.) Optional: delete the batch file $myPoE2Path\$PoE2Batch"
$thanks += "`n`nThank you and enjoy!"
Write-Log -LogText $thanks -SaveToLog $false
Write-Log -LogText "`nPress any key to exit..." -SaveToLog $false
$null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown');
