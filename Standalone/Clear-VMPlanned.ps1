<#
.SYNOPSIS
Cleans up after partially completed virtual machine import jobs.

.DESCRIPTION
Cleans up after partially completed virtual machine import jobs. Does not delete any hard disk files.

During operations that duplicate a virtual machine, Hyper-V uses staging CIM objects. Official Hyper-V tools clean up after any problems. Third party and testing scripts and applications may leave artifacts of "Msvm_PlannedComputerSystem".

Ensure that the target host has no active jobs as this script will cause unpredictable problems.

.SYNTAX
Clear-VMPlanned.ps1 [[-ComputerName] <String>]

.PARAMETER ComputerName
The name of the staging virtual machines' host.

.EXAMPLE

C:> Clear-PlannedVM

Removes all staging virtual machines from the local host.

.EXAMPLE

C:\> Clear-PlannedVM -ComputerName 'HYPERV1'

Removes all staging virtual machines from the host named "HYPERV1".

.NOTES

Author: Eric Siron
Version 1.0, November 29, 2022
Released under MIT license

.LINK
https://ejsiron.github.io/Posher-V/Clear-VMPlanned
#>

#requires -Modules Hyper-V

[CmdletBinding()]
param(
    [Parameter(ValueFromPipeline = $true, Position = 1)][String]$ComputerName = 'localhost'
)

begin
{
    $ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
}

process
{
    if(($ComputerName -match '^localhost$') -or ($ComputerName -match ('${0}^')))
    {
        $UserId = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $UserPrincipal = New-Object System.Security.Principal.WindowsPrincipal -ArgumentList @($UserId)
        if(-not ($UserPrincipal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)))
        {
            Write-Error -Message 'Must run as administrator when run against the local system'
        }
    }
    $GCIMParams = @{Namespace='root/virtualization/v2'; ComputerName=$ComputerName}
    $VSvc = Get-CimInstance @GCIMParams -ClassName 'Msvm_VirtualSystemManagementService'
    $PlannedVMs = Get-CimInstance @GCIMParams -ClassName 'Msvm_PlannedComputerSystem'
    foreach ($PlannedVM in $PlannedVMs)
    {
        Invoke-CimMethod -InputObject $VSvc -MethodName 'DestroySystem' -Arguments @{AffectedSystem=$PlannedVM}
    }
}