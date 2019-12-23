# ConvertTo-SwitchEmbeddedTeam

## SYNOPSIS

Converts LBFO+Virtual Switch combinations to switch-embedded teams.

## DESCRIPTION

Converts LBFO+Virtual Switch combinations to switch-embedded teams.

Performs the following steps:

1. Saves information about virtual switches and management OS vNICs (includes IPs, QoS settings, jumbo frame info, etc.)
2. If system belongs to a cluster, sets to maintenance mode
3. Disconnects attached virtual machine vNICs
4. Deletes the virtual switch
5. Deletes the LBFO team
6. Creates switch-embedded team
7. Recreates management OS vNICs
8. Reconnects previously-attached virtual machine vNICs
9. If system belongs to a cluster, ends maintenance mode

If you do not specify any overriding parameters, the new switch uses the same settings as the original LBFO+team.

## SYNTAX

### By Virtual Switch Name (Default)

```PowerShell
ConvertTo-SwitchEmbeddedTeam.ps1 [[-Name] <String[]>] [[-NewName] <String[]>] [-UseDefaults]
    [-LoadBalancingAlgorithm {HyperVPort | Dynamic}] [-MinimumBandwidthMode {Default | Weight | Absolute | None}]
    [-Notes <String>] [-Force] [<CommonParameters>]
```

### By Virtual Switch ID

```PowerShell
ConvertTo-SwitchEmbeddedTeam.ps1 [-Id] <Guid[]> [[-NewName] <String[]>] [-UseDefaults]
    [-LoadBalancingAlgorithm {HyperVPort | Dynamic}] [-MinimumBandwidthMode {Default | Weight | Absolute | None}]
    [-Notes <String>] [-Force] [<CommonParameters>]
```

### By Virtual Switch Object

```PowerShell
ConvertTo-SwitchEmbeddedTeam.ps1 [-VMSwitch] <VMSwitch[]> [[-NewName] <String[]>]
    [-UseDefaults] [-LoadBalancingAlgorithm {HyperVPort | Dynamic}] [-MinimumBandwidthMode {Default | Weight | Absolute | None}]
    [-Notes <String>] [-Force] [<CommonParameters>]
```

## EXAMPLES

### Example 1

Converts all existing LBFO+switch combinations to switch embedded teams. Copies settings from original switches and management OS virtual NICs to new switch and vNICs.

```PowerShell
ConvertTo-SwitchEmbeddedTeam
```

### Example 2

Converts the LBFO+switch combination of the virtual switch named "vSwitch" to a switch embedded teams. Copies settings from original switch and management OS virtual NICs to new switch and vNICs.

```PowerShell
ConvertTo-SwitchEmbeddedTeam -Name vSwitch
```

### Example 3

Converts all existing LBFO+team combinations without prompting.

```PowerShell
ConvertTo-SwitchEmbeddedTeam -Force
```

### Example 4

If the system has one LBFO+switch, converts it to a switch-embedded team with the name "NewSET". If the system has multiple LBFO+switch combinations, fails due to mismatch (see next example).

```PowerShell
ConvertTo-SwitchEmbeddedTeam -NewName NewSET
```

### Example 5

If the system has two LBFO+switches, converts them to switch-embedded team with the name "NewSET1" and "NEWSET2", **IN THE ORDER THAT GET-VMSWITCH RETRIEVES THEM**.

```PowerShell
ConvertTo-SwitchEmbeddedTeam -NewName NewSET1, NewSET2
```

### Example 6

Converts the LBFO+switches named "OldSwitch1" and "OldSwitch2" to SETs named "NewSET1" and "NewSET2", respectively.

```PowerShell
ConvertTo-SwitchEmbeddedTeam OldSwitch1, OldSwitch2 -NewName NewSET1, NewSET2
```

### Example 7

Converts all existing LBFO+switch combinations to switch embedded teams. Discards non-default settings for the switch and Hyper-V-related management OS vNICs. Keeps IP addresses and advanced settings (ex. jumbo frames).

```PowerShell
ConvertTo-SwitchEmbeddedTeam -UseDefaults
```

### Example 8

Converts all existing LBFO+switch combinations to switch embedded teams. Forces the new SET to use "Weight" for its minimum bandwidth mode.
**WARNING**: Changing the QoS mode may cause guest vNICS to fail to re-attach and may inhibit Live Migration. Use carefully if you have special QoS settings on guest virtual NICs.

```PowerShell
ConvertTo-SwitchEmbeddedTeam -MinimumBandwidthMode Weight
```

## PARAMETERS

### Name

The name(s) of the virtual switch(es) to convert.

```yaml
Type                         String[]
Required?                    true
Position?                    1
Default value
Accept pipeline input?       false
Accept wildcard characters?  true
```

### Id

The unique identifier(s) for the virtual switch(es) to convert.

```yaml
Type                         System.Guid[]
Required?                    true
Position?                    1
Default value
Accept pipeline input?       false
Accept wildcard characters?  false
```

### VMSwitch

The virtual switch(es) to convert.

```yaml
Type                         VMSwitch[]
Required?                    true
Position?                    1
Default value
Accept pipeline input?       false
Accept wildcard characters?  false
```

### NewName

Name(s) to assign to the converted virtual switch(es). If blank, keeps the original name.

```yaml
Type                         String[]
Required?                    false
Position?                    named
Default value
Accept pipeline input?       false
Accept wildcard characters?  false
```

### UseDefaults

If specified, uses defaults for all values on the converted switch(es). If not specified, uses the same parameters as the original LBFO+switch or any manually-specified parameters.

```yaml
Type                         SwitchParameter
Required?                    false
Position?                    named
Default value                false
Accept pipeline input?       false
Accept wildcard characters?  false
```

### LoadBalancingAlgorithm

Sets the load balancing algorithm for the converted switch(es). If not specified, uses the same setting as the original LBFO+switch or the default if UseDefaults is set.

```yaml
Type                         VMSwitchLoadBalancingAlgorithm
Required?                    false
Position?                    named
Default value
Accept pipeline input?       false
Accept wildcard characters?  false
```

### MinimumBandwidthMode

Sets the desired QoS mode for the converted switch(es). If not specified, uses the same setting as the original LBFO+switch or the default if UseDefaults is set.

* None: No network QoS
* Absolute: minimum bandwidth values specify bits per second
* Weight: minimum bandwidth values range from 1 to 100 and represent percentages
* Default: use system default

**WARNING**: Changing the QoS mode may cause guest vNICS to fail to re-attach and may inhibit Live Migration. Use carefully if you have special QoS settings on guest virtual NICs.

```yaml
Type                         VMSwitchBandwidthMode
Required?                    false
Position?                    named
Default value
Accept pipeline input?       false
Accept wildcard characters?  false
```

### Notes

A note to associate with the converted switch(es). If not specified, uses the same setting as the original LBFO+switch or the default if UseDefaults is set.

```yaml
Type                         String
Required?                    false
Position?                    named
Default value
Accept pipeline input?       false
Accept wildcard characters?  false
```

### Force

If specified, bypasses confirmation.

```yaml
Type                         SwitchParameter
Required?                    false
Position?                    named
Default value                false
Accept pipeline input?       false
Accept wildcard characters?  false
```

## NOTES

Author: Eric Siron
Version 1.0, December 22, 2019
Released under MIT license
