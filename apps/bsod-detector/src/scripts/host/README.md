# Host Scripts

Scripts that run on the orchestration host (CI operator machine or laptop).

These scripts manage the full BSOD detection and artifact extraction pipeline orchestrated from outside the Kubernetes cluster.

## Script Overview

### `trigger-bsod-intentional.sh`

**Purpose**: Main orchestration entry point for intentional BSOD testing.

**Responsibilities**:
- Validate `BSOD_DET__VM__NAME` and `BSOD_DET__NAMESPACE` are explicitly set (no defaults — prevents wrong-VM targeting)
- Create unique run directory under evidence mount
- Call `preflight-rhov.sh` for environment validation
- Start `watch-crash.sh` in background (monitors VM)
- Inject intentional BSOD via NotMyFault crash trigger
- Wait for watcher to detect crash and extract artifacts
- Report final pipeline status

**Environment Variables**:

| Variable | Purpose |
|---|---|
| `BSOD_DET__VM__NAME` | Target Windows VM name — **must be set explicitly, no default** |
| `BSOD_DET__NAMESPACE` | Kubernetes namespace — **must be set explicitly, no default** |
| `BSOD_DET__EVIDENCE__DIR` | Evidence storage directory (default: `/mnt/persistent-bsod-evidence`) |
| `BSOD_DET__SNAPSHOT__CLASS` | Storage snapshot class |
| `BSOD_DET__READY__TIMEOUT` | Watcher readiness timeout (default: 300s) |
| `BSOD_DET__PREFLIGHT__TIMEOUT` | Preflight timeout (default: 300s) |
| `BSOD_RECOVERY_IMAGE` | Digest-pinned guestfs image (required) |

**Example**:
```bash
BSOD_DET__VM__NAME="win2022-vm-hjoshi1" BSOD_DET__NAMESPACE="windows-bsod" \
  ./trigger-bsod-intentional.sh 0x01
```

---

### `watch-crash.sh`

**Purpose**: Background BSOD detection, memory capture, and recovery orchestration.

**Responsibilities**:
- Poll VM via QGA ping every 5s; detect BSOD when pings exceed miss threshold
- Require `domstate` corroboration (crashed/paused/pmsuspended/running) before entering recovery
- Capture full physical memory via `virtctl memory-dump` → `vm-memory.elf.tar.gz`
- Capture VNC screenshot, domain XML, host signals
- Monitor dump write progress (virsh domstats)
- Stop VM using `virtctl stop`
- Call `recover-natural-crash.sh` for offline NTFS extraction
- Restart VM after recovery
- Generate `evidence-summary.json`

**Developer tools (commented out — run offline)**:
- `elf2dmp` conversion → `vm-memory-windows.dmp` (17GB — removed from pipeline to save mount space)
- Volatility3 analysis (windows.info, crashinfo, driverscan, dumpfiles)

**Primary artifact**: `vm-memory.elf.tar.gz` — raw ELF memory dump from KubeVirt, always captured regardless of Windows disk state.

**Output**:
```
bsod-screenshot.png          (VNC screenshot at crash)
vm-memory.elf.tar.gz         (primary memory artifact ~800MB)
domain.xml                   (libvirt domain configuration at crash)
host-signals.json            (host diagnostics)
launcher-compute.log         (KVM launcher logs)
parse-dump-header.json       (bugcheck code — from elf2dmp if enabled, else stub)
watcher.log                  (full execution trace)
stage-errors.jsonl           (per-stage error tracking)
evidence-summary.json        (final pipeline verdict)
```

---

### `preflight-rhov.sh`

**Purpose**: Fail-closed pre-run validation before crash injection.

**Responsibilities**:
- Verify VMI exists and is in Running state with `runStrategy: Manual`
- Verify QGA is responsive (5 retries × 3s sleep)
- Upload and run `configure-dumps.ps1` on guest — validates crash dump registry
- **Die if `rebootRequired=true`** — CrashDumpEnabled or pagefile changes only take effect after reboot; arming with stale config produces no dump
- Verify `matchesRecommended=true`, `AutoReboot=0`, `pageFile.adequate=true`
- Verify evidence mount matches preflight snapshot (identity marker or mount attributes)
- Validate digest-pinned recovery image contract (`bash+guestfish-v1`)
- Generate `recovery-metadata.json` for downstream phases

**Critical checks**:
- `BSOD_DET__VM__NAME` and `BSOD_DET__NAMESPACE` must be explicitly set (no defaults)
- Recovery image must be digest-pinned (`@sha256:...`)
- `rebootRequired=false` in configure-dumps output — if true: `virtctl stop && virtctl start` then re-run

