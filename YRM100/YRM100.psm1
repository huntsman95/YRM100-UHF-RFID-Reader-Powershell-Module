Set-StrictMode -Version Latest

function Get-YRM100Port {
    <# .SYNOPSIS
    Lists serial port names available on this computer.
    #>
    [CmdletBinding()] param()
    [System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object
}

function Connect-YRM100 {
    <# .SYNOPSIS
    Opens a reader connection (default 115200 baud, 8N1, no flow control).
    #>
    [CmdletBinding()] param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PortName,
        [ValidateRange(1200,3000000)][int]$BaudRate = 115200,
        [ValidateRange(100,60000)][int]$TimeoutMilliseconds = 2000,
        [switch]$DtrEnable,
        [switch]$RtsEnable
    )
    $port = [System.IO.Ports.SerialPort]::new($PortName,$BaudRate,[System.IO.Ports.Parity]::None,8,[System.IO.Ports.StopBits]::One)
    $port.Handshake = [System.IO.Ports.Handshake]::None
    $port.ReadTimeout = 100
    $port.WriteTimeout = $TimeoutMilliseconds
    $port.DtrEnable = $DtrEnable.IsPresent
    $port.RtsEnable = $RtsEnable.IsPresent
    try { $port.Open() } catch { $port.Dispose(); throw }
    [pscustomobject]@{
        PSTypeName = 'YRM100.Connection'
        Port = $port
        TimeoutMilliseconds = $TimeoutMilliseconds
        SyncRoot = [object]::new()
    }
}

function Disconnect-YRM100 {
    <# .SYNOPSIS
    Closes and disposes a reader connection. Always call in a finally block.
    #>
    [CmdletBinding()] param([Parameter(Mandatory,ValueFromPipeline)]$Connection)
    process { $Connection.Port.Dispose() }
}

function ConvertTo-YRMHex([byte[]]$Bytes) {
    [BitConverter]::ToString($Bytes).Replace('-','')
}

function ConvertFrom-YRMHex([string]$Hex) {
    if ($Hex -notmatch '\A(?:[0-9A-Fa-f]{2})+\z') { throw 'Expected an even number of hexadecimal digits without separators.' }
    $bytes = [byte[]]::new($Hex.Length / 2)
    for ($i=0; $i -lt $bytes.Length; $i++) { $bytes[$i] = [Convert]::ToByte($Hex.Substring($i*2,2),16) }
    return ,$bytes
}

function Get-YRMBigEndian([uint32]$Value,[int]$Count) {
    $bytes = [byte[]]::new($Count)
    for ($i=0; $i -lt $Count; $i++) { $bytes[$Count-1-$i] = [byte](($Value -shr ($i*8)) -band 255) }
    return ,$bytes
}

function New-YRMFrame([byte]$Command,[byte[]]$Data = @()) {
    if ($Data.Length -gt 65535) { throw 'Payload exceeds 65535 bytes.' }
    $frame = [byte[]]::new($Data.Length+7)
    $frame[0]=0xBB; $frame[2]=$Command
    $frame[3]=[byte]($Data.Length -shr 8); $frame[4]=[byte]($Data.Length -band 255)
    [Array]::Copy($Data,0,$frame,5,$Data.Length)
    $sum=0
    for ($i=1; $i -lt $frame.Length-2; $i++) { $sum += $frame[$i] }
    $frame[$frame.Length-2]=[byte]($sum -band 255); $frame[$frame.Length-1]=0x7E
    return ,$frame
}

