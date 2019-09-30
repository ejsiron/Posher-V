<#
.SYNOPSIS
	Converts LBFO+Virtual Switch combinations to switch-embedded teams.

.DESCRIPTION
	Converts LBFO+Virtual Switch combinations to switch-embedded teams.

	Performs the following steps:
	1. Saves information about management OS vNICs
	2. Disconnects attached virtual machine vNICs
	3. Deletes the virtual switch
	4. Deletes the LBFO team
	5. Recreates management OS vNICs
	6. Reconnects previously-attached virtual machine vNICs

	If you do not specify any overriding parameters, the new switch uses the same settings as the original LBFO+team.

.PARAMETER Id
	The unique identifier(s) for the virtual switch(es) to convert.

.PARAMETER Name
	The name(s) of the virtual switch(es) to convert.

.PARAMETER VMSwitch
	The virtual switch(es) to convert.

.PARAMETER NewName
	Name(s) to assign to the converted virtual switch(es). If blank, keeps the original name.

.PARAMETER UseDefaults
	If specified, uses defaults for all values on the converted switch(es). If not specified, uses the same parameters as the original LBFO+switch or any manually-specified parameters.

.PARAMETER LoadBalancingAlgorithm
	Sets the load balancing algorithm for the converted switch(es). If not specified, uses the same setting as the original LBFO+switch or the default if UseDefaults is set.

.PARAMETER MinimumBandwidthMode
	Sets the desired QoS mode for the converted switch(es). If not specified, uses the same setting as the original LBFO+switch or the default if UseDefaults is set.

	None: No network QoS
	Absolute: minimum bandwidth values specify bits per second
	Weight: minimum bandwidth values range from 1 to 100 and represent percentages
	Default: use Absolute QoS

.PARAMETER Notes
	A note to associate with the converted switch(es). If not specified, uses the same setting as the original LBFO+switch or the default if UseDefaults is set.

.PARAMETER EnablePacketDirect
	Attempts to enable packet direct on the converted switch(es). If not specified, uses the same setting as the original LBFO+switch or the default if UseDefaults is set.
#>

#Requires -RunAsAdministrator
#Requires -Module Hyper-V
#Requires -Version 5

[CmdletBinding(DefaultParameterSetName = 'ByName', ConfirmImpact = 'High')]
param(
	[Parameter(Position = 1, ParameterSetName = 'ByName')][String[]]$Name = @(''),
	[Parameter(Position = 1, ParameterSetName = 'ByID', Mandatory = $true)][System.Guid[]]$Id,
	[Parameter(Position = 1, ParameterSetName = 'BySwitchObject', Mandatory = $true)][Microsoft.HyperV.PowerShell.VMSwitch[]]$VMSwitch,
	[Parameter(Position = 2)][String[]]$NewName = @(),
	[Parameter()][Switch]$UseDefaults,
	[Parameter()][Microsoft.HyperV.PowerShell.VMSwitchLoadBalancingAlgorithm]$LoadBalancingAlgorithm,
	[Parameter()][Microsoft.HyperV.PowerShell.VMSwitchBandwidthMode]$MinimumBandwidthMode,
	[Parameter()][String]$Notes = '',
	[Parameter()][Switch]$EnablePacketDirect
)

