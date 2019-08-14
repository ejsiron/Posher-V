<#
.SYNOPSIS
	Find virtual machine files that are no longer registered to a Hyper-V host or a virtual machine.

.DESCRIPTION
	Some operations may leave the XML definition file for a virtual machine orphaned, along with other files associated with a virtual machine.
	This script detects and returns those orphaned files.

	Use caution when interpreting results from a shared location. Files owned by a Hyper-V host that was not specified will be returned as a false positive.
	Use the Host parameter to specify other hosts to include in the same scan.

.PARAMETER Path
	A array string that contains one or more source paths to search. Subfolders will automatically be searched.
	If not specified, the behavior is the same as if the IncludeDefaultPath and IncludeExistingVMPaths parameters were specified.

.PARAMETER ComputerName
	A string array that contains the name(s) of host(s) to scan. It can also contain cluster name(s).
	If not specified, the local host will be used.

.PARAMETER IncludeDefaultPath
	If the Path parameter is specified, use this parameter to indicate that the Hyper-V host's default path should also be scanned.

.PARAMETER IncludeExistingVMPaths
	If the Path parameter is specified, use this parameter to indicate that the paths of existing VMs should also be scanned.

.PARAMETER ExcludeDefaultPath
	If the Path parameter is not specified, use this parameter to prevent the host's default VM path from being scanned.

.PARAMETER ExcludeExistingVMPaths
	If the Path parameter is not specified, use this parameter to prevent the paths of existing VMs from being scanned.

.PARAMETER IgnoreClusterMembership
	Ordinarily, the script will determine if a computer is part of a cluster and scan the VMs of all nodes as a fail-safe.
	If this switch is set, only the specified system(s) will be scanned. Any paths involving \ClusterStorage will be skipped.

.PARAMETER Credential
	The credential to use to connect to and scan remote hosts.
	Has no effect on SMB 3 storage locations. These will always be scanned as the locally logged-on account.

.OUTPUTS
	An array of deserialized FileInfo objects or $null if no items are found. GetType() shows the generic Object type.

.NOTES
	Author: Eric Siron
	Version 2.0

.LINK
	https://www.altaro.com/hyper-v/free-script-find-orphaned-hyper-v-vm-files

.EXAMPLE
	C:\PS> .\Get-VMOrphanedFiles

	Description
	-----------
	Retrieves orphaned VM files in this host's default VM path and those of current VMs.

.EXAMPLE
	C:\PS> .\Get-VMOrphanedFiles -Path D:\

	Description
	-----------
	Retrieves orphaned VMs on this host contained anywhere on the D: drive.

.EXAMPLE
	C:\PS> .\Get-VMOrphanedFiles -ExcludeExistingVMPaths

	Description
	-----------
	Retrieves orphaned VM files in this host's default VM path, ignoring any paths of VMs that are outside the default.

C:\PS> .\Get-VMOrphanedFiles -ExcludeDefaultPath

	Description
	-----------
	Retrieves orphaned VM files in the paths of existing VMs except those contained in the host's default path.

C:\PS> .\Get-VMOrphanedFiles -ComputerName svhv1, svhv2 -Path \\smb3share\vms

	Description
	-----------
	Checks for VM files on the \\smb3share\vms that are not connected to any VMs registered to svhv1 or svhv2.

C:\PS> .\Get-VMOrphanedFiles -ComputerName svhv1, svhv2 -Path C:\

	Description
	-----------
	Checks for VM files on the local C: drives of svhv1 and svhv2.

C:\PS> Get-VMHost server1, server2, server3 | .\Get-VMOrphanedFiles

	Description
	-----------
	Retrieves orphaned VM files in the default and current VM paths for hosts named server1, server2, and server3.

C:\PS> .\Get-VMOrphanedFiles -ComputerName svhv1 -Path C:\ -IgnoreClusterMembership

	Description
	-----------
	Retrieves orphaned VM files on the C: drive of SVHV1, skipping the \ClusterStorage folder and not scanning any other hosts in the cluster.

C:\PS> .\Get-VMOrphanedFiles -ComputerName svhv1, svhv2 -Path -Credential (Get-Credential)

	Description
	-----------
	Checks for orphaned VM files on svhv1's and svhv2's default paths using the credentials that you specify. Files on SMB 3 storage will be scanned using the credentials of the local session.

#>

#requires -Version 3

[CmdletBinding(DefaultParameterSetName='UnspecifiedPath')]
param(
	[Alias('Host', 'HostName', 'VMHosts', 'Hosts', 'VMHost')]
	[Parameter(ValueFromPipeline=$true, ValueFromPipelineByPropertyName=$true)]
	[Object[]]$ComputerName=@($env:COMPUTERNAME),

	[Alias("VirtualMachinePath")]
	[Parameter(ValueFromPipeline=$true, ValueFromPipelinebyPropertyName=$true,ParameterSetName='SpecifiedPath')]
	[String[]]$Path=@(),

	[Parameter(ValueFromPipelineByPropertyName=$true,ParameterSetName='SpecifiedPath')]
	[Switch]$IncludeDefaultPath,

	[Parameter(ValueFromPipelineByPropertyName=$true,ParameterSetName='SpecifiedPath')]
	[Switch]$IncludeExistingVMPaths,

	[Parameter(ValueFromPipelineByPropertyName=$true,ParameterSetName='UnspecifiedPath')]
	[Switch]$ExcludeDefaultPath,

	[Parameter(ValueFromPipelineByPropertyName=$true,ParameterSetName='UnspecifiedPath')]
	[Switch]$ExcludeExistingVMPaths,

	[Parameter(ValueFromPipelineByPropertyName=$true)]
	[Switch]$IgnoreClusterMembership,

	[Parameter(ValueFromPipeline=$true, ValueFromPipelineByPropertyName=$true)]
	[System.Management.Automation.PSCredential]$Credential
)

