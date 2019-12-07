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

	function Get-CimAdapterSettingsFromVirtualAdapter
	{
		param(
			[Parameter()][psobject]$VNIC
		)
		$VnicCim = Get-CimInstance -Namespace root/virtualization/v2 -ClassName Msvm_InternalEthernetPort -Filter ('Name="{0}"' -f $VNIC.AdapterId)
		$VnicLanEndpoint1 = Get-CimAssociatedInstance -InputObject $VnicCim -ResultClassName Msvm_LANEndpoint
		$NetAdapter = Get-CimInstance -ClassName Win32_NetworkAdapter -Filter ('GUID="{0}"' -f $VnicLANEndpoint1.Name.Substring(($VnicLANEndpoint1.Name.IndexOf('{'))))
		Get-CimAssociatedInstance -InputObject $NetAdapter -ResultClassName Win32_NetworkAdapterConfiguration
	}

	class NetAdapterDataPack
	{
		[System.String]$Name
		[System.String]$MacAddress
		[System.Int64]$MinimumBandwidthAbsolute = 0
		[System.Int64]$MinimumBandwidthWeight = 0
		[System.Int64]$MaximumBandwidth = 0
		[System.Int32]$VlanId = 0
		[Microsoft.Management.Infrastructure.CimInstance]$NetAdapterConfiguration

		NetAdapterDataPack([psobject]$VNIC)
		{
			$this.Name = $VNIC.Name
			$this.MacAddress = $VNIC.MacAddress
			if ($VNIC.BandwidthSetting -ne $null)
			{
				$this.MinimumBandwidthAbsolute = $VNIC.BandwidthSetting.MinimumBandwidthAbsolute
				$this.MinimumBandwidthWeight = $VNIC.BandwidthSetting.MinimumBandwidthWeight
				$this.MaximumBandwidth = $VNIC.BandwidthSetting.MaximumBandwidth
			}

			$this.NetAdapterConfiguration = Get-CimAdapterSettingsFromVirtualAdapter -VNIC $VNIC
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
		[System.Boolean]$PacketDirect
		[NetAdapterDataPack[]]$HostVNICs
		[Microsoft.HyperV.PowerShell.VMNetworkAdapter[]]$GuestVNICs

		SwitchDataPack(
			[psobject]$VSwitch,
			[Microsoft.Management.Infrastructure.CimInstance]$Team,
			[System.Object[]]$VNICs,
			[Microsoft.HyperV.PowerShell.VMNetworkAdapter[]]$GuestVNICs
		)
		{
			$this.Name = $VSwitch.Name
			$this.BandwidthReservationMode = $VSwitch.BandwidthReservationMode
			switch ($this.BandwidthReservationMode)
			{
				[Microsoft.HyperV.PowerShell.VMSwitchBandwidthMode]::Absolute { $this.DefaultFlow = $VSwitch.DefaultFlowMinimumBandwidthAbsolute }
				[Microsoft.HyperV.PowerShell.VMSwitchBandwidthMode]::Weight { $this.DefaultFlow = $VSwitch.DefaultFlowMinimumBandwidthWeight }
				default { $this.DefaultFlow = 0 }
			}
			$this.TeamName = $Team.Name
			$this.TeamMembers = ((Get-CimAssociatedInstance -InputObject $Team -ResultClassName MSFT_NetLbfoTeamMember).Name)
			$this.LoadBalancingAlgorithm = $Team.LoadBalancingAlgorithm
			$this.PacketDirect = $VSwitch.PacketDirectEnabled
			$this.HostVNICs = $VNICs
			$this.GuestVNICs = $GuestVNICs
		}
	}

	function Set-CimAdapterProperty
	{
		param(
			[Parameter()][System.Object]$InputObject,
			[Parameter()][System.String]$MethodName,
			[Parameter()][System.Object]$Arguments,
			[Parameter()][System.String]$Activity,
			[Parameter()][System.String]$Url
		)

		Write-Verbose -Message $Activity
		$CimResult = Invoke-CimMethod -InputObject $InputObject -MethodName $MethodName -Arguments $Arguments -ErrorAction Continue

		if ($CimResult -and $CimResult.ReturnValue -gt 0 )
		{
			Write-Warning -Message ('CIM error from operation: {0}. Consult {1} for error code {2}' -f $Activity, $Url, $CimResult.ReturnValue) -WarningAction Continue
		}
	}
}