function Receive-YRMFrame($Connection,$Clock,[int]$Deadline) {
    # Length-based framing: BB and 7E are legal bytes inside a payload.
    $buffer = [System.Collections.Generic.List[byte]]::new()
    while ($Clock.ElapsedMilliseconds -lt $Deadline) {
        try { $value=$Connection.Port.ReadByte() } catch [System.TimeoutException] { continue }
        if ($value -lt 0) { throw 'Serial connection ended.' }
        if ($buffer.Count -eq 0 -and $value -ne 0xBB) { continue }
        $buffer.Add([byte]$value)
        if ($buffer.Count -lt 5) { continue }
        $length = ([int]$buffer[3]*256)+$buffer[4]
        if ($buffer.Count -lt $length+7) { continue }
        $sum=0
        for ($i=1; $i -lt $buffer.Count-2; $i++) { $sum += $buffer[$i] }
        if ($buffer[$buffer.Count-1] -ne 0x7E -or ($sum -band 255) -ne $buffer[$buffer.Count-2]) {
            throw 'Invalid reader frame checksum or terminator. Check baud rate, wiring, and power.'
        }
        $data=[byte[]]::new($length)
        if ($length) { $buffer.CopyTo(5,$data,0,$length) }
        return [pscustomobject]@{ Type=$buffer[1]; Command=$buffer[2]; Data=$data; Raw=$buffer.ToArray() }
    }
    throw [System.TimeoutException]::new('Timed out waiting for a complete reader response. Check COM port, baud rate, wiring, and power.')
}

function Invoke-YRM100Command {
    <# .SYNOPSIS
    Sends one M100 protocol command and returns its validated response frame.
    .DESCRIPTION
    For request/response commands. Does not support starting continuous inventory.
    The connection must not be shared with another process or a continuous scan.
    No write commands are retried automatically.
    #>
    [CmdletBinding()] param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][byte]$Command,
        [byte[]]$Data = @()
    )
    [System.Threading.Monitor]::Enter($Connection.SyncRoot)
    try {
        if (-not $Connection.Port.IsOpen) { throw 'Reader connection is closed.' }
        if ($Command -eq 0x27) { throw 'Continuous inventory is unsupported; use Get-YRM100Tag for bounded single polling.' }
        $Connection.Port.DiscardInBuffer()
        $frame=New-YRMFrame $Command $Data
        Write-Verbose ('TX '+(ConvertTo-YRMHex $frame))
        $Connection.Port.Write($frame,0,$frame.Length)
        $clock=[Diagnostics.Stopwatch]::StartNew()
        while ($clock.ElapsedMilliseconds -lt $Connection.TimeoutMilliseconds) {
            $reply=Receive-YRMFrame $Connection $clock $Connection.TimeoutMilliseconds
            Write-Verbose ('RX '+(ConvertTo-YRMHex $reply.Raw))
            if ($reply.Type -eq 1 -and $reply.Command -eq 0xFF) {
                if (-not $reply.Data.Length) { throw 'Malformed reader error response.' }
                throw ('Reader error 0x{0:X2}; raw response {1}' -f $reply.Data[0],(ConvertTo-YRMHex $reply.Raw))
            }
            if (($reply.Type -eq 1 -or $reply.Type -eq 2) -and $reply.Command -eq $Command) { return $reply }
        }
        throw [System.TimeoutException]::new('No matching response arrived before the command deadline.')
    } finally { [System.Threading.Monitor]::Exit($Connection.SyncRoot) }
}

function Assert-YRMStatus($Reply) {
    if ($Reply.Type -ne 1 -or $Reply.Data.Length -ne 1 -or $Reply.Data[0] -ne 0) { throw 'Reader did not return a successful status response.' }
}

function Get-YRM100Info {
    <# .SYNOPSIS
    Reads hardware, software, or manufacturer information.
    #>
    [CmdletBinding()] param(
        [Parameter(Mandatory)]$Connection,
        [ValidateSet('Hardware','Software','Manufacturer')][string]$Kind='Hardware'
    )
    $id=@{Hardware=0;Software=1;Manufacturer=2}[$Kind]
    $reply=Invoke-YRM100Command $Connection 0x03 ([byte[]]@($id))
    if ($reply.Data.Length -lt 2 -or $reply.Data[0] -ne $id) { throw 'Malformed module information response.' }
    [pscustomobject]@{ Kind=$Kind; Value=[Text.Encoding]::ASCII.GetString($reply.Data,1,$reply.Data.Length-1).TrimEnd([char]0) }
}

