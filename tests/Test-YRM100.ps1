$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\..\YRM100\YRM100.psd1" -Force

# Dependency-free protocol tests; no real serial port is opened.
class FakeYRMPort {
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
Disconnect-YRM100 $c
Assert (-not $port.IsOpen) 'Disconnect failed'
'All protocol tests passed.'
