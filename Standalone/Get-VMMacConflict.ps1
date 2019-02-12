<#
.SYNOPSIS
Locate conflicting Hyper-V virtual network adapter MAC addresses.
.DESCRIPTION
Locate conflicting Hyper-V virtual network adapter MAC addresses. With default settings, will scan the indicated hosts and generate a report of all adapters, virtual and physical, that use the same MAC in the same VLAN.
Skips physical adapters bound by a virtual switch or team as these generate false positives.
.PARAMETER ComputerName
Name of one or more hosts running Hyper-V. If -HostFile is also set, uses both sources. If neither is set, uses the local system.
.PARAMETER ExcludeHost
If set, will not examine host MAC addresses for conflicts.
.PARAMETER ExcludeVlan
If set, will treat identical MAC addresses in distinct subnets as conflicts.
.PARAMETER IncludeAllZero
If set, will include virtual NICs with an all-zero MAC.
.PARAMETER IncludeDisconnected
If set, will include enabled but unplugged management operating system adapters. No effect if ExcludeHost is set.
.PARAMETER IncludeDisabled
If set, will include disabled management operating system adapters. No effect if ExcludeHost is set.
.PARAMETER HostFile
If provided, reads host names from the specified file. If -ComputerName is also set, uses both sources. If neither is set, uses the local system.
.PARAMETER FileHasHeader
If set, the first row in the file will be treated as a header row.
If not set, the parser will assume the first column contains host names.
Ignored if HostFile is not specified.
.PARAMETER HeaderColumn
If HostFile is a delimited type, use this to indicate which column contains the host names.
If -HeaderColumn is set, but -FileHeader is NOT set, then this value will be treated as a column header AND a host name.
If not set and the file is delimited, the first column will be used.
Ignored if HostFile is not specified.
.PARAMETER Delimiter
The parser will treat this character as the delimiter in -HostFile. Defaults to the separator defined in the local machine's current culture.
Ignored if HostFile is not specified.
.PARAMETER All
Bypasses duplicate check and outputs information on all discovered adapters.
.NOTES
Author: Eric Siron
Version 1.2, December 27, 2018
Released under MIT license
.INPUTS
String[]
.EXAMPLE
PS C:\> Get-VMMacConflict
Checks the local machine for duplicate Hyper-V virtual machine MAC addresses. Includes active host adapters.
.EXAMPLE
PS C:\> Get-VMMacConflict -ComputerName svhv1
Checks the Hyper-V system named "svhv1" for duplicate Hyper-V virtual machine MAC addresses. Includes active host adapters.
.EXAMPLE
PS C:\> Get-VMMacConflict -ComputerName svhv1, svhv2, svhv3, svhv4
Checks all of the named Hyper-V systems for duplicate Hyper-V virtual machine MAC addresses. Includes active host adapters.
.EXAMPLE
PS C:\> Get-VMMacConflict -HostFile C:\hostnames.txt
Reads host names from C:\hostnames.txt; it must be a single-column file of host names or all host names must be in the first column. VMs on these hosts are scanned for duplicate MAC addresses.
.EXAMPLE
PS C:\> Get-VMMacConflict -HostFile C:\hostnames.txt -FileHasHeader -HeaderColumn HostName
Reads host names from C:\hostnames.txt; host names must be in a column named "HostName". VMs on these hosts are scanned for duplicate MAC addresses.
.EXAMPLE
PS C:\> Get-VMMacConflict -HostFile C:\hostnames.txt -HeaderColumn svhv1
Reads host names from C:\hostnames.txt; looks for host names in a header-less column starting with svhv1. VMs on these hosts are scanned for duplicate MAC addresses.
.EXAMPLE
PS C:\> Get-VMMacConflict -ExcludeVlan
Checks the local machine for duplicate Hyper-V virtual machine MAC addresses, even if they are in distinct VLANs. Includes active host adapters.
.EXAMPLE
PS C:\> Get-VMMacConflict -IncludeDisconnected -IncludeDisabled
Checks the local machine for duplicate Hyper-V virtual machine MAC addresses. Includes active host adapters, even if they are disconnected or disabled.
.EXAMPLE
PS C:\> Get-VMMacConflict -ComputerName svhv1, svhv2, svhv3, svhv4 -All | Out-GridView
Retrieves information about all active adapters from the specified hosts and displays a grid view.
.LINK
https://github.com/ejsiron/Posher-V/blob/master/docs/Get-VMMacConflict.md
#>
#requires -Version 4
[CmdletBinding()]
[OutputType([psobject[]])]
param
(
	[Parameter(ValueFromPipeline = $true, Position = 1)][String[]]$ComputerName = [String]::Empty,
	[Parameter()][Switch]$ExcludeHost,
	[Parameter()][Switch]$ExcludeVlan,
	[Parameter()][Switch]$IncludeAllZero,
	[Parameter()][Switch]$IncludeDisconnected,
	[Parameter()][Switch]$IncludeDisabled,
	[Parameter()][String]$HostFile = [String]::Empty,
	[Parameter()][Switch]$FileHasHeader,
	[Parameter()][String]$HeaderColumn = [String]::Empty,
	[Parameter()][Char]$Delimiter = (Get-Culture).TextInfo.ListSeparator,
	[Parameter()][Switch]$All
)

