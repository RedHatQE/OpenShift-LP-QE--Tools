# BSOD Detector

Detect, capture, and analyze Blue Screen of Death (BSOD) events on Windows VMs
running under KubeVirt / OpenShift Virtualization (RHOV).

---

## What the Pipeline Does

1. **Detects** BSOD by polling the qemu-guest-agent; confirms via `virsh domstate`
2. **Captures** full physical memory via `virtctl memory-dump` → `vm-memory.elf.tar.gz`
3. **Extracts** offline forensics from the stopped VM disk:
   - Windows EventLogs (`System.evtx`, `Application.evtx`) via guestfish NTFS read
   - VNC screenshot of the blue screen
   - Libvirt domain XML, host signals (split-lock, KVM errors, Hyper-V features)
4. **Validates** all artifacts and generates `evidence-summary.json`

---

## Architecture

```
┌────────────────────────────────────────────────────────────┐
│               CI / Orchestration Host                       │
│           trigger-bsod-intentional.sh                       │
└────────┬───────────────────────────────────────────────────┘
         │
   ┌─────▼──────┐     ┌─────────────────┐     ┌────────────────────┐
   │ preflight  │     │  watch-crash.sh │     │recover-natural-    │
   │ -rhov.sh   │──►  │  (background)   │──►  │crash.sh            │
   └─────┬──────┘     └────────┬────────┘     └──────────┬─────────┘
         │                     │                          │
   QGA ping             virtctl memory-dump          guestfs-ntfs pod
   configure-dumps      VNC screenshot               guestfish NTFS mount
   recovery-metadata    domain.xml / host-signals    oc cp → evidence dir
```

---

## Evidence Directory Contents

Every pipeline run produces a directory under `/mnt/persistent-bsod-evidence/`:

| File | Typical Size | Phase | Produced by | Description |
|---|---|---|---|---|
| `recovery-metadata.json` | ~1.3 KB | Pre-BSOD | `preflight-rhov.sh` | VM name, namespace, PVC names, storage class, recovery image digest, armed epoch |
| `watcher-ready` | 42 B | Pre-BSOD | `watch-crash.sh` | Arming marker — written when watcher begins polling |
| `bsod-screenshot.png` | ~37 KB | At BSOD (VM frozen) | `watch-crash.sh` → `virtctl vnc` | VNC screenshot of the Windows blue screen |
| `vm-memory.elf.tar.gz` | ~800 MB–1.4 GB | At BSOD (VM frozen) | `watch-crash.sh` → `virtctl memory-dump` | **Primary dump artifact.** Full physical RAM in ELF ET_CORE format via KubeVirt. Run `elf2dmp` offline to convert for WinDbg / Volatility |
| `domain.xml` | ~14 KB | At BSOD (VM frozen) | `watch-crash.sh` → `virsh dumpxml` inside virt-launcher | Complete libvirt XML at crash time — CPU, memory, disks, devices. Richer than `oc get vmi -o yaml` |
| `launcher-compute.log` | ~100–200 KB | At BSOD (VM frozen) | `watch-crash.sh` → `oc logs` on virt-launcher | Raw QEMU/KVM compute logs — split-lock traps, KVM internal errors, device events |
| `host-signals.json` | ~1.3 KB | At BSOD (VM frozen) | `watch-crash.sh` → `collect-host-signals.sh` | Parsed from `launcher-compute.log` — split-lock count, KVM error count, Hyper-V feature states (tlbflush/ipi/vapic/spinlocks/synictimer), risk assessment |
| `guestFS_sda3/Windows/System32/winevt/Logs/System.evtx` | ~8–9 MB | After VM stopped | `recover-natural-crash.sh` → guestfs-ntfs pod | Windows System EventLog from NTFS. Contains crash event 1001 (BugCheck), dirty shutdown 6008. Partition name (`sda3`) is **detected dynamically** |
| `guestFS_sda3/Windows/System32/winevt/Logs/Application.evtx` | ~6 MB | After VM stopped | `recover-natural-crash.sh` → guestfs-ntfs pod | Windows Application EventLog — Application/1001 LiveKernelEvent and app-level crash events |
| `parse-dump-header.json` | ~146 B | After VM stopped | `recover-natural-crash.sh` | Bugcheck code stub (elf2dmp disabled in pipeline — run offline for actual bugcheck) |
| `events.json` | ~162 B | After VM stopped | `recover-natural-crash.sh` | Crash detection stub — run `extract-evtx.py` offline against `guestFS_*/Windows/System32/winevt/Logs/*.evtx` |
| `checksums.sha256` | ~900 B | After VM stopped | `recover-natural-crash.sh` | SHA-256 manifest of all evidence files (integrity verification) |
| `extraction.log` | ~3–5 KB | After VM stopped | `recover-natural-crash.sh` | Step-by-step guestfish extraction trace |
| `extraction-summary.json` | ~3 KB | After VM stopped | `reliability.py write-summary` | Recovery phase artifact inventory — type, format, size, sha256, valid flag per file |
| `stage-errors.jsonl` | 0 B (success) | Throughout | `watch-crash.sh` + `recover-natural-crash.sh` | One JSON line per stage failure. Empty on clean run |
| `evidence-summary.json` | ~3 KB | End of pipeline | `watch-crash.sh` → `reliability.py write-summary` | Final pipeline verdict: `ok: true/false`, missing artifact types, invalid artifacts |
| `watcher.log` | ~100–120 KB | Throughout | `watch-crash.sh` | Full timestamped execution trace of the entire pipeline |

