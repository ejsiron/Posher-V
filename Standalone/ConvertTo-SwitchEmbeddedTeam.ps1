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

.PARAMETER EnableIOV
	Attempts to enable SR-IOV on the converted switch(es). If not specified, uses the same setting as the original LBFO+switch or the default if UseDefaults is set.

.PARAMETER EnablePacketDirect
	Attempts to enable packet direct on the converted switch(es). If not specified, uses the same setting as the original LBFO+switch or the default if UseDefaults is set.

.PARAMETER MinimumBandwidthMode
	Sets the desired QoS mode for the converted switch(es). If not specified, uses the same setting as the original LBFO+switch or the default if UseDefaults is set.
	
	None: No network QoS
	Absolute: minimum bandwidth values specify bits per second
	Weight: minimum bandwidth values range from 1 to 100 and represent percentages
	Default: use Absolute QoS

.PARAMETER Notes
	A note to associate with the converted switch(es). If not specified, uses the same setting as the original LBFO+switch or the default if UseDefaults is set.
#>

#requires -Module Hyper-V

[CmdletBinding(DefaultParameterSetName = 'ByName', ConfirmImpact = 'High')]
param(
	[Parameter(Position = 1, ParameterSetName = 'ByName')][String[]]$Name = @(''),
	[Parameter(Position = 1, ParameterSetName = 'ByID', Mandatory = $true)][System.Guid[]]$Id,
	[Parameter(Position = 1, ParameterSetName = 'BySwitchObject', Mandatory = $true)][Microsoft.HyperV.PowerShell.VMSwitch[]]$VMSwitch,
	[Parameter(Position = 2)][String[]]$NewName = @(),
	[Parameter()][Switch]$UseDefaults,
	[Parameter()][Switch]$EnableIOV,
	[Parameter()][Switch]$EnablePacketDirect,
	[Parameter()][Microsoft.HyperV.PowerShell.VMSwitchBandwidthMode]$MinimumBandwidthMode = [Microsoft.HyperV.PowerShell.VMSwitchBandwidthMode]::Absolute,
	[Parameter()][String]$Notes = ''
)

BEGIN
{
	Set-StrictMode -Version Latest
	$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
	
	function New-NetAdapterObjectPack
	{
		param(
			[Parameter(Mandatory = $true)]$VNIC
		)
		
		$VLANData = Get-VMNetworkAdapterVlan -VMNetworkAdapter $VNIC
		$VnicCim = Get-CimInstance -Namespace root/virtualization/v2 -ClassName Msvm_InternalEthernetPort -Filter ('Name="{0}"' -f $VNIC.AdapterId)
		$VnicLanEndpoint1 = Get-CimAssociatedInstance -InputObject $VnicCim -ResultClassName Msvm_LANEndpoint
		$NetAdapter = Get-CimInstance -ClassName Win32_NetworkAdapter -Filter ('GUID="{0}"' -f $VnicLANEndpoint1.Name.Substring(($VnicLANEndpoint1.Name.IndexOf('{'))))
		$NetAdapterConfiguration = Get-CimAssociatedInstance -InputObject $NetAdapter -ResultClassName Win32_NetworkAdapterConfiguration
		$MinimumBandwidthAbsolute = 0
		$MinimumBandwidthWeight = 0
		$MaximumBandwidth = 0

		if ($VNIC.BandwidthSetting -ne $null)
		{
			$MinimumBandwidthAbsolute = $VNIC.BandwidthSetting.MinimumBandwidthAbsolute
			$MinimumBandwidthWeight = $VNIC.BandwidthSetting.MinimumBandwidthWeight
			$MaximumBandwidth = $VNIC.BandwidthSetting.MaximumBandwidth
		}

		$ObjectPack = New-Object psobject
		$OBParams = @{InputObject = $ObjectPack; MemberType = 'NoteProperty' }
		Add-Member @OBParams -Name NicName -TypeName System.String -Value $VNIC.Name
		Add-Member @OBParams -Name SwitchName -TypeName System.String -Value $VNIC.SwitchName
		Add-Member @OBParams -Name MacAddress -TypeName System.String -Value $VNIC.MacAddress
		Add-Member @OBParams -Name MinimumBandwidthAbsolute -TypeName System.Int64 -Value $MinimumBandwidthAbsolute
		Add-Member @OBParams -Name MinimumBandwidthWeight -TypeName System.Int64 -Value $MinimumBandwidthWeight
		Add-Member @OBParams -Name MaximumBandwidth -TypeName System.Int64 -Value $MaximumBandwidth
		Add-Member @OBParams -Name VLANID -TypeName System.Int32 -Value $VLANData.AccessVlanId
		Add-Member @OBParams -Name AdapterConfiguration -TypeName Microsoft.Management.Infrastructure.CimInstance -Value $NetAdapterConfiguration

		$ObjectPack
	}
}

