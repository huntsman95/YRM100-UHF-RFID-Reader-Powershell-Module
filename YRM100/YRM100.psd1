@{
    RootModule = 'YRM100.psm1'
    ModuleVersion = '0.5.0'
    GUID = 'c6535c53-2861-4784-bf30-701a4fc30eba'
    Author = 'TheHuntzman'
    Description = 'Serial communication with M100 protocol compatible YRM100 UHF RFID readers.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Get-YRM100Port','Connect-YRM100','Disconnect-YRM100','Get-YRM100Info','Get-YRM100Region','Get-YRM100OutputPower','Set-YRM100Region','Set-YRM100OutputPower','Get-YRM100OperatingChannel','Set-YRM100OperatingChannel','Get-YRM100Tag','Get-YRM100Tags','Read-YRM100Memory','Write-YRM100Memory','Invoke-YRM100Command')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
}
