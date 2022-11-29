# Clear-VMPlanned

## SYNOPSIS

Cleans up after partially completed virtual machine import jobs.

## DESCRIPTION

Cleans up after partially completed virtual machine import jobs. Does not delete any hard disk files.

During operations that duplicate a virtual machine, Hyper-V uses staging CIM objects. Official Hyper-V tools clean up after any problems. Third party and testing scripts and applications may leave artifacts of "Msvm_PlannedComputerSystem".

Ensure that the target host has no active jobs as this script will cause unpredictable problems.

## SYNTAX

```PowerShell
Clear-VMPlanned.ps1 [[-ComputerName] <String>]
```

## EXAMPLES

### Example 1

Removes all staging virtual machines from the local host.

```PowerShell
Clear-VMPlanned.ps1
```

### Example 2

Removes all staging virtual machines from the host named "HYPERV1".

```PowerShell
Clear-VMPlanned.ps1 -ComputerName 'HYPERV1'
```

## PARAMETERS

### ComputerName

The name of the staging virtual machines' host.

```yaml
Type                         String
Required?                    false
Position?                    1
Default value                localhost
Accept pipeline input?       true
Accept wildcard characters?  false
```

## NOTES

Author: Eric Siron

Version 1.0, November 29, 2022

Released under MIT license