PROCESS
{
	$Switches = New-Object System.Collections.ArrayList
	$HostVNICData = New-Object System.Collections.ArrayList

	switch ($PSCmdlet.ParameterSetName)
	{
		'ByID'
		{
			$Switches.AddRange($Id.ForEach( { Get-VMSwitch -Id $_ }))
		}
		'BySwitchObject'
		{
			$Switches.AddRange($VMSwitch.ForEach( { $_ }))
		}
		default	# ByName
		{
			$NameList = New-Object System.Collections.ArrayList
			$NameList.AddRange($Name.ForEach( { $_.Trim() }))
			if ($NameList.Contains('') -or $NameList.Contains('*'))
			{
				$Switches.AddRange(@(Get-VMSwitch))
			}
			else
			{
				$Switches.AddRange($NameList.ForEach( { Get-VMSwitch -Name $_ }))
			}
		}
	}
	if ($Switches.Count)
	{
		$Switches = @(Select-Object -InputObject $Switches -Unique)
	}
	else
	{
		throw('No virtual switches match the provided criteria')
	}

	Write-Progress -Activity 'Pre-flight' -Status 'Verifying operating system version' -PercentComplete 5
	Write-Verbose -Message 'Verifying operating system version'
	$OSVersion = [System.Version]::Parse((Get-CimInstance -ClassName Win32_OperatingSystem).Version)
	if ($OSVersion.Major -lt 10)
	{
		throw('Switch-embedded teams not supported on host operating system versions before 2016')
	}

	Write-Progress -Activity 'Pre-flight' -Status 'Loading virtual switches' -PercentComplete 15

	if ($NewName.Count -gt 0 -and $NewName.Count -ne $Switches.Count)
	{
		$SwitchNameMismatchMessage = 'Switch count ({0}) does not match NewName count ({1}).' -f $Switches.Count, $NewName.Count
		if ($NewName.Count -lt $Switches.Count)
		{
			$SwitchNameMismatchMessage += ' If you wish to rename some switches but not others, specify an empty string for the switches to leave.'
		}
		throw($SwitchNameMismatchMessage)
	}

	Write-Progress -Activity 'Pre-flight' -Status 'Validating virtual switch configurations' -PercentComplete 25
	foreach ($Switch in $Switches)
	{
		try
		{
			Write-Progress -Activity ('Validating virtual switch "{0}"' -f $Switch.Name) -Status 'Switch is external' -PercentComplete 25
			Write-Verbose -Message ('Verifying that switch "{0}" is external' -f $Switch.Name)
			if ($Switch.SwitchType -ne [Microsoft.HyperV.PowerShell.VMSwitchType]::External)
			{
				Write-Warning -Message ('Switch "{0}" is not external, skipping' -f $Switch.Name) -WarningAction Stop
			}

			Write-Progress -Activity ('Validating virtual switch "{0}"' -f $Switch.Name) -Status 'Switch is not a SET' -PercentComplete 50
			Write-Verbose -Message ('Verifying that switch "{0}" is not already a SET' -f $Switch.Name)
			if ($Switch.EmbeddedTeamingEnabled)
			{
				Write-Warning -Message ('Switch "{0}" already uses SET, skipping' -f $Switch.Name) -WarningAction Stop
			}

			Write-Progress -Activity ('Validating virtual switch "{0}"' -f $Switch.Name) -Status 'Switch uses LBFO' -PercentComplete 75
			Write-Verbose -Message ('Verifying that switch "{0}" uses an LBFO team' -f $Switch.Name)
			$TeamAdapter = Get-CimInstance -Namespace root/StandardCimv2 -ClassName MSFT_NetLbfoTeamNic -Filter ('InterfaceDescription="{0}"' -f $Switch.NetAdapterInterfaceDescription)
			if ($TeamAdapter -eq $null)
			{
				Write-Warning -Message ('Switch "{0}" does not use a team, skipping' -f $Switch.Name) -WarningAction Stop
			}
			if ($TeamAdapter.VlanID)
			{
				Write-Warning -Message ('Switch "{0}" is bound to a team NIC with a VLAN assignment, skipping' -f $Switch.Name) -WarningAction Stop
			}	
		}
		catch
		{
			continue
		}
		finally
		{
			Write-Progress -Activity ('Validating virtual switch "{0}"' -f $Switch.Name) -Completed
		}

		Write-Progress -Activity ('Loading information from virtual switch "{0}"' -f $Switch.Name) -Status 'Team NIC' -PercentComplete 25
		Write-Verbose -Message 'Loading team'
		$Team = Get-CimAssociatedInstance -InputObject $TeamAdapter -ResultClassName MSFT_NetLbfoTeam
		
		Write-Progress -Activity ('Loading information from virtual switch "{0}"' -f $Switch.Name) -Status 'Guest virtual adapters' -PercentComplete 50
		Write-Verbose -Message 'Loading VM adapters connected to this switch'
		$GuestVNICs = Get-VMNetworkAdapter -VMName * | Where-Object -Property SwitchName -EQ $Switch.Name

		Write-Progress -Activity ('Loading information from virtual switch "{0}"' -f $Switch.Name) -Status 'Host virtual adapters' -PercentComplete 75
		Write-Verbose -Message 'Loading management adapters connected to this switch'
		$HostVNICs = Get-VMNetworkAdapter -ManagementOS -SwitchName $Switch.Name

		Write-Verbose -Message 'Gathering management OS virtual NIC information'
		$HostVNICData.AddRange((ForEach-Object -InputObject $HostVNICs -Process { New-NetAdapterObjectPack -VNIC $_ } ))

		$HostVNICData
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