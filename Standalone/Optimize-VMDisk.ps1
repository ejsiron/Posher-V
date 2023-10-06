<#
.SYNOPSIS
	Compacts VHD/X files attached to a Hyper-V virtual machine.
.DESCRIPTION
	Compacts VHD/X files attached to a Hyper-V virtual machine. Takes the virtual machine offline if possible. Will skip a VM with a logged-on session unless -Force specified.
.PARAMETER VM
	The VM that owns the disk(s) to compact. Will not work on a remote system.
.PARAMETER Force
	Forces a running virtual machine to shut down even if it has an active session.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param
(
	[Parameter(Mandatory = $true)][psobject]$VM,
	[Parameter()][Switch]$Force
)
#requires -RunAsAdministrator
#requires -Modules Hyper-V

begin
{
	$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
}
process
{
	$VM = Get-VM $VM -WarningAction Stop	# deliberately uses positional parameter to ensure that we have a valid virtual machine
	$IsRunning = $VM.State -eq [Microsoft.HyperV.PowerShell.VMState]::Running
	if ($IsRunning)
	{
		Stop-VM -VM $VM -Force:$Force
	}
	$VMDiskArray = Get-VMHardDiskDrive -VM $VM | Where-Object -Property Path -Match 'vhd' -ErrorAction SilentlyContinue
	foreach ($VMDisk in $VMDiskArray)
	{
		$DriveLetterArray = New-Object -TypeName System.Collections.ArrayList
		try
		{
			Write-Verbose -Message ('Checking disk information for "{0}"' -f $VMDisk.Path)
			$MountInfo = Mount-VHD -Path $VMDisk.Path -Passthru
			foreach ($VPartition in Get-Partition -DiskNumber $MountInfo.DiskNumber -ErrorAction Stop)
			{
				Write-Verbose -Message 'Checking mounted partition for volumes...'
				foreach ($VVolume in Get-Volume -Partition $VPartition)
				{
					Write-Verbose -Message 'Checking mounted volume for drive letters...'
					$DriveLetter = $VVolume.DriveLetter
					if ($DriveLetter)
					{
						$OutNull = $DriveLetterArray.Add($DriveLetter)
					}
				}
			}
		}
		catch
		{
			Write-Verbose -Message ('An error occurred while discovering partitions or volumes, volume optimization skipped: "{0}"' -f $_.Exception.Message)
		}
		foreach ($DriveLetter in $DriveLetterArray)
		{
			Optimize-Volume -DriveLetter $DriveLetter -SlabConsolidate -ReTrim
		}
		Dismount-VHD -Path $VMDisk.Path
		Mount-VHD -Path $VMDisk.Path -ReadOnly
		Optimize-VHD -Path $VMDisk.Path -Mode Full
		Dismount-VHD -Path $VMDisk.Path
	}
	if ($IsRunning)
	{
		Start-VM -VM $VM
	}
}