begin
{
	Set-StrictMode -Version Latest
	$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Continue	# ensure that, even if errors occur, PSDefaultParameters is reset
	$ExistingDefaultParams = $PSDefaultParameterValues.Clone()
	$PSDefaultParameterValues['Get-CimInstance:Namespace'] = 'root/virtualization/v2'
	$PathToHostSwitchPort = 'Msvm_LANEndpoint/Msvm_LANEndpoint/Msvm_EthernetSwitchPort'
	$PathToHostVlanSettings = 'Msvm_EthernetPortAllocationSettingData/Msvm_EthernetSwitchPortVlanSettingData'

	$MacList = New-Object -TypeName System.Collections.ArrayList

	$SuppliedHostNames = New-Object -TypeName System.Collections.ArrayList
	$VerifiedHostNames = New-Object -TypeName System.Collections.ArrayList
	$ProcessedHostNames = New-Object -TypeName System.Collections.ArrayList
	if (-not $ComputerName -and [String]::IsNullOrEmpty($HostFile))
	{
		$OutNull = $SuppliedHostNames.Add($env:COMPUTERNAME)
	}

	if ($HostFile)
	{
		Write-Verbose -Message ('Importing host names from "{0}"' -f $HostFile)
		$HostListFile = (Resolve-Path -Path $HostFile).Path
		$FileData = Import-Csv -Path $HostListFile -Delimiter $Delimiter
		if ($FileData)
		{
			if ([String]::IsNullOrEmpty($HeaderColumn))
			{
				$HeaderColumn = ($FileData | Get-Member -MemberType NoteProperty)[0].Name
			}
			if ($FileHasHeader.ToBool() -eq $false)
			{
				$OutNull = $SuppliedHostNames.Add($HeaderColumn)	# Import-CSV ALWAYS treats line 1 as a header
			}
			$SuppliedHostNames.AddRange($FileData.$HeaderColumn)
		}
	}

	function Get-CimPathedAssociation
	{
		param
		(
			[Parameter(Mandatory = $true, Position = 1, ValueFromPipeline = $true)][Microsoft.Management.Infrastructure.CimInstance]$CimInstance,
			[Parameter(Mandatory = $true, Position = 2)][String]$PathToInstance,
			[Parameter()][Switch]$KeyOnly
		)
		$PathNodes = $PathToInstance.Split('/')
		$SearchInstances = @($CimInstance)
		for ($i = 0; $i -lt $PathNodes.Length; $i++)
		{
			$ChildCounter = 1
			if ($SearchInstances.Count)
			{
				$OnlyKeys = [bool]($KeyOnly -or $i -ne ($PathNodes.Count - 1))
				$TemporarySearchInstances = New-Object -TypeName System.Collections.ArrayList
				foreach ($SearchInstance in $SearchInstances)
				{
					Write-Progress -Id 2 -Activity 'Querying CIM instances' -Status ('At distance {0} of {1}' -f ($i + 1), $PathNodes.Count) -CurrentOperation ('Loading {0} instances related to {1}' -f $SearchInstances.Count, $SearchInstance.CimClass.CimClassName) -PercentComplete (($ChildCounter++) / $SearchInstances.Count * 100)
					$AssociatedInstances = @(Get-CimAssociatedInstance -InputObject $SearchInstance -ResultClassName $PathNodes[$i] -KeyOnly:$OnlyKeys)
					if ($AssociatedInstances)
					{
						$TemporarySearchInstances.AddRange($AssociatedInstances)
					}
				}
				Write-Progress -Id 2 -Activity 'Querying CIM instances' -Completed
				if ($TemporarySearchInstances.Count)
				{
					$SearchInstances = $TemporarySearchInstances
				}
				else
				{
					$SearchInstances.Clear()
				}
			}
		}
		$SearchInstances
	}

	function New-MacReportItem
	{
		param
		(
			[Parameter(Mandatory = $true)][String]$MacAddress,
			[Parameter()][String]$VMName = [String]::Empty,
			[Parameter()][String]$VmID = [String]::Empty,
			[Parameter(Mandatory = $true)][String]$ComputerName,
			[Parameter(Mandatory = $true)][String]$AdapterName,
			[Parameter(Mandatory = $true)][String]$AdapterID,
			[Parameter()][bool]$IsStatic = $false,
			[Parameter()][String]$SwitchName = [String]::Empty,
			[Parameter()][String]$VlanInfo
		)
		$MacReportItem = New-Object -TypeName psobject
		$MacReportItemNoteProperties = [ordered]@{
			VMName       = $VMName;
			VmID         = $VmID;
			ComputerName = $ComputerName;
			AdapterName  = $AdapterName;
			AdapterID    = $AdapterID;
			MacAddress   = $MacAddress;
			IsStatic     = $IsStatic;
			SwitchName   = $SwitchName;
			Vlan         = $VlanInfo
		}
		$OutNull = Add-Member -InputObject $MacReportItem -NotePropertyMembers $MacReportItemNoteProperties
		$MacReportItem
	}

	function Get-VlanInfoArray
	{
		param
		(
			[Parameter()][Microsoft.Management.Infrastructure.CimInstance]$VlanInfo
		)
		$VlanInfoArray = New-Object -TypeName System.Collections.ArrayList
		if ($VlanInfo)
		{
			switch ($VlanInfo.OperationMode)
			{
				2 # Trunk
				{
					$OutNull = $VlanInfoArray.Add($VlanInfo.NativeVlanId)
					foreach ($VlanId in $VlanInfo.TrunkVlanIdArray)
					{
						if ($VlanId -ne $VlanInfo.NativeVlanId)
						{
							$OutNull = $VlanInfoArray.Add($VlanId)
						}
					}
				}
				3 # Private
				{
					if ($VlanInfo.PvlanMode -eq 3)	# promiscuous; allows multiple secondaries
					{
						foreach ($SecondaryVlan in $VlanInfo.SecondaryVlanIdArray)
						{
							$OutNull = $VlanInfoArray.Add("$($VlanInfo.PrimaryVlanId):$SecondaryVlan")
						}
					}
					else	# community & isolated; one secondary
					{
						$OutNull = $VlanInfoArray.Add("${$VlanInfo.PrimaryVlanId}:${$VlanInfo.SecondaryVlanId}")
					}
				}
				default # 1 is access mode; 0 should never occur but if it does, treat it as access
				{
					$OutNull = $VlanInfoArray.Add($VlanInfo.AccessVlanId)
				}
			}
		}
		else
		{
			$OutNull = $VlanInfoArray.Add("0")
		}
		$VlanInfoArray
	}

	function IsDuplicate
	{
		param(
			[Parameter(Mandatory = $true)][psobject]$Left,
			[Parameter(Mandatory = $true)][psobject]$Right,
			[Parameter()][bool]$ExcludeVlan
		)
		[bool](
			$Left.MacAddress -eq $Right.MacAddress -and
			(
				$Left.ComputerName -ne $Right.ComputerName -or
				$Left.VmID -ne $Right.VmID -or
				$Left.AdapterID -ne $Right.AdapterID
			) -and
			($ExcludeVlan -or $Left.Vlan -eq $Right.Vlan)
		)
	}
}