function Get-YRM100Region {
    <# .SYNOPSIS
    Queries the reader's configured RF region without changing it.
    .DESCRIPTION
    Returns RegionCode and Region. Unrecognized firmware codes return Unknown
    with the original numeric code preserved.
    .EXAMPLE
    Get-YRM100Region -Connection $reader
    #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Connection)
    $reply=Invoke-YRM100Command $Connection 0x08
    if ($reply.Type -ne 1 -or $reply.Data.Length -ne 1) { throw 'Malformed RF region response: expected one data byte in a response frame.' }
    $code=[int]$reply.Data[0]
    $regions=@{ 1='China 900 MHz'; 2='America'; 3='Europe'; 4='China 800 MHz'; 6='South Korea' }
    $name='Unknown'
    if ($regions.ContainsKey($code)) { $name=$regions[$code] }
    [pscustomobject]@{ RegionCode=$code; Region=$name }
}

function Get-YRM100OutputPower {
    <# .SYNOPSIS
    Queries the reader's configured RF output power without changing it.
    .DESCRIPTION
    Returns OutputPowerdBm and the protocol's raw hundredths-of-dBm value.
    This is configured transmit power, not tag RSSI or a measured radiated power.
    .EXAMPLE
    Get-YRM100OutputPower -Connection $reader
    #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Connection)
    $reply=Invoke-YRM100Command $Connection 0xB7
    if ($reply.Type -ne 1 -or $reply.Data.Length -ne 2) { throw 'Malformed RF output power response: expected two data bytes in a response frame.' }
    $raw=[int]$reply.Data[0]*256+[int]$reply.Data[1]
    [pscustomobject]@{ OutputPowerdBm=$raw/100.0; RawPower=$raw }
}

function Set-YRM100Region {
    <# .SYNOPSIS
    Sets the reader's RF region by name or protocol code.
    .DESCRIPTION
    Supports -WhatIf and -Confirm. Use -PassThru to query the resulting setting.
    Region names: China900, America, Europe, China800, SouthKorea.
    .EXAMPLE
    Set-YRM100Region $reader -Region America -PassThru
    .EXAMPLE
    Set-YRM100Region $reader -RegionCode 2 -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess,DefaultParameterSetName='Name')] param(
        [Parameter(Mandatory,Position=0)]$Connection,
        [Parameter(Mandatory,ParameterSetName='Name')]
        [ValidateSet('China900','America','Europe','China800','SouthKorea')][string]$Region,
        [Parameter(Mandatory,ParameterSetName='Code')]
        [ValidateSet(1,2,3,4,6)][byte]$RegionCode,
        [switch]$PassThru
    )
    $code=$RegionCode
    if ($PSCmdlet.ParameterSetName -eq 'Name') {
        $code=[byte]@{China900=1;America=2;Europe=3;China800=4;SouthKorea=6}[$Region]
    }
    if (-not $PSCmdlet.ShouldProcess($Connection.Port.PortName,"Set RF region to code $code")) { return }
    [Threading.Monitor]::Enter($Connection.SyncRoot)
    try {
        Assert-YRMStatus (Invoke-YRM100Command $Connection 0x07 ([byte[]]@($code)))
        if ($PassThru) { Get-YRM100Region $Connection }
    } finally { [Threading.Monitor]::Exit($Connection.SyncRoot) }
}

function Set-YRM100OutputPower {
    <# .SYNOPSIS
    Sets configured transmit power in dBm (0 to 26, hundredth-dBm precision).
    .DESCRIPTION
    Uses the 26 dBm ceiling of the supported reader. Firmware may impose a
    narrower range or coarser steps. Use -PassThru to query the resulting value.
    Supports -WhatIf and -Confirm. Does not change received tag RSSI directly.
    .EXAMPLE
    Set-YRM100OutputPower $reader -OutputPowerdBm 20 -PassThru
    #>
    [CmdletBinding(SupportsShouldProcess)] param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][Alias('PowerdBm')]
        [ValidateRange(0,26)][decimal]$OutputPowerdBm,
        [switch]$PassThru
    )
    $scaled=$OutputPowerdBm*100
    if ($scaled -ne [decimal]::Truncate($scaled)) { throw 'OutputPowerdBm must have at most two decimal places.' }
    $raw=[uint16]$scaled
    if (-not $PSCmdlet.ShouldProcess($Connection.Port.PortName,"Set RF output power to $OutputPowerdBm dBm")) { return }
    [Threading.Monitor]::Enter($Connection.SyncRoot)
    try {
        Assert-YRMStatus (Invoke-YRM100Command $Connection 0xB6 (Get-YRMBigEndian $raw 2))
        if ($PassThru) { Get-YRM100OutputPower $Connection }
    } finally { [Threading.Monitor]::Exit($Connection.SyncRoot) }
}