**Environment Variables**:

| Variable | Purpose |
|---|---|
| `BSOD_DET__MEMORY__DUMP_PVC` | Memory dump PVC name |
| `BSOD_DET__SNAPSHOT__CLASS` | Storage snapshot class |
| `BSOD_DET__COMMAND__TIMEOUT` | Command timeout (default: 30s) |
| `BSOD_DET__PREFLIGHT__TIMEOUT` | Preflight timeout (default: 300s) |

**Output**: `recovery-metadata.json` (VM config, storage details, armed epoch, pre-crash inventory)

---

### `recover-natural-crash.sh`

**Purpose**: Offline NTFS artifact extraction from stopped VM disk.

**Responsibilities**:
- Validate output path and preflight metadata integrity
- Verify source PVC is not attached to any **running** VMI (direct or DataVolume-backed) — API errors block extraction
- Create `guestfs-ntfs` pod using `quay.io/konveyor/oadp-vmfr-access` with `force_tcg` backend (no KVM required)
- Dynamically detect Windows system partition via `guestfish list-filesystems`:
  - Tries each NTFS partition in order (sda3, sda4, etc.)
  - First partition where `System.evtx` / `Application.evtx` are found = Windows `C:\`
  - Non-Windows partitions (recovery, data) log `INFO` and are skipped
- Download ALL target evtx files in **one guestfish session** (single QEMU startup, single mount)
- Transfer from pod to host via `oc cp`; partial files from failed transfers are removed
- Generate `checksums.sha256` manifest (log files excluded — still being written at manifest time)
- Write `extraction-summary.json` via `reliability.py write-summary`

**Developer tools (commented out — run offline)**:
- `extract-evtx.py` call → `events.json` crash detection (requires python-evtx)
- Inline python-evtx parser → `EventLogs/System.json`, `Application.json`

**Output structure**:
```
guestFS_sda3/
  Windows/System32/winevt/Logs/
    System.evtx          (Windows System EventLog — 8MB typical)
    Application.evtx     (Windows Application EventLog — 6MB typical)
parse-dump-header.json   (stub — on-disk dumps blocked on KVM)
events.json              (stub — run extract-evtx.py offline)
checksums.sha256         (manifest of evidence files)
extraction.log           (guestfish extraction trace)
extraction-summary.json  (artifact inventory and validation)
```

**Why no EventLogs/ symlink**: `.evtx` files are directly accessible under `guestFS_<partition>/Windows/System32/winevt/Logs/`. Developer runs `extract-evtx.py` against this path directly.

**Platform limitations (KVM + VirtIO Balloon)**:
- `pagefile.sys` cannot be reliably created — Windows Server 2022 lazy pagefile allocation + balloon driver
- `MEMORY.DMP` (on-disk): Not produced — `AutoReboot=0` prevents the boot that copies DedicatedDump.sys → MEMORY.DMP
- `Minidump`: Not produced — requires pagefile which cannot be created
- Primary dump artifact is always `vm-memory.elf.tar.gz` from KubeVirt

**Environment Variables**:

| Variable | Purpose |
|---|---|
| `BSOD_DET__COMMAND__TIMEOUT` | Command timeout (default: 30s) |
| `BSOD_DET__EXTRACT_EVTX__BIN` | Path to extract-evtx.py (developer use) |
| `BSOD_DET__DATA__DIR` | Data directory for evtx metadata |
| `BSOD_DET__GUESTFS__NTFS_IMAGE` | guestfs pod image override |

---

### `guest-agent.py`

**Purpose**: Tunnel PowerShell commands into Windows VM via qemu-guest-agent.

**How it works**:
```
guest-agent.py <cmd>
  → oc exec virt-launcher-pod
    → virsh qemu-agent-command <domain> '<QMP JSON>'
      → qemu-guest-agent (Windows)
        → PowerShell / program execution
