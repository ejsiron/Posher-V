<#
.SYNOPSIS
Installs the Hyper-V integration services into offline local virtual machines.
.DESCRIPTION
Installs the Hyper-V integration services into offline local virtual machines.
Built specifically to work on Windows Server 2012 R2 guests. Modify the default filenames and override $Path to use a different set of Integration Services.
Use the -Verbose switch for verification of successful installations.
.PARAMETER VM
The name or virtual machine object(s) (from Get-VM, etc.) to update.
.PARAMETER Path
A valid path to the update CABs.
MUST have sub-folders names \amd64 and \x86 with the necessary Windows6.x-HyperVIntegrationServices-PLATFORM.cab.
You can override the file names by editing the script.
.PARAMETER x86
Use the x86 update instead of x64.
.PARAMETER Try32and64
Attempt to install both the 32-bit and 64-bit updates. Use if you're not sure of the bitness of the contained guest.
.EXAMPLE
C:\PS> Update-VMIntegrationServices -VMName vm04
Installs the x64 updates on the VM named vm04.
.EXAMPLE
C:\PS> Get-VM | Update-VMIntegrationServices -Try32and64
Attempts to update all VMs. Will try to apply both 32 and 64 bit to see if either is applicable.
.NOTES
Author: Eric Siron
Version 1.0, December 11, 2018
Released under MIT license
.LINK
https://github.com/ejsiron/Posher-V/blob/master/docs/Update-VMIntegrationServices.md
#>
[CmdletBinding(DefaultParameterSetName='Default')]
param(
    [Parameter(Mandatory = $true, Position = 1, ValueFromPipeline = $true, ParameterSetName='Default')]
    [Parameter(Mandatory = $true, Position = 1, ValueFromPipeline = $true, ParameterSetName='x86Only')]
    [Parameter(Mandatory = $true, Position = 1, ValueFromPipeline = $true, ParameterSetName='TryBoth')]
    [psobject[]]$VM,
    [Parameter(ParameterSetName='Default')]
    [Parameter(ParameterSetName = 'x86Only')]
    [Parameter(ParameterSetName = 'TryBoth')]
    [String]$Path = [String]::Empty,
	[Parameter(ParameterSetName = 'x86Only')][Switch]$x86,
	[Parameter(ParameterSetName = 'TryBoth')][Switch]$Try32and64
)

#requires -Version 4
#requires -RunAsAdministrator
#requires -Module Hyper-V

begin
{
	Set-StrictMode -Version Latest
	$DefaultPath = Join-Path -Path $env:SystemRoot -ChildPath 'vmguest\support'
	$x64UpdateFile = '\amd64\Windows6.x-HyperVIntegrationServices-x64.cab'
	$x86UpdateFile = '\x86\Windows6.x-HyperVIntegrationServices-x86.cab'

	if ([String]::IsNullOrEmpty($Path)) { $Path = $DefaultPath }
	$Path = (Resolve-Path -Path $Path -ErrorAction Stop).Path
	$UpdateFiles = New-Object -TypeName System.Collections.ArrayList
	if ($x86 -or $Try32and64)
	{
		$OutNull = $UpdateFiles.Add((Resolve-Path -Path (Join-Path -Path $Path -ChildPath $x86UpdateFile) -ErrorAction Stop).Path)
	}
	if (-not $Try32and64)
	{
		$OutNull = $UpdateFiles.Add((Resolve-Path -Path (Join-Path -Path $Path -ChildPath $x64UpdateFile) -ErrorAction Stop).Path)
	}
}

process
{
    if($VM.Count -eq 0) { exit 0 }
    $VMParamType = $VM[0].GetType().FullName
    switch($VMParamType)
    {
        'Microsoft.HyperV.PowerShell.VirtualMachine' {
            # preferred condition so do nothing; just capture the condition
        }
        'System.String' {
            $VM = Get-VM -Name $VM
        }
        default {
            Write-Error -Message ('Cannot work with objects of type {0}' -f $VMParamType) -ErrorAction Stop
        }
    }

	foreach ($Machine in $VM)
	{
		Write-Progress -Activity 'Adding current integration components to VMs' -Status $Machine.Name -Id 7 # ID just so it doesn't collide with Add-WindowsPackage or *-DiskImage
		if ($Machine.State -eq [Microsoft.HyperV.PowerShell.VMState]::Off)
		{
			$VMHDParams = @{
				VM                 = $Machine;
				ControllerType     = [Microsoft.HyperV.PowerShell.ControllerType]::IDE;
				ControllerNumber   = 0;
				ControllerLocation = 0
			}

			if ($Machine.Generation -eq 2)
			{
				$VMHDParams.ControllerType = [Microsoft.HyperV.PowerShell.ControllerType]::SCSI
			}

			$VHDPath = [String]::Empty
			try
			{
				$VHDPath = (Get-VMHardDiskDrive @VMHDParams).Path	
			}
			catch
			{
				Write-Warning ('VM "{0}" has no primary hard drive' -f $Machine.Name)
			}

            $DiskNum = (Mount-VHD -Path $VHDPath -Passthru).DiskNumber
            $DriveLetters = (Get-Disk $DiskNum | Get-Partition).DriveLetter
            if ((Get-Disk $DiskNum).OperationalStatus -ne 'Online')
            {
                Set-Disk $MountedVHD.Number -IsOffline:$false -IsReadOnly:$false
                Set-Disk -Number $DiskNum -IsOffline $false
                Set-Disk -Number $DiskNum -IsReadOnly $false
            }

            #Install the patch
            $TargetDriveLetter = ''
            foreach ($DriveLetter in $DriveLetters)
            {
                if (Test-Path ($DriveLetter + ':\Windows'))
                {
                    $TargetDriveLetter = $DriveLetter
                }
            }

            if($DriveLetter)
            {
                foreach ($UpdateFile in $UpdateFiles)
                {
                    try
                    {
                        $OutNull = Add-WindowsPackage -PackagePath $UpdateFile -Path ($TargetDriveLetter + ':\') -ErrorAction Stop	
                    }
                    catch
                    {
                        # Add-WindowsPackage writes to the warning and the error stream on errors so let its warning speak for itself
                        # Only include more information for an unnecessary patch
                        if ($_.Exception.ErrorCode -eq 0x800f081e)
                        {
                            Write-Warning 'This package is not applicable'
                        }
                    }
                }
            }
            else
            {
                Write-Error -Message ('No drive on VM {0} has a \Windows folder' -f $Machine.Name) -ErrorAction Continue
            }

            Dismount-VHD -Path $VHDPath
		}
		else
		{
			Write-Warning -Message ('{0} cannot be updated because it is not in an Off state' -f $Machine.Name)
		}
	}
}