BEGIN
{
	Set-StrictMode -Version Latest
	$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop

	class NetAdapterDataPack
	{
		[System.String]$NicName
		[System.String]$SwitchName
		[System.String]$MacAddress
		[System.Int64]$MinimumBandwidthAbsolute = 0
		[System.Int64]$MinimumBandwidthWeight = 0
		[System.Int64]$MaximumBandwidth = 0
		[System.Int32]$VlanId = 0
		[Microsoft.Management.Infrastructure.CimInstance]$NetAdapterConfiguration

		NetAdapterDataPack([psobject]$VNIC)
		{
			$this.NicName = $VNIC.Name
			$this.SwitchName = $VNIC.SwitchName
			$this.MacAddress = $VNIC.MacAddress
			if ($VNIC.BandwidthSetting -ne $null)
			{
				$this.MinimumBandwidthAbsolute = $VNIC.BandwidthSetting.MinimumBandwidthAbsolute
				$this.MinimumBandwidthWeight = $VNIC.BandwidthSetting.MinimumBandwidthWeight
				$this.MaximumBandwidth = $VNIC.BandwidthSetting.MaximumBandwidth
			}
			$VnicCim = Get-CimInstance -Namespace root/virtualization/v2 -ClassName Msvm_InternalEthernetPort -Filter ('Name="{0}"' -f $VNIC.AdapterId)
			$VnicLanEndpoint1 = Get-CimAssociatedInstance -InputObject $VnicCim -ResultClassName Msvm_LANEndpoint
			$NetAdapter = Get-CimInstance -ClassName Win32_NetworkAdapter -Filter ('GUID="{0}"' -f $VnicLANEndpoint1.Name.Substring(($VnicLANEndpoint1.Name.IndexOf('{'))))
			$this.NetAdapterConfiguration = Get-CimAssociatedInstance -InputObject $NetAdapter -ResultClassName Win32_NetworkAdapterConfiguration
			$this.VlanId = [System.Int32](Get-VMNetworkAdapterVlan -VMNetworkAdapter $VNIC).AccessVlanId
		}
	}

	class SwitchDataPack
	{
		[System.String]$Name
		[Microsoft.HyperV.PowerShell.VMSwitchBandwidthMode]$BandwidthReservationMode
		[System.UInt64]$DefaultFlow
		[System.String]$TeamName
		[System.String[]]$TeamMembers
		[System.UInt32]$LoadBalancingAlgorithm
		[NetAdapterDataPack[]]$HostVNICs

		SwitchDataPack(
			[psobject]$VSwitch,
			[Microsoft.Management.Infrastructure.CimInstance]$Team,
			[System.Object[]]$VNICs
		)
		{
			$this.Name = $VSwitch.Name
			$this.BandwidthReservationMode = $VSwitch.BandwidthReservationMode
			switch($this.BandwidthReservationMode)
			{
				[Microsoft.HyperV.PowerShell.VMSwitchBandwidthMode]::Absolute { $this.DefaultFlow = $VSwitch.DefaultFlowMinimumBandwidthAbsolute }
				[Microsoft.HyperV.PowerShell.VMSwitchBandwidthMode]::Weight { $this.DefaultFlow = $VSwitch.DefaultFlowMinimumBandwidthWeight }
				default { $this.DefaultFlow = 0 }
			}
			$this.TeamName = $Team.Name
			$this.TeamMembers = ((Get-CimAssociatedInstance -InputObject $Team -ResultClassName MSFT_NetLbfoTeamMember).Name)
			$this.LoadBalancingAlgorithm = $Team.LoadBalancingAlgorithm
			$this.HostVNICs = $VNICs
		}
	}
}

