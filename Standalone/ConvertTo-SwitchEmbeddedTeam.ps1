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
	[Parameter(Position = 2)][String[]]$NewName,
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
			[Parameter(Mandatory = $true)][Microsoft.HyperV.PowerShell.VMInternalNetworkAdapter]$VNIC
		)
		$ObjectPack = New-Object psobject
		Add-Member -InputObject $ObjectPack -Name VnicData -TypeName Microsoft.HyperV.PowerShell.VMInternalNetworkAdapter -Value $VNIC
		Add-Member -InputObject $ObjectPack -Name VlanData -TypeName Microsoft.HyperV.PowerShell.VMNetworkAdapterVlanSetting -Value (
			Get-VMNetworkAdapterVlan -ManagementOS -VMNetworkAdapter $VNIC
		)
		Add-Member -InputObject $ObjectPack

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


PROCESS
{
	$Switches = New-Object System.Collections.ArrayList

	switch (PSCmdlet.ParameterSetName)
	{
		'ByID'
		{
			$Switches.AddRange($Id.ForEach({ Get-VMSwitch -Id $_ }))
		}
		'BySwitchObject'
		{
			$Switches.AddRange($VMSwitch.ForEach({ $_ }))
		}
		default	# ByName
		{
			$NameList = New-Object System.Collections.ArrayList
			$NameList.AddRange($Name.ForEach({ $_.Trim() }))
			if ($NameList.Contains('') -or $NameList.Contains('*'))
			{
				$Switches = Get-VMSwitch
			}
			else
			{
				$Switches.AddRange($NameList.ForEach({ Get-VMSwitch -Name $_ }))
			}
		}
	}
	$Switches = Select-Object -InputObject $Switches -Unique
	if ($NewName.Count -gt 0 -and $NewName.Count -ne $Switches.Count)
	{
		$SwitchNameMismatchMessage = 'Switch count ({0}) does not match NewName count ({1}).' -f $Switches.Count, $NewName.Count
		if ($NewName.Count -lt $Switches.Count)
		{
			$SwitchNameMismatchMessage += ' If you wish to rename some switches but not others, specify an empty string for the switches to leave.'
		}
		Write-Error -Message $SwitchNameMismatchMessage
	}
	for ($i = 0; $i -lt $Switches.Count; $i++)
	{
		Write-Verbose -Message ('Verifying that switch "{0}" is external' -f $Switches[$i].Name)
		if ($Switches[$i].SwitchType -ne [Microsoft.HyperV.PowerShell.VMSwitchType]::External)
		{
			Write-Warning -Message ('Switch "{0}" is not external, skipping' -f $Switches[$i].Name)
			continue
		}

		Write-Verbose -Message ('Verifying that switch "{0}" is not already a SET' -f $Switches[$i].Name)
		if (-not $Switches[$i].EmbeddedTeamingEnabled)
		{
			Write-Warning -Message ('Switch "{0}" already uses SET, skipping' -f $Switches[$i].Name)
			continue
		}

		Write-Verbose -Message ('Verifying that switch "{0}" uses a standard team' -f $Switches[$i].Name)
		$AttachedAdapter = Get-NetAdapter -InterfaceDescription $Switches[$i].NetAdapterInterfaceDescription
		$TeamCIMAdapter = Get-CimInstance -Namespace root/StandardCimv2 -ClassName MSFT_NetLbfoTeamNic -Filter ('InstanceID="{{{0}}}"' -f ($Switches[$i].NetAdapterInterfaceGuid).Guid.ToUpper())
		if ($TeamCIMAdapter -eq $null)		
		{
			Write-Warning -Message ('Switch "{0}" does not use a team, skipping' -f $Switches[$i].Name)
			continue
		}
		if ($TeamCIMAdapter.VlanID)
		{
			Write-Warning -Message ('Switch "{0}" is bound to a team NIC with a VLAN assignment, skipping' -f $Switches[$i].Name)
			continue
		}

		Write-Verbose -Message 'Loading team'
		$Team = Get-NetLbfoTeam -TeamNicForTheTeam $TeamCIMAdapter
		
		Write-Verbose -Message 'Loading VM adapters connected to this switch'
		$GuestVNICs = Get-VMNetworkAdapter -VMName * | Where-Object -Property SwitchName -EQ $Switches[$i].Name

		Write-Verbose -Message 'Loading management adapters connected to this switch'
		$HostVNICs = Get-VMNetworkAdapter -ManagementOS -SwitchName $Switches[$i].Name


	}
}
