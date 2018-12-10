# Get-VMMacConflict

## SYNOPSIS

Locate conflicting Hyper-V virtual network adapter MAC addresses.

## DESCRIPTION

Locate conflicting Hyper-V virtual network adapter MAC addresses. With default settings, will scan the indicated hosts and generate a report of all adapters, virtual and physical, that use the same MAC in the same VLAN.

Skips physical adapters bound by a virtual switch or team as these generate false positives.

## SYNTAX

```PowerShell
Get-VMMacConflict [[-ComputerName] <String[]>] [-ExcludeHost] [-ExcludeVlan]
    [-IncludeAllZero] [-IncludeDisconnected] [-IncludeDisabled] [-HostFile <String>] [-FileHasHeader]
    [-HeaderColumn <String>] [-Delimiter <Char>] [<CommonParameters>]
```

## EXAMPLES

### Example 1: Check local machine for duplicate VM MAC addresses

```PowerShell
PS C:\> Get-VMMacConflict
```

Checks the local machine for duplicate Hyper-V virtual machine MAC addresses. Includes active host adapters.

### Example 2: Check a single remote system for duplicate VM MAC addresses

```PowerShell
PS C:\> Get-VMMacConflict -ComputerName svhv1
```

Checks the Hyper-V system named "svhv1" for duplicate Hyper-V virtual machine MAC addresses. Includes active host adapters.

### Example 3: Check for duplicate VM MAC addresses across multiple remote hosts

```PowerShell
PS C:\> Get-VMMacConflict -ComputerName svhv1, svhv2, svhv3, svhv4
```

Checks all of the named Hyper-V systems for duplicate Hyper-V virtual machine MAC addresses. Includes active host adapters.

### Example 4: Import a file with a simple list of host names, scan them for duplicate VM MAC addresses

```PowerShell
PS C:\> Get-VMMacConflict -HostFile C:\hostnames.txt
```

Reads host names from C:\hostnames.txt; it must be header-less and either a single-column file of host names or all host names must be in the first column. VMs on these hosts are scanned for duplicate MAC addresses.

### Example 5: Import a host names file with a more complicated structure, scan the hosts for duplicate VM MAC addresses

```PowerShell
PS C:\> Get-VMMacConflict -HostFile C:\hostnames.txt -FileHasHeader -HeaderColumn HostName
```

Reads host names from C:\hostnames.txt; host names must be in a column named "HostName". VMs on these hosts are scanned for duplicate MAC addresses. Example file structure:

| HostOwner | HostName |
| - | - |
| Eric | svhv1 |
| Eric | svhv2 |
| Andy | svhv3 |
| Andy | svhv4 |

### Example 6: Import a multiple-column file with no headers, scan indicated hosts for duplicate VM MAC addresses

```PowerShell
PS C:\> Get-VMMacConflict -HostFile C:\hostnames.txt -HeaderColumn svhv1
```
Reads host names from C:\hostnames.txt; looks for host names in a header-less column starting with svhv1. VMs on these hosts are scanned for duplicate MAC addresses. Example file structure:

| | |
| - | - |
| Eric | svhv1 |
| Eric | svhv2 |
| Andy | svhv3 |
| Andy | svhv4 |

### Example 7: Scan the local host, consider MACs to be duplicated even if their adapters reside in different VLANs

```PowerShell
PS C:\> Get-VMMacConflict -ExcludeVlan
```

Checks the local machine for duplicate Hyper-V virtual machine MAC addresses, even if they are in distinct VLANs. Includes active host adapters.

### EXAMPLE 8: Scan the local host, include disabled and disconnected physical adapters

```PowerShell
PS C:\> Get-VMMacConflict -IncludeDisconnected -IncludeDisabled
```

Checks the local machine for duplicate Hyper-V virtual machine MAC addresses. Includes active host adapters, even if they are disconnected or disabled.

### EXAMPLE 9: Retrieve all information and show output in a grid

```PowerShell
PS C:\> Get-VMMacConflict -ComputerName svhv1, svhv2, svhv3, svhv4 -All | Out-GridView
```

Retrieves information about all active adapters from the specified hosts and displays a grid view.

## PARAMETERS

### -ComputerName

