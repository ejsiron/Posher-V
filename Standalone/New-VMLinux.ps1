<#
.SYNOPSIS
Creates a new Hyper-V virtual machine suitable for operating a Linux-based server.
.DESCRIPTION
Creates a new Hyper-V virtual machine suitable for operating a Linux-based server.
Compatible with Hyper-V version 2016 or later.
Makes the following Linux-friendly modifications to the VM:
* Generation 2
* Enables Secure Boot with the Microsoft UEFI authority
* Creates a dynamically-expanding VHDX with 1MB block sizes (superior space usage for ext* file systems, no known drawbacks for other filesystems)
* Assigns a static MAC address to the virtual adapter
.PARAMETER VMName
Name of the virtual machine to create.
.PARAMETER VHDXName
Name of the VHDX file to create. Will use the name of the VM if not specified. Will automatically append .VHDX if necessary.
.PARAMETER VMStoragePath
The path where the virtual machine's configuration files will be stored. Uses the host's default if not specified.
.PARAMETER VHDStoragePath
The path where the virtual hard disk file will be stored. Uses the host's default if not specified.
.PARAMETER InstallISOPath
If specified, attaches the indicated ISO to the VM and sets the VM to boot from DVD.
.PARAMETER NoDVD
If set, will not create a virtual DVD for the VM. Cannot use with InstallISOPath.
.PARAMETER Cluster
If set, will add the virtual machine as a clustered resource.
.PARAMETER VMSwitchName
Name of the virtual switch to use. If not specified, selects the first external virtual switch. If no switch can be found, the script stops.
.PARAMETER CPUCount
Number of virtual CPUs to assign to the virtual machine. Uses 2 if not specified.
.PARAMETER StartupMemory
The amount of startup memory for the virtual machine. Uses 512MB if not specified.
.PARAMETER MinimumMemory
The minimum amount of memory to assign to the VM. Uses 256MB if not specified.
.PARAMETER MaximumMemory
The maximum amount of memory to assign to the VM. Uses 1GB if not specified.
.PARAMETER VHDXSizeBytes
The size of the virtual hard disk. Defaults to 40GB if not specified.
.NOTES
Must run directly on a Hyper-V host.
v1.2.0, October 9, 2019
.EXAMPLE
C:\Scripts\New-VMLinux -VMName svlcentos

Create a VM named "svlcentos" that uses all defaults.

.EXAMPLE
C:\Scripts\New-VMLinux -VMName svlcentos -InstallISOPath \\storage\isos\CentOS-7-x86_64-DVD-1810.iso

Create a VM named "svlcentos" that starts up to the CentOS ISO

.EXAMPLE
C:\Scripts\New-VMLinux -VMName svlcentos -InstallISOPath \\storage\isos\CentOS-7-x86_64-DVD-1810.iso -Cluster

Same as example 2, adding to the cluster

.EXAMPLE
C:\Scripts\New-VMLinux -VMName svlcentos -InstallISOPath \\storage\isos\CentOS-7-x86_64-DVD-1810.iso -Cluster -VHDXSizeBytes 60GB

Same as example 3, overriding the VHDX size

.LINK
https://ejsiron.github.io/Posher-V/New-VMLinux
#>
[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'DVD')]
param
(
    [Parameter(Mandatory = $true, Position = 1)][String]$VMName,
    [Parameter()][String]$VHDXName = '',
    [Parameter()][String]$VMStoragePath = '',
    [Parameter()][String]$VHDStoragePath = '',
    [Parameter(ParameterSetName = 'DVD')][String]$InstallISOPath = '',
    [Parameter(ParameterSetName = 'NoDVD')][Switch]$NoDVD,
    [Parameter()][Switch]$Cluster,
    [Parameter()][String]$VMSwitchName = '',
    [Parameter()][uint32]$CPUCount = 2,
    [Parameter()][Uint32]$StartupMemory = 512MB,
    [Parameter()][Uint32]$MinimumMemory = 256MB,
    [Parameter()][Uint32]$MaximumMemory = 1GB,
    [Parameter()][Uint64]$VHDXSizeBytes = 40GB
)
#requires -RunAsAdministrator
#requires -Modules Hyper-V

$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop

