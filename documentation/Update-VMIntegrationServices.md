# Update-VMIntegrationServices.ps1

## SYNOPSIS

Installs the Hyper-V integration services into offline local virtual machines.

## DESCRIPTION

Installs the Hyper-V integration services into offline local virtual machines.
Built specifically to work on Windows Server 2012 R2 guests. Modify the default filenames and override $Path to use a different set of Integration Services.
Use the -Verbose switch for verification of successful installations.

## SYNTAX

### Default Parameter Set

```PowerShell
D:\code\Posher-V\Standalone\Update-VMIntegrationServices.ps1 [-VM] <PSObject[]> [-Path <String>] [<CommonParameters>]
```

### Try 32-bit and 64-bit CAB

```PowerShell
D:\code\Posher-V\Standalone\Update-VMIntegrationServices.ps1 [-VM] <PSObject[]> [-Path <String>] [-Try32and64] [<CommonParameters>]
```

### Use 32-bit CAB instead of 64-bit

```PowerShell
D:\code\Posher-V\Standalone\Update-VMIntegrationServices.ps1 [-VM] <PSObject[]> [-Path <String>] [-x86] [<CommonParameters>]
```

## EXAMPLES

### Example 1: Update a single 64-bit virtual machine by name

```PowerShell
C:\PS> Update-VMIntegrationServices -VMName vm04
```

Installs the x64 updates on the VM named vm04.

### Example 2: Try to install 32-bit and 64-bit CAB on all local virtual machines

```PowerShell
C:\PS> Get-VM | Update-VMIntegrationServices -Try32and64
```

Attempts to update all VMs. Will try to apply both 32 and 64 bit to see if either is applicable.

## PARAMETERS

### VM

The name or virtual machine object(s) (from Get-VM, etc.) to update.

```yaml
Type                         PSObject[]
Required?                    true
Position?                    1
Default value
Accept pipeline input?       true (ByValue)
Accept wildcard characters?  false
```

### Path

A valid path to the update CABs.  
MUST have sub-folders names \amd64 and \x86 with the necessary
Windows6.x-HyperVIntegrationServices-PLATFORM.cab.  
You can override the file names by editing the script.

```yaml
Type                         String
Required?                    false
Position?                    named
Default value                [String]::Empty
Accept pipeline input?       false
Accept wildcard characters?  false
```

### x86

Use the x86 update instead of x64.

```yaml
Type                         SwitchParameter
Required?                    false
Position?                    named
Default value                False
Accept pipeline input?       false
Accept wildcard characters?  false
```

### Try32and64

Attempt to install both the 32-bit and 64-bit updates. Use if you're not sure of the bitness of the contained guest.

```yaml
Type                         SwitchParameter
Required?                    false
Position?                    named
Default value                False
Accept pipeline input?       false
Accept wildcard characters?  false
```

## INPUTS

PSObject[] (output from Get-VM)
String[] (virtual machine names)

## OUTPUTS

None

## NOTES

Author: Eric Siron  
First publication: December 11, 2018  
Released under MIT license