PROCESS
{
	$VMSwitches = New-Object System.Collections.ArrayList
	$SwitchRebuildData = New-Object System.Collections.ArrayList

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

	Write-Progress -Activity 'Pre-flight' -Status 'Verifying operating system version' -PercentComplete 5 -Id 1
	Write-Verbose -Message 'Verifying operating system version'
	$OSVersion = [System.Version]::Parse((Get-CimInstance -ClassName Win32_OperatingSystem).Version)
	if ($OSVersion.Major -lt 10)
	{
		throw('Switch-embedded teams not supported on host operating system versions before 2016')
	}

	Write-Progress -Activity 'Pre-flight' -Status 'Loading virtual VMswitches' -PercentComplete 15 -Id 1

	if ($NewName.Count -gt 0 -and $NewName.Count -ne $VMSwitches.Count)
	{
		$SwitchNameMismatchMessage = 'Switch count ({0}) does not match NewName count ({1}).' -f $VMSwitches.Count, $NewName.Count
		if ($NewName.Count -lt $VMSwitches.Count)
		{
			$SwitchNameMismatchMessage += ' If you wish to rename some VMswitches but not others, specify an empty string for the VMswitches to leave.'
		}
		throw($SwitchNameMismatchMessage)
	}

	Write-Progress -Activity 'Pre-flight' -Status 'Validating virtual switch configurations' -PercentComplete 25 -Id 1
	Write-Verbose -Message 'Validating virtual switches'
	foreach ($VSwitch in $VMSwitches)
	{
		try
		{
			Write-Progress -Activity ('Validating virtual switch "{0}"' -f $VSwitch.Name) -Status 'Switch is external' -PercentComplete 25 -ParentId 1
			Write-Verbose -Message ('Verifying that switch "{0}" is external' -f $VSwitch.Name)
			if ($VSwitch.SwitchType -ne [Microsoft.HyperV.PowerShell.VMSwitchType]::External)
			{
				Write-Warning -Message ('Switch "{0}" is not external, skipping' -f $VSwitch.Name)
				continue
			}

			Write-Progress -Activity ('Validating virtual switch "{0}"' -f $VSwitch.Name) -Status 'Switch is not a SET' -PercentComplete 50 -ParentId 1
			Write-Verbose -Message ('Verifying that switch "{0}" is not already a SET' -f $VSwitch.Name)
			if ($VSwitch.EmbeddedTeamingEnabled)
			{
				Write-Warning -Message ('Switch "{0}" already uses SET, skipping' -f $VSwitch.Name)
				continue
			}

			Write-Progress -Activity ('Validating virtual switch "{0}"' -f $VSwitch.Name) -Status 'Switch uses LBFO' -PercentComplete 75 -ParentId 1
			Write-Verbose -Message ('Verifying that switch "{0}" uses an LBFO team' -f $VSwitch.Name)
			$TeamAdapter = Get-CimInstance -Namespace root/StandardCimv2 -ClassName MSFT_NetLbfoTeamNic -Filter ('InterfaceDescription="{0}"' -f $VSwitch.NetAdapterInterfaceDescription)
			if ($TeamAdapter -eq $null)
			{
				Write-Warning -Message ('Switch "{0}" does not use a team, skipping' -f $VSwitch.Name)
				continue
			}
			if ($TeamAdapter.VlanID)
			{
				Write-Warning -Message ('Switch "{0}" is bound to a team NIC with a VLAN assignment, skipping' -f $VSwitch.Name)
				continue
			}
		}
		catch
		{
			Write-Warning -Message ('Switch "{0}" failed validation, skipping. Error: {1}' -f $VSwitch.Name, $_.Exception.Message)
			continue
		}
		finally
		{
			Write-Progress -Activity ('Validating virtual switch "{0}"' -f $VSwitch.Name) -Completed -ParentId 1
		}

		Write-Progress -Activity ('Loading information from virtual switch "{0}"' -f $VSwitch.Name) -Status 'Team NIC' -PercentComplete 25 -ParentId 1
		Write-Verbose -Message 'Loading team'
		$Team = Get-CimAssociatedInstance -InputObject $TeamAdapter -ResultClassName MSFT_NetLbfoTeam

		Write-Progress -Activity ('Loading information from virtual switch "{0}"' -f $VSwitch.Name) -Status 'Guest virtual adapters' -PercentComplete 50 -ParentId 1
		Write-Verbose -Message 'Loading VM adapters connected to this switch'
		$GuestVNICs = Get-VMNetworkAdapter -VMName * | Where-Object -Property SwitchName -EQ $VSwitch.Name

		Write-Progress -Activity ('Loading information from virtual switch "{0}"' -f $VSwitch.Name) -Status 'Host virtual adapters' -PercentComplete 75 -ParentId 1
		Write-Verbose -Message 'Loading management adapters connected to this switch'
		$HostVNICs = Get-VMNetworkAdapter -ManagementOS -SwitchName $VSwitch.Name

		Write-Verbose -Message 'Compiling virtual switch and management OS virtual NIC information'
		$OutNull = $SwitchRebuildData.Add([SwitchDataPack]::new($VSwitch, $Team, ($HostVNICs.ForEach({ [NetAdapterDataPack]::new($_) })), $GuestVNICs))
		Write-Progress -Activity ('Loading information from virtual switch "{0}"' -f $VSwitch.Name) -Completed
	}
	Write-Progress -Activity 'Pre-flight' -Status 'Cleaning up' -PercentComplete 99 -ParentId 1

	Write-Verbose -Message 'Clearing loop variables'
	$VSwitch = $Team = $TeamAdapter = $GuestVNICs = $HostVNICs = $null

	Write-Progress -Activity 'Pre-flight' -Completed

	if($SwitchRebuildData.Count -eq 0)
	{
		Write-Warning -Message 'No eligible virtual switches found.'
		exit 1
	}

	$SwitchMark = 0
	$SwitchCounter = 1
	$SwitchStep = 1 / $SwitchRebuildData.Count * 100

	foreach ($OldSwitchData in $SwitchRebuildData)
	{
		Write-Progress -Activity 'Rebuilding switches' -Status ('Processing virtual switch {0}/{1}' -f $SwitchCounter, $SwitchRebuildData.Count) -PercentComplete $SwitchMark -Id 1
		$SwitchCounter++
		$SwitchMark += $SwitchStep
		$ShouldProcessTargetText = 'Virtual switch {0}' -f $OldSwitchData.Name
		$ShouldProcessOperation = 'Disconnect all virtual adapters, remove team and switch, build switch-embedded team, replace management OS vNICs, reconnect virtual adapters'
		if ($PSCmdlet.ShouldProcess($ShouldProcessTargetText , $ShouldProcessOperation))
		{
			$SwitchProgressParams = @{Activity = ('Processing switch {0}' -f $OldSwitchData.Name); ParentId = 1; Id=2 }
			Write-Verbose -Message 'Disconnecting virtual machine adapters'
			Write-Progress @SwitchProgressParams -Status 'Disconnecting virtual machine adapters' -PercentComplete 10
			if($OldSwitchData.GuestVNICs)
			{
				Disconnect-VMNetworkAdapter -VMNetworkAdapter $OldSwitchData.GuestVNICs
			}

			if($OldSwitchData.HostVNICs)
			{
				Write-Verbose -Message 'Removing management vNICs'
				Write-Progress @SwitchProgressParams -Status 'Removing management vNICs' -PercentComplete 20
				Remove-VMNetworkAdapter -ManagementOS
			}

			Write-Verbose -Message 'Removing virtual switch'
			Write-Progress @SwitchProgressParams -Status 'Removing virtual switch' -PercentComplete 30
			Remove-VMSwitch -Name $OldSwitchData.Name -Force

			Write-Verbose -Message 'Removing team'
			Write-Progress @SwitchProgressParams -Status 'Removing team' -PercentComplete 40
			Remove-NetLbfoTeam -Name $OldSwitchData.TeamName -Confirm:$false

			Write-Verbose -Message 'Creating SET'
			Write-Progress @SwitchProgressParams -Status 'Creating SET' -PercentComplete 50
			$SetLoadBalancingAlgorithm = $null
			if (-not $UseDefaults)
			{
				if ($OldSwitchData.LoadBalancingAlgorithm -eq 5)
				{
					$SetLoadBalancingAlgorithm = [Microsoft.HyperV.PowerShell.VMSwitchLoadBalancingAlgorithm]::Dynamic # 5 is dynamic; https://docs.microsoft.com/en-us/previous-versions/windows/desktop/ndisimplatcimprov/msft-netlbfoteam
				}
				else # SET does not have LBFO's hash options for load-balancing; assume that the original switch used a non-Dynamic mode for a reason
				{
					$SetLoadBalancingAlgorithm = [Microsoft.HyperV.PowerShell.VMSwitchLoadBalancingAlgorithm]::HyperVPort
				}
			}
			if ($LoadBalancingAlgorithm)
			{
				$SetLoadBalancingAlgorithm = $LoadBalancingAlgorithm
			}

			$NewMinimumBandwidthMode = $null
			if(-not $UseDefaults)
			{
				$NewMinimumBandwidthMode = $OldSwitchData.BandwidthReservationMode
			}
			if ($MinimumBandwidthMode)
			{
				$NewMinimumBandwidthMode = $MinimumBandwidthMode
			}
			$NewSwitchParams = @{NetAdapterName=$OldSwitchData.TeamMembers}
			if($NewMinimumBandwidthMode)
			{
				$NewSwitchParams.Add('MinimumBandwidthMode', $NewMinimumBandwidthMode)
			}

			if ($EnablePacketDirect -or ($OldSwitchData.PacketDirect -and -not $UseDefaults))
			{
				$NewSwitchParams.Add('EnablePacketDirect', $true)
			}

			try
			{
				$NewSwitch = New-VMSwitch @NewSwitchParams -Name $OldSwitchData.Name -AllowManagementOS $false -EnableEmbeddedTeaming $true -Notes $Notes
			}
			catch
			{
				Write-Error -Message ('Unable to create virtual switch {0}: {1}' -f $OldSwitchData.Name, $_.Exception.Message) -ErrorAction Continue
				continue
			}

			if($SetLoadBalancingAlgorithm)
			{
				Write-Verbose -Message ('Setting load balancing mode to {0}' -f $SetLoadBalancingAlgorithm)
				Write-Progress @SwitchProgressParams -Status 'Setting SET load balancing algorithm' -PercentComplete 60
				$NewSwitchParams.Add('LoadBalancingAlgorithm', $SetLoadBalancingAlgorithm)
				Set-VMSwitchTeam -Name $NewSwitch.Name -LoadBalancingAlgorithm $SetLoadBalancingAlgorithm
			}

			$VNICCounter = 0

			foreach($VNIC in $OldSwitchData.HostVNICs)
			{
				$VNICCounter++
				Write-Progress @SwitchProgressParams -Status ('Configuring management OS vNIC {0}/{1}' -f $VNICCounter, $OldSwitchData.HostVNICs.Count) -PercentComplete 70

				$VNICProgressParams = @{Activity = ('Processing VNIC {0}' -f $VNIC.Name); ParentId = 2; Id=3 }

				Write-Verbose -Message ('Adding virtual adapter "{0}" to switch "{1}"' -f $VNIC.Name, $NewSwitch.Name)
				Write-Progress @VNICProgressParams -Status 'Adding vNIC' -PercentComplete 10
				$NewNic = Add-VMNetworkAdapter -SwitchName $NewSwitch.Name -ManagementOS -Name $VNIC.Name -StaticMacAddress $VNIC.MacAddress -Passthru
				$SetNicParams = @{ }
				if ($VNIC.MinimumBandwidthAbsolute)
				{
					$SetNicParams.Add('MinimumBandwidthAbsolute', $VNIC.MinimumBandwidthAbsolute)
				}
				elseif ($VNIC.MinimumBandwidthWeight)
				{
					$SetNicParams.Add('MinimumBandwidthWeight', $VNIC.MinimumBandwidthWeight)
				}
				if ($VNIC.MaximumBandwidth)
				{
					$SetNicParams.Add('MaximumBandwidth', $VNIC.MaximumBandwidth)
				}
				Write-Verbose -Message ('Setting properties on virtual adapter "{0}" on switch "{1}"' -f $VNIC.Name, $NewSwitch.Name)

				Write-Progress @VNICProgressParams -Status 'Setting vNIC parameters' -PercentComplete 20
				Set-VMNetworkAdapter -VMNetworkAdapter $NewNic @SetNicParams -ErrorAction Continue
				if($VNIC.VlanId)
				{
					Write-Progress @VNICProgressParams -Status 'Setting VLAN ID' -PercentComplete 30
					Write-Verbose -Message ('Setting VLAN ID on virtual adapter "{0}" on switch "{1}"' -f $VNIC.Name, $NewSwitch.Name)
					Set-VMNetworkAdapterVlan -VMNetworkAdapter $NewNic -Access -VlanId $VNIC.VlanId
				}
				$NewNicSettings = Get-CimAdapterSettingsFromVirtualAdapter -VNIC $NewNic

				if (-not ($VNIC.NetAdapterConfiguration.DHCPEnabled))
				{
					Write-Progress @VNICProgressParams -Status 'Setting DNS registration behavior' -PercentComplete 40
					Set-CimAdapterProperty -InputObject $NewNicSettings -MethodName 'SetDynamicDNSRegistration' `
					-Arguments @{ FullDNSRegistrationEnabled = $VNIC.NetAdapterConfiguration.FullDNSRegistrationEnabled; DomainDNSRegistrationEnabled = $VNIC.NetAdapterConfiguration.DomainDNSRegistrationEnabled } `
					-Activity ('Setting DNS registration behavior (dynamic registration: {0}, with domain name: {1}) on {2}' -f $VNIC.NetAdapterConfiguration.FullDNSRegistrationEnabled, $VNIC.NetAdapterConfiguration.DomainDNSRegistrationEnabled, $NewNic.Name) `
					-Url 'https://docs.microsoft.com/en-us/windows/win32/cimwin32prov/setdynamicdnsregistration-method-in-class-win32-networkadapterconfiguration'

					Write-Progress @VNICProgressParams -Status 'Setting IP and subnet masks' -PercentComplete 50
					# split up IP data because if EnableStatic doesn't like one thing in any IP/mask pair, it won't set anything at all
					$IPs = [System.Collections.ArrayList]$VNIC.NetAdapterConfiguration.IPAddress
					$SubnetMasks = [System.Collections.ArrayList]$VNIC.NetAdapterConfiguration.IPSubnet
					for ($i = 0; $i -lt $IPs.Count; $i++)
					{
						Set-CimAdapterProperty -InputObject $NewNicSettings -MethodName 'EnableStatic' `
							-Arguments @{ IPAddress = @($IPs[$i]); SubnetMask = @($SubnetMasks[$i]) } `
							-Activity ('Setting IP {0} and subnet mask {1} on {2}' -f $IPs[$i], $SubnetMasks[$i], $NewNic.Name) `
							-Url 'https://docs.microsoft.com/en-us/windows/win32/cimwin32prov/enablestatic-method-in-class-win32-networkadapterconfiguration'
					}

					Write-Progress @VNICProgressParams -Status 'Setting gateways' -PercentComplete 60
					if ($VNIC.NetAdapterConfiguration.DefaultIPGateway)
					{
						Set-CimAdapterProperty -InputObject $NewNicSettings -MethodName 'SetGateways' `
						-Arguments @{ DefaultIPGateway = $VNIC.NetAdapterConfiguration.DefaultIPGateway } `
						-Activity ('Setting gateways {0} on {1}'  -f $VNIC.NetAdapterConfiguration.DefaultIPGateway, $NewNic.Name) `
						-Url 'https://docs.microsoft.com/en-us/windows/win32/cimwin32prov/setgateways-method-in-class-win32-networkadapterconfiguration'
					}

					if($VNIC.NetAdapterConfiguration.DNSDomain)
					{
						Write-Progress @VNICProgressParams -Status 'Setting DNS domain' -PercentComplete 70
						Set-CimAdapterProperty -InputObject $NewNicSettings -MethodName 'SetDNSDomain' `
						-Arguments @{ DNSDomain = $VNIC.NetAdapterConfiguration.DNSDomain } `
						-Activity ('Setting DNS domain {0} on {1}' -f $VNIC.NetAdapterConfiguration.DNSDomain, $NewNic.Name) `
						-Url 'https://docs.microsoft.com/en-us/windows/win32/cimwin32prov/setdnsdomain-method-in-class-win32-networkadapterconfiguration'
					}

					if ($VNIC.NetAdapterConfiguration.DNSServerSearchOrder)
					{
						Write-Progress @VNICProgressParams -Status 'Setting DNS servers' -PercentComplete 80
						Set-CimAdapterProperty -InputObject $NewNicSettings -MethodName 'SetDNSServerSearchOrder' `
						-Arguments @{ DNSServerSearchOrder = $VNIC.NetAdapterConfiguration.DNSServerSearchOrder } `
						-Activity ('setting DNS servers {0} on {1}' -f [String]::Join(', ', $VNIC.NetAdapterConfiguration.DNSServerSearchOrder), $NewNic.Name) `
						-Url 'https://docs.microsoft.com/en-us/windows/win32/cimwin32prov/setdnsserversearchorder-method-in-class-win32-networkadapterconfiguration'
					}

					if($VNIC.NetAdapterConfiguration.WINSPrimaryServer)
					{
						Write-Progress @VNICProgressParams -Status 'Setting WINS servers' -PercentComplete 90
						Set-CimAdapterProperty -InputObject $NewNicSettings -MethodName 'SetWINSServer' `
						-Arguments @{ WINSPrimaryServer = $VNIC.NetAdapterConfiguration.WINSPrimaryServer; WINSSecondaryServer = $VNIC.NetAdapterConfiguration.WINSSecondaryServer }
						-Activity ('Setting WINS servers {0} on {1}' -f ([String]::Join(', ', $VNIC.NetAdapterConfiguration.WINSPrimaryServer, $VNIC.NetAdapterConfiguration.WINSSecondaryServer)), $NewNic.Name) `
						-Url 'https://docs.microsoft.com/en-us/windows/win32/cimwin32prov/setwinsserver-method-in-class-win32-networkadapterconfiguration'
					}

					Write-Progress @VNICProgressParams -Status 'Setting NetBIOS over TCP/IP behavior' -PercentComplete 100
					Set-CimAdapterProperty -InputObject $NewNicSettings -MethodName 'SetTcpipNetbios' `
					-Arguments @{ TcpipNetbiosOptions = $VNIC.NetAdapterConfiguration.TcpipNetbiosOptions } `
					-Activity ('Setting NetBIOS over TCP/IP behavior on {0} to {1}' -f $NewNic.Name, $VNIC.NetAdapterConfiguration.TcpipNetbiosOptions) `
					-Url 'https://docs.microsoft.com/en-us/windows/win32/cimwin32prov/settcpipnetbios-method-in-class-win32-networkadapterconfiguration'
				}
			}

			Write-Progress @VNICProgressParams -Completed

			Write-Progress @SwitchProgressParams -Status 'Reconnecting guest vNICs' -PercentComplete 80

			if($OldSwitchData.GuestVNICs)
			{
				foreach ($GuestVNIC in $OldSwitchData.GuestVNICs)
				{
					try
					{
						Connect-VMNetworkAdapter -VMNetworkAdapter $GuestVNIC -VMSwitch $NewSwitch
					}
					catch
					{
						Write-Error -Message ('Cannot connect virtual adapter "{0}" with MAC address "{1}" to virtual switch "{2}": {3}' -f $GuestVNIC.Name, $GuestVNIC.MacAddress, $NewSwitch.Name, $_.Exception.Message) -ErrorAction Continue
					}
				}
			}

			Write-Progress @SwitchProgressParams -Completed
		}
	}
}
