#requires -Version 4
#requires -Modules Hyper-V
[CmdletBinding()]
[OutputType([Microsoft.HyperV.PowerShell.VMNetworkAdapter[]])]
param
(
    [Parameter(Mandatory)][Alias('HardwareAddress', 'MAC')][String]$MacAddress,
	[Parameter(ValueFromPipeline = $true, Position = 2)][String[]]$ComputerName = [String]::Empty,
    [Parameter()][String]$VMName = '*',
	[Parameter()][Switch]$ContinueIfFound
)

begin
{
    $MacAddress = ($MacAddress).Replace('-', '').Replace(':', '').Replace('.', '').ToUpper()
    $gvmParams = @{VMName=$VMName}
    if(-not([String]::IsNullOrEmpty($ComputerName)))
    {
        $gvmParams.Add('ComputerName', $ComputerName)
    }
}

process
{

    $vmna = Get-VMNetworkAdapter @gvmParams | Where-Object -Property 'MacAddress' -EQ -Value $MacAddress
    $vmna
    if(($vmna -ne $null) -and (-not($ContinueIfFound)))
    {
        break
    }
}