BEGIN
{
	$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
	######################### Script block definitions ###############################
	$VMFilePathsScriptBlock = {
		param(
			[Parameter(Position=0)][Boolean]$ReturnDefaultPaths,
			[Parameter(Position=1)][Boolean]$ReturnVMPaths,
			[Parameter(Position=2)][System.Management.Automation.ActionPreference]$RemoteVerbosePreference = [System.Management.Automation.ActionPreference]::SilentlyContinue
        )

		$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
		function Parse-LocalOrSharedVMFilePath
		{
			param(
				[Parameter()][String]$VMHost = '',
				[Parameter()][String]$ItemType,		# 'path' for a file-system path, 'shared' for a UNC, 'metafile' for a non-disk VM file, 'disk' for a VM disk file
				[Parameter()][String]$PathOrFile,	# this is the item that will be operated on
				[Parameter()][String]$VMNameToRemove = '',	# if provided, it will be removed from the end of an item (usually to find the parent)
				[Parameter()][String]$VMId = $null
			)

			if($ItemType -eq 'converttopath')
			{
				$PathOrFile = $PathOrFile -replace '(\\)[^\\]*\\?$'	# remove file name
				$ItemType = 'path'
			}
			if($ItemType -ne 'path')
			{
				$PathOrFile = $PathOrFile -replace '\\$'	# no trailing slashes on files
			}
			if($PathOrFile -match '^\\\\[^?|.]')	# item is on a share
			{
				$HostPrefix = ''	# Hyper-V doesn't support SMB3 loopback, so no VMHost owns the supplied file or path
			}
			else
			{
				$PathOrFile = $PathOrFile -replace '^\\\\\?', '\\.'	# raw volume identifiers might come in with a ? but must go out with a .
				$HostPrefix = $VMHost
			}
			if(-not [String]::IsNullOrEmpty($VMNameToRemove))
			{
				$PathOrFile = $PathOrFile -replace "$VMNameToRemove\\?$"	# lop off any remote path
			}
			[String]::Join(';', ($HostPrefix, $ItemType, $PathOrFile))
		}

		function Get-DifferencingChain
		{
			param(
				[Parameter()][String]$VHDPath
			)
			if($VHDPath -notmatch '^\\\\[^?|.]')	# the calling host will have to deal with differencing disks on shares
			{
				$VHDPath = $VHDPath -replace '^\\\\\?', '\\.'	# Get-VHD can only operate on raw volume identifiers with a . and these files haven't yet gone through the sanitizer
				Write-Verbose -Message ('Checking for parent disks of ' + $VHDPath)
				$VHD = Get-VHD -Path $VHDPath -ErrorAction SilentlyContinue
				if($VHD.ParentPath)
				{
					Write-Verbose -Message ('Parent {0} found, traversing chain...' -f $VHD.ParentPath)
					$VHD.ParentPath
					Get-DifferencingChain -VHDPath $VHD.ParentPath
				}
			}
		}

		$VerbosePreference = $RemoteVerbosePreference
		#$FileList = @() # this is what is returned to the calling system
		#$MetaFileList = @()
        #$DiskFileList = @()
        $FileList = New-Object System.Collections.ArrayList     # this is returned to the calling system
        $MetaFileList = New-Object System.Collections.ArrayList
        $DiskFileList = New-Object System.Collections.ArrayList

		if(-not (Get-Module -Name Hyper-V -ListAvailable))
		{
            Write-Error -Message ('{0} does not have the Hyper-V PowerShell module installed' -f (Get-CimInstance -ClassName Win32_ComputerSystem).Name) 
		}

		Write-Verbose -Message 'Retrieving Hyper-V host information...'
		$VMHostData = Get-VMHost
		$VMHostName = $VMHostData.Name
		if($VMHostData.FullyQualifiedDomainName.Contains('.'))
		{
            $VMHostName = '{0}.{1}' -f $VMHostName, $VMHostData.FullyQualifiedDomainName
		}

		$VMHostName = $VMHostName.ToLower()
		Write-Verbose -Message ('Host name: {0}' -f $VMHostName)

        $HostHVRegistrationPath = (Resolve-Path '{0}\Microsoft\Windows\Hyper-V' -f $env:ProgramData).Path
		Write-Verbose -Message ('Virtual machine registration path: {0}' -f $HostHVRegistrationPath)
		
		Write-Verbose -Message ('Default virtual machine path: {0}' -f $VMHostData.VirtualMachinePath)
		if($VMHostData.VirtualMachinePath -match '^\\\\[^?|.]')
		{
			$ThisHostVMPathShared = $true
			$ThisHostVMPathType = 'shared'
			Write-Verbose -Message 'The default virtual machine path is on an SMB 3 share'
		}
		else
		{
			$ThisHostVMPathShared = $false
			$ThisHostVMPathType = 'path'
			Write-Verbose -Message 'The default virtual machine path is on locally-addressed storage'
		}

		Write-Verbose -Message ('Default virtual hard disk path: ' + $VMHostData.VirtualHardDiskPath)
		if($VMHostData.VirtualHardDiskPath -match '^\\\\[^?|.]')
		{
			$ThisHostVMHDShared = $true
			$ThisHostVMHDType = 'shared'
			Write-Verbose -Message 'The default virtual hard disk path is on an SMB share'
		}
		else
		{
			$ThisHostVMHDShared = $false
			$ThisHostVMHDType = 'path'
			Write-Verbose -Message 'The default virtual hard disk path is on locally-addressed storage'
		}
		if($ReturnDefaultPaths)
		{
			$FileList += Parse-LocalOrSharedVMFilePath -VMHost $VMHostName -ItemType $ThisHostVMPathType -PathOrFile $VMHostData.VirtualMachinePath
			Write-Verbose -Message ($VMHostData.VirtualMachinePath + ' added to scan paths')
			$FileList += Parse-LocalOrSharedVMFilePath -VMHost $VMHostName -ItemType $ThisHostVMHDType -PathOrFile $VMHostData.VirtualHardDiskPath
			Write-Verbose -Message ($VMHostData.VirtualHardDiskPath + ' added to scan paths')
			$FileList += Parse-LocalOrSharedVMFilePath -VMHost $VMHostName -ItemType 'path' -PathOrFile $HostHVRegistrationPath
			Write-Verbose -Message ($HostHVRegistrationPath + ' added to scan paths')
		}
		if(Test-Path -Path ($env:SystemDrive + '\ClusterStorage'))
		{
			Write-Verbose -Message 'Enumerating cluster shared volumes'
			foreach ($CSVPath in Get-ChildItem -Path ($env:SystemDrive + '\ClusterStorage'))
			{
				$FileList += Parse-LocalOrSharedVMFilePath -VMHost $VMHostName -ItemType 'path' -PathOrFile $CSVPath.FullName
				Write-Verbose -Message ($CSVPath.FullName + ' added to scan paths')
			}
		}
		foreach ($VM in Hyper-V\Get-VM)
		{
			$ThisVMId = $VM.VMId
			$ThisVMPrimaryPath = $VM.Path
			if($ThisVMPrimaryPath -match '^\\\\[^?|.]')
			{
				$ThisVMPrimaryPathShared = $true
				$ThisVMPrimaryPathType = 'shared'
				Write-Verbose -Message ('Primary path for "{0}" is on SMB share: "{1}"' -f $VM.Name, $ThisVMPrimaryPath)
			}
			else
			{
				$ThisVMPrimaryPathShared = $false
				$ThisVMPrimaryPathType = 'path'
				Write-Verbose -Message ('Primary path for "{0}" is in locally-addressed space: "{1}"' -f $VM.Name, $ThisVMPrimaryPath)
			}
			$ThisVMConfigurationPath = $VM.ConfigurationLocation
			if($ThisVMConfigurationPath -match '^\\\\[^?|.]')
			{
				$ThisVMConfigurationPathShared = $true
				$ThisVMConfigurationPathType = 'shared'
				Write-Verbose -Message ('Configuration files for "{0}" are on SMB share: "{1}"' -f $VM.Name, $ThisVMConfigurationPath)
			}
			else
			{
				$ThisVMConfigurationPathShared = $false
				$ThisVMConfigurationPathType = 'path'
				Write-Verbose -Message ('Configuration files for "{0}" are in locally-addressed space: "{1}"' -f $VM.Name, $ThisVMConfigurationPath)
			}
			$ThisVMSnapshotPath = $VM.SnapshotFileLocation
			if($ThisVMSnapshotPath -match '^\\\\[^?|.]')
			{
				$ThisVMSnapshotPathShared = $true
				$ThisVMSnapshotPathType = 'shared'
				Write-Verbose -Message ('Checkpoint files for "{0}" are on SMB share: "{1}"' -f $VM.Name, $ThisVMSnapshotPath)
			}
			else
			{
				$ThisVMSnapshotPathShared = $false
				$ThisVMSnapshotPathType = 'path'
				Write-Verbose -Message ('Checkpoint files for "{0}" are in locally-addressed space: "{1}"' -f $VM.Name, $ThisVMSnapshotPath)
			}
			$ThisVMSLPPath = $VM.SmartPagingFilePath
			if($ThisVMSLPPath -match '^\\\\[^?|.]')
			{
				$ThisVMSLPPathShared = $true
				$ThisVMSLPPathType = 'shared'
				Write-Verbose -Message ('Smart paging files for "{0}" are on SMB share: "{1}"' -f $VM.Name, $ThisVMSLPPath)
			}
			else
			{
				$ThisVMSLPPathShared = $false
				$ThisVMSLPPathType = 'path'
				Write-Verbose -Message ('Smart paging files for "{0}" are in locally-addressed space: "{1}"' -f $VM.Name, $ThisVMSLPPath)
			}
			# Get configuration files
			Write-Verbose -Message ('Adding configuration files for "{0}" to scan list' -f $VM.Name)
			$MetaFileList += (Get-ChildItem -File -Path $HostHVRegistrationPath -Recurse -Filter "$ThisVMId.xml").FullName
			if($ThisVMConfigurationPathShared)3333
			{
				$ThisItem = Parse-LocalOrSharedVMFilePath -ItemType 'shared' -PathOrFile $ThisVMConfigurationPath
				$FileList += [String]::Join(',', ($ThisItem, $ThisVMId, $VM.Name, 'configuration'))
			}
			else
			{
				$MetaFileList += (Get-ChildItem -File -Path $ThisVMConfigurationPath -Recurse -Filter "$ThisVMId.xml").FullName
				$MetaFileList += (Get-ChildItem -File -Path $ThisVMConfigurationPath -Recurse -Filter "$ThisVMId.bin").FullName
				$MetaFileList += (Get-ChildItem -File -Path $ThisVMConfigurationPath -Recurse -Filter "$ThisVMId.vsv").FullName
			}
			# Get snapshot files
			Write-Verbose -Message ('Adding checkpoint files for "' + $VM.Name + '" to scan list')
			if($ThisVMSnapshotPathShared)
			{
				$ThisItem = Parse-LocalOrSharedVMFilePath -ItemType 'shared' -PathOrFile $ThisVMSnapshotPath
				$FileList += [String]::Join(",", ($ThisItem, $ThisVMId, $VM.Name, 'snapshotpath'))
			}
			else
			{
				$SnapshotRoot = (Get-ChildItem -Directory -Path $ThisVMSnapshotPath -Filter 'Snapshots').FullName
			}
			Get-VMSnapshot -VM $VM | ForEach-Object -Process {
				Write-Verbose -Message ('Adding checkpoint files for "' + $VM.Name + '" with ID: "' + $_.Id + '" to scan list')
				$MetaFileList += (Get-ChildItem -File -Path $HostHVRegistrationPath -Recurse -Filter "$($_.Id).xml").FullName
				if($ThisVMSnapshotPathShared)
				{
					$SharedFileList += [String]::Join(",", ($ThisVMSnapshotPath, $_.Id, 'snapshot'))
				}
				else
				{
                    $SnapshotID = $_.Id
                    foreach($MetafileExtension in @('xml', 'vsv', 'bin', 'vmcx', 'vmgs', 'vmrs'))
                    {
                        $Filter = '{0}.{1}' -f $SnapshotID, $MetafileExtension
                        
                    }
					$MetaFileList += (Get-ChildItem -File -Path $SnapshotRoot -Recurse -Filter "$($_.Id).xml").FullName
					$MetaFileList += (Get-ChildItem -File -Path $SnapshotRoot -Recurse -Filter "$($_.Id).vsv").FullName
					$MetaFileList += (Get-ChildItem -File -Path $SnapshotRoot -Recurse -Filter "$($_.Id).bin").FullName
				}
				Get-VMHardDiskDrive -VMSnapshot $_ | foreach {
					$DiskFileList += $_.Path
					if($ReturnVMPaths)
					{
						$FileList += Parse-LocalOrSharedVMFilePath -VMHost $VMHostName -ItemType 'converttopath' -PathOrFile ($_.Path)
					}
				}
				if($VM.Generation -lt 2)
				{
					Get-VMFloppyDiskDrive -VMSnapshot $_ | foreach {
						if($_.Path)
						{
							$DiskFileList += $_.Path
							if($ReturnVMPaths)
							{
								$FileList += Parse-LocalOrSharedVMFilePath -VMHost $VMHostName -ItemType 'converttopath' -PathOrFile ($_.Path)
							}
						}
					}
				}
			}
			# Get Smart Paging files
			Write-Verbose -Message ('Adding smart paging files for "' + $VM.Name + '" to scan list')
			if($VM.SmartPagingFileInUse)
			{
				if($ThisVMSLPPathShared)
				{
					$ThisItem = Parse-LocalOrSharedVMFilePath -ItemType 'shared' -PathOrFile $ThisVMSLPPath
					$FileList += [String]::Join(',', ($ThisItem, $ThisVMId, $VM.Name, 'slp'))
				}
				else
				{
					$MetaFileList += (Get-ChildItem -File -Path $ThisVMSLPPath -Recurse -Filter "$($_.Id).*.slp").FullName
				}
			}

			# Get virtual hard/floppy disks
			Write-Verbose -Message ('Adding virtual disk files for "' + $VM.Name + '" to scan list')
			Get-VMHardDiskDrive -VM $VM | foreach {
				$ThisVMDiskList = @()
				$ThisVMDiskList += $_.Path
				$ThisVMDiskList += Get-DifferencingChain $_.Path
				if($ReturnVMPaths)
				{
					foreach($VMDisk in $ThisVMDiskList)
					{
						$FileList += Parse-LocalOrSharedVMFilePath -VMHost $VMHostName -ItemType 'converttopath' -PathOrFile ($VMDisk)
					}
				}
				$DiskFileList += $ThisVMDiskList
			}

			if($VM.Generation -lt 2)
			{
				$DiskFileList += (Get-VMFloppyDiskDrive -VM $VM).Path
			}
		}
		$MetaFileList | ForEach-Object -Process {
			if(-not [String]::IsNullOrEmpty($_))
			{
				$FileList += Parse-LocalOrSharedVMFilePath -VMHost $VMHostName -ItemType 'metafile' -PathOrFile $_
			}
		}
		$DiskFileList | ForEach-Object -Process {
			if(-not [String]::IsNullOrEmpty($_))
			{
				$FileList += Parse-LocalOrSharedVMFilePath -VMHost $VMHostName -ItemType 'disk' -PathOrFile $_
			}
			if($ReturnVMPaths)
			{
				$FileList += Parse-LocalOrSharedVMFilePath -VMHost $VMHostName -ItemType 'path' -PathOrFile $ThisVMPrimaryPath -VMNameToRemove $_.Name
				$FileList += Parse-LocalOrSharedVMFilePath -VMHost $VMHostName -ItemType 'path' -PathOrFile $ThisVMConfigurationPath -VMNameToRemove $_.Name
				$FileList += Parse-LocalOrSharedVMFilePath -VMHost $VMHostName -ItemType 'path' -PathOrFile $ThisVMSnapshotPath -VMNameToRemove $_.Name
				$FileList += Parse-LocalOrSharedVMFilePath -VMHost $VMHostName -ItemType 'path' -PathOrFile $ThisVMSLPPath -VMNameToRemove $_.Name
			}
		}
		$FileList | Select-Object -Unique
	}

	$SearchScriptBlock = {
		param
		(
			[Parameter(Position = 0)][String[]]$SearchPaths,
			[Parameter(Position = 1)][String[]]$FileExclusions,
			[Parameter(Position = 2)][String[]]$DiskExclusions,
			[Parameter(Position = 3)][Boolean]$SkipCSVs
		)
		$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
		function Escape-Path
		{
			param(
				[Parameter()][String]$Path
			)
				$Path -replace '\\', '\\'	# This is not a typo. This turns single backslashes into double backslashes. I promise.
		}
		$LocalClusterStorage = Escape-Path -Path (Join-Path -Path $env:SystemDrive -ChildPath 'ClusterStorage')
		$DirectoryExclusions = @(
			(Escape-Path -Path (Join-Path -Path $env:SystemRoot -ChildPath 'vss')),								# VSS writers are also registered as <guid>.xml
			(Escape-Path -Path (Join-Path -Path $env:SystemRoot -ChildPath 'WinSxs')),							# many things in WinSxs will trigger a response, also it takes forever to scan
			(Escape-Path -Path (Join-Path -Path $env:ProgramData -ChildPath 'Microsoft\Windows\Hyper-V\Resource Types'))	# HV resource types are also registered as <guid>.xml
		)
		if ($SkipCSVs)
		{
			$DirectoryExclusions += $LocalClusterStorage
		}
		foreach ($SearchPath in $SearchPaths)
		{
			try
			{	# We enclose this segment in a try block because of Get-ChildItem. Test-Path does not work on raw volume identifiers, but GCI does. If the path does not exist or we do not have access, the catch block will deal with it. Take note that the script has set ErrorActionPreference to Stop.
				$CompareGUID = New-Object System.Guid
				Get-ChildItem -File -Path $SearchPath -Recurse |
				where {
					# first, parse the extension for virtual hard/floppy disk files as that is the fastest of possible operations
					if ($_.Extension -match "v(h|f)d")
					{
						if ($SkipCSVs -and $_.DirectoryName -match $LocalClusterStorage)
						{
							$false
						}
						elseif ($DiskExclusions -notcontains $_.FullName.ToLower())
						{
							$true
						}
					}
					elseif ($_.Extension -match "xml|bin|vsv")
					{
						$InExcludedDirectory = $false
						$DirectoryName = $_.DirectoryName
						$DirectoryExclusions |
						foreach {
							if ($DirectoryName -match $_)
							{
								$InExcludedDirectory = $true
							}
						}
						if (-not $InExcludedDirectory)
						{
							#VM files of this type will all be formatted as a GUID
							if ([System.Guid]::TryParse($_.BaseName, [ref]$CompareGUID))
							{
								if ($FileExclusions -notcontains $_.FullName.ToLower())
								{
									$true
								}
							}
						}
					}
				}
			}
			catch
			{
				$PathFound = $false
			}
		}
	}

	######################### Function definitions ###############################
	function Parse-LocalOrSharedItem
	{
		<#
			.DESCRIPTION
			Determines if a path is on a local system or is shared. If local, attaches it to the submitted host name for later processing.
			Also cleans up path entries for use with later functions and cmdlets.
		#>
		param(
			[Parameter()][String]$CurrentPath,
			[Parameter()][String]$CurrentHost = ""
		)
		$CurrentPath = $CurrentPath -replace "`"|'"	# remove quotes
		$CurrentPath = $CurrentPath -replace "^\\\\\?", "\\."
		if($CurrentPath -match "^\\\\[^.]" -or [String]::IsNullOrEmpty($CurrentHost))
		{
			$($CurrentPath.ToLower())
		}
		else
		{
			([String]::Join(",", ($CurrentPath, $CurrentHost))).ToLower()
		}
	}

	function Dedupe-CSV
	<#
		Resets all items that target *\clusterstorage\* so that the same location isn't scanned from multiple nodes or false positives returned.
		Also, if the IgnoreClusterMembership flag is set, these items are simply removed so that they won't be scanned at all.
	#>
	{
		param(
			[Parameter()][String[]]$ClusterList,
			[Parameter()][String[]]$ArrayWithCSV	# this script was designed so that computer names will always appear in element[1]
		)
		$ItemsToRemove = @()
		$ReplacementItems = @()
		foreach($ClusterItem in $ClusterList)
		{
			$PrimaryNode = $ClusterItem.Split(";")[0]
			$NodeList = $ClusterItem.Split(";")[1]
			foreach($ItemWithCSV in $ArrayWithCSV)
			{
				if($ItemWithCSV -match ":\\clusterstorage")
				{
					$PathOrItem = $ItemWithCSV.Split(",")[0]
					$OriginalNode = $ItemWithCSV.Split(",")[1]
					if($PrimaryNode -ne $OriginalNode)
					{
						$ItemsToRemove += $ItemWithCSV
						if(-not $IgnoreClusterMembership)
						{
							$ReplacementItems += [String]::Join(",", ($PathOrItem, $PrimaryNode))
						}
					}
				}
			}
		}
		if($ItemsToRemove.Count -gt 0 -and $ReplacementItems.Count -gt 0)
		{
			$ArrayWithCSV = $ArrayWithCSV | where { $ItemsToRemove -notcontains $_ }
			$ArrayWithCSV + $ReplacementItems
		}
		else
		{
			$ArrayWithCSV
		}
	}

	function Remove-SubPaths
	{
		<#
			.DESCRIPTION
			Given an array of paths, finds items that are subpaths of another and removes them
		#>
		param(
			[Parameter()]$PathArray
		)
		$PathsToRemove = @()
		foreach($PathOuter in $PathArray)
		{
			if($IgnoreClusterMembership -and $PathOuter -match "(:|\\\\[.|?]\\Volume\{.*\})\\ClusterStorage")	# function re-usability warning on $IgnoreClusterMembership
			{
				$PathsToRemove += $PathOuter
			}
			else
			{
				foreach($PathInner in $PathArray)
				{
					if($PathOuter -ne $PathInner)
					{
						$Path1 = $PathOuter.Split(",")
						$Path2 = $PathInner.Split(",")
						$CanProcess = $true
						if($Path1[1].Length -gt 0 -and $Path2[1].Length -gt 0)
						{
							if($Path1[1] -ne $Path2[1])
							{
								$CanProcess = $false
							}
						}
						if($CanProcess)
						{
							if($Path1[0].Contains($Path2[0]))
							{
								$PathsToRemove += $PathOuter
							}
						}
					}
				}
			}
		}
		$PathArray | where { $PathsToRemove -notcontains $_ } | select -Unique
	}

	function Get-RemoteData
	{
		<#
			.DESCRIPTION
			A generic function that runs the indicated scriptblock in parallel against the indicated group of hosts and returns the results as an array.
		#>
		param(
			[Parameter()][String[]]$VMHosts,
			[Parameter()][ScriptBlock]$ScriptBlock,
			[Parameter()][String]$InvokeErrorTemplate,
			[Parameter()][String]$ResultsErrorTemplate,
			[Parameter()][Object[]]$ArgumentList = $null,
			[Parameter()][System.Management.Automation.PSCredential]$Credential = $null,
			[Parameter()][String]$VerboseAction=''
		)
		$SessionList = @()
		$JobList = @()
		$ResultsArray = @()
		$ArgumentList += $VerbosePreference

		foreach($VMHost in $VMHosts)
		{
			try
			{
				$SessionParameters = @{'ComputerName'=$VMHost;'ErrorAction'='Stop' }
				if($Credential)
				{
					$SessionParameters.Add('Credential', $Credential)
				}
				Write-Verbose -Message ('Establishing a PowerShell session on ' + $VMHost)
				$Session = New-PSSession @SessionParameters
				$JobList += Invoke-Command -Session $Session -ScriptBlock $ScriptBlock -ErrorAction Stop -AsJob -ArgumentList $ArgumentList
				$SessionList += $Session
			}
			catch [Exception]
			{
				Write-Error -Message ($InvokeErrorTemplate -f $VMHost, $_)
			}
		}
		if($JobList.Count)
		{
			Wait-Job -Job $JobList -ErrorAction Stop | Out-Null
		}
		foreach($Job in $JobList)
		{
			try
			{
				$ResultsArray += Receive-Job -Job $Job -ErrorAction Stop
			}
			catch
			{
				Write-Error -Message ($ResultsErrorTemplate -f $Job.Location, $_)
				$VMHosts = $VMHosts | where { $_ -ne $VMHost }
			}
		}
		$SessionList | Remove-PSSession
		$JobList | Remove-Job
		$ResultsArray
	}

	function Get-VHDDifferencingParent
	{
		param(
			[Parameter(Mandatory=$true, ValueFromPipeline=$true, ValueFromPipelineByPropertyName=$true)][String]$Path
		)

		$AbsolutePath = ""
		$IdentifierSize = 8
		$IdentifierBytes = New-Object Byte[] $IdentifierSize

		try
		{
			try
			{
				$VHDStream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite) -ErrorAction Stop
			}
			catch
			{
				throw ("Unable to open differencing disk {0} to determine its parent: {1}" -f $Path, $_)
			}

			try
			{
				$BytesRead = $VHDStream.Read($IdentifierBytes, 0, $IdentifierSize)
			}
			catch
			{
				throw ("Unable to read the VHD type identifier for {0}: {1}" -f $Path, $_)
			}

					if([System.Text.Encoding]::ASCII.GetString($IdentifierBytes) -eq "vhdxfile")
			{
				$1stRegionOffset = 196608; $1stRegionEntryCount = 0; $2ndRegionOffset = 262144; $2ndRegionEntryCount = 0
				$SignatureSize = 4; $EntryCountSize = 8; $GUIDSize = 16; $EntryOffsetSize = 8; $EntryLengthSize = 4
				$ShortEntrySize = 2; $MetadataOffsetSize = 4; $KeyValueCountSize = 2; $LocatorEntrySize = 12
				$SignatureBytes = New-Object Byte[] $SignatureSize; $EntryCountBytes = New-Object Byte[] $EntryCountSize
				$GUIDBytes = New-Object Byte[] $GUIDSize; $EntryOffset = New-Object Byte[] $EntryOffsetSize
				$ShortEntryBytes = New-Object Byte[] $ShortEntrySize; $MetadataOffsetBytes = New-Object Byte[] $MetadataOffsetSize
				$KeyValueCountBytes = New-Object Byte[] $KeyValueCountSize; $LocatorEntryBytes = New-Object Byte[] $LocatorEntrySize
				$LocatorEntries = @()

				($1stRegionOffset, $2ndRegionOffset) | foreach {
					$VHDStream.Position = $_
					try
					{
						$BytesRead = $VHDStream.Read($SignatureBytes, 0, $SignatureSize)
					}
					catch
					{
						throw ("Unable to read signature from header region of {0}: {1}" -f $Path, $_)
					}
					if([System.Text.Encoding]::ASCII.GetString($SignatureBytes) -eq "regi")
					{
						$VHDStream.Position += 4	# jump over the checksum
						try
						{
							$BytesRead = $VHDStream.Read($EntryCountBytes, 0, $EntryCountSize)
						}
						catch
						{
							throw ("Unable to determine number of header entries in {0}: {1}" -f $Path, $_)
						}
						$RegionEntryCount = [System.BitConverter]::ToInt32($EntryCountBytes, 0)
						if($_ = $1stRegionOffset)
						{
							$1stRegionEntryCount = $RegionEntryCount
						}
						else
						{
							$2ndRegionEntryCount = $RegionEntryCount
						}
					}
				}
				if($1stRegionEntryCount -ge $2ndRegionEntryCount)
				{
					$EntryCount = $1stRegionEntryCount
					$StartingEntryOffset = $1stRegionOffset + 16
				}
				else
				{
					$EntryCount = $2ndRegionEntryCount
					$StartingEntryOffset = $2ndRegionOffset + 16
				}

				1..$EntryCount | foreach {
					$VHDStream.Position = $StartingEntryOffset + (32 * ($_ - 1))	# an entry is 32 bytes long
					try
					{
						$BytesRead = $VHDStream.Read($GUIDBytes, 0, $GUIDSize)
					}
					catch
					{
						throw ("Unable to retrieve the GUID of a header entry in {0}, {1}" -f $Path, $_)
					}
					if([System.BitConverter]::ToString($GUIDBytes) -eq "06-A2-7C-8B-90-47-9A-4B-B8-FE-57-5F-05-0F-88-6E")	# this is the GUID of a metadata region
					{
						try
						{
							$BytesRead = $VHDStream.Read($EntryOffset, 0, $EntryOffsetSize)
						}
						catch
						{
							throw("Unable to determine the location of a metadata region in {0}: {1}" -f $Path, $_)
						}
						$MetadataStart = $VHDStream.Position = [System.BitConverter]::ToInt64($EntryOffset, 0)

						try
						{
							$BytesRead = $VHDStream.Read($IdentifierBytes, 0, $IdentifierSize)
						}
						catch
						{
							throw("Unable to parse the identifier of an expected metadata region in {0}: {1}"-f $Path, $_)
						}
						if([System.Text.Encoding]::ASCII.GetString($IdentifierBytes) -eq "metadata")
						{
							$VHDStream.Position += 2	# jump over reserved field
							try
							{
								$BytesRead = $VHDStream.Read($ShortEntryBytes, 0, $ShortEntrySize)
							}
							catch
							{
								throw("Unable to retrieve the number of header short entries in {0}: {1}" -f $Path, $_)
							}
							$VHDStream.Position += 20	# jump over the rest of the header
							1..([System.BitConverter]::ToUInt16($ShortEntryBytes, 0)) | foreach {
								try
								{
									$BytesRead = $VHDStream.Read($GUIDBytes, 0, $GUIDSize)
								}
								catch
								{
									throw ("Unable to retrieve the GUID of a short entry in {0}: {1}" -f $Path, $_)
								}
								$SavedStreamPosition = $VHDStream.Position
								switch([System.BitConverter]::ToString($GUIDBytes))
								{	## We're only watching for a single item so an "if" could do this, but switch is future-proofing.
									## Should be able to query 37-67-A1-CA-36-FA-43-4D-B3-B6-33-F0-AA-44-E7-6B for a "HasParent" value, but either the documentation is wrong or the implementation is broken as this field holds the same value for all disk types
									"2D-5F-D3-A8-0B-B3-4D-45-AB-F7-D3-D8-48-34-AB-0C" {	# Parent Locator
										try
										{
											$BytesRead = $VHDStream.Read($MetadataOffsetBytes, 0, $MetadataOffsetSize)
										}
										catch
										{
											throw ("Unable to read the location of a metadata entry in {0}: {1}" -f $Path, $_)
										}

										if($BytesRead)
										{
											$ParentLocatorOffset = $MetadataStart + [System.BitConverter]::ToInt32($MetadataOffsetBytes, 0)
											$VHDStream.Position = $ParentLocatorOffset + 18 # jump over the GUID and reserved fields

											try
											{
												$BytesRead = $VHDStream.Read($KeyValueCountBytes, 0, $KeyValueCountSize)
											}
											catch
											{
												throw("Unable to read the number of key/value metadata sets in {0}: {1}" -f $Path, $_)
											}
											if($BytesRead)
											{
												1..[System.BitConverter]::ToUInt16($KeyValueCountBytes, 0) | foreach {
													try
													{
														$BytesRead = $VHDStream.Read($LocatorEntryBytes, 0, $LocatorEntrySize)
													}
													catch
													{
														throw ("Unable to retrieve a key/value metadata set from {0}: {1}" -f $Path, $_)
													}
													if($BytesRead)
													{
														$KeyOffset = [System.BitConverter]::ToUInt32($LocatorEntryBytes, 0)
														$ValueOffset = [System.BitConverter]::ToUInt32($LocatorEntryBytes, 4)
														$KeyLength = [System.BitConverter]::ToUInt16($LocatorEntryBytes, 8)
														$ValueLength = [System.BitConverter]::ToUInt16($LocatorEntryBytes, 10)
														$LocatorEntries += [String]::Join(",", ($KeyOffset, $ValueOffset, $KeyLength, $ValueLength))
													}
												}
												foreach($Locator in $LocatorEntries)
												{
													$KeyValueSet = $Locator.Split(",")
													$KeyPosition = $ParentLocatorOffset + $KeyValueSet[0]
													$ValuePosition = $ParentLocatorOffset + $KeyValueSet[1]
													$KeyBytes = New-Object Byte[] $KeyValueSet[2]
													$ValueBytes = New-Object Byte[] $KeyValueSet[3]
													$VHDStream.Position = $KeyPosition

													try
													{
														# NOTE: we don't actually do anything with the key, technically could move the pointer past it to the value
														$BytesRead = $VHDStream.Read($KeyBytes, 0, $KeyBytes.Length)
													}
													catch
													{
														throw ("Unable to retrieve the parent path key in the key/value set of {0}: {1}")
													}
													if($BytesRead)
													{
														if([System.Text.Encoding]::Unicode.GetString($KeyBytes) -eq "absolute_win32_path")
														{
															try
															{
																$BytesRead = $VHDStream.Read($ValueBytes, 0, $ValueBytes.Length)
															}
															catch
															{
																throw ("Unable to retrieve the parent path value in the key/value set of {0}: {1}")
															}
															if($BytesRead)
															{
																$AbsolutePath = [System.Text.Encoding]::Unicode.GetString($ValueBytes)
																break
															}
														}
													}
												}
											}
										}
									}
								}
								# move to the start of the next entry
								$VHDStream.Position = $SavedStreamPosition + 16
							}
						}
					}
				}
			}
			elseif([System.Text.Encoding]::ASCII.GetString($IdentifierBytes) -eq "conectix") # this is a VHD file
			{
				$TypeSize = 4; $ChunkSize = 2
				$TypeBytes = New-Object Byte[] $TypeSize -ErrorAction Stop; $ChunkBytes = New-Object Byte[] $ChunkSize -ErrorAction Stop
				$ReverseParentBytes = [Byte[]]@()
				$VHDStream.Position = 60	# this is where the disk type is stored
				try
				{
					$BytesRead = $VHDStream.Read($TypeBytes, 0, $TypeSize)
				}
				catch
				{
					throw ("Unable to determine the disk type of {0}: {1}" -f $Path, $_)
				}
				if($BytesRead)
				{
					[Array]::Reverse($TypeBytes)	# surprise byte reversal!
					if([System.BitConverter]::ToUInt32($TypeBytes, 0) -eq 4)	# is the differencing type
					{
						$VHDStream.Position = 576	# this is where the name of the parent is stored, if any
						1..256 | foreach {	# there are 512 bytes in the name, but they're also reversed. this is much more miserable to fix
							try
							{
								$BytesRead = $VHDStream.Read($ChunkBytes, 0, $ChunkSize)
							}
							catch
							{
								throw ("Unable to read the parent of {0}: {1}" -f $Path, $_)
							}
							if($BytesRead)
							{
								[Array]::Reverse($ChunkBytes)
								$ReverseParentBytes += $ChunkBytes
							}
						}
						$AbsolutePath = [System.Text.Encoding]::Unicode.GetString($ReverseParentBytes) -replace "(?<=\.vhd).*"	# remove leftover noise
					}
				}
			}
			else
			{
				throw ("{0} is not a valid VHD(X) file or has a damaged header" -f $Path)
			}
		}
		catch
		{	<#
				PowerShell does not implement any form of "goto" or "using", so the purpose of this outer try block is to simulate goto functionality with an ending point
				that ensures that the file is always closed, if one was opened. otherwise, PS's normal erroring is sufficient
			#>
			throw($_)
		}
		finally
		{
			if($VHDStream)
			{
				$VHDStream.Close()
			}
		}
		$AbsolutePath
	}
}

