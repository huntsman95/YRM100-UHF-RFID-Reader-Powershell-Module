# YRM100 PowerShell module

NOTE: This module is 100% vibe-coded with Codex as a POC only.

PowerShell 5.1+ module for USB-to-UART readers using the MagicRF M100 binary
protocol (`BB ... checksum 7E`). No external PowerShell modules are required.
Uses .NET `System.IO.Ports.SerialPort`. Firmware sold as YRM100 varies; a
successful information query is the first compatibility check.

## Quick start

From this directory:

```powershell
Import-Module .\YRM100\YRM100.psd1
Get-YRM100Port
$reader = Connect-YRM100 -PortName COM9 -BaudRate 115200
try {
    Get-YRM100Info $reader -Kind Hardware
    Get-YRM100Info $reader -Kind Software
    Get-YRM100Info $reader -Kind Manufacturer
    Get-YRM100Tag $reader | Format-List
} finally {
    Disconnect-YRM100 $reader
}
```

The connection defaults to 115200 baud, 8 data bits, no parity, one stop bit,
no flow control, and a 2000 ms command timeout. Override `-BaudRate` and
`-TimeoutMilliseconds` when needed. `-DtrEnable` and `-RtsEnable` are optional
adapter settings. Changing `-BaudRate` configures the computer port only.

For installation, copy the `YRM100` directory into a directory listed in
`$env:PSModulePath`; then use `Import-Module YRM100`.

## Commands

| Command | Purpose |
| --- | --- |
| `Get-YRM100Port` | List available serial port names |
| `Connect-YRM100` | Open a configurable serial connection |
| `Disconnect-YRM100` | Release the port |
| `Get-YRM100Info` | Read hardware, software, or manufacturer identification |
| `Get-YRM100Tag` | One inventory poll, returning the first reported EPC, signed RSSI, PC, CRC, and timestamp |
| `Get-YRM100Tags` | Timed multiple inventory, returning one result per observed EPC with read counts and signal statistics |
| `Read-YRM100Memory` | Select an EPC and read a memory bank |
| `Write-YRM100Memory` | Select an EPC and write complete words; supports `-WhatIf` |
| `Invoke-YRM100Command` | Send an advanced request/response command and return validated binary data |

Use `Get-Help <command> -Full` for parameter help. Pass the returned connection
object explicitly; multiple readers can have independent connections. Dispose
each connection in `finally`. Module removal does not close connection objects.

## Scan for multiple tags

```powershell
Import-Module .\YRM100\YRM100.psd1 -Force
$reader = Connect-YRM100 COM9
try {
    $tags = @(Get-YRM100Tags $reader -DurationSeconds 5)
    $tags | Format-Table EPC, RSSIdBm, PeakRSSIdBm, ReadCount
} finally {
    Disconnect-YRM100 $reader
}
```

The default scan is three seconds. The command uses the reader's multiple-polling
mode and processes its tag notifications until the duration expires. It stops
inventory in a `finally` block, including when parsing or reader errors occur.
Selection mode is set to 2 before scanning so inventory is unfiltered; memory
operations can still select their target EPC. This setting persists afterward.

Results are sorted by EPC. Each contains `EPC`, `RSSIdBm` (latest), `PeakRSSIdBm`
(strongest), `ReadCount`, `FirstSeen`, `LastSeen`, `PC`, and `CRC`. No detections
produce no objects; routine no-tag notifications are ignored. Other errors fail
the scan. Tags with identical EPCs are combined. These are all tags **observed
during the scan**, not a guarantee that every physical tag in range was detected;
increase the duration or adjust tag placement if needed. The duration bounds
the collection window; setup and stopping may add command timeout overhead.

## Memory operations

Inventory the current EPC first. Addresses and lengths are **16-bit words**;
hex strings contain no spaces or `0x` prefix. The default bank is `User`, the
default word address is zero, and the default access password is `00000000`.