function Get-YRM100OperatingChannel {
    <# .SYNOPSIS
    Queries the operating channel index and derives its frequency from the region.
    .DESCRIPTION
    Returns ChannelIndex, RegionCode, Region, and FrequencyMHz. Frequency is null
    for unknown regions. Frequency is calculated, not measured; automatic hopping
    can change the operating channel. Does not change hopping or region settings.
    .EXAMPLE
    Get-YRM100OperatingChannel $reader
    #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Connection)
    [Threading.Monitor]::Enter($Connection.SyncRoot)
    try {
        $reply=Invoke-YRM100Command $Connection 0xAA
        if ($reply.Type -ne 1 -or $reply.Data.Length -ne 1) { throw 'Malformed operating channel response: expected one data byte in a response frame.' }
        $index=[int]$reply.Data[0]
        $region=Get-YRM100Region $Connection
        $plans=@{1=@(920.125,0.25);2=@(902.25,0.5);3=@(865.1,0.2);4=@(840.125,0.25);6=@(917.1,0.2)}
        $frequency=$null
        if ($plans.ContainsKey($region.RegionCode)) {
            $plan=$plans[$region.RegionCode]
            $frequency=[Math]::Round($plan[0]+$index*$plan[1],3)
        }
        [pscustomobject]@{ ChannelIndex=$index; RegionCode=$region.RegionCode; Region=$region.Region; FrequencyMHz=$frequency }
    } finally { [Threading.Monitor]::Exit($Connection.SyncRoot) }
}

function Set-YRM100OperatingChannel {
    <# .SYNOPSIS
    Sets the operating channel by zero-based protocol index.
    .DESCRIPTION
    Supports -WhatIf, -Confirm, and -PassThru readback. Index must fit a byte;
    firmware validates which indices are supported for the configured region.
    Does not disable automatic frequency hopping or change the region.
    .EXAMPLE
    Set-YRM100OperatingChannel $reader -ChannelIndex 1 -PassThru
    #>
    [CmdletBinding(SupportsShouldProcess)] param(
        [Parameter(Mandatory,Position=0)]$Connection,
        [Parameter(Mandatory)][ValidateRange(0,255)][int]$ChannelIndex,
        [switch]$PassThru
    )
    if (-not $PSCmdlet.ShouldProcess($Connection.Port.PortName,"Set operating channel index to $ChannelIndex")) { return }
    [Threading.Monitor]::Enter($Connection.SyncRoot)
    try {
        Assert-YRMStatus (Invoke-YRM100Command $Connection 0xAB ([byte[]]@($ChannelIndex)))
        if ($PassThru) { Get-YRM100OperatingChannel $Connection }
    } finally { [Threading.Monitor]::Exit($Connection.SyncRoot) }
}

function Get-YRM100Tag {
    <# .SYNOPSIS
    Performs one inventory poll and returns the first reported tag.
    .DESCRIPTION
    No-tag error 0x15 is reported as a terminating reader error. Repeat calls for
    simple polling. This command is not a complete inventory of every tag in range.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Connection)
    $reply=Invoke-YRM100Command $Connection 0x22
    ConvertFrom-YRMInventory $reply
}

function ConvertFrom-YRMInventory($Reply) {
    $d=$Reply.Data
    if ($d.Length -lt 5) { throw 'Malformed inventory response.' }
    $epcLength=($d[1] -shr 3)*2
    if ($d.Length -ne $epcLength+5) { throw 'Inventory PC length does not match EPC payload.' }
    $epc=[byte[]]::new($epcLength)
    [Array]::Copy($d,3,$epc,0,$epcLength)
    $rssi=[int]$d[0]; if ($rssi -ge 128) { $rssi-=256 }
    [pscustomobject]@{ EPC=ConvertTo-YRMHex $epc; RSSIdBm=$rssi; PC=('{0:X2}{1:X2}' -f $d[1],$d[2]); CRC=('{0:X2}{1:X2}' -f $d[$d.Length-2],$d[$d.Length-1]); Timestamp=[DateTimeOffset]::Now }
}