Write-Verbose -Message 'Validating VHDX name'
if ([String]::IsNullOrEmpty($VHDXName))
{
    $VHDXName = '{0}.vhdx' -f $VMName
    Write-Verbose -Message ('VHDX name not specified, using {0}' -f $VHDXName)
}
if ($VHDXName -notmatch '\.vhdx$')
{
    Write-Verbose -Message ('Appending .vhdx to {0}' -f $VHDXName)
    $VHDXName += '.vhdx'
}
Write-Verbose -Message 'Verifying virtual machine configuration storage path'
if ([String]::IsNullOrEmpty($VMStoragePath))
{
    Write-Verbose -Message 'Using host default virtual machine configuration storage path'
    $VMStoragePath = (Get-VMHost).VirtualMachinePath
}
if (-not (Test-Path -Path $VMStoragePath))
{
    Write-Error -Message ('VM path {0} does not exist.' -f $VMStoragePath)
}
Write-Verbose -Message 'Verifying virtual hard disk storage path'
if ([String]::IsNullOrEmpty($VHDStoragePath))
{
    Write-Verbose -Message 'Using host default virtual hard disk storage path'
    $VHDStoragePath = (Get-VMHost).VirtualHardDiskPath
}
if (-not (Test-Path -Path $VHDStoragePath))
{
    Write-Error -Message ('Virtual hard disk storage path {0} does not exist.' -f $VHDStoragePath)
}
$VHDStoragePath = Join-Path -Path $VHDStoragePath -ChildPath $VHDXName
Write-Verbose -Message 'Validating virtual DVD and ISO file settings'
if (-not $NoDVD -and -not [String]::IsNullOrEmpty($InstallISOPath) -and -not (Test-Path -Path $InstallISOPath -PathType Leaf))
{
    Write-Error -Message ('ISO file "{0}" does not exist' -f $InstallISOPath)
}
Write-Verbose -Message 'Verifying virtual switch'
if ([String]::IsNullOrEmpty($VMSwitchName))
{
    Write-Verbose -Message 'No virtual switch specified, looking for an external switch'
    $externalSwitches = @(Get-VMSwitch | Where-Object -Property SwitchType -EQ 'External')
    if ($externalSwitches.Count -eq 0)
    {
        Write-Error "No external Switches found, please add one or specify the internal one to be used."
    }
    else
    {
        $VMSwitchName = $externalSwitches[0].Name
        Write-Verbose -Message ('Using external Switch: {0}' -f $VMSwitchName)
    }
}

Write-Verbose -Message 'Creating the virtual machine'
$VM = New-VM -Name $VMName -MemoryStartupBytes $StartupMemory -SwitchName $VMSwitchName -Path $VMStoragePath -Generation 2 -NoVHD
Write-Verbose -Message 'Setting virtual machine memory'
Set-VMMemory -VM $VM -DynamicMemoryEnabled $true -MinimumBytes $MinimumMemory -MaximumBytes $MaximumMemory
Write-Verbose -Message 'Setting virtual CPU count'
Set-VMProcessor -VM $VM -Count $CPUCount
Write-Verbose -Message 'Starting the virtual machine so that it receives a non-zero MAC address'
Start-VM -VM $VM
Write-Verbose -Message 'Forcing the VM to stop so that configuration options can continue'
Stop-VM -VM $VM -TurnOff -Force
Write-Progress -Activity 'Waiting for VM to stabilize...'
Start-Sleep -Seconds 5
Write-Progress -Activity 'Waiting for VM to stabilize...' -Completed
Write-Verbose -Message 'Loading the virtual network adapter'
$VMNetAdapter = Get-VMNetworkAdapter -VM $VM
Write-Verbose -Message 'Setting the MAC address to static'
Set-VMNetworkAdapter -VM $VM -StaticMacAddress ($VMNetAdapter.MacAddress)
Write-Verbose -Message 'Creating the VHDX'
$VMVHD = New-VHD -Path $VHDStoragePath -SizeBytes $VHDXSizeBytes -Dynamic -BlockSizeBytes 1MB
Write-Verbose -Message 'Attaching the newly-created VHDX'
Add-VMHardDiskDrive -VM $VM -ControllerType SCSI -ControllerNumber 0 -ControllerLocation 0 -Path $VHDStoragePath
Write-Verbose -Message 'Configuring UEFI settings'
$VMFirmware = Set-VMFirmware -VM $VM -EnableSecureBoot On -SecureBootTemplate 'MicrosoftUEFICertificateAuthority' -Passthru
if ($NoDVD)
{
    Write-Verbose -Message 'Skipping virtual DVD configuration as instructed'
}
else
{
    $VMDVDDrive = Add-VMDvdDrive -VM $VM -ControllerNumber 0 -ControllerLocation 1 -Passthru
    if (-not ([String]::IsNullOrEmpty($InstallISOPath)))
    {
        Write-Verbose -Message ('Assigning ISO file "{0}"' -f $InstallISOPath)
        Set-VMDvdDrive -VMDvdDrive $VMDVDDrive -Path $InstallISOPath
        $NewBootOrder = New-Object System.Collections.ArrayList
        $OutNull = $NewBootOrder.Add($VMDVDDrive)
        foreach ($BootEntry in $VMFirmware.BootOrder)
        {
            if ($BootEntry.Device.Name -ne $VMDVDDrive.Name)
            {
                $OutNull = $NewBootOrder.Add($BootEntry)
            }
        }
        Write-Verbose -Message 'Assigning new boot order'
        Set-VMFirmware -VM $VM -BootOrder $NewBootOrder
    }
}

if ($Cluster)
{
    Write-Verbose -Message ('Adding VM {0} to the cluster' -f $VMName)
    $OutNull = Add-ClusterVirtualMachineRole -VMName $VMName
}
