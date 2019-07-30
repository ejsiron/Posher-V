# Get-VMMacConflict

## SYNOPSIS

Creates a new Hyper-V virtual machine suitable for operating a Linux-based server.

## DESCRIPTION

Creates a new Hyper-V virtual machine suitable for operating a Linux-based server.
Compatible with Hyper-V version 2016 or later.
Makes the following Linux-friendly modifications to the VM:

* Generation 2
* Enables Secure Boot with the Microsoft UEFI authority
* Creates a dynamically-expanding VHDX with 1MB block sizes (superior space usage for ext* file systems, no known drawbacks for other file systems)
* Assigns a static MAC address to the virtual adapter

## SYNTAX

```PowerShell
    New-VMLinux.ps1 [-VMName] <String> [-VHDXName <String> [-VMStoragePath <String>] [-VHDStoragePath
    <String>] [-InstallISOPath <String>] [-Cluster] [-VMSwitchName <String>] [-CPUCount <UInt32>] [-StartupMemory <UInt32>] [-MinimumMemory <UInt32>] [-MaximumMemory <UInt32>] [-VHDXSizeBytes <UInt64>] [<CommonParameters>]
```

```PowerShell
    C:\Scripts\New-VMLinux.ps1 [-VMName] <String> [-VHDXName <String>] [-VMStoragePath <String>] [-VHDStoragePath
    <String>] [-NoDVD] [-Cluster] [-VMSwitchName <String>] [-CPUCount <UInt32>] [-StartupMemory <UInt32>] [-MinimumMemory <UInt32>] [-MaximumMemory <UInt32>] [-VHDXSizeBytes <UInt64>] [<CommonParameters>]
```

## EXAMPLES

### Example 1: Create a VM named "CentOS" that starts up to the CentOS ISO

```PowerShell
New-VMLinux -VMName svlcentos -InstallISOPath \\storage\isos\CentOS-7-x86_64-DVD-1810.iso
```

### Example 2: Same as example 1, adding to the cluster

```PowerShell
New-VMLinux -VMName svlcentos -InstallISOPath \\storage\isos\CentOS-7-x86_64-DVD-1810.iso -Cluster
```

### Example 3: Same as example 2, overriding the VHDX size

```PowerShell
New-VMLinux -VMName svlcentos -InstallISOPath \\storage\isos\CentOS-7-x86_64-DVD-1810.iso -Cluster -VHDXSizeBytes 60GB
```

## PARAMETERS

### -VMName

Name of the virtual machine to create.

```yaml
    Type: String
    Required: True
    Position: 1
    Default value: None
    Accept pipeline input: False
    Accept wildcard characters: False
```

### -VHDXName

Name of the VHDX file to create. Will use the name of the VM if not specified. Will automatically append .VHDX if necessary.

```yaml
    Type: String
    Required: False
    Position: Named
    Default value: None
    Accept pipeline input: False
    Accept wildcard characters: False
```

### -VMStoragePath

The path where the virtual machine's configuration files will be stored. Uses the host's default if not specified.

```yaml
    Type: String
    Required: False
    Position: Named
    Default value: None
    Accept pipeline input: False
    Accept wildcard characters: False
```

### -VHDStoragePath

The path where the virtual hard disk file will be stored. Uses the host's default if not specified.

```yaml
    Type: String
    Required: False
    Position: Named
    Default value: None
    Accept pipeline input: False
    Accept wildcard characters: False
```

### -InstallISOPath

If specified, attaches the indicated ISO to the VM and sets the VM to boot from DVD.

```yaml
    Type: String
    Required: False
    Position: Named
    Default value: None
    Accept pipeline input: False
    Accept wildcard characters: False
```

### -NoDVD

If set, will not create a virtual DVD for the VM. Cannot use with InstallISOPath.

```yaml
Type: SwitchParameter
Required: False
Position: Named
Default value: 0
Accept pipeline input: False
Accept wildcard characters: False
```

### -Cluster

If set, will add the virtual machine as a clustered resource.

```yaml
Type: SwitchParameter
Required: False
Position: Named
Default value: 0
Accept pipeline input: False
Accept wildcard characters: False
```

### -VMSwitchName

Name of the virtual switch to use. If not specified, selects the first external virtual switch.

```yaml
    Type: String
    Required: False
    Position: Named
    Default value: None
    Accept pipeline input: False
    Accept wildcard characters: False
```

### -CPUCount

Number of virtual CPUs to assign to the virtual machine. Uses 2 if not specified.

```yaml
    Type: UInt32
    Required: False
    Position: Named
    Default value: None
    Accept pipeline input: False
    Accept wildcard characters: False
```

### -StartupMemory

The amount of startup memory for the virtual machine. Uses 512MB if not specified.

```yaml
    Type: UInt32
    Required: False
    Position: Named
    Default value: None
    Accept pipeline input: False
    Accept wildcard characters: False
```

### -MinimumMemory

The minimum amount of memory to assign to the VM. Uses 256MB if not specified.

```yaml
    Type: UInt32
    Required: False
    Position: Named
    Default value: None
    Accept pipeline input: False
    Accept wildcard characters: False
```

### -MaximumMemory

The maximum amount of memory to assign to the VM. Uses 1GB if not specified.

```yaml
    Type: UInt32
    Required: False
    Position: Named
    Default value: None
    Accept pipeline input: False
    Accept wildcard characters: False
```

### -VHDXSizeBytes

The size of the virtual hard disk. Defaults to 40GB if not specified.

```yaml
    Type: UInt64
    Required: False
    Position: Named
    Default value: None
    Accept pipeline input: False
    Accept wildcard characters: False
```

## INPUTS

String[]

## OUTPUTS

None

## NOTES

v1.1, July 30, 2019
Author: Eric Siron
Released under MIT license