function Get-YRM100Tags {
    <# .SYNOPSIS
    Scans for a bounded duration and returns one result per observed EPC.
    .DESCRIPTION
    Uses multiple inventory, consumes every notification, and stops inventory in
    finally. No-tag notifications are normal; other reader errors terminate.
    RSSIdBm is the latest reading; PeakRSSIdBm is the strongest reading.
    Tags sharing an EPC are combined. A scan cannot guarantee detection of every
    physical tag. Selection mode is set to 2 so inventory is unfiltered.
    .EXAMPLE
    Get-YRM100Tags -Connection $reader -DurationSeconds 5
    #>
    [CmdletBinding()] param(
        [Parameter(Mandatory)]$Connection,
        [ValidateRange(0.1,3600)][double]$DurationSeconds=3
    )
    $tags=@{}
    $started=$false
    [Threading.Monitor]::Enter($Connection.SyncRoot)
    try {
        Assert-YRMStatus (Invoke-YRM100Command $Connection 0x12 ([byte[]]@(2)))
        $frame=New-YRMFrame 0x27 ([byte[]]@(0x22,0xFF,0xFF))
        $Connection.Port.DiscardInBuffer()
        $started=$true
        $Connection.Port.Write($frame,0,$frame.Length)
        $clock=[Diagnostics.Stopwatch]::StartNew()
        $deadline=[int][Math]::Ceiling($DurationSeconds*1000)
        while ($clock.ElapsedMilliseconds -lt $deadline) {
            try { $reply=Receive-YRMFrame $Connection $clock $deadline }
            catch [System.TimeoutException] { break }
            Write-Verbose ('RX '+(ConvertTo-YRMHex $reply.Raw))
            if ($reply.Type -eq 1 -and $reply.Command -eq 0xFF) {
                if ($reply.Data.Length -eq 1 -and $reply.Data[0] -eq 0x15) { continue }
                throw ('Reader error during inventory; raw response '+(ConvertTo-YRMHex $reply.Raw))
            }
            if ($reply.Type -ne 2 -or $reply.Command -notin @(0x22,0x27)) { continue }
            $tag=ConvertFrom-YRMInventory $reply
            if ($tags.ContainsKey($tag.EPC)) {
                $entry=$tags[$tag.EPC]
                $entry.ReadCount++
                $entry.RSSIdBm=$tag.RSSIdBm
                $entry.PeakRSSIdBm=[Math]::Max($entry.PeakRSSIdBm,$tag.RSSIdBm)
                $entry.LastSeen=$tag.Timestamp
                $entry.PC=$tag.PC; $entry.CRC=$tag.CRC
            } else {
                $tags[$tag.EPC]=[pscustomobject]@{
                    EPC=$tag.EPC; RSSIdBm=$tag.RSSIdBm; PeakRSSIdBm=$tag.RSSIdBm
                    ReadCount=1; FirstSeen=$tag.Timestamp; LastSeen=$tag.Timestamp
                    PC=$tag.PC; CRC=$tag.CRC
                }
            }
        }
    } finally {
        try {
            if ($started) { Assert-YRMStatus (Invoke-YRM100Command $Connection 0x28) }
        } finally { [Threading.Monitor]::Exit($Connection.SyncRoot) }
    }
    $tags.Values | Sort-Object EPC
}

function Set-YRMSelection($Connection,[string]$EPC) {
    $mask=ConvertFrom-YRMHex $EPC
    if ($mask.Length -gt 31) { throw 'EPC selection supports at most 248 bits (31 bytes).' }
    Assert-YRMStatus (Invoke-YRM100Command $Connection 0x0C ([byte[]](@(1,0,0,0,32,($mask.Length*8),0)+$mask)))
    # Select only for memory operations; leave inventory unfiltered (mode 2).
    Assert-YRMStatus (Invoke-YRM100Command $Connection 0x12 ([byte[]]@(2)))
}