Name of one or more hosts running Hyper-V. If -HostFile is also set, uses both sources. If neither is set, uses the local system.

```yaml
Type: String[]
Required: False
Position: 1
Default value: None
Accept pipeline input: True (ByValue)
Accept wildcard characters: False
```

### -ExcludeHost

If set, will not examine host MAC addresses for conflicts.

```yaml
Type: SwitchParameter
Required: False
Position: Named
Default value: 0
Accept pipeline input: False
Accept wildcard characters: False
```

### -ExcludeVlan

If set, will treat identical MAC addresses in distinct subnets as conflicts.

```yaml
Type: SwitchParameter
Required: False
Position: Named
Default value: 0
Accept pipeline input: False
Accept wildcard characters: False
```

### -IncludeAllZero

If set, will include virtual NICs with an all-zero MAC.

```yaml
Type: SwitchParameter
Required: False
Position: Named
Default value: 0
Accept pipeline input: False
Accept wildcard characters: False
```

### -IncludeDisconnected

If set, will include enabled but unplugged management operating system adapters. No effect if ExcludeHost is set.

```yaml
Type: SwitchParameter
Required: False
Position: Named
Default value: 0
Accept pipeline input: False
Accept wildcard characters: False
```

### -IncludeDisabled

If set, will include disabled management operating system adapters. No effect if ExcludeHost is set.

```yaml
Type: SwitchParameter
Required: False
Position: Named
Default value: 0
Accept pipeline input: False
Accept wildcard characters: False
```

### -PathOnly

Instead of the discovered instances, returns the path(s) the search followed to find them.

Results are displayed in the format "SourceClassName/FirstAssociation/SecondAssociation/..."

```yaml
Type: SwitchParameter
Required: False
Position: Named
Default value: False
Accept pipeline input: False
Accept wildcard characters: False
```

### -PARAMETER HostFile

If provided, reads host names from the specified file. If -ComputerName is also set, uses both sources. If neither is set, uses the local system.

```yaml
Type: String
Required: False
Position: Named
Default value: False
Accept pipeline input: False
Accept wildcard characters: False
```

### -FileHasHeader

If set, the first row in the file will be treated as a header row.
If not set, the parser will assume the first column contains host names.
Ignored if HostFile is not specified.

```yaml
Type: SwitchParameter
Required: False
Position: Named
Default value: False
Accept pipeline input: False
Accept wildcard characters: False
```

### -HeaderColumn

If HostFile is a delimited type, use this to indicate which column contains the host names.
If -HeaderColumn is set, but -FileHeader is NOT set, then this value will be treated as a column header AND a host name.
If not set and the file is delimited, the first column will be used.
Ignored if HostFile is not specified.

```yaml
Type: String
Required: False
Position: Named
Default value: False
Accept pipeline input: False
Accept wildcard characters: False
```

### -PARAMETER Delimiter

The parser will treat this character as the delimiter in -HostFile. Defaults to the separator defined in the local machine's current culture.
Ignored if HostFile is not specified.

```yaml
Type: Char
Required: False
Position: Named
Default value: Current culture default separator
Accept pipeline input: False
Accept wildcard characters: False
```

### -All

Output all information on every discovered adapter.

```yaml
Type: SwitchParameter
Required: False
Position: Named
Default value: 0
Accept pipeline input: False
Accept wildcard characters: False
```

## INPUTS

String[]

## OUTPUTS

**System.Management.Automation.PSObject[]**
A custom object with the following properties:

- *VMName*: Name of the virtual machine; blank if the adapter belongs to the management operating system
- *VmID*: Virtual machine GUID. Will have the same name as the host if the adapter belongs to the management operating system
- *ComputerName*: Physical host name
- *AdapterName*: Friendly name of the adapter
- *AdapterID*: Adapter GUID. For physical adapters, the Device GUID
- *MacAddress*: Adapter's MAC address
- *IsStatic*: True if the MAC is statically assigned, False if dynamic
- *SwitchName*: Name of the connected virtual switch, if any
- *Vlan*: VLAN of the adapter, if any. If the adapter is in private mode, will display as N:X, where N is the primary VLAN and X is the secondary

## NOTES

Author: Eric Siron

First publication: December 7, 2018

Released under MIT license
