# Guest Scripts

PowerShell scripts that run inside Windows VMs via qemu-guest-agent tunnel.

These scripts configure Windows crash dump settings and manage pre-test/post-test state.

## Script Overview

### `configure-dumps.ps1`

**Purpose**: Configure Windows crash dump settings for BSOD detection.

**Responsibilities**:
- Set CrashDumpEnabled registry value (determines what gets dumped)
- Set AutoReboot flag (0 = stay at BSOD screen for capture)
- Set DumpFile path (optional custom dump location)
- Create DedicatedDump.sys pre-allocated dump file (optional)
- Verify configuration was applied correctly
- Report current crash dump state

**Execution**:
```powershell
# Run via guest-agent.py tunnel from host
./guest-agent.py exec configure-dumps.ps1
```

**Configuration Parameters** (passed via crash-control.json):

| Parameter | Type | Typical Value | Purpose |
|---|---|---|---|
| `CrashDumpEnabled` | INT | `1` or `3` or `7` or `11` | Determines what gets dumped (see values below) |
| `AutoReboot` | INT | `0` | 0 = don't reboot (stay at BSOD), 1 = auto reboot |
| `DumpFile` | STRING | `C:\DedicatedDump.sys` | Optional custom dump path |
| `DedicatedDumpSize` | INT | 17179869184 | DedicatedDump.sys size in bytes (16GB typical) |

**CrashDumpEnabled Values**:

| Value | Name | Behavior | Size |
|---|---|---|---|
| `0x00` | None | No dump | 0 bytes |
| `0x01` | Minidump | Only kernel stack traces | 256 KB |
| `0x03` | Kernel dump | Full kernel memory | Variable (~2GB) |
| `0x07` | Complete dump | Full RAM dump to pagefile.sys | ~16GB |
| `0x0B` (11) | Automatic | CrashDumpEnabled=1 + DedicatedDump.sys | 16GB |

**How It Works**:

```powershell
# 1. Load crash-control.json configuration
$config = Get-Content crash-control.json | ConvertFrom-Json

# 2. Set registry values
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl" `
  -Name "CrashDumpEnabled" `
  -Value $config.CrashControl.CrashDumpEnabled `
  -Type DWord

# 3. Verify settings applied
Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl" | 
  Select-Object CrashDumpEnabled, AutoReboot, DumpFile
```

**Environment Handling**:
- Requires **Administrator** privileges (run as SYSTEM via virsh RPC)
- Must disable VirtIO Balloon driver before setting crash dumps (blocks pagefile.sys creation)
- Registry changes take effect on next BSOD
- DedicatedDump.sys is pre-allocated at configuration time (faster than pagefile)

**Output**:
- Registry updated with crash dump settings
- DedicatedDump.sys created on disk (if configured)
- Verification output showing current settings

**Typical Configuration**:

For BSOD detector pipeline, we use:
```json
{
  "CrashDumpEnabled": 11,
  "AutoReboot": 0,
  "DumpFile": "C:\\DedicatedDump.sys",
  "DedicatedDumpSize": 17179869184
}
```

This creates a 16GB DedicatedDump.sys file so Windows doesn't depend on pagefile.sys (which is blocked by KVM balloon driver).

---

### `clear-dumps.ps1`

**Purpose**: Clean up old crash dumps and log files before testing.

**Responsibilities**:
- Remove old crash dumps from C:\Windows\Minidump\
- Remove old .dmp files from system directories
- Clear dump configuration metadata
- Prepare VM disk for fresh BSOD test

**Execution**:
```powershell
# Run via guest-agent.py tunnel to clean up before test
./guest-agent.py exec clear-dumps.ps1
```

**What It Clears**:

| Location | Pattern | Purpose |
|---|---|---|
| `C:\Windows\Minidump\` | `*.dmp` | Old minidump files |
| `C:\` | `MEMORY.DMP`, `Minidump/` | Legacy dump locations |
| System logs | Old event logs | Clean audit trail |

**Why Important**:
- Ensures fresh test state — no old crash artifacts in Minidump directory
- Prevents confusion between old and new crash evidence
- Keeps filesystem clean for new DedicatedDump.sys or pagefile.sys

**Side Effects**:
- Does NOT reset CrashControl registry settings (keeps them as-is)
- Does NOT delete DedicatedDump.sys (pre-allocated file stays)
- Only removes actual dump files and logs from previous crashes

---

## Execution Flow (Full Test Sequence)

```
1. Host: trigger-bsod-intentional.sh
   ├─ Call preflight-rhov.sh
   │  ├─ Call guest-agent.py
   │  │  └─ Execute configure-dumps.ps1 (set crash dump settings)
   │  └─ Verify CrashControl registry configured
   │
   ├─ Optional: clear-dumps.ps1 (clean old artifacts)
   │
   ├─ Inject crash via guest-agent.py
   │  └─ Upload NotMyFault.exe
   │  └─ Execute notmyfault.exe /crash 0x01
   │
   └─ Watch detects BSOD and captures memory
