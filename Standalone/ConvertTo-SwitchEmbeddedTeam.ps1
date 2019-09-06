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

.PARAMETER CimSession
	Runs the cmdlet in a remote session or on a remote computer. Enter a computer name or a session object, such as the output of a New-CimSession or Get-CimSession cmdlet. The default is the current session on the local computer.
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
	[Parameter()][String]$Notes = '',
	[Parameter()][Microsoft.Management.Infrastructure.CimSession]$CimSession
)

BEGIN
{
	$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
	$CimSessionParam = @{ }
	if ($CimSession)
	{
		$CimSessionParam = @{CimSession = $CimSession }
	}

	$Switches = New-Object System.Collections.ArrayList

	switch ($PSCmdlet.ParameterSetName)
	{
		'ByID'
		{
			$Switches.AddRange($Id.ForEach({ Get-VMSwitch -Id $_ @CimSessionParam }))
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
				$Switches = Get-VMSwitch @CimSessionParam
			}
			else
			{
				$Switches.AddRange($NameList.ForEach({ Get-VMSwitch -Name $_ @CimSessionParam }))
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
	$Switches
}

PROCESS
{
	
}
