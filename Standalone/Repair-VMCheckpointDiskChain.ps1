#requires -RunAsAdministrator
#requires -Modules Hyper-V

[CmdletBinding(SupportsShouldProcess=$true, DefaultParameterSetName='ByName')]
param
(
    [Parameter(Mandatory=$true, ValueFromPipeline = $true, Position = 1, ParameterSetName='ByName')][String]$VMName,
    [Parameter(Mandatory=$true, ValueFromPipeline = $true, Position = 1, ParameterSetName='ByVM')][Microsoft.HyperV.PowerShell.VirtualMachine]$VM
)

begin {
    $ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
    Set-StrictMode -Version Latest

    function Create-VMCheckpointDiskChain
    {
        param(
            [Parameter()][Object[]]$CheckpointList,
            [Parameter()][System.Guid]$ParentID,
            [Parameter()][Microsoft.HyperV.PowerShell.VirtualMachine]$VMObject = $null
        )
        Write-Verbose 'here'
        $CP = Get-VMSnapshot -Id $ParentID
        Write-Verbose -Message ('Parent is {0}' -f $CP.Name)
        $ParentDisks = @(Get-VMHardDiskDrive -VMSnapshot ($CheckpointList | Where-Object -Property Id -eq $ParentID))
        $ParentDisks = Sort-Object -InputObject $ParentDisks -Property ControllerType, ControllerLocation, ControllerNumber
        if($VMObject)
        {
            $Children = @($VMObject)
        }
        else
        {
            $Children = @($CheckpointList | Where-Object -Property ParentCheckpointId -EQ $ParentID)   
        }
        
        foreach($Child in $Children)
        {
            $DiskParams = @()
            if($VMObject)
            {
                $DiskParams = @{VM = $VMObject}
            }
            else
            {
                $DiskParams = @{VMSnapshot = $Child}
            }
            $ChildDisks = @(Get-VMHardDiskDrive @DiskParams)
            $ChildDisks = Sort-Object -InputObject $ChildDisks -Property ControllerType, ControllerLocation, ControllerNumber
            foreach($ParentDisk in $ParentDisks)
            {
                $ChildDisk = $ChildDisks | Where-Object {
                    ($ParentDisk.ControllerType -eq $_.ControllerType) -and
                    ($ParentDisk.ControllerLocation -eq $_.ControllerLocation) -and
                    ($ParentDisk.ControllerNumber -eq $_.ControllerNumber)
                }
                if($ChildDisk)
                {
                    $ParentPath = Split-Path -Path $ParentDisk.Path
                    $PermanentParentFileName = Split-Path -Path $ParentDisk.Path -Leaf
                    $TemporaryParentFileName = $PermanentParentFileName -replace 'avhdx', 'vhdx'
                    $TemporaryParentPath = Join-Path -Path $ParentPath -ChildPath $TemporaryParentFileName
                    $TargetDiskFileName = Split-Path -Path $ChildDisk.Path -Leaf
                    Write-Verbose -Message ('Temporarily changing parent disk from {0} to {1}' -f $ParentDisk.Path, $TemporaryParentFileName)
                    Rename-Item -Path $ParentDisk.Path -NewName $TemporaryParentFileName
                    Write-Verbose -Message ('Deleting any pre-existing child disk {0}' -f $ChildDisk.Path)
                    Remove-Item -Path $ChildDisk.Path -Force -ErrorAction SilentlyContinue
                    Write-Verbose -Message ('Creating child disk {0} from {1}' -f $ChildDisk.Path, $TemporaryParentPath)
                    if((Test-Path -Path $TemporaryParentPath))
                    {
                        Write-Verbose -Message ('{0} exists' -f $TemporaryParentPath)
                    }
                    else
                    {
                        Write-Verbose -Message ('{0} does NOT exist' -f $TemporaryParentPath)
                    }
                    $NewDisk = New-VHD -ParentPath $TemporaryParentPath -Path ($ChildDisk.Path -replace 'avhdx', 'vhdx')
                    Write-Verbose -Message ('Restoring parent disk name from {0} to {1}' -f $TemporaryParentPath, $PermanentParentFileName)
                    Rename-Item -Path $TemporaryParentPath -NewName $PermanentParentFileName
                    Write-Verbose -Message ('Setting parent disk of {0} to {1}' -f $NewDisk.Path, $ParentDisk.Path)
                    Set-VHD -Path $NewDisk.Path -ParentPath $ParentDisk.Path
                    Write-Verbose -Message ('Renaming child disk {0} to checkpoint disk {1}' -f $NewDisk.Path, $TargetDiskFileName)
                    Rename-Item -Path $NewDisk.Path -NewName $TargetDiskFileName
                }
            }
            Create-VMCheckpointDiskChain -CheckpointList $CheckpointList -ParentID $Child.Id
        }
    }
}

process {
    $VMObject = $VM
    if($VMName)
    {
        $VMObject = Get-VM -Name $VMName
    }
    if(-not $VMObject)
    {
        Write-Error -Message 'Specified VM not found'
    }
    Write-Verbose -Message 'Loading checkpoints'
    $Checkpoints = @(Get-VMSnapshot -VM $VMObject)
    $RootCheckpoint = $Checkpoints | Where-Object -Property ParentCheckpointId -EQ $null
    Create-VMCheckpointDiskChain -CheckpointList $Checkpoints -ParentID $RootCheckpoint.Id
    Create-VMCheckpointDiskChain -CheckpointList $Checkpoints -ParentID $VMObject.ParentCheckpointId -VM $VMObject
    Remove-VMSnapshot -VM $VM -IncludeAllChildSnapshots -Confirm:$false
}