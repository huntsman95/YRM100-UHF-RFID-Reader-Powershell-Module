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
| `Get-YRM100Region` | Query the configured RF region code and name |
| `Get-YRM100OutputPower` | Query configured transmit power in dBm and raw hundredths of dBm |
| `Set-YRM100Region` | Set region by name or code; supports `-WhatIf`, `-Confirm`, and `-PassThru` |
| `Set-YRM100OutputPower` | Set transmit power in dBm; supports `-WhatIf`, `-Confirm`, and `-PassThru` |
| `Get-YRM100OperatingChannel` | Query channel index and calculate frequency from the current region |
| `Set-YRM100OperatingChannel` | Set a channel index; supports `-WhatIf`, `-Confirm`, and `-PassThru` |
| `Get-YRM100Tag` | One inventory poll, returning the first reported EPC, signed RSSI, PC, CRC, and timestamp |
| `Get-YRM100Tags` | Timed multiple inventory, returning one result per observed EPC with read counts and signal statistics |
| `Read-YRM100Memory` | Select an EPC and read a memory bank |
| `Write-YRM100Memory` | Select an EPC and write complete words; supports `-WhatIf` |
| `Invoke-YRM100Command` | Send an advanced request/response command and return validated binary data |

Use `Get-Help <command> -Full` for parameter help. Pass the returned connection
object explicitly; multiple readers can have independent connections. Dispose
each connection in `finally`. Module removal does not close connection objects.

## Query RF configuration

```powershell
$reader = Connect-YRM100 COM9
try {
    Get-YRM100Region $reader
    Get-YRM100OutputPower $reader
} finally {
    Disconnect-YRM100 $reader
}
```

Both queries are read-only. Region results contain `RegionCode` and `Region`:
1 = China 900 MHz, 2 = America, 3 = Europe, 4 = China 800 MHz,
6 = South Korea. Unknown codes are preserved with the name `Unknown`.
Power results contain `OutputPowerdBm` and `RawPower` (hundredths of a dBm).
Configured output power is distinct from received tag RSSI and does not measure
radiated power. On COM9, verification returned region 1 (China 900 MHz) and
26 dBm (raw 2600); neither setting was changed.

## Set RF configuration

```powershell
$reader = Connect-YRM100 COM9
try {
    Set-YRM100Region $reader -Region America -WhatIf
    Set-YRM100OutputPower $reader -OutputPowerdBm 20 -WhatIf

    # Remove -WhatIf to apply settings; -PassThru queries the resulting value.
    # Set-YRM100Region $reader -Region America -PassThru
    # Set-YRM100OutputPower $reader -OutputPowerdBm 20 -PassThru
} finally {
    Disconnect-YRM100 $reader
}
```

Region names are `China900`, `America`, `Europe`, `China800`, and `SouthKorea`.
Alternatively use `-RegionCode` with 1, 2, 3, 4, or 6 respectively. Choose either
name or code, not both. Output power accepts 0–26 dBm with at most two decimal
places (`-PowerdBm` is an alias for `-OutputPowerdBm`). The module uses the
26 dBm ceiling of the tested reader; firmware may reject lower settings or
quantize values to its supported steps. Zero dBm does not turn RF off.

Setters require a successful status reply and return no objects by default.
`-PassThru` performs a subsequent query and returns the actual reported setting.
If that query fails, the setting may already have been applied. No automatic
retry or rollback occurs. `-WhatIf` performs no serial I/O. Settings take effect
on the reader; persistence across power cycles is firmware-dependent. The setters
do not alter channel or frequency-hopping configuration. Setter tests use simulated
responses; the attached reader's configuration was not changed during validation.

## Operating channel

```powershell
Import-Module .\YRM100\YRM100.psd1 -Force
$reader = Connect-YRM100 COM9
try {
    Get-YRM100OperatingChannel $reader
    Set-YRM100OperatingChannel $reader -ChannelIndex 1 -WhatIf
    # Apply and query the resulting channel:
    # Set-YRM100OperatingChannel $reader -ChannelIndex 1 -PassThru
} finally {
    Disconnect-YRM100 $reader
}
```

The index is zero-based, not a frequency in MHz. `Get-YRM100OperatingChannel`
queries both channel and region, returning `ChannelIndex`, `RegionCode`, `Region`,
and `FrequencyMHz`. Frequency is calculated using the protocol's region plan:

| Region | Frequency in MHz |
| --- | --- |
| China 900 MHz | 920.125 + index × 0.25 |
| America | 902.25 + index × 0.5 |
| Europe | 865.1 + index × 0.2 |
| China 800 MHz | 840.125 + index × 0.25 |
| South Korea | 917.1 + index × 0.2 |

Unknown region codes return a null frequency. The setter accepts a protocol byte
index (0–255); firmware validates the supported indices for the active region.
This byte range does not mean every index is usable in every region. It requires
a successful status reply and returns no objects unless `-PassThru` is specified.
If readback fails, the setting may already have been applied.

Neither command changes region or automatic frequency hopping. When hopping is
enabled, the channel can change after querying or setting it; calculated frequency
is not a measured or guaranteed fixed transmit frequency. Persistence across
power cycles depends on firmware. Hardware verification on 2026-10-30 using COM9
successfully queried the America region channel, changed index 16 (910.25 MHz)
to index 20 (912.25 MHz), verified the result, then restored index 16 and verified
the restoration. The serial connection was closed afterward.

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
# Read current RF output power using the dedicated query command.
Get-YRM100OutputPower $reader
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
RF-query tests cover exact command bytes, all documented region codes, unknown
codes, integer and fractional output power, malformed payloads, and reader errors.
RF-setter tests cover region mappings, exact power encoding, bounds and precision,
readback, `-WhatIf`, invalid status responses, and reader errors.
Channel tests cover command bytes, region frequency formulas, unknown regions,
readback, byte boundaries, invalid indices, `-WhatIf`, malformed responses, and
reader errors.

Hardware verification on 2026-10-30, COM9 at 115200 baud: identification returned
`M100 26dBm V2.01`, software `V2.4.9`, manufacturer `MagicRf`. Inventory returned
EPC `E2806A960000501FD0783E52`; selecting that EPC and reading two TID words
returned `E2806A96`. No tag memory writes were performed. Write handling has
been verified with simulated responses only. Runtime verification used PowerShell
7; the module declares PowerShell 5.1 compatibility but has not been run under 5.1.

Protocol reference: [M5Stack Unit RFID-UHF common control commands](https://m5stack-doc.oss-cn-shenzhen.aliyuncs.com/842/Unit-RFID-UHF-Protocol-EN.pdf),
which documents the M100 command format. Related hardware may differ; hardware
confirmation is needed for individual firmware variants.