**Timing overview**:
```
Pre-BSOD     → recovery-metadata.json, watcher-ready
At BSOD      → bsod-screenshot.png, vm-memory.elf.tar.gz (~5–10 min),
               domain.xml, launcher-compute.log, host-signals.json
After stop   → guestFS_sda3/.../System.evtx, Application.evtx,
               parse-dump-header.json, events.json, checksums.sha256,
               extraction.log, extraction-summary.json
End          → stage-errors.jsonl, evidence-summary.json, watcher.log
```

---

## Platform Limitations (KVM + VirtIO Balloon)

| Artifact | Status | Reason |
|---|---|---|
| `vm-memory.elf.tar.gz` | ✅ Always captured | KubeVirt virtctl — independent of Windows disk state |
| `System.evtx` / `Application.evtx` | ✅ Always captured | Offline guestfish NTFS read after VM stopped |
| `MEMORY.DMP` (on-disk) | ❌ Not captured | `AutoReboot=0` prevents boot that copies DedicatedDump.sys → MEMORY.DMP |
| `Minidump/*.dmp` | ❌ Not captured | Requires `pagefile.sys`. Windows Server 2022 on KVM defers pagefile creation until memory pressure (never triggered on ≥16GB VMs) |
| `vm-memory-windows.dmp` | ❌ Not in pipeline | elf2dmp disabled (17GB, run offline) |
| Volatility outputs | ❌ Not in pipeline | Developer tool, run offline against vm-memory.elf.tar.gz |

---

## Offline EventLog Extraction (guestfs-ntfs Pod)

The `.evtx` files are extracted from the stopped VM's NTFS disk using a guestfish pod — **no SSH or Windows reboot required**.

### How it works

```
Stop VM (virtctl stop)
    ↓
Create guestfs-ntfs pod (quay.io/konveyor/oadp-vmfr-access, force_tcg backend)
PVC attached as block device → /dev/vda inside pod
    ↓
Single guestfish session per partition:
  guestfish --ro -a /dev/vda run
    : mount-ro /dev/sda3 /
    : download /Windows/System32/winevt/Logs/System.evtx /tmp/sys.bin
    : download /Windows/System32/winevt/Logs/Application.evtx /tmp/app.bin
    : umount-all
    ↓
oc cp pod:/tmp/sys.bin → guestFS_sda3/Windows/System32/winevt/Logs/System.evtx
oc cp pod:/tmp/app.bin → guestFS_sda3/Windows/System32/winevt/Logs/Application.evtx
    ↓
Delete pod, cleanup
```

**One guestfish session** = one QEMU startup for all target files. Multiple separate sessions caused pod OOM on the second file transfer.

### Dynamic partition detection

```
guestfish list-filesystems returns:
  /dev/sda1: vfat   ← EFI System Partition (skipped — not NTFS)
  /dev/sda2: (none) ← MSR partition (skipped — no filesystem)
  /dev/sda3: ntfs   ← C:\ Windows system partition ← extracted here
  /dev/sda4: ntfs   ← WinRE recovery partition (skipped — no evtx files)

First NTFS partition where System.evtx is found = Windows C:\
```

The partition name (`sda3`) is detected dynamically every run — never hardcoded.

### Security context (Baseline PSS — no escalation)

```yaml
runAsNonRoot: true
fsGroup: 1000800000
seccompProfile: RuntimeDefault
allowPrivilegeEscalation: false
capabilities:
  drop: ["ALL"]
```

`force_tcg` (software QEMU) requires no `/dev/kvm` device — works on any node.

---

## Quick Start

```bash
# 1. Set targets explicitly (no defaults — prevents wrong-VM targeting)
export BSOD_DET__VM__NAME=win2022-vm-hjoshi1
export BSOD_DET__NAMESPACE=windows-bsod

# 2. Run pipeline
./src/scripts/crash-injector/trigger-bsod-intentional.sh 0x01

# 3. Check result
run=$(ls -t /mnt/persistent-bsod-evidence/ | head -1)
cat /mnt/persistent-bsod-evidence/$run/evidence-summary.json | jq '{ok,stageErrors}'
```