process
{
	foreach ($HostName in $ComputerName)
	{
		if (-not $SuppliedHostNames.Contains($HostName))
		{
			$OutNull = $SuppliedHostNames.Add($HostName)
		}
	}

	if ($SuppliedHostNames.Count)
	{
		$Activity = 'Verifying hosts lists'
		foreach ($HostName in $SuppliedHostNames)
		{
			if ([String]::IsNullOrEmpty($HostName))
			{
				continue
			}
			Write-Progress -Activity $Activity -Status $HostName
			if (-not $VerifiedHostNames.Contains($HostName))
			{
				$DiscoveredName = $HostName
				try
				{
					$DiscoveredName = (Get-CimInstance -ComputerName $HostName -Namespace 'root/cimv2' -ClassName 'Win32_ComputerSystem' -ErrorAction Stop).Name
					if (-not $VerifiedHostNames.Contains($HostName))
					{
						$OutNull = $VerifiedHostNames.Add($DiscoveredName)
					}
				}
				catch
				{
					Write-Error -Exception $_.Exception -ErrorAction Continue
					continue
				}
			}
		}
		Write-Progress -Activity $Activity -Completed

		foreach ($HostName in $VerifiedHostNames)
		{
			if ($ProcessedHostNames.Contains($HostName))
			{
				continue
			}
			else
			{
				$OutNull = $ProcessedHostNames.Add($HostName)
			}

			$Session = $null
			try
			{
				Write-Progress -Activity $Activity -Status ('Connecting to host "{0}"' -f $HostName)
				$Session = New-CimSession -ComputerName $HostName -ErrorAction Stop
			}
			catch
			{
				Write-Warning -Message ('Cannot connect to {0}' -f $HostName)
				Write-Error -Exception $_.Exception -ErrorAction Continue
				continue
			}

			$Activity = 'Discovering MAC addresses on {0}' -f $Session.ComputerName
			foreach ($VM in Get-CimInstance -CimSession $Session -ClassName Msvm_ComputerSystem)
			{
				$CurrentOperation = 'Querying {0}' -f $VM.ElementName
				if ($HostName -eq $VM.Name) # "$VM" in this case is the physical machine
				{
					if ($ExcludeHost) { continue }
					Write-Progress -Activity $Activity -Status 'Loading host adapters' -CurrentOperation $CurrentOperation
					$AdapterList = New-Object System.Collections.ArrayList

					$ExternalPorts = @(Get-CimAssociatedInstance -InputObject $VM -ResultClassName Msvm_ExternalEthernetPort -ErrorAction SilentlyContinue)
					$InternalPorts = @(Get-CimAssociatedInstance -InputObject $VM -ResultClassName Msvm_InternalEthernetPort -ErrorAction SilentlyContinue)

					if ($ExternalPorts)
					{
						$AdapterList.AddRange($ExternalPorts)
					}

					if ($InternalPorts)
					{
						$AdapterList.AddRange($ExternalPorts)
					}

					foreach ($Adapter in $AdapterList)
					{
						if ($Adapter.IsBound)
						{
							continue
						}
						$TargetDeviceId = $null
						if ($Adapter.DeviceId -match '{.*}')
						{
							$TargetDeviceId = $Matches[0]
						}
						$VLAN = 0
						$SwitchName = [String]::Empty
						Write-Progress -Activity $Activity -Status 'Loading host adapter information' -CurrentOperation $CurrentOperation
						$MSAdapter = Get-CimInstance -CimSession $Session -Namespace root/StandardCimv2 -ClassName MSFT_NetAdapter -Filter ('DeviceId="{0}"' -f $TargetDeviceId)
						$AdapterID = $TargetDeviceId
						$Enabled = $MSAdapter.State -eq 2 -or $IncludeDisabled
						$Connected = $MSAdapter.MediaConnectState -eq 1 -or ($IncludeDisconnected -or ($MSAdapter.State -ne 2 -and $IncludeDisabled))
						if ($Enabled -and $Connected)
						{
							if ($Adapter.CimClass.CimClassName -eq 'Msvm_InternalEthernetPort')
							{
								Write-Progress -Activity $Activity -Status 'Loading host adapter switch information' -CurrentOperation $CurrentOperation
								$SwitchPort = Get-CimPathedAssociation -CimInstance $Adapter -PathToInstance $PathToHostSwitchPort
								if ($SwitchPort)
								{
									$AdapterID = ('Microsoft:{0}\{1}' -f $SwitchPort.SystemName, $SwitchPort.Name)
									$VMSwitch = Get-CimAssociatedInstance -InputObject $SwitchPort -ResultClassName Msvm_VirtualEthernetSwitch
									if ($VMSwitch)
									{
										$SwitchName = $VMSwitch.ElementName
									}
									$VlanSettings = Get-CimPathedAssociation -CimInstance $SwitchPort -PathToInstance $PathToHostVlanSettings
									if ($VlanSettings)
									{
										$VLAN = $VlanSettings.AccessVlanId
									}
									else
									{
										$VLAN = $MSAdapter.VlanID
									}
								}
							}
							$OutNull = $MacList.Add((New-MacReportItem -MacAddress $Adapter.PermanentAddress -ComputerName $HostName -AdapterName $MSAdapter.Name -AdapterID $AdapterID -IsStatic $true -SwitchName $SwitchName -Vlan $VLAN))
						}
					}
				}
				else
				{
					Write-Progress -Activity $Activity -Status 'Loading virtual machine settings' -CurrentOperation $CurrentOperation
					$VMSettings = Get-CimAssociatedInstance -InputObject $VM -ResultClassName Msvm_VirtualSystemSettingData | where -Property VirtualSystemType -eq 'Microsoft:Hyper-V:System:Realized'
					if ($VMSettings)
					{
						Write-Progress -Activity $Activity -Status 'Loading virtual machine vNIC settings' -CurrentOperation $CurrentOperation
						foreach ($EthPortSettings in Get-CimAssociatedInstance -InputObject $VMSettings -ResultClassName Msvm_EthernetPortAllocationSettingData)
						{
							$VMSwitchName = [String]::Empty
							if ($EthPortSettings.EnabledState -eq 2)
							{
								if(Test-Path -Path 'variable:\EthPortSettings.LastKnownSwitchName')
								{
									$VMSwitchName = $EthPortSettings.LastKnownSwitchName	
								}
								elseif ($EthPortSettings.HostResource)
								{
									$SwitchComponents = $EthPortSettings.HostResource[0].Split(',')
									$SwitchGUIDComponent = $SwitchComponents[($SwitchComponents.Length-1)]
									if($SwitchGUIDComponent -match '"(.*)"')
									{
										$VMSwitchName = (Get-CimInstance -CimSession $Session -ClassName Msvm_VirtualEthernetSwitch -Filter ('Name="{0}"' -f $Matches[1])).ElementName
									}
								}
							}
							$VNICPortSettings = Get-CimAssociatedInstance -InputObject $EthPortSettings -ResultClassName Msvm_SyntheticEthernetPortSettingData
							if (-not $VNICPortSettings)
							{
								$VNICPortSettings = Get-CimAssociatedInstance -InputObject $EthPortSettings -ResultClassName Msvm_EmulatedEthernetPortSettingData
							}

							if ($VNICPortSettings -and ($IncludeAllZero -or $VNICPortSettings.Address -ne '0' * 12))
							{
								$VlanSettings = Get-CimAssociatedInstance -InputObject $EthPortSettings -ResultClassName Msvm_EthernetSwitchPortVlanSettingData

								foreach ($VlanSet in @(Get-VlanInfoArray $VlanSettings))
								{
									$OutNull = $MacList.Add((New-MacReportItem -MacAddress $VNICPortSettings.Address -VMName $VM.ElementName -VmID $VM.Name -ComputerName $HostName -AdapterName $VNICPortSettings.ElementName -AdapterID $VNICPortSettings.InstanceID -IsStatic $VNICPortSettings.StaticMacAddress -VlanInfo $VlanSet -SwitchName $VMSwitchName))
								}
							}
						}
					}
				}
			}
			$Session.Close()
		}
		Write-Progress -Activity $Activity -Completed
	}
}

end
{
	if ($All)
	{
		$MacList.ToArray()
	}
	else
	{
		$Duplicates = New-Object -TypeName System.Collections.ArrayList
		foreach ($OuterItem in $MacList)
		{
			foreach ($InnerItem in $MacList)
			{
				if (-not $Duplicates.Contains($InnerItem))
				{
					if (IsDuplicate -Left $InnerItem -Right $OuterItem -ExcludeVlan $ExcludeVlan.ToBool())
					{
						$OutNull = $Duplicates.Add($InnerItem)
					}
				}

			}
		}

		$Duplicates.ToArray()
	}

	$PSDefaultParameterValues.Clear()
	foreach ($ParamKey in $ExistingDefaultParams.Keys)
	{
		$PSDefaultParameterValues.Add($ParamKey, $ExistingDefaultParams[$ParamKey])
	}
}