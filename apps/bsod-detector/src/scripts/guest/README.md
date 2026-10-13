# Guest Scripts

PowerShell scripts that run **inside Windows VMs** via the qemu-guest-agent tunnel.

These scripts configure Windows crash dump settings and clean up pre-test state.

## Script Overview

### `configure-dumps.ps1`

**Purpose**: Apply and verify Windows crash dump registry settings before BSOD injection.

**Called by**: `preflight-rhov.sh` via `guest-agent.py psfile`

**What it configures** (reads from `crash-control.json`):

| Registry Key | Value | Why |
|---|---|---|
| `CrashDumpEnabled` | `7` (Automatic) | Kernel dump → MEMORY.DMP + Minidump. Blocked on KVM but needed for EventLog crash events |
| `AutoReboot` | `0` | **Critical** — keeps VM frozen at BSOD so pipeline can detect and capture |
| `AlwaysKeepMemoryDump` | `1` | Prevents Windows from auto-deleting MEMORY.DMP |
| `Overwrite` | `1` | Overwrite previous dump |
| `LogEvent` | `1` | Write crash event to System EventLog |
| `DumpFile` | `%SystemRoot%\MEMORY.DMP` | Output path for kernel dump |
| `MinidumpDir` | `%SystemRoot%\Minidump` | Minidump output directory |
| `DedicatedDumpFile` | `C:\DedicatedDump.sys` | Bypass pagefile for crash staging |

**DedicatedDumpFile pre-allocation**: If `C:\DedicatedDump.sys` doesn't exist, the script pre-creates it using `fsutil file createnew` sized to `TotalPhysicalMemory + 1MB`. This file is used by Windows for crash dump staging instead of pagefile.

**Reboot detection**: The script returns `rebootRequired=true` if any change requires a reboot (e.g., `CrashDumpEnabled` type change). Preflight will `Die` if reboot is pending — operator must do `virtctl stop && virtctl start` then re-run.

**Output JSON**:
```json
{
  "ok": true,
  "matchesRecommended": true,
  "rebootRequired": false,
  "action": "applied",
  "current": { "CrashDumpEnabled": 7, "AutoReboot": 0, ... },
  "pageFile": { "adequate": true, "configured": "..." }
}
```

**Pagefile note**: Preflight requires `pageFile.adequate=true`. With `DedicatedDumpFile` configured this is satisfied without `pagefile.sys`. The pagefile block was removed from configure-dumps.ps1 because `pagefile.sys` cannot be reliably created on KVM with VirtIO Balloon (Windows Server 2022 lazy pagefile allocation defers creation until memory pressure — which rarely occurs on VMs with ≥16GB RAM).

---

### `clear-dumps.ps1`

**Purpose**: Remove stale crash artifacts from the guest before a new test run.

**Called by**: `trigger-bsod-intentional.sh` (Phase 3 — guest cleanup)

**What it clears**:
- `C:\Windows\MEMORY.DMP`
- `C:\Windows\Minidump\*.dmp`

**What it preserves**:
- `CrashControl` registry settings (do not reset)
- `C:\DedicatedDump.sys` (pre-allocated file — keep it)
- All other system state

**Output JSON** (verified by trigger script):
```json
{ "memory": false, "minidumpCount": 0 }
```
Pipeline fails if `memory=true` or `minidumpCount>0` — ensures clean state before injection.

---

## Platform Limitations (KVM + VirtIO Balloon)

| Artifact | Status | Reason |
|---|---|---|
| `System.evtx` | ✅ Extracted | Offline NTFS read via guestfish |
| `Application.evtx` | ✅ Extracted | Offline NTFS read via guestfish |
| `vm-memory.elf.tar.gz` | ✅ Captured | KubeVirt virtctl memory-dump — always works |
| `MEMORY.DMP` (on-disk) | ❌ Not captured | `AutoReboot=0` prevents the boot that copies DedicatedDump.sys → MEMORY.DMP |
| `Minidump/*.dmp` | ❌ Not captured | Requires `pagefile.sys` which cannot be created on KVM |
| `vm-memory-windows.dmp` | ❌ Not in pipeline | elf2dmp conversion disabled (17GB — developer runs offline) |