```

## Guest-Agent Communication Protocol

These scripts run **inside the Windows VM** via the qemu-guest-agent tunnel.

**How Host → Guest Communication Works**:

```
Host: guest-agent.py exec configure-dumps.ps1
  ↓
ssh/oc exec → virt-launcher pod
  ↓
virsh RPC → qemu-guest-agent socket
  ↓
qemu-guest-agent (inside VM via QEMU serial channel)
  ↓
PowerShell execution in Windows (guest context)
  ↓
Output captured and returned to host
```

**Key Constraints**:
- Scripts run as SYSTEM (highest Windows privilege level)
- No interactive input possible (command-line only)
- Output limited to stdout/stderr capture
- Files must be uploaded separately (not embedded in commands)
- Timeout: typically 30-60 seconds per command

## Registry Locations

All crash dump configuration is stored in:
```
HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl\
```

**Key Values**:
- `CrashDumpEnabled` (DWORD): What gets dumped (0-11)
- `AutoReboot` (DWORD): Reboot after BSOD (0=no, 1=yes)
- `DumpFile` (STRING): Custom dump file path
- `Overwrite` (DWORD): Overwrite existing dump (1=yes)

**Related Keys**:
- `HKLM:\SYSTEM\CurrentControlSet\Services\VirtIO` — KVM drivers
- `HKLM:\SYSTEM\CurrentControlSet\Services\VirtIOBalloon` — Memory balloon driver

## Known Issues & Workarounds

**Issue**: Pagefile.sys never created (VirtIO Balloon blocks it)
- **Workaround**: Use DedicatedDump.sys instead (`CrashDumpEnabled=11`)
- **Config**: Pre-allocate 16GB file at C:\DedicatedDump.sys

**Issue**: AutoReboot doesn't stick (registry reverts)
- **Workaround**: Disable Windows Update that resets this value
- **Config**: Force `AutoReboot=0` in configure-dumps.ps1

**Issue**: DedicatedDump.sys not written during BSOD
- **Cause**: CrashDumpEnabled must be set BEFORE the BSOD occurs
- **Solution**: Ensure configure-dumps.ps1 runs successfully in preflight

**Issue**: Registry changes require reboot
- **Workaround**: Some settings take effect immediately via group policy refresh
- **Command**: `gpupdate /force` if needed

## Debugging

**From Host**: Check what settings were actually applied
```bash
guest-agent.py exec 'Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl"'
```

**From Guest**: Manual registry check (if you have VM access)
```powershell
Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl" | 
  Select-Object CrashDumpEnabled, AutoReboot, DumpFile, Overwrite
```

## Related Resources

- **crash-control.json**: Database of Windows CrashControl registry values (see `src/data/`)
- **guest-agent.py**: Tunnel for executing these scripts (see `src/scripts/host/`)
- **configure-dumps.ps1**: Main configuration script (this directory)
- **Windows Crash Dump Docs**: https://docs.microsoft.com/en-us/windows-hardware/drivers/debugger/kernel-memory-dump

## Integration with BSOD Detector Pipeline

These guest scripts are called during two phases:

**Phase 1: Preflight (preflight-rhov.sh)**
- Executes configure-dumps.ps1 to set crash dump settings
- Verifies settings via registry read-back
- Builds recovery-metadata.json with configuration details

**Phase 2: Cleanup (optional pre-test)**
- Can run clear-dumps.ps1 to remove old artifacts
- Ensures fresh test state with no prior crash evidence