```

**Environment Variables** (re-read at resolve time, not just import time):

| Variable | Purpose |
|---|---|
| `BSOD_DET__VM__NAME` | Target VM name |
| `BSOD_DET__NAMESPACE` | Kubernetes namespace |
| `BSOD_DET__POD__NAME` | Virt-launcher pod (auto-resolved if unset) |
| `BSOD_DET__DOMAIN__NAME` | Libvirt domain name (auto-derived as `<ns>_<vm>`) |

**Subcommands**:
- `ping` — QGA liveness check
- `exec <program> [args]` — run and wait for output
- `exec-crash <program> [args]` — run crash command (handles disconnect as success)
- `psfile <local.ps1> [--companion ...] [-- args]` — upload and run PowerShell script
- `put <local> <guestpath>` — upload file
- `get <guestpath> <local>` — download file

---

### `parse-dump-header.sh`

**Purpose**: Extract Windows bugcheck code from a `.dmp` file header.

**Output**:
```json
{
  "ok": true,
  "totalDumps": 1,
  "dumps": [{
    "file": "vm-memory-windows.dmp",
    "bugCheckCode": "0x00000161",
    "bugCheckName": "LIVE_SYSTEM_DUMP",
    "parameters": ["0x0", "0x0", "0x0", "0x0"],
    "valid": true
  }]
}
```

**Note**: When elf2dmp is disabled (default), `parse-dump-header.json` is written as a stub with `ok=true` and no dumps — the bugcheck code from the ELF dump is not extracted at pipeline time. Developer runs elf2dmp offline and re-runs parse-dump-header.sh.

---

### `reliability.py`

**Purpose**: Artifact validation, evidence integrity, and summary generation.

**Commands**:
- `decision` — crash capture decision from QGA misses + domstate + pvpanic
- `progress-step` — advance dump write progress state machine
- `validate-artifact` — check individual file format (screenshot/memory/dump/evtx/json)
- `write-summary` — generate extraction-summary.json or evidence-summary.json
- `map-disk` — map libvirt disk target to VMI PVC

**Required artifact types per mode**:

| Mode | Required types |
|---|---|
| `intentional-rhov` | screenshot, memory, log, json |
| `natural-rhov` | screenshot, memory, evtx, log, json, checksums |
| `rhov-snapshot-recovery` | memory, evtx, log, json, checksums |

**Note**: `dump` (MEMORY.DMP/Minidump) is **not required** — blocked on KVM (pagefile unavailable).

**Manifest validation rules**:
- Log files (`.log`, `.xml`) — exempt from manifest (still being written at manifest time)
- `checksums.sha256` — exempt from manifest (cannot be in its own manifest)
- Summary files (`extraction-summary.json`, `evidence-summary.json`) — excluded from scan (generated after manifest)
- All other classified artifacts — must have manifest entry and matching hash

---

### `extract-evtx.py`

**Purpose**: Parse Windows `.evtx` EventLog files to JSON with crash detection. **Developer tool — not called by pipeline.**

**Crash detection tiers**:
1. `System/1001` BugCheck — classic BSOD with bugcheck code
2. `Application/1001` LiveKernelEvent — kernel event
3. `System/6008` dirty shutdown

**Usage (offline)**:
```bash
python3 extract-evtx.py --data-dir src/data \
  guestFS_sda3/Windows/System32/winevt/Logs/System.evtx \
  guestFS_sda3/Windows/System32/winevt/Logs/Application.evtx
```

Requires: `pip install python-evtx`

---

## Execution Flow (Intentional Crash)

```
trigger-bsod-intentional.sh
  ├─ preflight-rhov.sh
  │    ├─ QGA ping (5 retries)
  │    ├─ configure-dumps.ps1 → verify rebootRequired=false
  │    └─ write recovery-metadata.json
  │
  ├─ watch-crash.sh (background)
  │    ├─ Poll QGA every 5s
  │    ├─ BSOD detected (misses ≥ threshold + domstate corroboration)
  │    ├─ CaptureScreenshot, CaptureMemory (→ vm-memory.elf.tar.gz)
  │    ├─ CaptureHostSignals
  │    ├─ WaitDumpMonitor (non-fatal on timeout)
  │    ├─ StopVM
  │    ├─ recover-natural-crash.sh
  │    │    ├─ Verify PVC not attached to running VMI
  │    │    ├─ Create guestfs-ntfs pod
  │    │    ├─ Detect Windows partition dynamically
  │    │    ├─ Batch guestfish download (single QEMU session)
  │    │    ├─ oc cp to host
  │    │    └─ write extraction-summary.json
  │    ├─ RestartVM
  │    └─ write evidence-summary.json
  │
  └─ Inject BSOD via guest-agent.py exec-crash notmyfaultc64.exe /crash <type>
```

## Environment Variable Convention

All variables follow Red Hat Chaos Team naming: `BSOD_DET__[<COMPONENT>__]<NAME>`

- Prefix: `BSOD_DET`
- Component separator: `__` (double underscore)
- Multi-word within component: `_` (single underscore)
