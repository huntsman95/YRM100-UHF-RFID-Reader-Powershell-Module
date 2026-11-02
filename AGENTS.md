# Project handoff and development instructions

Last updated: 2026-10-31. Read this file, README.md, and the current source before
continuing. Treat hardware observations below as historical, not live settings.

## Purpose and current state

This is a PowerShell proof of concept for a user-owned AliExpress YRM100 UHF RFID
reader/writer connected through USB serial. Implement requested features directly
in this module, preserving existing command names and behavior unless the user
requests a change. No external PowerShell dependencies are required.

Current version: **0.5.0**. Latest commit observed during this handoff:
`50b1cb5 Add RF region, output power, and operating channel commands`.
Earlier commit: `79fb0ee V1`. The working tree was clean before this file was added.
The RF/channel work is committed; an earlier session's commit attempt failed due
to sandbox permissions, but that is no longer an outstanding uncommitted change.
Always check current Git state rather than relying on this snapshot.

## Files

- `YRM100/YRM100.psm1`: public commands and private protocol helpers.
- `YRM100/YRM100.psd1`: manifest, version, explicit export list.
- `tests/Test-YRM100.ps1`: dependency-free tests using `FakeYRMPort`; no hardware.
- `README.md`: user examples, parameters, protocol reference, validation history.
- `AGENTS.md`: development conventions and session handoff.

## Public API

- `Get-YRM100Port`: enumerate serial ports.
- `Connect-YRM100`: configurable port, baud rate, timeout, optional DTR/RTS;
  returns a connection object containing `Port`, `TimeoutMilliseconds`, `SyncRoot`.
- `Disconnect-YRM100`: dispose the serial port. Module removal does not close it.
- `Get-YRM100Info`: Hardware, Software, Manufacturer.
- `Get-YRM100Tag`: single poll; returns the first tag, not a complete inventory.
- `Get-YRM100Tags`: timed multiple inventory, default 3 seconds; unique EPC rows
  with latest RSSI, peak RSSI, read count, first/last seen, PC, CRC. Sorted by EPC.
- `Read-YRM100Memory`, `Write-YRM100Memory`: select by EPC, then operate on
  Reserved/EPC/TID/User bank. Addresses and lengths are 16-bit words; 1–32 words.
  Password defaults to eight hex zeros; hex strings have no separators.
- `Get-YRM100Region`, `Set-YRM100Region`: code/name queries and configuration.
  Names/codes: China900=1, America=2, Europe=3, China800=4, SouthKorea=6.
- `Get-YRM100OutputPower`, `Set-YRM100OutputPower`: dBm configuration;
  setter accepts 0–26 dBm in hundredths, matching this reader's 26 dBm ceiling.
  `-PowerdBm` aliases `-OutputPowerdBm`. Zero dBm does not mean RF off.
- `Get-YRM100OperatingChannel`, `Set-YRM100OperatingChannel`: zero-based byte
  index (0–255); firmware validates region-specific supported indices. Getter
  also queries region and calculates FrequencyMHz; unknown region gives null.
- `Invoke-YRM100Command`: advanced synchronous request/response interface.
  Starting multiple inventory (0x27) here is rejected; use Get-YRM100Tags.

RF setters support `-WhatIf`, `-Confirm`, `-PassThru`. They normally return no
objects; PassThru queries the actual resulting setting. A readback failure does
not undo a successful write. Write-YRM100Memory supports ShouldProcess too.

## Protocol and implementation invariants

Reference: https://m5stack-doc.oss-cn-shenzhen.aliyuncs.com/842/Unit-RFID-UHF-Protocol-EN.pdf
(M5Stack's M100-compatible protocol; some prose/examples contain inconsistencies,
so compare frame tables, existing tests, and actual hardware when adding commands.)

Frame: `BB Type Command LengthMSB LengthLSB Data... Checksum 7E`.
Checksum is the low byte of the sum from Type through the last payload byte.
Type 0=host command, 1=response, 2=notification. Length is big endian.
Parse by length: BB and 7E may occur inside a payload. Validate checksum/tail.
RSSI is signed 8-bit dBm. EPC byte length is derived from PC length bits.
Returned tag CRC is exposed; the host does not independently verify RF CRC.

| Operation | Command |
| --- | --- |
| Module information | 03 |
| Single inventory | 22 |
| Multiple inventory / stop | 27 / 28 |
| Set selection / mode | 0C / 12 |
| Read / write memory | 39 / 49 |
| Get / set region | 08 / 07 |
| Get / set output power | B7 / B6 |
| Get / set channel | AA / AB |
| Reader error | FF |

Power payload is an unsigned big-endian value in hundredths of dBm (2000=20 dBm).
Channel payload is one byte. Frequency plans in MHz: China900=920.125+index*0.25;
America=902.25+index*0.5; Europe=865.1+index*0.2;
China800=840.125+index*0.25; SouthKorea=917.1+index*0.2.
Channel configuration does not disable hopping. Region/power setters do not
configure channel or hopping. Persistence across power cycles is not verified.