**Why pagefile.sys fails on KVM**:
- Windows Server 2022 defers pagefile creation until memory pressure occurs
- VMs with ≥16GB RAM on KVM rarely experience enough pressure to trigger eager pagefile creation
- Multiple approaches attempted: `Set-ItemProperty`, `Win32_PageFileSetting` WMI, .NET Registry API — none resulted in `pagefile.sys` on disk after reboot
- `DedicatedDumpFile` bypasses this entirely for crash dump staging

---

## Golden Image Requirements

These settings must be applied **before sealing the VM image**. Requires one reboot after applying.

```powershell
# Run as Administrator on the VM to be sealed
$cc = 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'
Set-ItemProperty $cc CrashDumpEnabled    7                          -Type DWord
Set-ItemProperty $cc AutoReboot          0                          -Type DWord
Set-ItemProperty $cc AlwaysKeepMemoryDump 1                         -Type DWord
Set-ItemProperty $cc Overwrite           1                          -Type DWord
Set-ItemProperty $cc LogEvent            1                          -Type DWord
Set-ItemProperty $cc DumpFile            '%SystemRoot%\MEMORY.DMP'  -Type ExpandString
Set-ItemProperty $cc MinidumpDir         '%SystemRoot%\Minidump'    -Type ExpandString
Set-ItemProperty $cc DedicatedDumpFile   'C:\DedicatedDump.sys'     -Type ExpandString

# Pre-allocate DedicatedDump.sys (RAM + 1MB)
$size = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory + 1MB
fsutil file createnew C:\DedicatedDump.sys $size

# Disable automatic pagefile (VirtIO Balloon blocks it anyway)
$cs = Get-CimInstance Win32_ComputerSystem
Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $false }
```

Then reboot once before sealing:
```bash
virtctl stop <vm> -n <ns>
virtctl start <vm> -n <ns>
```

**At pipeline runtime**, `configure-dumps.ps1` finds settings already in place → `rebootRequired=false` → preflight passes cleanly.

---

## Guest-Agent Communication

```
host: guest-agent.py psfile configure-dumps.ps1 --companion crash-control.json C:\Windows\Temp\crash-control.json -- -DataFile C:\Windows\Temp\crash-control.json
  ↓
oc exec virt-launcher-<vm>-<hash>
  ↓
virsh qemu-agent-command <ns>_<vm> '<QMP JSON>'
  ↓
qemu-guest-agent (Windows service)
  ↓
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Windows\Temp\configure-dumps.ps1 -DataFile C:\Windows\Temp\crash-control.json
  ↓
stdout/stderr captured → returned to host
```

Scripts run as `NT AUTHORITY\SYSTEM` — full Windows privilege, no interactive input.

## Registry Reference

**CrashControl** (`HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl`):

| Key | Type | Pipeline value |
|---|---|---|
| `CrashDumpEnabled` | DWORD | `7` (Automatic) |
| `AutoReboot` | DWORD | `0` |
| `AlwaysKeepMemoryDump` | DWORD | `1` |
| `Overwrite` | DWORD | `1` |
| `LogEvent` | DWORD | `1` |
| `DumpFile` | ExpandString | `%SystemRoot%\MEMORY.DMP` |
| `MinidumpDir` | ExpandString | `%SystemRoot%\Minidump` |
| `DedicatedDumpFile` | ExpandString | `C:\DedicatedDump.sys` |

**CrashDumpEnabled values**:

| Value | Name | Behavior |
|---|---|---|
| `0` | None | No dump |
| `1` | Complete | Full RAM — needs pagefile ≥ RAM (blocked on KVM) |
| `2` | Kernel | Kernel pages only — needs pagefile (blocked on KVM) |
| `3` | Small/Minidump | 256KB — needs pagefile (blocked on KVM) |
| `7` | **Automatic** | Like kernel, Windows manages pagefile size — **pipeline default** |
| `11` | Filtered | Variable — needs DedicatedDumpFile |

## Related

- `crash-control.json` — Recommended values database (`src/data/`)
- `guest-agent.py` — Execution tunnel (`src/scripts/host/`)
- `preflight-rhov.sh` — Calls configure-dumps.ps1 and validates output (`src/scripts/host/`)