function New-YRMMemoryParameters([string]$Password,[string]$Bank,[uint16]$WordAddress,[uint16]$WordCount) {
    $pw=ConvertFrom-YRMHex $Password
    if ($pw.Length -ne 4) { throw 'AccessPassword must contain exactly eight hexadecimal digits.' }
    $bankId=@{Reserved=0;EPC=1;TID=2;User=3}[$Bank]
    return ,([byte[]]($pw+@($bankId)+(Get-YRMBigEndian $WordAddress 2)+(Get-YRMBigEndian $WordCount 2)))
}

function Read-YRM100Memory {
    <# .SYNOPSIS
    Selects a tag by EPC and reads memory. Addresses and counts are 16-bit words.
    #>
    [CmdletBinding()] param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string]$EPC,
        [ValidateSet('Reserved','EPC','TID','User')][string]$Bank='User',
        [uint16]$WordAddress=0,
        [ValidateRange(1,32)][uint16]$WordCount=1,
        [string]$AccessPassword='00000000'
    )
    $parameters=New-YRMMemoryParameters $AccessPassword $Bank $WordAddress $WordCount
    [Threading.Monitor]::Enter($Connection.SyncRoot)
    try {
        Set-YRMSelection $Connection $EPC
        $reply=Invoke-YRM100Command $Connection 0x39 $parameters
        $d=$reply.Data
        if ($d.Length -lt 3 -or $d[0] -lt 2 -or $d.Length -ne (1+$d[0]+2*$WordCount)) { throw 'Malformed memory read response.' }
        $bytes=[byte[]]::new(2*$WordCount)
        [Array]::Copy($d,(1+$d[0]),$bytes,0,$bytes.Length)
        [pscustomobject]@{ EPC=ConvertTo-YRMHex ([byte[]]$d[3..$d[0]]); Bank=$Bank; WordAddress=$WordAddress; WordCount=$WordCount; Data=$bytes; Hex=ConvertTo-YRMHex $bytes }
    } finally { [Threading.Monitor]::Exit($Connection.SyncRoot) }
}

function Write-YRM100Memory {
    <# .SYNOPSIS
    Selects a tag by EPC and writes 1 to 32 complete words to a memory bank.
    .DESCRIPTION
    Supports -WhatIf. Writing EPC, PC, or password memory can change subsequent
    selection or access. Use the current EPC for selection and read back afterward.
    #>
    [CmdletBinding(SupportsShouldProcess)] param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string]$EPC,
        [ValidateSet('Reserved','EPC','TID','User')][string]$Bank='User',
        [uint16]$WordAddress=0,
        [Parameter(Mandatory)][string]$HexData,
        [string]$AccessPassword='00000000'
    )
    $bytes=ConvertFrom-YRMHex $HexData
    if ($bytes.Length -gt 64 -or $bytes.Length%2) { throw 'HexData must contain 1 to 32 complete 16-bit words (4 to 128 hex digits).' }
    $parameters=New-YRMMemoryParameters $AccessPassword $Bank $WordAddress ($bytes.Length/2)
    $null=ConvertFrom-YRMHex $EPC
    if (-not $PSCmdlet.ShouldProcess($EPC,"Write $($bytes.Length/2) words to $Bank at word $WordAddress")) { return }
    [Threading.Monitor]::Enter($Connection.SyncRoot)
    try {
        Set-YRMSelection $Connection $EPC
        $reply=Invoke-YRM100Command $Connection 0x49 ([byte[]]($parameters+$bytes))
        $d=$reply.Data
        if ($d.Length -lt 4 -or $d[0] -lt 2 -or $d.Length -ne $d[0]+2 -or $d[$d.Length-1] -ne 0) { throw 'Malformed or unsuccessful memory write response.' }
        [pscustomobject]@{ EPC=$EPC; Bank=$Bank; WordAddress=$WordAddress; WordsWritten=$bytes.Length/2; Success=$true }
    } finally { [Threading.Monitor]::Exit($Connection.SyncRoot) }
}

Export-ModuleMember -Function Get-YRM100Port,Connect-YRM100,Disconnect-YRM100,Get-YRM100Info,Get-YRM100Region,Get-YRM100OutputPower,Set-YRM100Region,Set-YRM100OutputPower,Get-YRM100OperatingChannel,Set-YRM100OperatingChannel,Get-YRM100Tag,Get-YRM100Tags,Read-YRM100Memory,Write-YRM100Memory,Invoke-YRM100Command