PROCESS
{
	$VMSwitches = New-Object System.Collections.ArrayList
	$HostVNICData = New-Object System.Collections.ArrayList

	switch ($PSCmdlet.ParameterSetName)
	{
		'ByID'
		{
			$VMSwitches.AddRange($Id.ForEach( { Get-VMSwitch -Id $_ }))
		}
		'BySwitchObject'
		{
			$VMSwitches.AddRange($VMSwitch.ForEach( { $_ }))
		}
		default	# ByName
		{
			$NameList = New-Object System.Collections.ArrayList
			$NameList.AddRange($Name.ForEach( { $_.Trim() }))
			if ($NameList.Contains('') -or $NameList.Contains('*'))
			{
				$VMSwitches.AddRange(@(Get-VMSwitch))
			}
			else
			{
				$VMSwitches.AddRange($NameList.ForEach( { Get-VMSwitch -Name $_ }))
			}
		}
	}
	if ($VMSwitches.Count)
	{
		$VMSwitches = @(Select-Object -InputObject $VMSwitches -Unique)
	}
	else
	{
		throw('No virtual VMswitches match the provided criteria')
	}

	Write-Progress -Activity 'Pre-flight' -Status 'Verifying operating system version' -PercentComplete 5
	Write-Verbose -Message 'Verifying operating system version'
	$OSVersion = [System.Version]::Parse((Get-CimInstance -ClassName Win32_OperatingSystem).Version)
	if ($OSVersion.Major -lt 10)
	{
		throw('Switch-embedded teams not supported on host operating system versions before 2016')
	}

	Write-Progress -Activity 'Pre-flight' -Status 'Loading virtual VMswitches' -PercentComplete 15

	if ($NewName.Count -gt 0 -and $NewName.Count -ne $VMSwitches.Count)
	{
		$SwitchNameMismatchMessage = 'Switch count ({0}) does not match NewName count ({1}).' -f $VMSwitches.Count, $NewName.Count
		if ($NewName.Count -lt $VMSwitches.Count)
		{
			$SwitchNameMismatchMessage += ' If you wish to rename some VMswitches but not others, specify an empty string for the VMswitches to leave.'
		}
		throw($SwitchNameMismatchMessage)
	}

	Write-Progress -Activity 'Pre-flight' -Status 'Validating virtual switch configurations' -PercentComplete 25
	Write-Verbose -Message 'Validating virtual switches'
	foreach ($VSwitch in $VMSwitches)
	{
		New-Variable -Name TeamAdapter
		try
		{
			Write-Progress -Activity ('Validating virtual switch "{0}"' -f $VSwitch.Name) -Status 'Switch is external' -PercentComplete 25
			Write-Verbose -Message ('Verifying that switch "{0}" is external' -f $VSwitch.Name)
			if ($VSwitch.SwitchType -ne [Microsoft.HyperV.PowerShell.VMSwitchType]::External)
			{
				Write-Warning -Message ('Switch "{0}" is not external, skipping' -f $VSwitch.Name) -WarningAction Stop
			}

			Write-Progress -Activity ('Validating virtual switch "{0}"' -f $VSwitch.Name) -Status 'Switch is not a SET' -PercentComplete 50
			Write-Verbose -Message ('Verifying that switch "{0}" is not already a SET' -f $VSwitch.Name)
			if ($VSwitch.EmbeddedTeamingEnabled)
			{
				Write-Warning -Message ('Switch "{0}" already uses SET, skipping' -f $VSwitch.Name) -WarningAction Stop
			}

			Write-Progress -Activity ('Validating virtual switch "{0}"' -f $VSwitch.Name) -Status 'Switch uses LBFO' -PercentComplete 75
			Write-Verbose -Message ('Verifying that switch "{0}" uses an LBFO team' -f $VSwitch.Name)
			$TeamAdapter = Get-CimInstance -Namespace root/StandardCimv2 -ClassName MSFT_NetLbfoTeamNic -Filter ('InterfaceDescription="{0}"' -f $VSwitch.NetAdapterInterfaceDescription)
			if ($TeamAdapter -eq $null)
			{
				Write-Warning -Message ('Switch "{0}" does not use a team, skipping' -f $VSwitch.Name) -WarningAction Stop
			}
			if ($TeamAdapter.VlanID)
			{
				Write-Warning -Message ('Switch "{0}" is bound to a team NIC with a VLAN assignment, skipping' -f $VSwitch.Name) -WarningAction Stop
			}
		}
		catch
		{
			continue
		}
		finally
		{
			Write-Progress -Activity ('Validating virtual switch "{0}"' -f $VSwitch.Name) -Completed
		}

		Write-Progress -Activity ('Loading information from virtual switch "{0}"' -f $VSwitch.Name) -Status 'Team NIC' -PercentComplete 25
		Write-Verbose -Message 'Loading team'
		$Team = Get-CimAssociatedInstance -InputObject $TeamAdapter -ResultClassName MSFT_NetLbfoTeam

		Write-Progress -Activity ('Loading information from virtual switch "{0}"' -f $VSwitch.Name) -Status 'Guest virtual adapters' -PercentComplete 50
		Write-Verbose -Message 'Loading VM adapters connected to this switch'
		$GuestVNICs = Get-VMNetworkAdapter -VMName * | Where-Object -Property SwitchName -EQ $VSwitch.Name

		Write-Progress -Activity ('Loading information from virtual switch "{0}"' -f $VSwitch.Name) -Status 'Host virtual adapters' -PercentComplete 75
		Write-Verbose -Message 'Loading management adapters connected to this switch'
		$HostVNICs = Get-VMNetworkAdapter -ManagementOS -SwitchName $VSwitch.Name

		Write-Verbose -Message 'Gathering management OS virtual NIC information'
		#$HostVNICData.AddRange($HostVNICs.ForEach({New-NetAdapterDataPack -VNIC $_ }))

		#$HostVNICs.ForEach({[NetAdapterDataPack]::new($_)})

		[SwitchDataPack]::new($VSwitch, $Team, $HostVNICs.ForEach({[NetAdapterDataPack]::new($_)}))
	}
}

# DHCP or no
# IP
# gateways
# DNS addresses
# DNS search suffixes
# DNS suffixes
# Register
# Use suffix in registration
# WINS
# LMHOSTS
# NetBIOS over TCP/IP