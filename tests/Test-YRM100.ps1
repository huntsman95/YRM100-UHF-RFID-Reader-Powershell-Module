$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\..\YRM100\YRM100.psd1" -Force

# Dependency-free protocol tests; no real serial port is opened.
class FakeYRMPort {
    [string]$PortName = 'FAKE'
    [bool]$IsOpen = $true
    [System.Collections.Generic.Queue[byte]]$InputBytes = [System.Collections.Generic.Queue[byte]]::new()
    [System.Collections.Generic.List[byte[]]]$Replies = [System.Collections.Generic.List[byte[]]]::new()
    [System.Collections.Generic.List[byte[]]]$Writes = [System.Collections.Generic.List[byte[]]]::new()
    [void] DiscardInBuffer() { $this.InputBytes.Clear() }
    [void] Write([byte[]]$data,[int]$offset,[int]$length) {
        $this.Writes.Add($data)
        if ($this.Replies.Count) {
            foreach ($b in $this.Replies[0]) { $this.InputBytes.Enqueue($b) }
            $this.Replies.RemoveAt(0)
        }
    }
    [int] ReadByte() {
        if (-not $this.InputBytes.Count) { throw [System.TimeoutException]::new() }
        return $this.InputBytes.Dequeue()
    }
    [void] Dispose() { $this.IsOpen=$false }
}
function Assert($Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
function Response([byte]$Command,[byte[]]$Data,[byte]$Type=1) {
    $m=Get-Module YRM100
    $frame=& $m { param($c,$d) New-YRMFrame $c $d } $Command $Data
    $frame[1]=$Type; $sum=0
    for ($i=1;$i -lt $frame.Length-2;$i++) { $sum+=$frame[$i] }
    $frame[$frame.Length-2]=[byte]($sum -band 255)
    return ,$frame
}
$port=[FakeYRMPort]::new()
$c=[pscustomobject]@{Port=$port;TimeoutMilliseconds=100;SyncRoot=[object]::new()}
$m=Get-Module YRM100
$hex=& $m { ConvertTo-YRMHex (New-YRMFrame 0x22) }
Assert ($hex -eq 'BB00220000227E') 'Single polling frame mismatch'
$hex=& $m { ConvertTo-YRMHex (New-YRMFrame 0x39 ([byte[]]@(0,0,255,255,3,0,0,0,2))) }
Assert ($hex -eq 'BB003900090000FFFF0300000002457E') 'Documented read frame mismatch'
$port.Replies.Add((Response 3 ([byte[]]@(0,77,49,48,48))))
Assert ((Get-YRM100Info $c).Value -eq 'M100') 'Information decode failed'
# EPC contains both delimiter bytes; parsing must follow length, not delimiters.
$port.Replies.Add((Response 0x22 ([byte[]]@(201,16,0,187,126,18,52,0,0)) 2))
$tag=Get-YRM100Tag $c
Assert ($tag.EPC -eq 'BB7E1234' -and $tag.RSSIdBm -eq -55) 'Inventory decode failed'
$port.Replies.Add((Response 0x0C ([byte[]]@(0))))
$port.Replies.Add((Response 0x12 ([byte[]]@(0))))
$port.Replies.Add((Response 0x39 ([byte[]]@(6,16,0,187,126,18,52,171,205))))
$read=Read-YRM100Memory $c -EPC BB7E1234
Assert ($read.Hex -eq 'ABCD' -and $read.EPC -eq 'BB7E1234') 'Read decode failed'
Assert ($port.Writes[$port.Writes.Count-2][2] -eq 0x12 -and $port.Writes[$port.Writes.Count-2][5] -eq 2) 'Memory selection must leave inventory unfiltered'
$count=$port.Writes.Count
Write-YRM100Memory $c -EPC BB7E1234 -HexData ABCD -WhatIf
Assert ($port.Writes.Count -eq $count) 'WhatIf performed serial I/O'
$port.Replies.Add((Response 0x0C ([byte[]]@(0))))
$port.Replies.Add((Response 0x12 ([byte[]]@(0))))
$port.Replies.Add((Response 0x49 ([byte[]]@(6,16,0,187,126,18,52,0))))
Assert ((Write-YRM100Memory $c -EPC BB7E1234 -HexData ABCD).Success) 'Write failed'
$port.Replies.Add((Response 0xFF ([byte[]]@(0x15))))
$failed=$false
try { Get-YRM100Tag $c } catch { $failed=$_.Exception.Message -match '0x15' }
Assert $failed 'No-tag reader error was not surfaced'
$bad=Response 3 ([byte[]]@(0,65)); $bad[$bad.Length-2]=0
$port.Replies.Add($bad)
$failed=$false
try { Get-YRM100Info $c } catch { $failed=$_.Exception.Message -match 'checksum' }
Assert $failed 'Bad checksum accepted'
$failed=$false
try { Get-YRM100Info $c } catch { $failed=$_.Exception.Message -match 'Timed out' }
Assert $failed 'Missing response did not time out'
$port.Replies.Add((Response 0x12 ([byte[]]@(0))))
$a=Response 0x22 ([byte[]]@(201,16,0,187,126,18,52,0,0)) 2
$b=Response 0x22 ([byte[]]@(190,16,0,0,0,0,54,0,0)) 2
$a2=Response 0x22 ([byte[]]@(210,16,0,187,126,18,52,0,0)) 2
$none=Response 0xFF ([byte[]]@(0x15))
$port.Replies.Add(([byte[]]($a+$none+$b+$a2)))
$port.Replies.Add((Response 0x28 ([byte[]]@(0))))
$found=@(Get-YRM100Tags $c -DurationSeconds 0.1)
Assert ($found.Count -eq 2) 'Multi inventory did not return two unique EPCs'
$seen=$found | Where-Object EPC -eq BB7E1234
Assert ($seen.ReadCount -eq 2 -and $seen.RSSIdBm -eq -46 -and $seen.PeakRSSIdBm -eq -46) 'Multi inventory aggregation failed'
Assert ($port.Writes[$port.Writes.Count-1][2] -eq 0x28) 'Inventory was not stopped'
$port.Replies.Add((Response 0x12 ([byte[]]@(0))))
$port.Replies.Add($none)
$port.Replies.Add((Response 0x28 ([byte[]]@(0))))
Assert (@(Get-YRM100Tags $c -DurationSeconds 0.1).Count -eq 0) 'Empty scan should return no objects'
$port.Replies.Add((Response 0x12 ([byte[]]@(0))))
$port.Replies.Add($bad)
$port.Replies.Add((Response 0x28 ([byte[]]@(0))))
$failed=$false
try { Get-YRM100Tags $c -DurationSeconds 0.1 } catch { $failed=$_.Exception.Message -match 'checksum' }
Assert ($failed -and $port.Writes[$port.Writes.Count-1][2] -eq 0x28) 'Failed scan must stop inventory and surface error'
foreach ($pair in @(@(1,'China 900 MHz'),@(2,'America'),@(3,'Europe'),@(4,'China 800 MHz'),@(6,'South Korea'),@(255,'Unknown'))) {
    $port.Replies.Add((Response 0x08 ([byte[]]@($pair[0]))))
    $region=Get-YRM100Region $c
    Assert ($region.RegionCode -eq $pair[0] -and $region.Region -eq $pair[1]) 'Region decode failed'
    Assert (([BitConverter]::ToString($port.Writes[$port.Writes.Count-1])) -eq 'BB-00-08-00-00-08-7E') 'Region query frame mismatch'
}
$port.Replies.Add((Response 0xB7 ([byte[]]@(7,0xD0))))
$power=Get-YRM100OutputPower $c
Assert ($power.OutputPowerdBm -eq 20 -and $power.RawPower -eq 2000) 'Power decode failed'
Assert (([BitConverter]::ToString($port.Writes[$port.Writes.Count-1])) -eq 'BB-00-B7-00-00-B7-7E') 'Power query frame mismatch'
$port.Replies.Add((Response 0xB7 ([byte[]]@(8,0x4D))))
Assert ((Get-YRM100OutputPower $c).OutputPowerdBm -eq 21.25) 'Fractional power decode failed'
foreach ($command in @(0x08,0xB7)) {
    $port.Replies.Add((Response $command ([byte[]]@())))
    $failed=$false
    try {
        if ($command -eq 0x08) { Get-YRM100Region $c } else { Get-YRM100OutputPower $c }
    } catch { $failed=$_.Exception.Message -match 'Malformed RF' }
    Assert $failed 'Malformed RF query response was accepted'
    $port.Replies.Add((Response 0xFF ([byte[]]@(0x20))))
    $failed=$false
    try {
        if ($command -eq 0x08) { Get-YRM100Region $c } else { Get-YRM100OutputPower $c }
    } catch { $failed=$_.Exception.Message -match 'Reader error 0x20' }
    Assert $failed 'RF query reader error was swallowed'
}
$count=$port.Writes.Count
Set-YRM100Region $c -Region America -WhatIf -PassThru
Set-YRM100OutputPower $c -OutputPowerdBm 20 -WhatIf -PassThru
Assert ($port.Writes.Count -eq $count) 'RF setter WhatIf performed serial I/O'
foreach ($pair in @(@('China900',1),@('America',2),@('Europe',3),@('China800',4),@('SouthKorea',6))) {
    $port.Replies.Add((Response 0x07 ([byte[]]@(0))))
    Set-YRM100Region $c -Region $pair[0] -Confirm:$false
    $sent=$port.Writes[$port.Writes.Count-1]
    Assert ($sent[2] -eq 7 -and $sent[5] -eq $pair[1]) 'Region setter mapping failed'
}
$port.Replies.Add((Response 0x07 ([byte[]]@(0))))
$port.Replies.Add((Response 0x08 ([byte[]]@(2))))
Assert ((Set-YRM100Region $c -RegionCode 2 -PassThru).Region -eq 'America') 'Region setter readback failed'
$port.Replies.Add((Response 0xB6 ([byte[]]@(0))))
$port.Replies.Add((Response 0xB7 ([byte[]]@(7,0xD0))))
Assert ((Set-YRM100OutputPower $c -OutputPowerdBm 20 -PassThru).OutputPowerdBm -eq 20) 'Power setter readback failed'
Assert (([BitConverter]::ToString($port.Writes[$port.Writes.Count-2])) -eq 'BB-00-B6-00-02-07-D0-8F-7E') 'Power setter frame mismatch'
foreach ($power in @(0,21.25,26)) {
    $port.Replies.Add((Response 0xB6 ([byte[]]@(0))))
    Set-YRM100OutputPower $c -OutputPowerdBm $power
    $sent=$port.Writes[$port.Writes.Count-1]
    Assert (($sent[5]*256+$sent[6]) -eq $power*100) 'Power setter scaling failed'
}
$count=$port.Writes.Count
foreach ($power in @(-1,27,20.001)) {
    $failed=$false
    try { Set-YRM100OutputPower $c -OutputPowerdBm $power } catch { $failed=$true }
    Assert $failed 'Invalid output power accepted'
}
$failed=$false
try { Set-YRM100Region $c -RegionCode 5 } catch { $failed=$true }
Assert ($failed -and $port.Writes.Count -eq $count) 'Invalid RF parameters performed serial I/O'
foreach ($command in @(0x07,0xB6)) {
    foreach ($payload in @([byte[]]@(1),[byte[]]@(0,0))) {
        $port.Replies.Add((Response $command $payload))
        $failed=$false
        try {
            if ($command -eq 7) { Set-YRM100Region $c -Region Europe } else { Set-YRM100OutputPower $c -OutputPowerdBm 20 }
        } catch { $failed=$_.Exception.Message -match 'successful status' }
        Assert $failed 'RF setter accepted malformed or unsuccessful status'
    }
    $port.Replies.Add((Response 0xFF ([byte[]]@(0x20))))
    $failed=$false
    try {
        if ($command -eq 7) { Set-YRM100Region $c -Region Europe } else { Set-YRM100OutputPower $c -OutputPowerdBm 20 }
    } catch { $failed=$_.Exception.Message -match 'Reader error 0x20' }
    Assert $failed 'RF setter swallowed reader error'
}
foreach ($pair in @(@(1,920.375),@(2,902.75),@(3,865.3),@(4,840.375),@(6,917.3),@(255,$null))) {
    $port.Replies.Add((Response 0xAA ([byte[]]@(1))))
    $port.Replies.Add((Response 0x08 ([byte[]]@($pair[0]))))
    $channel=Get-YRM100OperatingChannel $c
    Assert ($channel.ChannelIndex -eq 1 -and $channel.RegionCode -eq $pair[0] -and $channel.FrequencyMHz -eq $pair[1]) 'Channel frequency decode failed'
    Assert (([BitConverter]::ToString($port.Writes[$port.Writes.Count-2])) -eq 'BB-00-AA-00-00-AA-7E') 'Channel query frame mismatch'
}
$count=$port.Writes.Count
Set-YRM100OperatingChannel $c -ChannelIndex 1 -PassThru -WhatIf
foreach ($index in @(-1,256)) {
    $failed=$false
    try { Set-YRM100OperatingChannel $c -ChannelIndex $index } catch { $failed=$true }
    Assert $failed 'Invalid channel index accepted'
}
Assert ($port.Writes.Count -eq $count) 'Channel validation or WhatIf performed I/O'
$port.Replies.Add((Response 0xAB ([byte[]]@(0))))
$port.Replies.Add((Response 0xAA ([byte[]]@(1))))
$port.Replies.Add((Response 0x08 ([byte[]]@(1))))
$channel=Set-YRM100OperatingChannel $c -ChannelIndex 1 -PassThru
Assert ($channel.FrequencyMHz -eq 920.375) 'Channel setter readback failed'
Assert (([BitConverter]::ToString($port.Writes[$port.Writes.Count-3])) -eq 'BB-00-AB-00-01-01-AD-7E') 'Channel setter frame mismatch'
foreach ($index in @(0,255)) {
    $port.Replies.Add((Response 0xAB ([byte[]]@(0))))
    Set-YRM100OperatingChannel $c -ChannelIndex $index
    Assert ($port.Writes[$port.Writes.Count-1][5] -eq $index) 'Channel setter boundary encoding failed'
}
foreach ($command in @(0xAA,0xAB)) {
    $port.Replies.Add((Response $command ([byte[]]@(0,0))))
    $failed=$false
    try {
        if ($command -eq 0xAA) { Get-YRM100OperatingChannel $c } else { Set-YRM100OperatingChannel $c -ChannelIndex 1 }
    } catch { $failed=$true }
    Assert $failed 'Malformed channel response accepted'
    $port.Replies.Add((Response 0xFF ([byte[]]@(0x20))))
    $failed=$false
    try {
        if ($command -eq 0xAA) { Get-YRM100OperatingChannel $c } else { Set-YRM100OperatingChannel $c -ChannelIndex 1 }
    } catch { $failed=$_.Exception.Message -match 'Reader error 0x20' }
    Assert $failed 'Channel command swallowed reader error'
}
$port.Replies.Add((Response 0xAB ([byte[]]@(1))))
$failed=$false
try { Set-YRM100OperatingChannel $c -ChannelIndex 1 } catch { $failed=$true }
Assert $failed 'Channel setter accepted failure status'
Disconnect-YRM100 $c
Assert (-not $port.IsOpen) 'Disconnect failed'
'All protocol tests passed.'