**Diagnosing failures**:
```bash
run=/mnt/persistent-bsod-evidence/<run-id>
cat $run/stage-errors.jsonl | jq .
cat $run/evidence-summary.json   | jq '{ok,stageErrors,missingRequiredArtifactTypes,invalidArtifacts}'
cat $run/extraction-summary.json | jq '{ok,stageErrors,missingRequiredArtifactTypes,invalidArtifacts}'
tail -30 $run/extraction.log
```

---

## Golden Image Requirements

The Windows VM image must be pre-configured before pipeline use (one reboot required after applying):

```powershell
# Run as Administrator before sealing the image
$cc = 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'
Set-ItemProperty $cc CrashDumpEnabled    7                          -Type DWord  # Automatic
Set-ItemProperty $cc AutoReboot          0                          -Type DWord  # Stay frozen
Set-ItemProperty $cc AlwaysKeepMemoryDump 1                         -Type DWord
Set-ItemProperty $cc DedicatedDumpFile   'C:\DedicatedDump.sys'     -Type ExpandString

# Pre-allocate DedicatedDump.sys (RAM + 1MB)
$size = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory + 1MB
fsutil file createnew C:\DedicatedDump.sys $size

# Disable automatic pagefile (VirtIO Balloon blocks it on KVM anyway)
$cs = Get-CimInstance Win32_ComputerSystem
Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $false }
```

Then reboot once: `virtctl stop <vm> -n <ns> && virtctl start <vm> -n <ns>`

---

## Developer Tools (Run Offline)

These are **not called by the pipeline** — run manually on captured artifacts:

```bash
# Convert ELF → Windows DMP for WinDbg
elf2dmp vm-memory.elf.tar.gz vm-memory-windows.dmp

# Volatility3 analysis
vol -f vm-memory-windows.dmp windows.info.Info
vol -f vm-memory-windows.dmp windows.crashinfo.CrashInfo

# Parse EventLogs → JSON crash detection
pip install python-evtx
python3 src/scripts/host/extract-evtx.py \
  --data-dir src/data \
  guestFS_sda3/Windows/System32/winevt/Logs/System.evtx \
  guestFS_sda3/Windows/System32/winevt/Logs/Application.evtx
```

---

## Directory Structure

```
apps/bsod-detector/
├── README.md (this file)
├── src/
│   ├── scripts/
│   │   ├── crash-injector/
│   │   │   ├── README.md
│   │   │   └── trigger-bsod-intentional.sh    # Pipeline entry point
│   │   ├── host/
│   │   │   ├── README.md
│   │   │   ├── watch-crash.sh                 # BSOD detection + memory capture
│   │   │   ├── preflight-rhov.sh              # Pre-run validation
│   │   │   ├── recover-natural-crash.sh       # Offline NTFS extraction
│   │   │   ├── guest-agent.py                 # QGA PowerShell tunnel
│   │   │   ├── parse-dump-header.sh           # Bugcheck code extraction
│   │   │   ├── reliability.py                 # Artifact validation + summary
│   │   │   ├── extract-evtx.py                # EventLog → JSON (developer tool)
│   │   │   └── collect-host-signals.sh        # KVM/Hyper-V signal parser
│   │   └── guest/
│   │       ├── README.md
│   │       ├── configure-dumps.ps1            # Windows crash dump config
│   │       └── clear-dumps.ps1                # Pre-test cleanup
│   └── data/
│       ├── crash-control.json                 # CrashControl registry values
│       ├── bugcheck-codes.json                # Windows bugcheck code database
│       └── event-sources.json                 # EventLog source definitions
└── test/
    └── ...                                    # Unit tests
```

---

## Environment Variables

All variables use `BSOD_DET__` prefix (Red Hat Chaos Team convention):

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `BSOD_DET__VM__NAME` | **Yes** | none | Target VM — must be explicit |
| `BSOD_DET__NAMESPACE` | **Yes** | none | Kubernetes namespace — must be explicit |
| `BSOD_DET__EVIDENCE__DIR` | No | `/mnt/persistent-bsod-evidence` | Evidence storage root |
| `BSOD_DET__SNAPSHOT__CLASS` | No | — | Storage snapshot class |
| `BSOD_DET__MEMORY__DUMP_PVC` | No | — | Memory dump PVC name |
| `BSOD_DET__COMMAND__TIMEOUT` | No | `30` | Command timeout (seconds) |
| `BSOD_DET__READY__TIMEOUT` | No | `300` | Watcher readiness timeout |
| `BSOD_DET__PREFLIGHT__TIMEOUT` | No | `300` | Preflight timeout |
| `BSOD_DET__GUESTFS__NTFS_IMAGE` | No | `quay.io/konveyor/oadp-vmfr-access:latest` | guestfs pod image override |
| `BSOD_RECOVERY_IMAGE` | No | — | Digest-pinned recovery image |