PROCESS
{
	$VMHosts = [String[]]@()	# verified list of hosts to scan; built from -ComputerName; cluster nodes will be added automatically
	$Clusters = [String[]]@()	# discovered clusters. item format: primary node; node1, node2, node3, ...
	$RemotePathsToScan = @()	# any paths to scan that are not on a share; even local paths will be scanned via remote session, includes host name
	$SharedPathsToScan = @()	# any shared paths to scan
	$RemoteMetaFileExclusions = @()	# known good xml, bin, vsv, and slp files that are not on a share, includes host name
	$RemoteDiskFileExclusions = @()	# known good vhd, vhdx, avhd, avhdx, and vfd files that are not on a share, includes host name
	$SharedMetaFileExclusions = @()	# known good xml, bin, vsv, and slp files that are on a share
	$SharedDiskFileExclusions = @()	# known good vhd, vhdx, avhd, avhdx, and vfd files that are on a share

	######################### Validate input parameters ###############################
	switch($PSCmdlet.ParameterSetName)
	{
		'SpecifiedPath' {
			$UseDefaultPath = $IncludeDefaultPath
			$UseExistingVMPaths = $IncludeExistingVMPaths
		}
		'UnspecifiedPath' {
			$UseDefaultPath = -not $ExcludeDefaultPath
			$UseExistingVMPaths = -not $ExcludeExistingVMPaths
		}
	}
	if([String]::IsNullOrEmpty($Path) -and -not $UseDefaultPath -and -not $UseExistingVMPaths)
	{
		throw('No path specified for scan')
	}

	Write-Verbose -Message "Using default path(s): $UseDefaultPath"
	Write-Verbose -Message "Using existing VM path(s): $UseExistingVMPaths"

	######################### Validate host list ###############################
	Write-Verbose "Verifying hosts"
	foreach ($VMHost in $ComputerName)
	{
		if($VMHost.GetType().ToString() -match "Microsoft.HyperV.PowerShell.VMHost")
		{
			$VMHost = $VMHost.Name
		}
		try
		{
			$GwmiComputerParameters = @{'ComputerName'=$VMHost;'Class'='Win32_ComputerSystem';'ErrorAction'='Stop' }
			if($Credential)
			{
				$GwmiComputerParameters.Add('Credential', $Credential)
			}
			$ComputerObject = Get-WmiObject @GwmiComputerParameters
		}
		catch
		{
			Write-Warning "Unable to contact $VMHost. Skipping."
			$VMHost = ""
		}
		if(-not [String]::IsNullOrEmpty($VMHost))
		{
			$ShortName = $ComputerObject.Name.ToLower()
			if($ComputerObject.Domain.Contains("."))	# this will drop the ball for single-level domains, but people with single-level domains have bigger problems than a few VM files going astray so the extra effort to determine if it's truly a domain member is probably not worth it
			{
				$VMHost = [String]::Join(".", ($ShortName, $ComputerObject.Domain))
				if(-not $IgnoreClusterMembership)
				{
					try
					{
						$GwmiNodeParameters = @{'ComputerName'=$VMHost;'Class'='MSCluster_Node';'Namespace'='root\MSCluster';'ErrorAction'='Stop' }
						if($Credential)
						{
							$GwmiNodeParameters.Add('Credential',$Credential)
						}
						$Nodes = (Get-WmiObject @GwmiNodeParameters).Name
						$GwmiClusterDomainParameters = @{'ComputerName'=$VMHost;'Class'='Win32_ComputerSystem';'Namespace'='root\CIMV2';'ErrorAction'='Stop' }
						if($Credential)
						{
							$GwmiClusterDomainParameters.Add('Credential',$Credential)
						}
						$ClusterDomain = (Get-WmiObject @GwmiClusterDomainParameters).Domain
						$Nodes = $Nodes | foreach { "$_.$ClusterDomain" }
						foreach($Node in $Nodes)
						{
							if($VMHosts -notcontains $Node)
							{
								Write-Verbose "Adding $Node to scan list"
								$VMHosts += $Node
							}
						}
						$Clusters += [String]::Join(";", ("$($Nodes[0])", ([String]::Join(",", $Nodes))))
					}
					catch
					{
						# this just means that the target system isn't a cluster node
					}
				}
			}
			else
			{
				$VMHost = $ShortName
			}
			if($VMHosts -notcontains $VMHost)
			{
				Write-Verbose -Message "Adding $VMHost to scan list"
				$VMHosts += $VMHost
			}
		}
	}

	######################### Build exclusion and scan paths lists ###############################
	$ExclusionsAndPaths = Get-RemoteData `
		-VMHosts $VMHosts `
		-ScriptBlock $VMFilePathsScriptBlock `
		-InvokeErrorTemplate "Unable to connect to {0}`r`n{1}" `
		-ResultsErrorTemplate "An error occurred while retrieving host and VM data from {0}`r`n{1}" `
		-ArgumentList @($UseDefaultPath, $UseExistingVMPaths) `
		-Credential $Credential `
		-VerboseAction 'Retrieving virtual machine files and paths'

	foreach($EPItem in $ExclusionsAndPaths)
	{
		$FullItem = $EPItem.Split(';')
		if($FullItem[1] -eq 'metafile')
		{
			$RemoteMetaFileExclusions += Parse-LocalOrSharedItem -CurrentPath $FullItem[2] -CurrentHost $FullItem[0]
		}
		elseif($FullItem[1] -eq 'disk')
		{
			$DiskFileExclusion = Parse-LocalOrSharedItem -CurrentPath $FullItem[2] -CurrentHost $FullItem[0]
			if($DiskFileExclusion.Contains(','))
			{
				$RemoteDiskFileExclusions += $DiskFileExclusion
			}
			else
			{
				$SharedDiskFileExclusions += $DiskFileExclusion
			}
		}
		elseif($FullItem[1] -eq 'path')
		{
			$ThisPath = $FullItem[2]
			if($ThisPath -match '^\\\\[^?|.]')
			{
				$SharedPathsToScan += Parse-LocalOrSharedItem -CurrentPath $ThisPath
			}
			else
			{
				$RemotePathsToScan += Parse-LocalOrSharedItem -CurrentPath $ThisPath -CurrentHost $FullItem[0]
			}
		}
		else # 'shared'
		{
			$SharedPathItem = $FullItem[2].Split(',')
			$SharedPath = $SharedPathItem[0]
			$VMId = $SharedPathItem[1]
			$VMName = $SharedPathItem[2]
			$SharedItemType = $SharedPathItem[3]
			switch($SharedItemType)
			{
				{ 'configuration' -or 'snapshot' } {
					$SharedMetaFileExclusions += (Get-ChildItem -File -Path $SharedPath -Recurse -Filter "$VMId.xml").FullName
					$SharedMetaFileExclusions += (Get-ChildItem -File -Path $SharedPath -Recurse -Filter "$VMId.bin").FullName
					$SharedMetaFileExclusions += (Get-ChildItem -File -Path $SharedPath -Recurse -Filter "$VMId.vsv").FullName
				}
				'slp' {
					$SharedMetaFileExclusions += (Get-ChildItem -File -Path $SharedPath -Recurse -Filter "$VMId.*.slp").FullName
				}
			}
		}
	}
	foreach($SharedDiskFile in $SharedDiskFileExclusions)
	{
		try
		{
			$DiskFile = (Get-Item -Path $SharedDiskFile -ErrorAction Stop).FullName
		}
		catch
		{
			Write-Error -Message "Unable to access $SharedDiskFile`r`n$_"
		}
		if(-not [String]::IsNullOrEmpty($DiskFile))
		{
			Write-Verbose -Message ("Determining the parent (if any) of {0}" -f $DiskFile)
			try
			{
				$Parent = Get-VHDDifferencingParent -Path $DiskFile -ErrorAction Stop
				while(-not [String]::IsNullOrEmpty($Parent))
				{
					$SharedDiskFileExclusions += $Parent
					Write-Verbose -Message ("Determining the parent (if any) of {0}" -f $Parent)
					$Parent = Get-VHDDifferencingParent -Path $Parent
				}
			}
			catch
			{
				Write-Error $_
			}
		}
	}

	# perform basic sanitization of user-supplied paths; no need to get crazy as PowerShell will throw its own errors on malformed paths without damaging the system
	if($Path.Count)
	{
		foreach($PathItem in $Path)
		{
			if($PathItem -notmatch '\\$')
			{
				$PathItem += '\'	# for some reason, script behaves erratically when root drives are supplied without trailing slashes (e.g. 'c:'); forcing a trailing slash corrects this
			}
			if($PathItem -match '^\\\\[^?|.]')	# matches on share paths but not raw volume identifiers
			{
				$SharedPathsToScan += Parse-LocalOrSharedItem -CurrentPath $PathItem
			}
			else
			{
				foreach($VMHost in $VMHosts)	# when user supplies a path, look for it on every host; script can handle paths that don't exist everywhere
				{
					$RemotePathsToScan += Parse-LocalOrSharedItem -CurrentPath $PathItem -CurrentHost $VMHost
				}
			}
		}
	}

	# eliminate scanning the same CSV locations from different hosts by retargeting all CSV scans to the first cluster node
	$RemotePathsToScan = Dedupe-CSV -ClusterList $Clusters -ArrayWithCSV $RemotePathsToScan
	$RemoteMetaFileExclusions = Dedupe-CSV -ClusterList $Clusters -ArrayWithCSV $RemoteMetaFileExclusions
	$RemoteDiskFileExclusions = Dedupe-CSV -ClusterList $Clusters -ArrayWithCSV $RemoteDiskFileExclusions

	# Paths are collected; eliminate duplicates
	$RemotePathsToScan = $RemotePathsToScan | select -Unique
	$SharedPathsToScan = Remove-SubPaths -PathArray $SharedPathsToScan
	$SharedPathsToScan = $SharedPathsToScan | select -Unique

	if($PSCmdlet.MyInvocation.BoundParameters.ContainsKey('Verbose'))
	{
		foreach($PathItem in $RemotePathsToScan)
		{
			$PathDetail = $PathItem.Split(',')
			if($PathDetail[1].Length -gt 0)
			{
				$Addition = " on $($PathDetail[1])"
			}
			else
			{
				$Addition = ''
			}
			Write-Verbose -Message "Scan list entry: $($PathDetail[0])$Addition"
		}
		foreach($PathItem in $SharedPathsToScan)
		{
			Write-Verbose -Message "Scan list entry: $PathItem"
		}
	}

	# Start scanning
	$SessionList = @()
	$JobList = @()
	foreach($VMHost in $VMHosts)
	{
		$TargetSystemPaths = @()
		$TargetSystemFileExclusions = @()
		$TargetSystemDiskExclusions = @()
		$SkipCSVs = $IgnoreClusterMembership

		if(-not $SkipCSVs)
		{
			$VMHostIsPrimary = $false
			foreach($Cluster in $Clusters)
			{
				if($VMHost -eq $Cluster.Split(";")[0])
				{
					$VMHostIsPrimary = $true
				}
			}
			$SkipCSVs = -not $VMHostIsPrimary
		}

		foreach($PathItem in $RemotePathsToScan)
		{
			$SearchPath = $PathItem.Split(",")[0]
			$SearchHost = $PathItem.Split(",")[1]
			if($VMHost -eq $SearchHost -or [String]::IsNullOrEmpty($SearchHost))
			{
				$TargetSystemPaths += $SearchPath.ToLower()
				Write-Verbose -Message ('Adding "{0}" to search paths on "{1}"' -f $SearchPath, $VMHost)
			}
		}
		foreach($ExclusionItem in $RemoteMetaFileExclusions)
		{
			$Exclusion = $ExclusionItem.Split(",")[0]
			$ExclusionHost = $ExclusionItem.Split(",")[1]
			if($VMHost -eq $ExclusionHost)
			{
				$TargetSystemFileExclusions += $Exclusion.ToLower()
				Write-Verbose -Message ('Excluding "{0} from search on "{1}"' -f $Exclusion, $VMHost)
			}
		}
		foreach($ExclusionItem in $RemoteDiskFileExclusions)
		{
			$Exclusion = $ExclusionItem.Split(",")[0]
			$ExclusionHost = $ExclusionItem.Split(",")[1]
			if($VMHost -eq $ExclusionHost)
			{
				$TargetSystemDiskExclusions += $Exclusion.ToLower()
				Write-Verbose -Message ('Excluding "{0} from search on "{1}"' -f $Exclusion, $VMHost)
			}
		}

		# eliminate sub-paths of directories already marked to be scanned
		$TargetSystemPaths = Remove-SubPaths -PathArray $TargetSystemPaths

		# knock out any duplicates generated from previous operations
		$TargetSystemPaths = $TargetSystemPaths | select -Unique
		$SessionParameters = @{'ComputerName'=$VMHost}
		if($Credential)
		{
			$SessionParameters.Add('Credential', $Credential)
		}
		Write-Verbose "Establishing a remote session on $VMHost"
		$Session = New-PSSession @SessionParameters
		Write-Verbose "Initiating orphaned file scan on $VMHost"
		$JobList += Invoke-Command -Session $Session -ScriptBlock $SearchScriptBlock -AsJob -ArgumentList $TargetSystemPaths, $TargetSystemFileExclusions, $TargetSystemDiskExclusions, $SkipCSVs
		$SessionList += $Session
	}
	foreach($PathItem in $SharedPathsToScan)
	{
		Write-Verbose -Message "Scanning $PathItem for orphaned files"
		$JobList += Start-Job -ScriptBlock $SearchScriptBlock -ArgumentList $PathItem, $SharedMetaFileExclusions, $SharedDiskFileExclusions
	}
	if($JobList.Count)
	{
		Write-Verbose -Message 'Waiting for remote scans to complete'
		Wait-Job -Job $JobList | Out-Null
		Write-Verbose -Message "Retrieving file lists"
		$FileList = Receive-Job -Job $JobList
		$JobList | Remove-Job
	}
	$SessionList | Remove-PSSession
	$FileList
}

END {}