```powershell
$reader = Connect-YRM100 COM9
try {
    $tag = Get-YRM100Tag $reader
    Read-YRM100Memory $reader -EPC $tag.EPC -Bank TID -WordCount 2

    # Preview a write. Remove -WhatIf only when ready to write this tag.
    Write-YRM100Memory $reader -EPC $tag.EPC -Bank User `
        -WordAddress 0 -HexData '12345678' -WhatIf

    # After an actual write, read back the same range to verify the contents.
    # Read-YRM100Memory $reader -EPC $tag.EPC -Bank User -WordCount 2
} finally {
    Disconnect-YRM100 $reader
}
```

Reads and writes support 1–32 words per call. A tag must implement the requested
bank and address range; some tags have no User memory and TID is typically
read-only. EPC memory includes CRC and PC words before the EPC itself. Writing
EPC or password words changes how the tag is subsequently selected or accessed.
The selection settings persist in the reader after these commands. Selection
uses an EPC mask starting at bit 32 and mode 2, applying selection to memory
operations while leaving inventory unfiltered;
tags sharing that EPC cannot be distinguished by this mask.

## Advanced commands and limitations

```powershell
# Read current RF output power (hundredths of a dBm).
$reply = Invoke-YRM100Command $reader -Command 0xB7
($reply.Data[0] * 256 + $reply.Data[1]) / 100
```

Advanced commands can change reader settings or tag contents; consult the
protocol before sending them. No automatic retries are performed. Starting multiple
inventory (`0x27`) through the raw command function is deliberately rejected;
use `Get-YRM100Tags` to manage the notification stream and stop it afterward. Single polling
returns the first tag, not a complete inventory of all tags in range. Each command
discards pending input before sending its request, so do not run another scanner
on the same connection. Connection operations are serialized within this module.

Frames are parsed using their declared binary length and validated for checksum
and terminator. Malformed frames fail the request; incomplete responses time out.
Reader error frames become terminating exceptions containing the error byte and
raw response. Error `0x15` means no tag was read or its RF CRC check failed.
Other errors can indicate unsupported commands, invalid passwords, unavailable
memory, or a tag outside the field. `-Verbose` shows raw frames, including access
password bytes for memory commands; avoid sharing those traces unchanged.

If opening fails, close other serial terminal applications. For timeouts, confirm
the selected COM port, adapter driver, baud rate, common ground, TX/RX wiring,
and adequate module power. Use the UART voltage levels specified for your board;
a bare UART module needs a compatible USB-to-UART adapter. Attach the intended
antenna before inventory and use the module's appropriate region and RF settings.
This module does not change RF region or output power on connection.

## Validation

Run the dependency-free simulated serial tests:

```powershell
.\tests\Test-YRM100.ps1
```

They cover documented command bytes, delimiter bytes inside payloads, information
and tag decoding, memory selection/read/write, `-WhatIf`, reader errors, bad
checksums, timeouts, and disposal. They never open a real port.
Multiple-inventory tests also cover deduplication, signal aggregation, empty scans,
and stopping after a malformed frame. A three-second hardware scan on COM9
detected three unique EPCs and successfully returned to request/response mode.

Hardware verification on 2026-10-30, COM9 at 115200 baud: identification returned
`M100 26dBm V2.01`, software `V2.4.9`, manufacturer `MagicRf`. Inventory returned
EPC `E2806A960000501FD0783E52`; selecting that EPC and reading two TID words
returned `E2806A96`. No tag memory writes were performed. Write handling has
been verified with simulated responses only. Runtime verification used PowerShell
7; the module declares PowerShell 5.1 compatibility but has not been run under 5.1.

Protocol reference: [M5Stack Unit RFID-UHF common control commands](https://m5stack-doc.oss-cn-shenzhen.aliyuncs.com/842/Unit-RFID-UHF-Protocol-EN.pdf),
which documents the M100 command format. Related hardware may differ; hardware
confirmation is needed for individual firmware variants.