Use each connection's reentrant Monitor lock for compound transactions. The raw
request function clears pending input before sending, so never use it to consume
an active inventory stream. Get-YRM100Tags writes its own start frame with count
65535, processes notifications, and sends stop in finally. Keep cleanup on errors.
No-tag error 0x15 is normal during multi-inventory and is ignored there; single
polling currently throws it. Other errors terminate. Do not silently swallow
checksum, connection, or firmware failures. Do not automatically retry writes.

Important past bug: memory testing enabled selection mode 0, leaving inventory
filtered to one EPC. This made a second tag appear unreadable. The fix uses mode
**2** (selection for non-inventory operations only) in Set-YRMSelection and at the
start of Get-YRM100Tags. Preserve this fix. Selection masks start at EPC bit 32;
mask length is limited to 248 bits. Identical EPCs cannot be distinguished by
this selection, and scan aggregation combines identical EPCs.

## Development and validation

Maintain PowerShell 5.1 syntax compatibility; runtime tests so far used PowerShell
7. Windows PowerShell 5.1 execution has not yet been verified. Use StrictMode and
explicit exports. When adding a public command, update both export lists, README,
comment-based help, relevant tests, and increment the manifest version as appropriate.
Use existing helpers for framing, endian conversion, and successful status checks.
ShouldProcess previews must perform no serial I/O, including readback queries.

From the project directory:

```powershell
.\tests\Test-YRM100.ps1
Test-ModuleManifest .\YRM100\YRM100.psd1
git diff --check
git status --short
```

Run tests in a fresh PowerShell process when needed because they declare a class.
The suite covers frame bytes, payload delimiters, parsing, timeout/error paths,
memory operations, selection mode, scans/deduplication, cleanup, WhatIf, RF/channel
encoding, bounds, precision, unknown regions, readback, and status validation.
Add meaningful simulated tests for behavior changes; keep tests independent of
attached hardware. Preserve unrelated user edits. Commit when requested.

## Hardware testing and historical observations

Known port: **COM9**, 115200 baud, 8N1, no flow control; default timeout 2000 ms.
Identification: Hardware `M100 26dBm V2.01`, Software `V2.4.9`, Manufacturer `MagicRf`.
Another application/PowerShell connection holding COM9 causes access denied.
Always close the connection in finally. Do not assume the port is available.

```powershell
Import-Module .\YRM100\YRM100.psd1 -Force
$reader = Connect-YRM100 COM9
try {
    Get-YRM100Info $reader
    Get-YRM100Region $reader
    Get-YRM100OutputPower $reader
    Get-YRM100OperatingChannel $reader
    Get-YRM100Tags $reader -DurationSeconds 3
} finally {
    Disconnect-YRM100 $reader
}
```

Hardware tests on 2026-10-30 verified identification, inventory, multi-inventory,
selection and a two-word TID read, region/power queries, channel query/set/readback.
Initial RF query returned China900/code1 and 26 dBm. Later channel testing found
America/code2; do not reset it based on the initial observation. The successful
channel-change test captured index16, set index20, verified 912.25 MHz in America,
then restored index16 and verified 910.25 MHz. COM9 was closed afterward.
Query current settings before any new test; never assume historical settings
are still in effect. For temporary configuration tests, capture and restore the
original setting in finally, then verify restoration. No tag memory writes have
been performed in hardware tests. Region and power setter tests were simulated.
Do not introduce tag writes, password changes, lock, or kill operations as routine
tests; use simulation unless the user specifically requests such hardware work.

Observed test tags (not guaranteed still present):
- `E2806A960000501FD0783E52`: original tag; two TID words returned `E2806A96`.
- `000000000000000000000036`: sticker added near the reader.
- `E2000017570D016823002A0E`: third EPC discovered by multiple inventory.

Less-negative RSSI is stronger. Proximity does not imply single polling will
return that tag. Scans return observed EPCs, not guaranteed physical completeness.

## Environment quirks and follow-up opportunities

In this session, shell workdir/Set-Location could fail due to denied traversal of
`G:\Workspace\Home Lab` even though direct absolute file reads/writes worked.
Use absolute paths, `git -C '<project path>'`, and fail immediately on directory
change failure to avoid running searches against C:\. `apply_patch` with absolute
workspace paths worked. Do not bypass sandbox permissions. Earlier Git staging
failed because .git was read-only; if it recurs, report that rather than claiming
a commit succeeded. The current permission profile still marks .git read-only.

No feature request remains unfinished at handoff. Possible future work, only as
requested: automatic hopping commands, hardware validation of RF setters and tag
writes, PS5.1 validation, richer error codes, and robustness around truncated scan
frames or stop failures (current stop exceptions can mask an earlier scan error).
Verbose raw memory frames contain access password bytes; avoid sharing them.
Update this handoff when material behavior or validation coverage changes.
