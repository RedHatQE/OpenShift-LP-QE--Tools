# BSOD Detector

Detect, capture, and analyze Blue Screen of Death (BSOD) events on Windows VMs
running under KVM/libvirt or KubeVirt/OpenShift Virtualization.

---

## Executive Summary

### Goal

Build a complete BSOD detector for **RHOV/KubeVirt** that:
1. **Detects** BSOD crashes on Windows VMs
2. **Captures** full memory dump via `virtctl memory-dump`
3. **Extracts** offline forensics artifacts from stopped VM disk:
   - Windows Event Logs (System.evtx, Application.evtx)
   - On-disk crash dumps (MEMORY.DMP, Minidump, DedicatedDump.sys)
   - BSOD screenshot
4. **Analyzes** dumps with volatility3 for crash metadata
5. **Validates** all artifacts and generates evidence summary

### What We Successfully Capture (Every Pipeline Run)

| Artifact | Format | Size | Method |
|---|---|---|---|
| `vm-memory-windows.dmp` | Windows pagedu64 | **16GB** | KubeVirt `virtctl memory-dump` → elf2dmp conversion |
| `vm-memory.elf.tar.gz` | ELF tar.gz | ~800MB | Raw memory dump from KubeVirt |
| `bsod-screenshot.png` | PNG | ~37KB | `virtctl` vnc screenshot |
| `EventLogs/System.evtx` | EVTX | ~6MB | NTFS offline extraction (ntfscat) |
| `EventLogs/Application.evtx` | EVTX | ~4MB | NTFS offline extraction (ntfscat) |
| `EventLogs/System.json` | JSON | ~16MB | Python evtx parser (16k+ events) |
| `EventLogs/Application.json` | JSON | ~8MB | Python evtx parser (9k+ events) |
| `volatility-windows-info.txt` | Text | ~1KB | OS/kernel version from memory |
| `volatility-driverscan.txt` | Text | ~120KB | Driver scan from memory |
| `volatility-dumpfiles.txt` | Text | ~120KB | Dump file inventory from memory |
| `parse-dump-header.json` | JSON | ~371B | Bugcheck code, stop reason |
| `domain.xml` | XML | ~14KB | VM config at crash time |

✅ **Pipeline Success Rate**: 100% (all required artifacts captured in runs 3-7)

### What We Cannot Capture (Architectural Blockers)

| Artifact | Why It's Impossible | Investigation Status |
|---|---|---|
| **Minidump** (`C:\Windows\Minidump\*.dmp`) | Requires `pagefile.sys` which Windows refuses to create on this VM (even with balloon driver disabled, explicit registry config, startup scripts, multiple reboots) | ❌ **Permanently blocked** — see INVESTIGATION.md |
| **DedicatedDump.sys** (16GB on-disk dump) | File IS written during BSOD but ntfscat fails to extract large files (works for 6MB .evtx, fails for 16GB .sys); would need ntfs-3g mount instead | ⚠️ **Extractable with code changes** (switch from ntfscat to ntfs-3g mount) |

**Note**: `vm-memory-windows.dmp` (16GB full RAM dump) contains **everything** Minidump would have and much more. Minidump is a 256KB subset — its absence has **zero functional impact** on crash analysis capabilities.

See [`/mnt/persistent-bsod-evidence/INVESTIGATION.md`](/mnt/persistent-bsod-evidence/INVESTIGATION.md) for complete technical investigation (7 pipeline runs, all attempted workarounds documented).

---

## Disk Extraction Methods Investigation

To extract artifacts from the stopped Windows VM disk after BSOD, we tested three approaches. This section documents what worked, what failed, and why.

### Summary of Approaches

| Approach | Method | NTFS Support | Requires Privileged | Status |
|---|---|---|---|---|
| **libguestfs/guestfish** | QEMU appliance built via supermin | ✅ Yes | ✅ Yes | ❌ **FAILED** — supermin cannot build appliance in container (UID namespace restrictions) |
| **virtctl guestfs** | Pre-built QEMU appliance from Red Hat | ❌ No | ❌ No | ⚠️ **PARTIAL** — Can list partitions, cannot mount NTFS (appliance lacks ntfs-3g) |
| **ntfscat/ntfsls** (current) | Direct block device access via libntfs | ✅ Yes | ✅ Yes | ✅ **WORKS** — Successfully extracts small files (EventLogs 6MB), fails on large files (DedicatedDump.sys 16GB) |
| **ntfs-3g mount** (tested) | FUSE NTFS mount | ✅ Yes | ✅ Yes | ✅ **WORKS** — Successfully reads DedicatedDump.sys (16GB) at 601 MB/s |

### Approach 1: libguestfs/guestfish (ABANDONED)

**What we tried**: Install `libguestfs-tools-c` in a privileged container and use `guestfish` to mount NTFS:

```bash
# Custom extraction pod with ubi8:latest
guestfish --ro -a /dev/disk-pvc run : list-filesystems
```

**Critical failure**: Supermin UID namespace restriction

```
supermin exited with error status 1
tar: Cannot change ownership to uid 1000, gid 1000: Operation not permitted
```

**Root cause**: guestfish builds a mini QEMU appliance at runtime using `supermin`. Inside a container, `tar` tries to `chown` files to uid 1000 but fails due to **UID namespace restrictions** — even with `privileged:true`, container processes cannot change file ownership to arbitrary UIDs. This is a fundamental Kubernetes security boundary.

**Additional blockers encountered**:
- PSS baseline blocks `privileged:true` at admission (solvable via temporary escalation)
- `LIBGUESTFS_BACKEND=direct` required (libvirt daemon doesn't run in Kubernetes pods)
- Invalid cache directory `/dev/null` (changed to `/tmp`)

**Verdict**: Even with all workarounds, the supermin appliance build is architecturally incompatible with containerized execution. Abandoned in favor of alternatives.

---

### Approach 2: virtctl guestfs (PARTIAL SUCCESS)

**What we tried**: KubeVirt's built-in `virtctl guestfs` command, which uses a **pre-built appliance** from Red Hat's official image:

```
registry.redhat.io/container-native-virtualization/libguestfs-tools-rhel9@sha256:4a15b04...
```

**Key advantage**: Pre-built appliance at `/usr/local/lib/guestfs/appliance` — **supermin never runs**, avoiding the UID namespace blocker.

**Security context** (no privileged mode required):
```yaml
securityContext:
  allowPrivilegeEscalation: false
  capabilities:
    drop: ["ALL"]
  runAsNonRoot: true  # Can run as root (runAsUser:0) without privileged:true
  seccompProfile:
    type: RuntimeDefault
```

**Test results**:

| Command | Result | Notes |
|---|---|---|
| `guestfish --ro -a /dev/vda run : list-filesystems` | ✅ `/dev/sda3: ntfs` | Disk accessible! Partition table readable |
| `mount-ro /dev/sda3 /` | ❌ `unsupported filesystem type` | NTFS driver missing from appliance |
| `feature-available ntfs3g` | ❌ `false` | ntfs-3g not built into appliance |
| `available-all-groups` | Lists ntfs3g group | Package exists but not in pre-built appliance |

**Why NTFS fails**: Red Hat's libguestfs-tools image is **intentionally stripped** for enterprise deployment:

| Reason | Detail |
|---|---|
| **Licensing** | ntfs-3g is GPL-licensed; Red Hat minimizes GPL components |
| **Support scope** | RHOV/KubeVirt primarily targets **Linux VMs** (RHEL, Fedora, Ubuntu); Windows is secondary |
| **Image size** | Smaller appliance without ntfs-3g = faster Kubernetes pulls |
| **Security surface** | Fewer packages = smaller CVE attack surface |

**Upstream alternative tested**: `quay.io/libguestfs/libguestfs-tools:latest`
- ✅ Includes ntfs-3g and full supermin.d (built from Fedora)
- ❌ **Blocked by registry auth**: `ImagePullBackOff: unauthorized` — repository requires quay.io account credentials (not available on this cluster)
- ⚠️ **Not Red Hat supported** — community image, potential compatibility issues

**Libvirt session mode attempt** (2026-10-05):

Tried `LIBGUESTFS_BACKEND="libvirt:qemu:///session"` to build appliance with ntfs-3g inside the pod:

```
libvirt: XML-RPC error : Failed to connect socket to '/var/run/libvirt/virtqemud-sock'
```

**Root cause**: Both `qemu:///system` and `qemu:///session` URIs require **libvirt daemons** (`virtqemud`) running in the container. Kubernetes pods don't run systemd by default. Would require:
- systemd or supervisor in container
- Likely `privileged:true` for QEMU/KVM device access
- Complex entrypoint setup
- May conflict with KubeVirt's own libvirt infrastructure on the node

The `direct` backend is the only one that works in containerized environments.

**Verdict**: Can LIST partitions without privileged mode, but **cannot MOUNT NTFS** with Red Hat's stripped appliance. Upstream images blocked by registry auth.

---

### Approach 3: guestfish mount-ro (CURRENT PRODUCTION)

**Why chosen**: Two-phase extraction approach using `guestfish` with pod temp file + `oc cp` for reliable binary transfer.

**How it works**:

```bash
# Phase 1: Write to pod temp file (guestfish direct mount)
guestfish --ro -a /dev/vda run : mount-ro /dev/sda3 / : download /Windows/System32/winevt/Logs/System.evtx /tmp/bsod-extract-PID-RANDOM.bin : umount-all

# Phase 2: Copy from pod to host (reliable file transfer)
oc cp pod:/tmp/bsod-extract-PID-RANDOM.bin /host/guestFS/Windows/System32/winevt/Logs/System.evtx -c libguestfs

# Phase 3: Cleanup temp file
rm -f /tmp/bsod-extract-PID-RANDOM.bin
```

**Why two-phase approach**:
- ✅ Bypasses broken stdout redirection through nested shell layers
- ✅ Uses `oc cp` (designed for reliable binary file transfer)
- ✅ Clean separation between extraction and transfer
- ✅ Clear error handling at each phase
- ✅ No FUSE process leaks on pod deletion
- ❌ Previous approach (guestfish stdout redirect) silently failed — files logged as extracted but didn't exist on disk

**Image and Security Context** (no PSS escalation required):

```yaml
image: quay.io/konveyor/oadp-vmfr-access:latest
securityContext:
  runAsNonRoot: true
  fsGroup: 1000800000
  seccompProfile:
    type: RuntimeDefault
  allowPrivilegeEscalation: false
  capabilities:
    drop: ["ALL"]
```

**Why no `privileged:true` needed**:

- **guestfish mount-ro**: Uses direct QEMU backend (no KVM device needed), compatible with PSS baseline
- **No pod privilege escalation**: Runs as non-root (fsGroup: 1000800000), restricted capabilities, RuntimeDefault seccomp
- **No FUSE cleanup issues**: Unlike previous ntfs-3g mount approach (caused stuck FUSE processes on ntfs-test-dedicateddump pod), guestfish has clean process exit

**Implementation Details**:

| Feature | Details |
|---|---|
| **Partition Discovery** | `DiscoverNTFSPartitions()` function — dynamically calls `guestfish list-filesystems`, filters out recovery partitions (sda1/sda2) |
| **Comprehensive Search** | Pre-extraction phase scans all partitions for `*.evtx` files using `guestfish find /` before attempting extraction |
| **Two-Phase Extraction** | Phase 1: guestfish mounts and downloads to pod `/tmp/`; Phase 2: `oc cp` transfers to host; Phase 3: cleanup |
| **Directory Structure** | Files preserved as `guestFS/Windows/System32/winevt/Logs/System.evtx` (full path hierarchy maintained) |
| **Error Handling** | Clear logging at each phase; failures at partition-level don't block fallback extraction attempts |
| **Environment Variables** | Standardized to `BSOD_DET__GUESTFS__NTFS_IMAGE` (Red Hat Chaos Team best practices) |

**Why two-phase approach fixed silent extraction failure**:

Previous single-phase approach tried to redirect guestfish stdout through nested `oc exec` shells:
```bash
# BROKEN: stdout redirection lost in shell layers
oc exec pod -- bash -c 'guestfish ... download path - ...' > host-file
# Files logged as "extracted" but empty or never written
```

New two-phase approach separates concerns:
```bash
# Phase 1: Write inside pod (guestfish handles mount/download)
guestfish --ro -a /dev/vda run : mount-ro /dev/sda3 / : download /path /tmp/outfile : umount-all

# Phase 2: Transfer via oc cp (designed for reliable binary transfer)
oc cp pod:/tmp/outfile /host/path -c container
```

**Success rate**: ✅ 100% for EventLogs (System.evtx ~7.1MB, Application.evtx ~5.1MB)  
**Verified**: Both files are valid Windows Event Log format with proper structure

---

### Approach 4: ntfs-3g Mount (TESTED, NOT INTEGRATED)

**Test date**: 2026-10-05  
**Purpose**: Verify if DedicatedDump.sys (16GB) can be extracted via FUSE mount instead of ntfscat

**Test setup**:

```bash
# Privileged pod with ntfs-3g from EPEL
dnf install -y epel-release
dnf install -y ntfs-3g

# Mount NTFS read-only
mount -t ntfs-3g -o ro,norecovery /dev/disk-pvcp /mnt/ntfs

# Verify file exists and is readable
ls -lh /mnt/ntfs/DedicatedDump.sys
# -rwxrwxrwx. 2 root root 16G Sep 27 21:08 /mnt/ntfs/DedicatedDump.sys
#                               ↑
#                     Timestamp matches BSOD crash time ✓

# Test read performance
dd if=/mnt/ntfs/DedicatedDump.sys of=/tmp/test.dmp bs=1M count=1
# 1+0 records out, 1048576 bytes (1.0 MB) copied, 601 MB/s
```

**Results**:
- ✅ **DedicatedDump.sys IS written** during BSOD (file exists with crash-time timestamp)
- ✅ **File is readable** via ntfs-3g mount (601 MB/s read speed)
- ✅ **File attributes normal**: Archive only (32), not sparse/compressed/encrypted
- ❌ **ntfscat fails** for 16GB files (works for 6MB .evtx, fails for 16GB .sys)

**Root cause of ntfscat failure**: Likely timeout or memory exhaustion when buffering very large files. ntfscat is designed for small file extraction, not multi-gigabyte dumps.

**Potential integration path**:
1. Replace ntfscat extraction logic in `recover-natural-crash.sh` with ntfs-3g mount
2. Add EPEL repository to extraction container image
3. Install `ntfs-3g` package
4. Mount `/dev/disk-pvcp` → `/mnt/ntfs` (read-only)
5. Copy `DedicatedDump.sys` via standard `cp` or `dd`
6. Unmount and cleanup

**Trade-offs**:
- ➕ Works for large files (proven at 16GB)
- ➕ Standard filesystem tools (`ls`, `cp`, `find`) instead of specialized ntfscat
- ➖ More complex setup (EPEL repo, mount/umount lifecycle)
- ➖ Requires FUSE support in kernel (available in RHEL 8/9)
- ➖ Still requires `privileged:true` + PSS escalation (same as ntfscat)

**Operational Issue - FUSE Process Leak** (lessons learned 2026-10-07):

The ntfs-3g approach has a critical operational problem: **Pod deletion doesn't guarantee FUSE process cleanup**.

**Production incident**: Pod `ntfs-test-dedicateddump` (old test pod with ntfs-3g):
- Pod API object deleted cleanly
- **BUT**: ntfs-3g FUSE child process remained stuck on node gs04
- Parent process also blocked during teardown, preventing volume unmount
- Required **targeted FUSE abort** to cleanup residual processes and unmap volumes
- This is why we chose **guestfish** for production (no FUSE, clean exit)

**Verdict**: **Not recommended for production** despite large-file capability, due to:
1. FUSE cleanup complexity requiring manual node-level intervention
2. Cannot automate fully in containerized environment
3. Current pipeline successfully captures `vm-memory-windows.dmp` (16GB full RAM dump) via virtctl — contains everything DedicatedDump.sys would have
4. guestfish mount-ro achieves same functionality without FUSE overhead

---

### Why PSS Escalation is Unavoidable

**Question**: Can we extract NTFS files without changing namespace PSS to `privileged`?

**Answer**: No. Here's the technical chain:

#### The Fundamental Problem

```
PVC attachment:     /dev/disk-pvc → block device 252:352 (full 120GB disk)
NTFS extraction:    Needs /dev/disk-pvcp → block device 252:355 (partition 3)
                                           ↑
                                    Must create with mknod
```

Kubernetes gives us the full disk, but ntfscat/ntfsls (and ntfs-3g) require a **partition device** (GPT partition 3 where Windows C: lives).

#### Why Individual Capabilities Don't Work

```yaml
# Attempt: Add CAP_MKNOD + CAP_SYS_ADMIN
securityContext:
  capabilities:
    add: [CAP_MKNOD, CAP_SYS_ADMIN]

# Result:
mknod /dev/disk-pvcp b 252 355        # ✅ Creates device node
ntfscat /dev/disk-pvcp /Windows/file  # ❌ "Operation not permitted"
```

**Why it fails**: **cgroup device allowlist**

When Kubernetes attaches the PVC as a block device, it configures the pod's cgroup:
```
devices.allow = b 252:352 rwm  (only the declared device)
```

The partition device (252:355) is **not in the allowlist**. Even with capabilities, the kernel blocks I/O to undeclared devices at cgroup level.

**Only `privileged: true`** bypasses the cgroup device allowlist (grants access to all host devices).

#### Why PSS Admission Can't Be Bypassed

```
Request flow:
  oc apply -f pod.yaml
    ↓
  1. API Server
    ↓
  2. PSS Admission Controller  ← RUNS BEFORE RBAC
     Namespace label: pod-security.kubernetes.io/enforce=baseline
     Pod spec: privileged: true
     → ❌ REJECTED: "would violate PodSecurity baseline"
    ↓
  3. RBAC (NEVER REACHED if PSS rejects)
    ↓
  4. SCC (NEVER REACHED if PSS rejects)
```

**PSS admission runs BEFORE authorization** — RBAC/SCC permissions cannot override it.

#### Current Implementation is Secure

**Privilege window**: ~30 seconds (only during extraction pod lifetime)  
**Auto-revert**: `trap EXIT` ensures PSS reverts to baseline even on script crash  
**Scope**: Only `windows-bsod` namespace affected (not cluster-wide)  
**Audit**: Namespace label changes logged in Kubernetes audit logs  

```bash
# recover-natural-crash.sh lines 79-88
function Cleanup () {
  # Delete extraction pod (removes privileged container)
  oc delete pod "${extractionPod}" -n "${ns}" --wait=true
  
  # Revert PSS to baseline
  oc patch namespace "${ns}" \
    -p '{"metadata":{"labels":{"pod-security.kubernetes.io/enforce":"baseline"}}}'
}

trap Cleanup EXIT  # Runs on success, error, or signal (INT/TERM)
```

**No RBAC/SCC alternative**: SecurityContextConstraints (SCC) could theoretically grant `privileged` access to specific service accounts, but PSS admission **rejects the pod before SCC evaluation**. The only path is temporary PSS escalation with immediate auto-revert.

---

### Extraction Method Selection Matrix

**Which approach to use when?**

| Use Case | Recommended Method | Why |
|---|---|---|
| **EventLogs (System.evtx, Application.evtx)** | ntfscat (current) | ✅ Small files (6MB) work reliably; no mount overhead |
| **DedicatedDump.sys (16GB on-disk dump)** | ntfs-3g mount | ntfscat fails on large files; mount proven at 601 MB/s |
| **Minidump (256KB)** | N/A | ❌ Blocked — requires pagefile.sys which doesn't exist |
| **Full RAM dump (16GB)** | virtctl memory-dump | ✅ Already works; no disk extraction needed |
| **List files/directories** | ntfsls -p /path | ✅ Works without mount; faster than mounting for enumeration |

**Current production verdict**: ntfscat for EventLogs + virtctl memory-dump for full RAM = **all required artifacts captured**. DedicatedDump.sys extraction blocked only by ntfscat large-file limitation, not architectural constraint.

---

## File Structure & Script Responsibilities

```
apps/bsod-detector/
├── src/
│   ├── scripts/
│   │   ├── host/                      # Run on orchestration host (CI operator / laptop)
│   │   │   ├── watch-crash.sh         # Main pipeline: detect BSOD → capture dumps → extract artifacts
│   │   │   ├── recover-natural-crash.sh  # Offline NTFS extraction from stopped VM disk
│   │   │   ├── preflight-rhov.sh      # Pre-run validation: checks VM config, builds extraction image
│   │   │   ├── guest-agent.py         # Tunnel PowerShell commands into Windows VM via qemu-guest-agent
│   │   │   ├── reliability.py         # Artifact validation & evidence summary generation
│   │   │   └── extract-evtx.py        # Parse Windows .evtx event logs to JSON
│   │   │
│   │   ├── crash-injector/            # Intentional crash triggers (testing)
│   │   │   └── trigger-bsod-intentional.sh  # Trigger BSOD + run full pipeline
│   │   │
│   │   └── guest/                     # Run inside Windows VM (via guest-agent.py)
│   │       ├── configure-dumps.ps1    # Configure Windows crash dump settings (CrashDumpEnabled, DedicatedDumpFile)
│   │       └── clear-dumps.ps1        # Clean up old crash dumps before test
│   │
│   └── data/
│       └── crash-control.json         # Source of truth for Windows CrashControl registry settings
│
└── README.md                          # This file
```

### Script Execution Flow (Intentional Crash)

```
1. trigger-bsod-intentional.sh (orchestration host)
     ↓
   Calls preflight-rhov.sh
     → Validates VM configuration
     → Builds extraction image (if needed)
     → Verifies crash dump settings via guest-agent.py
     ↓
   Calls watch-crash.sh (background)
     → Monitors VM for BSOD
     → Captures memory dump via virtctl memory-dump
     → Converts ELF → Windows DMP via elf2dmp
     → Runs volatility3 analysis
     ↓
   Injects BSOD via guest-agent.py psfile
     → Runs NotMyFault.exe (bugcheck 0x01)
     ↓
   watch-crash.sh detects BSOD
     → Stops VM (runStrategy: Manual)
     ↓
   Calls recover-natural-crash.sh
     → Temporarily escalates namespace PSS to "privileged"
     → Creates extraction pod with privileged:true
     → Mounts NTFS partition via ntfscat/ntfsls
     → Extracts System.evtx, Application.evtx
     → Auto-reverts PSS to "baseline"
     → Deletes extraction pod
     ↓
   Calls reliability.py write-summary
     → Validates all artifacts (checksums, format)
     → Generates evidence-summary.json
     ↓
   Returns exit code 0 (success) or 1 (failure)
```

### Detailed Pipeline Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ 1. preflight-rhov.sh                                        │
│    Purpose: Validate environment before triggering crash    │
│    ✓ Check VM state (Running, runStrategy: Manual)          │
│    ✓ Check qemu-guest-agent responsive                      │
│    ✓ Validate CrashControl settings (CrashDumpEnabled=1)    │
│    ✓ Verify evidence PVC mounted                            │
│    ✓ Build/verify extraction container image                │
│    → Produces: recovery-metadata.json                       │
└──────────────────┬──────────────────────────────────────────┘
                   ↓
┌─────────────────────────────────────────────────────────────┐
│ 2. guest-agent.py (configure phase)                         │
│    Purpose: Configure Windows crash dump settings           │
│    → Tunnel: oc exec → virt-launcher → virsh → qemu-ga      │
│    → Upload: configure-dumps.ps1 + crash-control.json       │
│    → Execute: Set CrashDumpEnabled=1, AutoReboot=0          │
│    → Create: C:\DedicatedDump.sys (16GB pre-allocated)      │
└──────────────────┬──────────────────────────────────────────┘
                   ↓
┌─────────────────────────────────────────────────────────────┐
│ 3. watch-crash.sh (background monitoring)                   │
│    Purpose: Monitor VM for BSOD and capture memory          │
│    → Start monitoring: Poll VMI status every 5 seconds      │
│    → Detect BSOD: Check vmi.status.guestOSInfo disappeared  │
│    → Capture memory: virtctl memory-dump → memory.bin       │
│    → Convert: elf2dmp → vm-memory-windows.dmp (16GB)        │
│    → Analyze: volatility3 windows.info, crashinfo, dumpfiles│
│    → Stop VM: virtctl stop (freeze at BSOD)                 │
└──────────────────┬──────────────────────────────────────────┘
                   ↓
┌─────────────────────────────────────────────────────────────┐
│ 4. guest-agent.py (inject crash)                            │
│    Purpose: Trigger intentional BSOD for testing            │
│    → Upload: NotMyFault.exe (Sysinternals crash tool)       │
│    → Execute: notmyfault.exe /crash <type>                  │
│    → Result: Windows Blue Screen (bugcheck 0x01 default)    │
└──────────────────┬──────────────────────────────────────────┘
                   ↓
┌─────────────────────────────────────────────────────────────┐
│ 5. recover-natural-crash.sh (offline extraction)            │
│    Purpose: Extract artifacts from stopped VM disk          │
│    → Escalate PSS: baseline → privileged (temporary)        │
│    → Create pod: privileged:true, volumeDevices: /dev/disk  │
│    → Partition: mknod /dev/disk-pvcp (Windows C:)           │
│    → Clear dirty: ntfsfix --clear-dirty /dev/disk-pvcp      │
│    → Extract: ntfscat System.evtx, Application.evtx         │
│    → Parse: extract-evtx.py → System.json, Application.json │
│    → Cleanup: Delete pod, revert PSS to baseline            │
└──────────────────┬──────────────────────────────────────────┘
                   ↓
┌─────────────────────────────────────────────────────────────┐
│ 6. parse-dump-header.sh (analyze)                           │
│    Purpose: Extract bugcheck code from dump header          │
│    → Read: vm-memory-windows.dmp at offset 0x38             │
│    → Extract: Bugcheck code (4 bytes, little-endian)        │
│    → Extract: 4 parameters (8 bytes each, offsets 0x40-0x58)│
│    → Lookup: bugcheck-codes.json for human-readable name    │
│    → Output: parse-dump-header.json                         │
│      {"bugCheckCode": "0x00000161", "bugCheckName": "..."}  │
└──────────────────┬──────────────────────────────────────────┘
                   ↓
┌─────────────────────────────────────────────────────────────┐
│ 7. reliability.py write-summary (validate)                  │
│    Purpose: Validate all artifacts and generate report      │
│    → Check: File formats (dump=PAGEDU64, evtx=ElfFile, etc) │
│    → Verify: Required artifacts present for mode            │
│    → Calculate: SHA256 checksums for all files              │
│    → Generate: evidence-summary.json                        │
│      {"ok": true, "artifacts": [...], "stageErrors": []}    │
└─────────────────────────────────────────────────────────────┘
```

### Script Roles Summary

| Script | Runs Where | Runs When | Purpose |
|---|---|---|---|
| **preflight-rhov.sh** | Orchestrator | Pre-flight | Validate environment (fail-fast) |
| **guest-agent.py** | Orchestrator | Setup + Inject | Configure VM + trigger BSOD |
| **watch-crash.sh** | Orchestrator | Monitoring | Detect crash + dump memory |
| **recover-natural-crash.sh** | Orchestrator | Post-crash | Extract artifacts from stopped disk |
| **parse-dump-header.sh** | Orchestrator | Analysis | Extract bugcheck code |
| **reliability.py** | Orchestrator | Validation | Verify artifacts + generate summary |
| **configure-dumps.ps1** | Inside VM | Setup | Apply Windows CrashControl registry settings |
| **NotMyFault.exe** | Inside VM | Inject | Trigger BSOD (Sysinternals tool) |

**Key insight**: All orchestration scripts run from **your laptop/CI**, not inside the VM. Only `configure-dumps.ps1` and `NotMyFault.exe` execute inside Windows (uploaded via guest-agent.py).

### Key Scripts Deep-Dive

#### `watch-crash.sh` — Main Pipeline Orchestrator

**Purpose**: Detect BSOD, capture memory, extract artifacts, validate evidence

**What it does**:
1. Monitors VM for crash (checks `vmi.status.guestOSInfo`, domain state)
2. Captures full memory via `virtctl memory-dump` (creates VirtualMachineExport)
3. Downloads `memory.bin` (raw ELF format)
4. Converts ELF → Windows DMP via `elf2dmp` (Microsoft tool)
5. Runs volatility3 plugins: `windows.info.Info`, `windows.crashinfo.CrashInfo`, `windows.dumpfiles.DumpFiles`
6. Calls `recover-natural-crash.sh` for offline NTFS extraction
7. Parses dump header for bugcheck code
8. Generates final evidence summary via `reliability.py`

**Key features**:
- Fail-safe: All cleanup in `trap EXIT`
- Timeout handling: `virtctl memory-dump` can take 10+ minutes for 16GB RAM
- Fallback logic: `windows.crashinfo.CrashInfo` → `windows.driverscan.DriverScan` if crashinfo not applicable

**Evidence directory**: `/mnt/persistent-bsod-evidence/YYYYMMDDTHHMMSSZ-<type>-<pid>-<random>/`

---

#### `recover-natural-crash.sh` — Offline NTFS Artifact Extraction

**Purpose**: Extract Windows Event Logs and crash dumps from stopped VM disk without mounting in the VM itself

**What it does**:
1. **Temporarily escalates namespace PSS** from `baseline` to `privileged` (required for privileged pod)
2. **Creates extraction pod**:
   ```yaml
   securityContext:
     privileged: true      # Required: bypass cgroup device allowlist for partition access
     runAsUser: 0
   volumeDevices:
     - name: guest-disk
       devicePath: /dev/disk-pvc   # Full 120GB disk (major:minor 252:352)
   ```
3. **Creates partition device node**:
   ```bash
   mknod /dev/disk-pvcp b 252 355  # Partition 3 (Windows C:)
   ```
4. **Clears NTFS dirty bit** (set by BSOD unclean shutdown):
   ```bash
   ntfsfix --clear-dirty /dev/disk-pvcp
   ```
5. **Extracts files via ntfscat** (direct block device access, no mount):
   ```bash
   ntfscat /dev/disk-pvcp /Windows/System32/winevt/Logs/System.evtx > System.evtx
   ```
6. **Searches for crash dumps**:
   - Scans `/`, `/Windows`, `/Windows/Minidump`, `/Temp` for `*.dmp`, `*.dump`
   - Tries to extract `C:\DedicatedDump.sys` (16GB complete dump)
   - Extracts any found files via ntfscat
7. **Parses Event Logs** to JSON via `extract-evtx.py`
8. **Auto-reverts PSS** to `baseline` (even on crash via `trap EXIT`)
9. **Deletes extraction pod**

**Why PSS escalation is unavoidable**:
- Kubernetes attaches PVC as `/dev/disk-pvc` (full disk, cgroup allowlist: `252:352`)
- ntfscat needs `/dev/disk-pvcp` (partition 3, device `252:355`)
- `mknod` creates partition device successfully, but cgroup blocks I/O to undeclared devices
- Only `privileged: true` bypasses cgroup device allowlist
- PSS `baseline` blocks `privileged:true` at admission (runs before RBAC/SCC)
- **Solution**: Temporary escalation (30 seconds) + auto-revert via `trap EXIT`

See INVESTIGATION.md § "Why PSS Escalation is Unavoidable" for full technical deep-dive.

**Security**:
- Privilege window: ~30 seconds
- Auto-revert: `trap EXIT` ensures PSS reverts even on script crash
- Scope: Only `windows-bsod` namespace affected
- Disk writes: Only 1 bit (ntfsfix clears dirty bit)
- Audit: All namespace label changes logged in Kubernetes audit log

---

#### `preflight-rhov.sh` — Pre-Flight Validation

**Purpose**: Validate environment before running pipeline; prevent failures due to misconfiguration

**What it checks**:
1. **VM requirements**:
   - `runStrategy: Manual` (required for `virtctl stop` after BSOD)
   - qemu-guest-agent running
   - VM is Running (not Paused/Stopped)
2. **CrashControl settings** (via guest-agent.py):
   - `CrashDumpEnabled` matches recommended value (1 = complete dump)
   - `AutoReboot=0` (VM stays frozen at BSOD)
   - `DedicatedDumpFile` exists and is pre-allocated
3. **Kubernetes resources**:
   - Evidence PVC exists and is mounted
   - Snapshot class available (if using snapshots)
   - RBAC permissions for virtctl commands
4. **Extraction image**:
   - Builds container image with ntfs-3g tools (if not already built)
   - Pushes to OpenShift internal registry
   - Validates image pull-ability

**Outputs**:
- `recovery-metadata.json`: VM config, PVC names, image digest, volumeMode
- Exit code 0 (pass) or 1 (fail)

**Usage**:
```bash
bash src/scripts/host/preflight-rhov.sh \
  --ns windows-bsod \
  --vm win2022-vm-hjoshi1 \
  --out /mnt/persistent-bsod-evidence/<runId> \
  --metadata recovery-metadata.json
```

---

#### `guest-agent.py` — Windows VM Command Tunnel

**Purpose**: Execute PowerShell commands inside Windows VM from orchestration host (without SSH/WinRM)

**What it does**:
- Uses KubeVirt qemu-guest-agent channel (exposed via `virtctl guestfs` API)
- Tunnels commands through virt-launcher pod → libvirt → qemu-ga → Windows
- Returns stdout/stderr/exit code

**Subcommands**:

| Subcommand | What It Does | Example |
|---|---|---|
| `exec` | Run PowerShell command | `guest-agent.py exec Get-Service` |
| `psfile` | Upload & execute .ps1 script | `guest-agent.py psfile configure-dumps.ps1` |
| `write` | Write file to guest | `guest-agent.py write crash-control.json C:\Temp\data.json` |
| `read` | Read file from guest | `guest-agent.py read C:\Windows\MEMORY.DMP` |

**Environment variables**:
```bash
export GA_NS=windows-bsod           # Kubernetes namespace
export GA_VM=win2022-vm-hjoshi1     # VM name
```

**Usage**:
```bash
# Check crash dump settings
python3 guest-agent.py exec powershell.exe -NoProfile -Command \
  'Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl" | ConvertTo-Json'

# Configure dumps
python3 guest-agent.py psfile \
  src/scripts/guest/configure-dumps.ps1 \
  --companion src/data/crash-control.json C:\Temp\crash-control.json \
  -- -DataFile C:\Temp\crash-control.json
```

---

#### `configure-dumps.ps1` — Windows Guest Configuration

**Purpose**: Configure Windows to write crash dumps on BSOD

**What it does**:
1. Reads `crash-control.json` for recommended settings
2. Applies registry values under `HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl`:
   - `CrashDumpEnabled = 1` (complete dump)
   - `DedicatedDumpFile = C:\DedicatedDump.sys` (16GB pre-allocated file)
   - `AutoReboot = 0` (stay frozen at BSOD)
   - `AlwaysKeepMemoryDump = 1`
   - `Overwrite = 1`
3. Pre-creates `DedicatedDumpFile` sized to RAM+1MB (via `fsutil`)
4. Verifies settings match recommended values
5. Returns JSON:
   ```json
   {
     "ok": true,
     "action": "applied",
     "matchesRecommended": true,
     "rebootRequired": false
   }
   ```

**Why DedicatedDumpFile instead of pagefile**:
- KVM VMs with balloon driver refuse to create `pagefile.sys`
- `DedicatedDumpFile` is an alternative staging area (Windows 7+)
- Works for `CrashDumpEnabled=1` (complete) or `2` (kernel)
- Does NOT work for `CrashDumpEnabled=3` (small/Minidump) — that requires real pagefile

**Usage** (via guest-agent.py):
```bash
python3 guest-agent.py psfile \
  src/scripts/guest/configure-dumps.ps1 \
  --companion src/data/crash-control.json C:\Temp\crash-control.json \
  -- -DataFile C:\Temp\crash-control.json
```

---

#### `reliability.py` — Artifact Validation & Evidence Summary

**Purpose**: Validate captured artifacts and generate machine-readable evidence summary

**What it does**:
1. **`validate-artifact`**: Check if file matches expected format
   - `dump`: Windows memory dump (pagedu64 header magic)
   - `memory`: ELF format (KubeVirt memory export)
   - `evtx`: Windows Event Log (ElfFile header)
   - `json`: Valid JSON
   - `log`: Non-empty text file
   - `screenshot`: PNG image
2. **`write-summary`**: Generate `evidence-summary.json`
   ```json
   {
     "ok": true,
     "mode": "intentional-rhov",
     "artifacts": [
       {"path": "vm-memory-windows.dmp", "type": "dump", "valid": true, "size": 17129283584, "sha256": "..."},
       {"path": "EventLogs/System.evtx", "type": "evtx", "valid": true, "size": 6361088, "sha256": "..."}
     ],
     "missingRequiredArtifactTypes": [],
     "stageErrors": []
   }
   ```

**Required artifact types by mode**:
- `intentional-rhov`: screenshot, memory, dump, log, json
- `natural-rhov`: screenshot, memory, dump, evtx, log, json, checksums

**Usage**:
```bash
# Validate single artifact
python3 reliability.py validate-artifact --type dump --path vm-memory-windows.dmp

# Generate evidence summary
python3 reliability.py write-summary \
  --out /mnt/persistent-bsod-evidence/<runId> \
  --mode intentional-rhov \
  --vm win2022-vm-hjoshi1 \
  --namespace windows-bsod \
  --run-id <runId>
```

---

#### `parse-dump-header.sh` — Extract Bugcheck Code from Dump

**Purpose**: Read the Windows crash dump header to extract BSOD error code without WinDbg

**What it does**:
1. Reads PAGEDU64 (64-bit Windows dump) binary file at fixed offsets
2. Extracts bugcheck code (4 bytes at offset `0x38`)
3. Extracts 4 bugcheck parameters (8 bytes each at `0x40`, `0x48`, `0x50`, `0x58`)
4. Looks up bugcheck name in `bugcheck-codes.json`
5. Returns structured JSON output

**Example**:
```bash
parse-dump-header.sh vm-memory-windows.dmp
# Or scan directory:
parse-dump-header.sh --dir /mnt/persistent-bsod-evidence/<runId>
```

**Output**:
```json
{
  "ok": true,
  "dumps": [{
    "file": "vm-memory-windows.dmp",
    "bugCheckCode": "0x00000161",
    "bugCheckName": "LIVE_SYSTEM_DUMP",
    "parameters": ["0x1589", "0x0", "0x0", "0x0"],
    "valid": true
  }],
  "warnings": []
}
```

**Common bugcheck codes**:
- `0x00000001` — APC_INDEX_MISMATCH (intentional test crash via NotMyFault)
- `0x00000161` — LIVE_SYSTEM_DUMP (KubeVirt memory export)
- `0x0000000A` — IRQL_NOT_LESS_OR_EQUAL (driver bug)
- `0x0000001E` — KMODE_EXCEPTION_NOT_HANDLED (kernel exception)

**Why needed**: Provides immediate crash classification. The bugcheck code tells you what caused the BSOD (driver bug, memory corruption, test crash, etc.) without needing WinDbg or volatility3.

---

#### `trigger-bsod-intentional.sh` — Full Pipeline Orchestrator

**Purpose**: End-to-end orchestration for intentional BSOD testing (development/CI)

**What it does**:
1. **Preflight** → Calls `preflight-rhov.sh` to validate environment
2. **Start watcher** → Launches `watch-crash.sh` in background
3. **Inject crash** → Uses `guest-agent.py` to upload and run NotMyFault.exe
4. **Wait for completion** → Monitors watcher process
5. **Validate evidence** → Checks `evidence-summary.json` reports success
6. **Cleanup** → Removes temporary guestfish cache files

**Usage**:
```bash
export GA_NS=windows-bsod GA_VM=win2022-vm-hjoshi1

# Default crash type (0x01 - APC_INDEX_MISMATCH)
bash src/scripts/crash-injector/trigger-bsod-intentional.sh

# Custom crash type
bash src/scripts/crash-injector/trigger-bsod-intentional.sh 0x08  # IRQL fault
```

**NotMyFault crash types**:
- `0x01` — APC index mismatch (default)
- `0x02` — High IRQL fault
- `0x03` — Buffer overflow
- `0x04` — Hardcoded breakpoint
- `0x05` — Code overwrite
- `0x08` — Stack overflow
- `0x09` — HAL timer watchdog

**Evidence directory**:
```
/mnt/persistent-bsod-evidence/YYYYMMDDTHHMMSSZ-intentional-<pid>-<random>/
├── vm-memory-windows.dmp      # 16GB full RAM dump
├── vm-memory.elf.tar.gz       # Raw ELF dump from KubeVirt
├── bsod-screenshot.png        # BSOD screen
├── EventLogs/
│   ├── System.evtx            # Windows event log (binary)
│   ├── Application.evtx
│   ├── System.json            # Parsed events (16k+ events)
│   └── Application.json
├── parse-dump-header.json     # Bugcheck code
├── volatility-*.txt           # Memory analysis outputs
├── evidence-summary.json      # Final validation report
└── watcher.log                # Pipeline execution log
```

**Exit codes**:
- `0` — Success (all artifacts captured and validated)
- `1` — Failure (preflight failed, watcher timeout, or evidence validation failed)

---

### Data Files Reference

#### `crash-control.json` — Windows CrashControl Registry Settings

**Location**: `src/data/crash-control.json`

**Purpose**: Source of truth for Windows crash dump configuration

**Structure**:
```json
{
  "registryPath": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\CrashControl",
  "crashDumpTypes": {
    "none":      { "CrashDumpEnabled": 0, "description": "No dump" },
    "complete":  { "CrashDumpEnabled": 1, "description": "Complete memory dump" },
    "kernel":    { "CrashDumpEnabled": 2, "description": "Kernel memory dump" },
    "small":     { "CrashDumpEnabled": 3, "description": "Small/Minidump (64KB)" },
    "automatic": { "CrashDumpEnabled": 7, "description": "Automatic (Win8+)" },
    "filtered":  { "CrashDumpEnabled": 11, "description": "Filtered (variable size)" }
  },
  "recommended": {
    "crashDumpType": "complete",
    "values": {
      "CrashDumpEnabled": 1,
      "AlwaysKeepMemoryDump": 1,
      "Overwrite": 1,
      "LogEvent": 1,
      "AutoReboot": 0,
      "MinidumpDir": "%SystemRoot%\\Minidump",
      "DedicatedDumpFile": "C:\\DedicatedDump.sys"
    }
  }
}
```

**Key settings**:
- `CrashDumpEnabled=1` — Write complete dump to DedicatedDumpFile
- `AutoReboot=0` — **Critical**: Keep VM frozen at BSOD (allows offline extraction)
- `DedicatedDumpFile` — Pre-allocated 16GB file (replaces pagefile for dump staging)
- `AlwaysKeepMemoryDump=1` — Don't delete dump after Event Log written
- `Overwrite=1` — Replace previous dump (testing scenario)

**Why DedicatedDumpFile**:
- KubeVirt VMs with VirtIO balloon driver refuse to create `pagefile.sys`
- DedicatedDumpFile is an alternative staging area (Windows 7+)
- Works for `CrashDumpEnabled=1` (complete) and `2` (kernel)
- Does **NOT** work for `3` (small/Minidump) — that requires real pagefile

**Used by**:
- `configure-dumps.ps1` — Reads recommended settings and applies to Windows registry
- `preflight-rhov.sh` — Validates current settings match recommended

---

#### `bugcheck-codes.json` — Windows BSOD Error Code Mappings

**Location**: `src/data/bugcheck-codes.json`

**Purpose**: Maps numeric bugcheck codes to human-readable names and descriptions

**Structure**:
```json
{
  "codes": {
    "0x00000001": {
      "name": "APC_INDEX_MISMATCH",
      "description": "Asynchronous Procedure Call (APC) state index mismatch"
    },
    "0x00000161": {
      "name": "LIVE_SYSTEM_DUMP",
      "description": "Live dump captured by kernel (not an actual crash)"
    },
    "0x0000000A": {
      "name": "IRQL_NOT_LESS_OR_EQUAL",
      "description": "Driver accessed pageable memory at DISPATCH_LEVEL or higher"
    }
  }
}
```

**Common codes in testing**:
| Code | Name | Cause |
|---|---|---|
| `0x00000001` | APC_INDEX_MISMATCH | NotMyFault intentional crash |
| `0x00000161` | LIVE_SYSTEM_DUMP | KubeVirt memory export (not a real crash) |
| `0x0000000A` | IRQL_NOT_LESS_OR_EQUAL | Driver bug (memory access at wrong IRQL) |
| `0x0000001E` | KMODE_EXCEPTION_NOT_HANDLED | Unhandled kernel exception |
| `0x00000050` | PAGE_FAULT_IN_NONPAGED_AREA | Memory corruption or bad driver |
| `0x000000D1` | DRIVER_IRQL_NOT_LESS_OR_EQUAL | Driver bug (common in network/storage drivers) |

**Used by**:
- `parse-dump-header.sh` — Looks up bugcheck code names
- `watch-crash.sh` — Resolves bugcheck code in final evidence report

**Source**: Microsoft Windows Driver Development documentation

---

## Supported automated reliability path

The fail-closed automated watcher/recovery path is **RHOV/KubeVirt-only**. It
requires `runStrategy: Manual`, a durable evidence mount, a compatible CSI
snapshot class, explicit RBAC, a digest-pinned recovery image, and verified guest
CrashControl/QGA prerequisites. It does not patch platform or guest safety
settings automatically. KVM scripts elsewhere in this repository are separate
development tools, not automatic fallbacks.

See [`docs/rhov-reliability.md`](docs/rhov-reliability.md) for the exact
preflight, state-machine, disk-progress, artifact, failure, and cleanup contract.
Those behaviors are fixture/mock tested; this change does not claim live-cluster
validation.

> **Documentation boundary:** `docs/rhov-reliability.md` and the current script
> `--help` output are the authoritative operational contract. The remaining
> long-form material below contains historical experiments and standalone KVM
> examples; references to automatic reboot, old watcher flags, path1/path2, or
> implicit backend fallback are legacy notes and must not be used as an RHOV
> runbook.

## Architecture

**Offline-first:** the guest is a pure crash target. After a BSOD, the host
stops the VM, mounts the guest disk via guestfs, and extracts crash dumps +
event logs offline. No guest-side scripts, staging, or SSH needed for evidence
collection.

The standalone offline/KVM tools retain a backend dispatch layer. The automated
watcher and snapshot recovery do not use it: they are explicitly RHOV-only and
prefer `virtctl`/`oc`, with narrowly scoped pod-local `virsh` diagnostics.

## What It Captures

Keep it simple. Prefer a small, well-defined tool over a broad framework.

---

## Deployment Model: Where Scripts Run

BSOD detection is a **3-tier distributed system**:

```
┌─────────────────────────┐
│   CI Operator           │  Orchestration host: manages test execution
│   (Local/CI Agent)      │
│                         │
│ • watch-crash.sh        │
│ • guest-agent.py        │
│ • collect-from-host.sh  │
│ • crash-injector/       │
│                         │
└────────────┬────────────┘
             │ oc exec / SSH
             ↓
┌─────────────────────────┐
│ Virt-Launcher Pod       │  Kubernetes: manages the VM
│ (or KVM Host)           │
│                         │
│ • virsh commands        │
│ • VM lifecycle mgmt     │
│ • Evidence extraction   │
│                         │
└────────────┬────────────┘
             │ qemu-guest-agent
             ↓
┌─────────────────────────┐
│ Windows VM (Guest)      │  Test target: configuration and monitoring
│                         │
│ • configure-dumps.ps1   │
│ • clear-dumps.ps1       │
│ • NotMyFault.exe        │
│ (crash trigger)         │
└─────────────────────────┘
```

### CI Operator (CI/CD System or Orchestration Host)

Scripts executed on the orchestration layer to coordinate the entire test pipeline:

- `watch-crash.sh` — natural BSOD detection with automatic escalation
- `guest-agent.py` — tunnel PowerShell commands into the VM
- `collect-from-host.sh` — coordinate detection → capture → analysis
- `src/scripts/crash-injector/` — intentional crash triggers

**Execution context:**
- **KubeVirt:** Via `oc exec` into virt-launcher pod
- **KVM/libvirt:** Directly on the hypervisor host via SSH

---

### Virt-Launcher Pod (Kubernetes) or KVM Host

The hypervisor layer that manages the VM. Scripts here are invoked **indirectly** by the CI Operator:

- `virsh` commands (executed inside the pod or on the KVM host)
- VM lifecycle management (start, stop, snapshot)
- Evidence extraction from disk images
- Memory/screen capture

**Execution method:**
- **KubeVirt:** Inside the `virt-launcher-<vm>-*` pod
- **KVM/libvirt:** On the Linux host directly

---

### Windows VM (Guest)

PowerShell scripts **inside** the Windows guest for one-time configuration:

- `configure-dumps.ps1` — enable full crash dumps (CrashControl registry)
- `clear-dumps.ps1` — clear existing crash dumps before test
- NotMyFault.exe — optional crash trigger utility

**Execution context:**
- **KubeVirt:** Via qemu-guest-agent protocol (SSH not available)
- **KVM/libvirt:** Via SSH connection to Windows guest

---

## Testing Workflow: Commands by Layer

This section shows **exactly which commands run on each layer** during a complete test.

### Complete Test Sequence: Intentional Crash Injection

```
╔════════════════════════════════════════════════════════════════════════════╗
║                         INTENTIONAL CRASH INJECTION FLOW                   ║
╚════════════════════════════════════════════════════════════════════════════╝

PHASE 1: SETUP (One-Time)
─────────────────────────────────────────────────────────────────────────────
┌─────────────────────────────┐
│ CI Operator (Orchestration)  │
│  - Stage toolkit            │
│  - Configure dumps          │
│  - Setup NotMyFault injector│
└──────────────┬──────────────┘
               │ guest-agent.py psfile
               ↓
┌──────────────────────────────┐
│ Virt-Launcher Pod            │
│  - Forward via qemu-agent    │
└──────────────┬───────────────┘
               │ virsh qemu-agent-command
               ↓
┌──────────────────────────────┐
│ Windows VM (Guest)           │
│  [Setup Scripts Execute]     │
│  - Directories created       │
│  - Registry configured       │
│  - NotMyFault.exe installed  │
└──────────────────────────────┘

PHASE 2: CRASH TRIGGER (Per-Test)
─────────────────────────────────────────────────────────────────────────────
┌─────────────────────────────┐
│ CI Operator                  │
│  - Clear old dumps (optional)│
│  - Execute crash command     │
└──────────────┬──────────────┘
               │ guest-agent.py exec
               ↓
┌──────────────────────────────┐
│ Virt-Launcher Pod            │
│  - Forward crash trigger     │
└──────────────┬───────────────┘
               │ virsh qemu-agent-command
               ↓
┌──────────────────────────────┐
│ Windows VM (Guest)           │
│  [CRASH OCCURS]              │
│  notmyfaultc64.exe /crash    │
│  ↓ BSOD triggered (0x01)     │
│  ↓ MEMORY.DMP written        │
│  ↓ Agent unresponsive        │
└──────────────────────────────┘

PHASE 3: EVIDENCE COLLECTION (Offline)
─────────────────────────────────────────────────────────────────────────────
┌─────────────────────────────┐
│ CI Operator                  │
│  - Run host-tools extraction │
└──────────────┬──────────────┘
               │ libguestfs container
               ↓
┌──────────────────────────────┐
│ Disk Image (Offline Mount)   │
│  [Read-Only NTFS Access]     │
│  - Extract MEMORY.DMP        │
│  - Extract Minidump/*.dmp    │
│  - Extract System.evtx       │
│  - Extract Application.evtx  │
└──────────────┬───────────────┘
               │
               ↓
┌──────────────────────────────┐
│ Evidence Directory           │
│  ./evidence/                 │
│  ├── MEMORY.DMP              │
│  ├── Minidump/               │
│  ├── winevt/System.evtx      │
│  ├── winevt/Application.evtx │
│  └── evidence-summary.json   │
└──────────────────────────────┘
```

---

### Layer-by-Layer Commands

#### Layer 1: CI Operator (Your Machine)

**What runs:** Bash/Python orchestration scripts

**Location:** Your laptop, CI/CD pipeline, or anywhere with `oc`/SSH access to cluster

**Commands you execute:**

```bash
# Set variables
export VM=win2022-vm-hjoshi1
export NS=windows-bsod

# 1. Setup: Stage toolkit on guest
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/guest/clear-dumps.ps1
# Expected output: [uploaded ...] [exit 0]

# 2. Setup: Configure crash dumps
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py exec \
  powershell -NoProfile -ExecutionPolicy Bypass \
  -Command 'C:\bsod-detector\src\scripts\guest\configure-dumps.ps1'
# Expected output: Registry keys set, dump type configured

# 3. Prepare: Setup NotMyFault
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/crash-injector/setup-notmyfault.ps1
# Expected output: [uploaded ...] notmyfaultc64.exe present: True

# 4. Action: Trigger crash
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py exec \
  powershell -NoProfile -ExecutionPolicy Bypass \
  -Command 'C:\Temp\nmf\notmyfaultc64.exe /accepteula /crash 0x01'
# Expected output: (timeout or error — guest has crashed, agent unresponsive)
# This is NORMAL and EXPECTED

# 5. Collect: Extract dumps offline
# Resolve disk image dynamically first (see "Resolving Disk Image Paths Dynamically" section)
POD=$(oc get pod -n "$NS" -o name | grep "virt-launcher-${VM}" | head -1 | cut -d/ -f2)
DISK_IMAGE=$(oc -n "$NS" exec "$POD" -- virsh domblklist "${NS}_${VM}" | grep vda | awk '{print $2}')
./host-tools/run.sh --disk "$DISK_IMAGE" \
  --out ./evidence/dumps
# Expected output: MEMORY.DMP extracted, minidumps extracted, JSON result

# 6. Verify: Check evidence
ls -lah ./evidence/dumps/
cat ./evidence/dumps/MEMORY.DMP | head -c 100
```

---

#### Layer 2: Virt-Launcher Pod (Kubernetes)

**What runs:** `virsh` commands and qemu-guest-agent forwarding

**Location:** Inside the `virt-launcher-<vm>-*` pod in the cluster

**Commands that run indirectly** (invoked by `guest-agent.py` on Layer 1):

```bash
# You don't run these directly — guest-agent.py does it for you via oc exec
# But here's what happens inside the pod:

# Check VM is running
virsh -q domifaddr win2022-vm-hjoshi1
# Output: vnet0  52:54:00:12:34:56  ipv4  10.0.0.42/24

# Forward PowerShell command to guest agent
virsh qemu-agent-command "windows-bsod_win2022-vm-hjoshi1" \
  '{"execute":"guest-exec","arguments":{"path":"C:\\Windows\\System32\\cmd.exe",...}}'
# Output: {"return":{"pid":1234}}

# Check guest agent status
virsh qemu-agent-command "windows-bsod_win2022-vm-hjoshi1" '{"execute":"guest-ping"}'
# Output: (hangs or timeout if guest has crashed — EXPECTED)

# After crash: Stop the VM
virsh destroy win2022-vm-hjoshi1
# Output: Domain win2022-vm-hjoshi1 destroyed
```

**How to manually run these (for debugging):**

```bash
# SSH/exec into the pod
POD=$(oc get pod -n windows-bsod -o name | grep virt-launcher-win2022-vm-hjoshi1 | head -1 | cut -d/ -f2)
oc -n windows-bsod exec -it $POD -- bash

# Inside pod, now you can run virsh directly
virsh domifaddr win2022-vm-hjoshi1
virsh qemu-agent-command "windows-bsod_win2022-vm-hjoshi1" '{"execute":"guest-ping"}'
virsh dumpxml win2022-vm-hjoshi1 | grep disk  # Find disk path
```

---

#### Layer 3: Windows VM (Guest)

**What runs:** PowerShell scripts executed via guest-agent

**Location:** Inside the Windows guest VM

**Commands that execute** (via `GA_VM=... guest-agent.py exec`):

```powershell
# 1. Configure crash dumps (runs once)
C:\bsod-detector\src\scripts\guest\configure-dumps.ps1

# What it does:
#   - Sets HKEY_LOCAL_MACHINE\System\CurrentControlSet\Control\CrashControl
#   - AutoReboot = 1 (VM reboots after crash so evidence can be pulled via QGA)
#   - CrashDumpEnabled = 2 (kernel dump)
#   - AlwaysKeepMemoryDump = 1
#   - DumpFile = C:\Windows\MEMORY.DMP
#   - MinidumpDir = C:\Windows\Minidump

# 2. Clear existing dumps before test
C:\bsod-detector\src\scripts\guest\clear-dumps.ps1

# What it does:
#   - Deletes C:\Windows\Minidump\*
#   - Deletes C:\Windows\MEMORY.DMP
#   (MEMORY.DMP must be gone before crash — existing file causes Windows
#   to write only changed pages, producing a fast but partial dump)

# 3. Trigger crash
C:\Temp\nmf\notmyfaultc64.exe /accepteula /crash 0x01

# What it does:
#   - Loads myfault.sys driver
#   - Executes crash code 0x01 (IRQL_NOT_LESS_OR_EQUAL → 0xD1)
#   - Windows writes MEMORY.DMP then reboots (AutoReboot=1)
#   - Guest becomes unresponsive to QGA queries during crash+dump write
```

**Expected behavior:**

| Step | Expected | What to Check |
|------|----------|---------------|
| Setup toolkit | [exit 0] | `oc exec <pod> -- virsh qemu-agent-command ... '{"execute":"guest-ping"}'` returns immediately |
| Configure dumps | Registry set | Guest still responsive to ping |
| Setup NotMyFault | notmyfaultc64.exe present | `ls C:\Temp\nmf\` shows files |
| Trigger crash | **TIMEOUT** | This is EXPECTED — guest crashed, agent unresponsive |
| After crash | No response | `virsh qemu-agent-command` hangs/times out |

---

### Troubleshooting: What to Check at Each Layer

| Symptom | Check | Solution |
|---------|-------|----------|
| `guest-agent.py` hangs on setup | Pod exists and running | `oc get pod -n $NS \| grep virt-launcher` |
| Setup commands timeout | Guest agent responsive | `GA_VM=... guest-agent.py ping` |
| Crash trigger timeout | Expected if crash worked | Wait 30s, VM should be unresponsive |
| Can't extract dumps | Disk image readable | `ls -l /var/lib/libvirt/images/...qcow2` |
| MEMORY.DMP not found | AutoReboot setting | Verify `configure-dumps.ps1` ran successfully |

---

## guest-agent.py Reference

**What it does:** Tunnel PowerShell commands into the Windows guest via qemu-guest-agent.  
**Where it runs:** CI Operator layer (orchestration host or CI/CD pipeline).  
**Transport:** `oc exec` into virt-launcher pod → `virsh qemu-agent-command` → guest.

### Setup Environment

```bash
export VM=win2022-vm-hjoshi1
export NS=windows-bsod

# Verify guest agent is responsive before running anything
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py ping
# Output: (empty/immediate if responsive; timeout if guest unreachable)
```

### Subcommands

| Command | Purpose | Example |
|---------|---------|---------|
| `ping` | Check if guest agent is alive | `GA_VM=$VM GA_NS=$NS python3 ... ping` |
| `exec <program> [args]` | Run a command in guest | `GA_VM=$VM GA_NS=$NS python3 ... exec powershell -Command 'Get-Date'` |
| `psfile <script.ps1> [args]` | Upload and run PowerShell script | `GA_VM=$VM GA_NS=$NS python3 ... psfile src/scripts/guest/configure-dumps.ps1` |
| `put <local> <guest-path>` | Upload file to guest | `GA_VM=$VM GA_NS=$NS python3 ... put file.zip 'C:\Temp\file.zip'` |
| `get <guest-path> <local>` | Download file from guest | `GA_VM=$VM GA_NS=$NS python3 ... get 'C:\Windows\MEMORY.DMP' ./MEMORY.DMP` |

### Quick Reference

```bash
# ONE-TIME SETUP (run once per VM)
export VM=win2022-vm-hjoshi1
export NS=windows-bsod

# 1. Stage toolkit
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/guest/stage-toolkit.ps1

# 2. Configure crash dumps
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/guest/configure-dumps.ps1

# 3. Setup crash trigger (if using NotMyFault)
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/crash-injector/setup-notmyfault.ps1

# BEFORE EACH TEST
# 4. Clear old dumps (optional, for clean evidence)
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/guest/clear-dumps.ps1

# AFTER CRASH
# 5. Extract evidence (guest is now offline/crashed)
# Resolve disk image dynamically first (see "Resolving Disk Image Paths Dynamically" section)
POD=$(oc get pod -n "$NS" -o name | grep "virt-launcher-${VM}" | head -1 | cut -d/ -f2)
DISK_IMAGE=$(oc -n "$NS" exec "$POD" -- virsh domblklist "${NS}_${VM}" | grep vda | awk '{print $2}')
./host-tools/run.sh --disk "$DISK_IMAGE" \
  --out ./evidence/dumps
```

### Performance Considerations: guest-agent.py Slowness

**⚠️ Known Issue:** `guest-agent.py psfile` and `guest-agent.py exec` commands can be **very slow** (30-120+ seconds per command) due to:

1. **qemu-guest-agent overhead** — RPC communication through libvirt/KVM
2. **PowerShell startup time** — Even simple scripts take time to load
3. **Network latency** — oc exec → virt-launcher pod → virsh adds layers
4. **Guest system load** — Heavy I/O or high CPU makes responses slower

**Recommended Timeout Values:**
- `psfile <script>` — **120 seconds** (setup scripts can be slow)
- `exec <command>` — **60 seconds** (simpler commands are faster)
- Large file transfers (`put`, `get`) — **180+ seconds** (I/O bound)

**Optimization Tips:**
- ✅ Batch commands where possible (one large script vs. multiple small ones)
- ✅ Check `GA_VM=$VM GA_NS=$NS python3 ... ping` first (should return immediately)
- ✅ If `ping` hangs, the guest-agent is unresponsive — restart the VM
- ✅ For production, pre-stage setup scripts (stage-toolkit, configure-dumps) once during VM creation
- ✅ Use `host-tools/run.sh` for evidence extraction instead of guest-side collection (offline is faster)

**Debugging:**
```bash
# Check if guest-agent is reachable
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py ping
# Expected: Returns immediately (empty output {})
# If it hangs: guest-agent is unresponsive

# Test with a simple command (60s timeout)
timeout 60 bash -c 'GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py exec powershell -NoProfile -Command "Write-Host done"'
# If this times out: guest may be under high load or unresponsive
```

---

## Integration: Detecting Externally-Triggered BSOD

**Scenario:** An external test operator generates a BSOD via an independent mechanism (not via our crash-injector). The BSOD Detector watches for the event, detects it, and captures evidence automatically.

### External Test Operator Responsibilities

1. **Pre-BSOD Setup** (one-time, before triggering crash):
   - Coordinate with CI Operator to confirm `configure-dumps.ps1` has been executed
   - Verify VM is ready to write full crash dumps (registry configured)
   - Note: AutoReboot=1 is required — VM reboots after crash so evidence can be pulled via QGA

2. **Generate BSOD**:
   - Trigger the crash using external mechanism (independent of this toolkit)
   - Windows writes crash dump to `C:\Windows\MEMORY.DMP`
   - Guest becomes unresponsive to network/agent

3. **Notify CI Operator**:
   - Inform CI Operator when BSOD has been triggered
   - Provide timestamp for correlation
   - CI Operator detects it automatically via `watch-crash.sh`

### CI Operator Responsibilities

```bash
export VM=win2022-vm-hjoshi1
export NS=windows-bsod

# Step 1: ONE-TIME GUEST SETUP (before external test operator triggers BSOD)
echo "=== Configuring guest for crash dump collection ==="
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/guest/configure-dumps.ps1

GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/guest/clear-dumps.ps1

echo "Setup complete. Notify external test operator that VM is ready for BSOD."

# Step 2: START DETECTION WATCHER (before external operator triggers BSOD)
echo "=== Watching for externally-triggered BSOD (will block until detected or timeout) ==="
./src/scripts/host/watch-crash.sh \
  --provider kubevirt \
  --ns $NS \
  --vm $VM \
  --scenario natural \
  --out ./evidence \
  --duration 3600

# (This command will block until BSOD detected)
# External operator triggers crash while this is running
# Detector will automatically:
#   1. Capture screenshot at crash time
#   2. Capture raw VM memory
#   3. Stop the VM
#   4. Extract crash dumps offline via libguestfs

# Step 3: COLLECT & VERIFY RESULTS (after watch-crash.sh exits)
echo "=== Evidence collection complete ==="
ls -lah ./evidence/
cat ./evidence/evidence-summary.json | jq .
cat ./evidence/evidence-summary.json | jq .verdict
```

### Execution Flow

```
╔════════════════════════════════════════════════════════════════════════════╗
║                    EXTERNAL BSOD DETECTION & CAPTURE                       ║
╚════════════════════════════════════════════════════════════════════════════╝

External Operator               CI Operator                 VM (Guest)
     ┌─────────────┐            ┌─────────────┐          ┌──────────────┐
     │  PREPARE    │            │   SETUP     │          │   WAITING    │
     │ (Notify)    │────────→   │ configure   │   ┌─────→│    Ready     │
     │             │            │ dumps.ps1   │   │      │              │
     └─────────────┘            └─────────────┘   │      └──────────────┘
                                                   │
                                 ┌─────────────┐  │
                                 │  WATCH      │──┘
                                 │ watch-crash │
                                 │  (blocking)  │
                                 └──────┬──────┘
                                        │ polls
                                        │ guest-agent every 5s
                                        ├──────────────────→

     ┌──────────┐                                          ┌──────────────┐
     │ TRIGGER  │──→ (external mechanism) ──→ [Crash!] ──→│  BSOD        │
     │  BSOD    │                                         │ Writes MEMORY │
     └──────────┘                                         │ Agent DOWN    │
                                                          └──────┬───────┘
                                 ┌──────────────┐                │
                                 │ DETECTS ✅   │← ─ ─ ─ ─ ─ ─ ┘
                                 │ Unresponsive │
                                 └───────┬──────┘
                                        ┌┴──────────────────────┐
                                        │  ESCALATE:             │
                                        │  1. Screenshot         │
                                        │  2. Memory capture     │
                                        │  3. Stop VM            │
                                        │  4. Extract offline    │
                                        └───────┬────────────────┘
                                                ↓
                                    ┌──────────────────┐
                                    │ ./evidence/      │
     ┌──────────┐                  │  ├─ MEMORY.DMP   │
     │ NOTIFIED │←─────────────────│  ├─ Minidumps    │
     │  Done    │                  │  ├─ Event logs   │
     └──────────┘                  │  └─ JSON summary │
                                    └──────────────────┘
                                         ✅ Analysis Ready
```

### Coordination Checklist

**Pre-BSOD Coordination:**
1. ✅ CI Operator confirms `configure-dumps.ps1` executed successfully
2. ✅ External Test Operator confirms readiness to trigger crash
3. ✅ CI Operator initiates `watch-crash.sh`
4. ✅ Allow ~10 seconds for watch initialization

**During BSOD Trigger:**
5. ✅ External Test Operator triggers crash via designated mechanism
6. ✅ Verify AutoReboot=1 is set so VM reboots and evidence can be collected
7. ✅ Guest unresponsiveness is expected behavior

**Post-BSOD Collection:**
8. ✅ External Test Operator notifies CI Operator upon crash completion
9. ✅ CI Operator's `watch-crash.sh` detects event automatically
10. ✅ Evidence collection to `./evidence/` executes automatically

### Troubleshooting External Integration

| Issue | Cause | Resolution |
|-------|-------|-----------|
| Detector doesn't detect externally-triggered BSOD | Guest agent still responsive | Verify `configure-dumps.ps1` ran and set `AutoReboot=1` |
| MEMORY.DMP not found after crash | Dump not written before VM stopped | Increase detection timeout or verify crash actually occurred |
| Evidence directory empty | Guest agent responsive despite crash | Check if external mechanism actually triggered proper BSOD |
| Timeout waiting for crash | External operator hasn't triggered yet | Verify communication and timing with external operator |

---

## Resolving Disk Image Paths Dynamically

Instead of hardcoding disk image paths like `/var/lib/libvirt/images/win2022-vm-hjoshi1.qcow2`, you can extract the disk path dynamically from the running VM.

### Why Dynamic Resolution?

✅ Works across different hypervisors (KVM/libvirt and KubeVirt)  
✅ Supports custom storage paths  
✅ Makes scripts portable and reusable  
✅ Doesn't depend on naming conventions  

### How to Extract the Disk Path

**For KubeVirt VMs**, query virsh inside the virt-launcher pod:

```bash
# Variables
VM="win2022-vm-hjoshi1"
NS="windows-bsod"
DOM_NAME="${NS}_${VM}"

# 1. Find the virt-launcher pod
POD=$(oc get pod -n "$NS" -o name | grep "virt-launcher-${VM}" | head -1 | cut -d/ -f2)

# 2. Extract disk path using virsh domblklist
DISK_IMAGE=$(oc -n "$NS" exec "$POD" -- virsh domblklist "$DOM_NAME" | grep vda | awk '{print $2}')

# 3. Use the resolved path
./host-tools/run.sh --disk "$DISK_IMAGE" --out ./evidence/dumps
```

**What each step does:**

1. **Find the pod:** Queries KubeVirt for the virt-launcher pod managing your VM
2. **Extract disk:** Uses `virsh domblklist` to list block devices (returns path like `/var/lib/libvirt/images/...qcow2`)
3. **Use path:** Pass to `host-tools/run.sh` for offline evidence extraction

### In Your Test Script

The complete test script (`bsod-detector-test.sh`) automatically does this:

```bash
# Step 0: Resolve VM configuration
POD=$(oc get pod -n "$NS" -o name | grep "virt-launcher-${VM}" | head -1 | cut -d/ -f2)
DISK_IMAGE=$(oc -n "$NS" exec "$POD" -- virsh domblklist "${NS}_${VM}" | grep vda | awk '{print $2}')

# Step 3: Use resolved path for evidence extraction
./host-tools/run.sh --disk "$DISK_IMAGE" --out ./evidence/dumps
```

This eliminates manual disk path lookups and makes the script work on any VM in any namespace.

---

## Test Scenarios

The toolkit supports **3 ways to trigger and capture a BSOD**:

### Scenario 1: Intentional Crash Injection (NotMyFault)

**When to use:** Controlled testing with a known crash code via NotMyFault.exe.

**CI Operator runs:**
```bash
export VM=win2022-vm-hjoshi1
export NS=windows-bsod
export KUBECONFIG=<path-to-kubeconfig>

# ONE-TIME SETUP (run once per VM)

# 1. Stage toolkit (one-time)
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/guest/stage-toolkit.ps1
# Expected: Directories created, guest ready

# 2. Configure crash dumps (one-time)
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/guest/configure-dumps.ps1
# Expected: Registry configured, AutoReboot=1 set, dump type=kernel

# 3. Setup NotMyFault injector (one-time)
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/crash-injector/setup-notmyfault.ps1
# Expected: notmyfaultc64.exe present in C:\Temp\nmf\

# PER-TEST SEQUENCE

# 4. Clear existing dumps (before each test - optional but recommended)
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/guest/clear-dumps.ps1
# Expected: Old dumps cleared, clean slate for new crash

# 5. Trigger the crash
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py exec \
  powershell -NoProfile -ExecutionPolicy Bypass \
  -Command 'C:\Temp\nmf\notmyfaultc64.exe /accepteula /crash 0x01'
# Expected: TIMEOUT (guest has crashed, this is expected)

# 6. Extract evidence offline (guest is now stopped)
# IMPORTANT: Use dynamic disk path resolution (see section above)
POD=$(oc get pod -n "$NS" -o name | grep "virt-launcher-${VM}" | head -1 | cut -d/ -f2)
DISK_IMAGE=$(oc -n "$NS" exec "$POD" -- virsh domblklist "${NS}_${VM}" | grep vda | awk '{print $2}')
./host-tools/run.sh --disk "$DISK_IMAGE" --out ./evidence/dumps
# Expected: MEMORY.DMP extracted, minidumps extracted, JSON result
```

**What happens inside the VM:**
- configure-dumps.ps1 sets registry (AutoReboot=1, CrashDumpEnabled=2 kernel dump)
- NotMyFault.exe executes crash code 0x01
- Windows writes MEMORY.DMP to C:\Windows\

**What the CI Operator captures:**
- BSOD screenshot
- Raw VM memory (optional)
- MEMORY.DMP + minidumps (offline extraction)
- Event logs (.evtx files)

---

### Scenario 2: Natural BSOD Detection (Watch-Crash)

**When to use:** Detecting a real, unplanned BSOD triggered externally (by external test operator).

**CI Operator runs:**
```bash
export VM=win2022-vm-hjoshi1
export NS=windows-bsod
export KUBECONFIG=<path-to-kubeconfig>

# ONE-TIME SETUP (run once per VM)

# 1. Stage toolkit (one-time)
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/guest/stage-toolkit.ps1
# Expected: Directories created, guest ready

# 2. Configure crash dumps (one-time)
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/guest/configure-dumps.ps1
# Expected: Registry configured, AutoReboot=1 set, dump type=kernel

# PER-TEST SEQUENCE

# 3. Clear existing dumps (before each test - optional but recommended)
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/guest/clear-dumps.ps1
# Expected: Old dumps cleared, clean slate for new crash

# 4. Start watching for natural BSOD (blocks until detected)
./src/scripts/host/watch-crash.sh \
  --ns $NS \
  --vm $VM \
  --out ./evidence \
  --interval 5 \
  --miss 2 \
  --reboot-wait 300
# This will block until BSOD detected or timeout occurs
# External Test Operator triggers crash while this is running
# watch-crash.sh automatically:
#   1. Detects guest unresponsiveness
#   2. Captures screenshot
#   3. Captures host-side signals
#   4. Extracts evidence offline
#   5. Generates evidence-summary.json
```

**What happens during monitoring:**
- Continuously polls qemu-guest-agent health
- Detects BSOD/freeze when guest stops responding
- Automatically captures screenshot at crash moment
- Records host-side signals (TLB-flush, split-lock)
- Waits for guest reboot or detects hard-freeze

**What the CI Operator gets:**
- Automatic screenshot at crash time
- Host kernel log analysis
- Crash dump files (if guest reboots)
- Event log evidence
- Evidence summary JSON with crash metadata

See **[docs/natural-bsod-workflow.md](docs/natural-bsod-workflow.md)** for detailed runbook.

---

### Scenario 3: Offline Dump Extraction

**When to use:** VM is already crashed/frozen/stopped; extract evidence from disk image without VM interaction.

**CI Operator runs:**
```bash
# IMPORTANT: Resolve disk image dynamically (see section above)
VM="win2022-vm-hjoshi1"
NS="windows-bsod"
POD=$(oc get pod -n "$NS" -o name | grep "virt-launcher-${VM}" | head -1 | cut -d/ -f2)
DISK_IMAGE=$(oc -n "$NS" exec "$POD" -- virsh domblklist "${NS}_${VM}" | grep vda | awk '{print $2}')

# Method 1: Direct extraction via host-tools
./host-tools/run.sh \
  --disk "$DISK_IMAGE" \
  --out ./evidence/dumps
# Expected: MEMORY.DMP extracted, minidumps extracted, JSON result

# Method 2: Via collect-offline orchestrator
./src/scripts/host/collect-offline.sh \
  --vm win2022-vm-hjoshi1 \
  --out ./evidence
# Expected: Full evidence bundle with analysis
```

**What happens:**
- ✅ Mounts disk image via libguestfs (read-only)
- ✅ Extracts MEMORY.DMP and minidumps from C:\Windows\
- ✅ Extracts event logs (.evtx files)
- ✅ Parses dump headers for crash analysis
- ✅ No VM interaction or reboots needed

**Useful for:**
- Unbootable/unconfigurable guests
- Frozen VMs (cannot reach via guest-agent)
- Post-mortem analysis of existing disk images
- Recovery from hard-freeze states

---

## Execution Environments

### KubeVirt (OpenShift Cluster)

**Use when:** Testing in Kubernetes/OpenShift environment.

**CI Operator location:** Your laptop or CI/CD pipeline  
**Command pattern:**
```bash
GA_VM=<vm-name> GA_NS=<namespace> python3 src/scripts/host/guest-agent.py <subcommand>
oc -n <namespace> exec <virt-launcher-pod> -- virsh <cmd>
```

**Transport:** `oc exec` into virt-launcher pod → `virsh qemu-agent-command` → guest

**Example (from earlier):**
```bash
export VM=win2022-vm-hjoshi1
export NS=windows-bsod

# Trigger crash injection
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/crash-injector/setup-notmyfault.ps1
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py exec \
  powershell -Command 'C:\Temp\nmf\notmyfaultc64.exe /accepteula /crash 0x01'

# Watch for natural BSOD
./src/scripts/host/watch-crash.sh \
  --provider kubevirt --ns $NS --vm $VM --out ./evidence
```

---

### KVM/libvirt (Local Host)

**Use when:** Testing locally on KVM/libvirt infrastructure.

**CI Operator location:** The KVM host itself  
**Command pattern:**
```bash
export VM_NAME=bsod-test
export LIBVIRT_DEFAULT_URI=qemu:///system

src/scripts/host/guest-ssh.sh -c '<PowerShell command>'
# For disk path, use: virsh domblklist <vm> | grep vda | awk '{print $2}'
# or the dynamic resolution pattern (see "Resolving Disk Image Paths Dynamically" section)
./host-tools/run.sh --disk <resolved-disk-image> --out ./output
```

**Transport:** SSH to Windows guest or `virsh` on the host

**Example (local testing):**
```bash
export VM_NAME=bsod-test

# Trigger crash injection
src/scripts/host/guest-ssh.sh -f src/scripts/crash-injector/setup-notmyfault.ps1
src/scripts/host/guest-ssh.sh -c 'C:\Temp\nmf\notmyfaultc64.exe /accepteula /crash 0x01'

# Watch for natural BSOD
./src/scripts/host/watch-crash.sh \
  --provider kvm --vm $VM_NAME --out ./evidence

# Or extract from offline image directly
# Resolve disk path: virsh domblklist $VM_NAME | grep vda | awk '{print $2}'
DISK_IMAGE=$(virsh domblklist $VM_NAME | grep vda | awk '{print $2}')
./host-tools/run.sh --disk "$DISK_IMAGE" --out ./output
```

---

## Conventions

### Scripts as tooling

Deterministic operations live in scripts with clear stdin/stdout contracts.

- **Scripts produce facts; humans make decisions.** Data collection, parsing dump files, reading event logs, and formatting output belong in scripts. Interpreting a crash or deciding how to act on it is a human call.
- `src/scripts/` contains guest collection and configuration scripts. Host-side collectors (such as `collect-host-signals.sh`) also live here when they consume `src/data/` lookups and follow the same output contract. Each collector script does one thing and emits exactly one JSON object to stdout so downstream steps can consume it with `jq` or `json.loads()`. Helper scripts like `capture-vm-screen.sh` that produce file artifacts instead of JSON are excluded from this contract.
- Every script is documented in [`src/scripts/README.md`](src/scripts/README.md): what it does, its inputs, and its output shape.
- **No hardcoded duplicated data.** Bug-check code tables, driver mappings, and log source names come from a single source-of-truth file that scripts read; never copy the same lookup into multiple scripts.

### Style

- Windows-first. Scripts are PowerShell (`.ps1`) unless there is a reason to use another language; note the requirement at the top of each script.
- Keep functions small and testable. Fail loudly with clear error messages.
- Never require interactive input in a script that may run unattended after a crash.

Keep it simple. Prefer a small, well-defined tool over a broad framework.

- Bug-check (stop) code and parameters, resolved via `data/bugcheck-codes.json`
- Crash dump files (`MEMORY.DMP`, minidumps) extracted offline from the guest disk
- Windows event log entries (System/Application `.evtx`) parsed offline
- Host-side signals (kernel log split-lock `#AC`, Hyper-V enlightenments)
- Raw VM memory backup (ELF format, via `virsh dump --memory-only`)
- BSOD screenshot (framebuffer capture)

---

## Deployment Model: Where Scripts Run

BSOD detection is a **3-tier distributed system**:

```
┌─────────────────────────┐
│   CI Operator           │  Orchestration host: manages test execution
│   (Local/CI Agent)      │
│                         │
│ • watch-crash.sh        │
│ • guest-agent.py        │
│ • collect-from-host.sh  │
│ • crash-injector/       │
│                         │
└────────────┬────────────┘
             │ oc exec / SSH
             ↓
┌─────────────────────────┐
│ Virt-Launcher Pod       │  Kubernetes: manages the VM
│ (or KVM Host)           │
│                         │
│ • virsh commands        │
│ • VM lifecycle mgmt     │
│ • Evidence extraction   │
│                         │
└────────────┬────────────┘
             │ qemu-guest-agent
             ↓
┌─────────────────────────┐
│ Windows VM (Guest)      │  Test target: configuration and monitoring
│                         │
│ • configure-dumps.ps1   │
│ • clear-dumps.ps1       │
│ • NotMyFault.exe        │
│ (crash trigger)         │
└─────────────────────────┘
```

### CI Operator (CI/CD System or Orchestration Host)

Scripts executed on the orchestration layer to coordinate the entire test pipeline:

- `watch-crash.sh` — natural BSOD detection with automatic escalation
- `guest-agent.py` — tunnel PowerShell commands into the VM
- `collect-from-host.sh` — coordinate detection → capture → analysis
- `src/scripts/crash-injector/` — intentional crash triggers

**Execution context:**
- **KubeVirt:** Via `oc exec` into virt-launcher pod
- **KVM/libvirt:** Directly on the hypervisor host via SSH

---

### Virt-Launcher Pod (Kubernetes) or KVM Host

The hypervisor layer that manages the VM. Scripts here are invoked **indirectly** by the CI Operator:

- `virsh` commands (executed inside the pod or on the KVM host)
- VM lifecycle management (start, stop, snapshot)
- Evidence extraction from disk images
- Memory/screen capture

**Execution method:**
- **KubeVirt:** Inside the `virt-launcher-<vm>-*` pod
- **KVM/libvirt:** On the Linux host directly

---

### Windows VM (Guest)

PowerShell scripts **inside** the Windows guest for one-time configuration:

- `configure-dumps.ps1` — enable full crash dumps (CrashControl registry)
- `clear-dumps.ps1` — clear existing crash dumps before test
- NotMyFault.exe — optional crash trigger utility

**Execution context:**
- **KubeVirt:** Via qemu-guest-agent protocol (SSH not available)
- **KVM/libvirt:** Via SSH connection to Windows guest

---

## Testing Workflow: Commands by Layer

This section shows **exactly which commands run on each layer** during a complete test.

### Complete Test Sequence: Intentional Crash Injection

```
╔════════════════════════════════════════════════════════════════════════════╗
║                         INTENTIONAL CRASH INJECTION FLOW                   ║
╚════════════════════════════════════════════════════════════════════════════╝

PHASE 1: SETUP (One-Time)
─────────────────────────────────────────────────────────────────────────────
┌─────────────────────────────┐
│ CI Operator (Orchestration)  │
│  - Stage toolkit            │
│  - Configure dumps          │
│  - Setup NotMyFault injector│
└──────────────┬──────────────┘
               │ guest-agent.py psfile
               ↓
┌──────────────────────────────┐
│ Virt-Launcher Pod            │
│  - Forward via qemu-agent    │
└──────────────┬───────────────┘
               │ virsh qemu-agent-command
               ↓
┌──────────────────────────────┐
│ Windows VM (Guest)           │
│  [Setup Scripts Execute]     │
│  - Directories created       │
│  - Registry configured       │
│  - NotMyFault.exe installed  │
└──────────────────────────────┘

PHASE 2: CRASH TRIGGER (Per-Test)
─────────────────────────────────────────────────────────────────────────────
┌─────────────────────────────┐
│ CI Operator                  │
│  - Clear old dumps (optional)│
│  - Execute crash command     │
└──────────────┬──────────────┘
               │ guest-agent.py exec
               ↓
┌──────────────────────────────┐
│ Virt-Launcher Pod            │
│  - Forward crash trigger     │
└──────────────┬───────────────┘
               │ virsh qemu-agent-command
               ↓
┌──────────────────────────────┐
│ Windows VM (Guest)           │
│  [CRASH OCCURS]              │
│  notmyfaultc64.exe /crash    │
│  ↓ BSOD triggered (0x01)     │
│  ↓ MEMORY.DMP written        │
│  ↓ Agent unresponsive        │
└──────────────────────────────┘

PHASE 3: EVIDENCE COLLECTION (Offline)
─────────────────────────────────────────────────────────────────────────────
┌─────────────────────────────┐
│ CI Operator                  │
│  - Run host-tools extraction │
└──────────────┬──────────────┘
               │ libguestfs container
               ↓
┌──────────────────────────────┐
│ Disk Image (Offline Mount)   │
│  [Read-Only NTFS Access]     │
│  - Extract MEMORY.DMP        │
│  - Extract Minidump/*.dmp    │
│  - Extract System.evtx       │
│  - Extract Application.evtx  │
└──────────────┬───────────────┘
               │
               ↓
┌──────────────────────────────┐
│ Evidence Directory           │
│  ./evidence/                 │
│  ├── MEMORY.DMP              │
│  ├── Minidump/               │
│  ├── winevt/System.evtx      │
│  ├── winevt/Application.evtx │
│  └── evidence-summary.json   │
└──────────────────────────────┘
```

---

### Layer-by-Layer Commands

#### Layer 1: CI Operator (Operator Workstation)

**What runs:** Bash/Python orchestration scripts

**Location:** The operator workstation, CI/CD pipeline, or anywhere with `oc`/SSH access to cluster

**Commands executed at this layer:**

```bash
# Set these to match the target environment
export VM="<vm-name>"
export NS="<namespace>"

# 1. Setup: Stage toolkit on guest
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/guest/clear-dumps.ps1
# Expected output: [uploaded ...] [exit 0]

# 2. Setup: Configure crash dumps
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py exec \
  powershell -NoProfile -ExecutionPolicy Bypass \
  -Command 'C:\bsod-detector\src\scripts\guest\configure-dumps.ps1'
# Expected output: Registry keys set, dump type configured

# 3. Prepare: Setup NotMyFault
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/crash-injector/setup-notmyfault.ps1
# Expected output: [uploaded ...] notmyfaultc64.exe present: True

# 4. Action: Trigger crash
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py exec \
  powershell -NoProfile -ExecutionPolicy Bypass \
  -Command 'C:\Temp\nmf\notmyfaultc64.exe /accepteula /crash 0x01'
# Expected output: (timeout or error — guest has crashed, agent unresponsive)
# This is NORMAL and EXPECTED

# 5. Collect: Extract dumps offline
# Resolve disk image dynamically first (see "Resolving Disk Image Paths Dynamically" section)
POD=$(oc get pod -n "$NS" -o name | grep "virt-launcher-${VM}" | head -1 | cut -d/ -f2)
DISK_IMAGE=$(oc -n "$NS" exec "$POD" -- virsh domblklist "${NS}_${VM}" | grep vda | awk '{print $2}')
./host-tools/run.sh --disk "$DISK_IMAGE" \
  --out ./evidence/dumps
# Expected output: MEMORY.DMP extracted, minidumps extracted, JSON result

# 6. Verify: Check evidence
ls -lah ./evidence/dumps/
cat ./evidence/dumps/MEMORY.DMP | head -c 100
```

---

#### Layer 2: Virt-Launcher Pod (Kubernetes)

**What runs:** `virsh` commands and qemu-guest-agent forwarding

**Location:** Inside the `virt-launcher-<vm>-*` pod in the cluster

**Commands that run indirectly** (invoked by `guest-agent.py` on Layer 1):

```bash
# Set these to match the target environment
VM="<vm-name>"
NS="<namespace>"

# These are not executed directly by the operator — guest-agent.py handles this via oc exec
# Here is what happens inside the pod:

# Check VM is running
virsh -q domifaddr "$VM"
# Output: vnet0  52:54:00:12:34:56  ipv4  10.0.0.42/24

# Forward PowerShell command to guest agent
virsh qemu-agent-command "${NS}_${VM}" \
  '{"execute":"guest-exec","arguments":{"path":"C:\\Windows\\System32\\cmd.exe",...}}'
# Output: {"return":{"pid":1234}}

# Check guest agent status
virsh qemu-agent-command "${NS}_${VM}" '{"execute":"guest-ping"}'
# Output: (hangs or timeout if guest has crashed — EXPECTED)

# After crash: Stop the VM
virsh destroy "$VM"
# Output: Domain <vm-name> destroyed
```

**How to manually run these (for debugging):**

```bash
# SSH/exec into the pod
POD=$(oc get pod -n "$NS" -o name | grep "virt-launcher-${VM}" | head -1 | cut -d/ -f2)
oc -n "$NS" exec -it $POD -- bash

# Inside pod, virsh commands can be run directly
virsh domifaddr "$VM"
virsh qemu-agent-command "${NS}_${VM}" '{"execute":"guest-ping"}'
virsh dumpxml "$VM" | grep disk  # Find disk path
```

---

#### Layer 3: Windows VM (Guest)

**What runs:** PowerShell scripts executed via guest-agent

**Location:** Inside the Windows guest VM

**Commands that execute** (via `GA_VM=... guest-agent.py exec`):

```powershell
# 1. Configure crash dumps (runs once)
C:\bsod-detector\src\scripts\guest\configure-dumps.ps1

# What it does:
#   - Sets HKEY_LOCAL_MACHINE\System\CurrentControlSet\Control\CrashControl
#   - AutoReboot = 0 (don't reboot after crash)
#   - CrashDumpEnabled = 1 (full kernel+user dump)
#   - DumpFile = C:\Windows\MEMORY.DMP
#   - MinidumpDir = C:\Windows\Minidump

# 2. Stage toolkit (runs once)
C:\bsod-detector\src\scripts\guest\clear-dumps.ps1

# What it does:
#   - Extracts bsod-src.zip
#   - Sets up crash-injector tools
#   - Verifies paths

# 3. Trigger crash
C:\Temp\nmf\notmyfaultc64.exe /accepteula /crash 0x01

# What it does:
#   - Loads notmyfault driver
#   - Executes crash code 0x01 (IRQL_NOT_LESS_OR_EQUAL)
#   - Windows writes MEMORY.DMP while rebooting
#   - BUT: AutoReboot=0 means no reboot, stays at crash screen
#   - Guest becomes unresponsive to guest-agent queries
```

**Expected behavior:**

| Step | Expected | What to Check |
|------|----------|---------------|
| Setup toolkit | [exit 0] | `oc exec <pod> -- virsh qemu-agent-command ... '{"execute":"guest-ping"}'` returns immediately |
| Configure dumps | Registry set | Guest still responsive to ping |
| Setup NotMyFault | notmyfaultc64.exe present | `ls C:\Temp\nmf\` shows files |
| Trigger crash | **TIMEOUT** | This is EXPECTED — guest crashed, agent unresponsive |
| After crash | No response | `virsh qemu-agent-command` hangs/times out |

---

### Troubleshooting: What to Check at Each Layer

| Symptom | Check | Solution |
|---------|-------|----------|
| `guest-agent.py` hangs on setup | Pod exists and running | `oc get pod -n $NS \| grep virt-launcher` |
| Setup commands timeout | Guest agent responsive | `GA_VM=... guest-agent.py ping` |
| Crash trigger timeout | Expected if crash worked | Wait 30s, VM should be unresponsive |
| Can't extract dumps | Disk image readable | `ls -l /var/lib/libvirt/images/...qcow2` |
| MEMORY.DMP not found | AutoReboot setting | Verify `configure-dumps.ps1` ran successfully |

---

## guest-agent.py Reference

**What it does:** Tunnel PowerShell commands into the Windows guest via qemu-guest-agent.  
**Where it runs:** CI Operator layer (orchestration host or CI/CD pipeline).  
**Transport:** `oc exec` into virt-launcher pod → `virsh qemu-agent-command` → guest.

### Setup Environment

```bash
export VM="<vm-name>"
export NS="<namespace>"

# Verify guest agent is responsive before running anything
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py ping
# Output: (empty/immediate if responsive; timeout if guest unreachable)
```

### Subcommands

| Command | Purpose | Example |
|---------|---------|---------|
| `ping` | Check if guest agent is alive | `GA_VM=$VM GA_NS=$NS python3 ... ping` |
| `exec <program> [args]` | Run a command in guest | `GA_VM=$VM GA_NS=$NS python3 ... exec powershell -Command 'Get-Date'` |
| `psfile <script.ps1> [args]` | Upload and run PowerShell script | `GA_VM=$VM GA_NS=$NS python3 ... psfile src/scripts/guest/configure-dumps.ps1` |
| `put <local> <guest-path>` | Upload file to guest | `GA_VM=$VM GA_NS=$NS python3 ... put file.zip 'C:\Temp\file.zip'` |
| `get <guest-path> <local>` | Download file from guest | `GA_VM=$VM GA_NS=$NS python3 ... get 'C:\Windows\MEMORY.DMP' ./MEMORY.DMP` |

### Quick Reference

```bash
# ONE-TIME SETUP (run once per VM)
export VM="<vm-name>"
export NS="<namespace>"

# 1. Stage toolkit
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/guest/stage-toolkit.ps1

# 2. Configure crash dumps
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/guest/configure-dumps.ps1

# 3. Setup crash trigger (if using NotMyFault)
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/crash-injector/setup-notmyfault.ps1

# BEFORE EACH TEST
# 4. Clear old dumps (optional, for clean evidence)
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/guest/clear-dumps.ps1

# AFTER CRASH
# 5. Extract evidence (guest is now offline/crashed)
# Resolve POD and DISK_IMAGE — see "Resolving Disk Image Paths Dynamically" above
./host-tools/run.sh --disk "$DISK_IMAGE" \
  --out ./evidence/dumps
```

### Performance Considerations: guest-agent.py Slowness

**⚠️ Known Issue:** `guest-agent.py psfile` and `guest-agent.py exec` commands can be **very slow** (30-120+ seconds per command) due to:

1. **qemu-guest-agent overhead** — RPC communication through libvirt/KVM
2. **PowerShell startup time** — Even simple scripts take time to load
3. **Network latency** — oc exec → virt-launcher pod → virsh adds layers
4. **Guest system load** — Heavy I/O or high CPU makes responses slower

**Recommended Timeout Values:**
- `psfile <script>` — **120 seconds** (setup scripts can be slow)
- `exec <command>` — **60 seconds** (simpler commands are faster)
- Large file transfers (`put`, `get`) — **180+ seconds** (I/O bound)

**Optimization Tips:**
- ✅ Batch commands where possible (one large script vs. multiple small ones)
- ✅ Check `GA_VM=$VM GA_NS=$NS python3 ... ping` first (should return immediately)
- ✅ If `ping` hangs, the guest-agent is unresponsive — restart the VM
- ✅ For production, pre-stage setup scripts (stage-toolkit, configure-dumps) once during VM creation
- ✅ Use `host-tools/run.sh` for evidence extraction instead of guest-side collection (offline is faster)

**Debugging:**
```bash
# Check if guest-agent is reachable
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py ping
# Expected: Returns immediately (empty output {})
# If it hangs: guest-agent is unresponsive

# Test with a simple command (60s timeout)
timeout 60 bash -c 'GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py exec powershell -NoProfile -Command "Write-Host done"'
# If this times out: guest may be under high load or unresponsive
```

---

## Integration: Detecting Externally-Triggered BSOD

**Scenario:** An external test operator generates a BSOD via an independent mechanism (not via our crash-injector). The BSOD Detector watches for the event, detects it, and captures evidence automatically.

### External Test Operator Responsibilities

1. **Pre-BSOD Setup** (one-time, before triggering crash):
   - Coordinate with CI Operator to confirm `configure-dumps.ps1` has been executed
   - Verify VM is ready to write full crash dumps (registry configured)
   - Note: AutoReboot=0 is critical — ensures guest stays at crash screen

2. **Generate BSOD**:
   - Trigger the crash using external mechanism (independent of this toolkit)
   - Windows writes crash dump to `C:\Windows\MEMORY.DMP`
   - Guest becomes unresponsive to network/agent

3. **Notify CI Operator**:
   - Inform CI Operator when BSOD has been triggered
   - Provide timestamp for correlation
   - CI Operator detects it automatically via `watch-crash.sh`

### CI Operator Responsibilities

```bash
export VM="<vm-name>"
export NS="<namespace>"

# Step 1: ONE-TIME GUEST SETUP (before external test operator triggers BSOD)
echo "=== Configuring guest for crash dump collection ==="
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/guest/configure-dumps.ps1

GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/guest/clear-dumps.ps1

echo "Setup complete. Notify external test operator that VM is ready for BSOD."

# Step 2: START DETECTION WATCHER (before external operator triggers BSOD)
echo "=== Watching for externally-triggered BSOD (will block until detected or timeout) ==="
./src/scripts/host/watch-crash.sh \
  --provider kubevirt \
  --ns $NS \
  --vm $VM \
  --scenario natural \
  --out ./evidence \
  --duration 3600

# (This command will block until BSOD detected)
# External operator triggers crash while this is running
# Detector will automatically:
#   1. Capture screenshot at crash time
#   2. Capture raw VM memory
#   3. Stop the VM
#   4. Extract crash dumps offline via libguestfs

# Step 3: COLLECT & VERIFY RESULTS (after watch-crash.sh exits)
echo "=== Evidence collection complete ==="
ls -lah ./evidence/
cat ./evidence/evidence-summary.json | jq .
cat ./evidence/evidence-summary.json | jq .verdict
```

### Execution Flow

```
╔════════════════════════════════════════════════════════════════════════════╗
║                    EXTERNAL BSOD DETECTION & CAPTURE                       ║
╚════════════════════════════════════════════════════════════════════════════╝

External Operator               CI Operator                 VM (Guest)
     ┌─────────────┐            ┌─────────────┐          ┌──────────────┐
     │  PREPARE    │            │   SETUP     │          │   WAITING    │
     │ (Notify)    │────────→   │ configure   │   ┌─────→│    Ready     │
     │             │            │ dumps.ps1   │   │      │              │
     └─────────────┘            └─────────────┘   │      └──────────────┘
                                                   │
                                 ┌─────────────┐  │
                                 │  WATCH      │──┘
                                 │ watch-crash │
                                 │  (blocking)  │
                                 └──────┬──────┘
                                        │ polls
                                        │ guest-agent every 5s
                                        ├──────────────────→

     ┌──────────┐                                          ┌──────────────┐
     │ TRIGGER  │──→ (external mechanism) ──→ [Crash!] ──→│  BSOD        │
     │  BSOD    │                                         │ Writes MEMORY │
     └──────────┘                                         │ Agent DOWN    │
                                                          └──────┬───────┘
                                 ┌──────────────┐                │
                                 │ DETECTS ✅   │← ─ ─ ─ ─ ─ ─ ┘
                                 │ Unresponsive │
                                 └───────┬──────┘
                                        ┌┴──────────────────────┐
                                        │  ESCALATE:             │
                                        │  1. Screenshot         │
                                        │  2. Memory capture     │
                                        │  3. Stop VM            │
                                        │  4. Extract offline    │
                                        └───────┬────────────────┘
                                                ↓
                                    ┌──────────────────┐
                                    │ ./evidence/      │
     ┌──────────┐                  │  ├─ MEMORY.DMP   │
     │ NOTIFIED │←─────────────────│  ├─ Minidumps    │
     │  Done    │                  │  ├─ Event logs   │
     └──────────┘                  │  └─ JSON summary │
                                    └──────────────────┘
                                         ✅ Analysis Ready
```

### Coordination Checklist

**Pre-BSOD Coordination:**
1. ✅ CI Operator confirms `configure-dumps.ps1` executed successfully
2. ✅ External Test Operator confirms readiness to trigger crash
3. ✅ CI Operator initiates `watch-crash.sh`
4. ✅ Allow ~10 seconds for watch initialization

**During BSOD Trigger:**
5. ✅ External Test Operator triggers crash via designated mechanism
6. ✅ Ensure AutoReboot=0 prevents automatic VM restart
7. ✅ Guest unresponsiveness is expected behavior

**Post-BSOD Collection:**
8. ✅ External Test Operator notifies CI Operator upon crash completion
9. ✅ CI Operator's `watch-crash.sh` detects event automatically
10. ✅ Evidence collection to `./evidence/` executes automatically

### Troubleshooting External Integration

| Issue | Cause | Resolution |
|-------|-------|-----------|
| Detector doesn't detect externally-triggered BSOD | Guest agent still responsive | Verify `configure-dumps.ps1` disabled AutoReboot |
| MEMORY.DMP not found after crash | Dump not written before VM stopped | Increase detection timeout or verify crash actually occurred |
| Evidence directory empty | Guest agent responsive despite crash | Check if external mechanism actually triggered proper BSOD |
| Timeout waiting for crash | External operator hasn't triggered yet | Verify communication and timing with external operator |

---

## Resolving Disk Image Paths Dynamically

Instead of hardcoding disk image paths like `/var/lib/libvirt/images/<vm-name>.qcow2`, the disk path can be extracted dynamically from the running VM.

### Why Dynamic Resolution?

✅ Works across different hypervisors (KVM/libvirt and KubeVirt)  
✅ Supports custom storage paths  
✅ Makes scripts portable and reusable  
✅ Doesn't depend on naming conventions  

### How to Extract the Disk Path

**For KubeVirt VMs**, query virsh inside the virt-launcher pod:

```bash
# Variables
VM="<vm-name>"
NS="<namespace>"
DOM_NAME="${NS}_${VM}"

# 1. Find the virt-launcher pod
POD=$(oc get pod -n "$NS" -o name | grep "virt-launcher-${VM}" | head -1 | cut -d/ -f2)

# 2. Extract disk path using virsh domblklist
DISK_IMAGE=$(oc -n "$NS" exec "$POD" -- virsh domblklist "$DOM_NAME" | grep vda | awk '{print $2}')

# 3. Use the resolved path
./host-tools/run.sh --disk "$DISK_IMAGE" --out ./evidence/dumps
```

**What each step does:**

1. **Find the pod:** Queries KubeVirt for the virt-launcher pod managing the target VM
2. **Extract disk:** Uses `virsh domblklist` to list block devices (returns path like `/var/lib/libvirt/images/...qcow2`)
3. **Use path:** Pass to `host-tools/run.sh` for offline evidence extraction

### In the Test Script

The complete test script (`bsod-detector-test.sh`) automatically does this:

```bash
# Resolve POD and DISK_IMAGE — see "Resolving Disk Image Paths Dynamically" above

# Use resolved path for evidence extraction
./host-tools/run.sh --disk "$DISK_IMAGE" --out ./evidence/dumps
```

This eliminates manual disk path lookups and makes the script work on any VM in any namespace.

---

## Test Scenarios

The toolkit supports **3 ways to trigger and capture a BSOD**:

### Scenario 1: Intentional Crash Injection (NotMyFault)

**When to use:** Controlled testing with a known crash code via NotMyFault.exe.

**CI Operator runs:**
```bash
export VM="<vm-name>"
export NS="<namespace>"
export KUBECONFIG=<path-to-kubeconfig>

# ONE-TIME SETUP (run once per VM)

# 1. Stage toolkit (one-time)
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/guest/stage-toolkit.ps1
# Expected: Directories created, guest ready

# 2. Configure crash dumps (one-time)
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/guest/configure-dumps.ps1
# Expected: Registry configured, AutoReboot=0 set, dump type configured

# 3. Setup NotMyFault injector (one-time)
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/crash-injector/setup-notmyfault.ps1
# Expected: notmyfaultc64.exe present in C:\Temp\nmf\

# PER-TEST SEQUENCE

# 4. Clear existing dumps (before each test - optional but recommended)
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/guest/clear-dumps.ps1
# Expected: Old dumps cleared, clean slate for new crash

# 5. Trigger the crash
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py exec \
  powershell -NoProfile -ExecutionPolicy Bypass \
  -Command 'C:\Temp\nmf\notmyfaultc64.exe /accepteula /crash 0x01'
# Expected: TIMEOUT (guest has crashed, this is expected)

# 6. Extract evidence offline (guest is now stopped)
# Resolve POD and DISK_IMAGE — see "Resolving Disk Image Paths Dynamically" above
./host-tools/run.sh --disk "$DISK_IMAGE" --out ./evidence/dumps
# Expected: MEMORY.DMP extracted, minidumps extracted, JSON result
```

**What happens inside the VM:**
- configure-dumps.ps1 sets registry (AutoReboot=0, dump type to kernel+user)
- NotMyFault.exe executes crash code 0x01
- Windows writes MEMORY.DMP to C:\Windows\

**What the CI Operator captures:**
- BSOD screenshot
- Raw VM memory (optional)
- MEMORY.DMP + minidumps (offline extraction)
- Event logs (.evtx files)

---

### Scenario 2: Natural BSOD Detection (Watch-Crash)

**When to use:** Detecting a real, unplanned BSOD triggered externally (by external test operator).

**CI Operator runs:**
```bash
export VM="<vm-name>"
export NS="<namespace>"
export KUBECONFIG=<path-to-kubeconfig>

# ONE-TIME SETUP (run once per VM)

# 1. Stage toolkit (one-time)
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/guest/stage-toolkit.ps1
# Expected: Directories created, guest ready

# 2. Configure crash dumps (one-time)
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/guest/configure-dumps.ps1
# Expected: Registry configured, AutoReboot=0 set, dump type configured

# PER-TEST SEQUENCE

# 3. Clear existing dumps (before each test - optional but recommended)
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/guest/clear-dumps.ps1
# Expected: Old dumps cleared, clean slate for new crash

# 4. Start watching for natural BSOD (blocks until detected)
./src/scripts/host/watch-crash.sh \
  --ns $NS \
  --vm $VM \
  --out ./evidence \
  --interval 5 \
  --miss 3 \
  --reboot-wait 300
# This will block until BSOD detected or timeout occurs
# External Test Operator triggers crash while this is running
# watch-crash.sh automatically:
#   1. Detects guest unresponsiveness
#   2. Captures screenshot
#   3. Captures host-side signals
#   4. Extracts evidence offline
#   5. Generates evidence-summary.json
```

**What happens during monitoring:**
- Continuously polls qemu-guest-agent health
- Detects BSOD/freeze when guest stops responding
- Automatically captures screenshot at crash moment
- Records host-side signals (TLB-flush, split-lock)
- Waits for guest reboot or detects hard-freeze

**What the CI Operator gets:**
- Automatic screenshot at crash time
- Host kernel log analysis
- Crash dump files (if guest reboots)
- Event log evidence
- Evidence summary JSON with crash metadata

See **[docs/natural-bsod-workflow.md](docs/natural-bsod-workflow.md)** for detailed runbook.

---

### Scenario 3: Offline Dump Extraction

**When to use:** VM is already crashed/frozen/stopped; extract evidence from disk image without VM interaction.

**CI Operator runs:**
```bash
# Set these to match the target environment
VM="<vm-name>"
NS="<namespace>"

# Resolve POD and DISK_IMAGE — see "Resolving Disk Image Paths Dynamically" above

# Method 1: Direct extraction via host-tools
./host-tools/run.sh \
  --disk "$DISK_IMAGE" \
  --out ./evidence/dumps
# Expected: MEMORY.DMP extracted, minidumps extracted, JSON result

# Method 2: Via collect-offline orchestrator
./src/scripts/host/collect-offline.sh \
  --vm "$VM" \
  --out ./evidence
# Expected: Full evidence bundle with analysis
```

**What happens:**
- ✅ Mounts disk image via libguestfs (read-only)
- ✅ Extracts MEMORY.DMP and minidumps from C:\Windows\
- ✅ Extracts event logs (.evtx files)
- ✅ Parses dump headers for crash analysis
- ✅ No VM interaction or reboots needed

**Useful for:**
- Unbootable/unconfigurable guests
- Frozen VMs (cannot reach via guest-agent)
- Post-mortem analysis of existing disk images
- Recovery from hard-freeze states

---

## Execution Environments

### KubeVirt (OpenShift Cluster)

**Use when:** Testing in Kubernetes/OpenShift environment.

**CI Operator location:** The operator workstation or CI/CD pipeline  
**Command pattern:**
```bash
GA_VM=<vm-name> GA_NS=<namespace> python3 src/scripts/host/guest-agent.py <subcommand>
oc -n <namespace> exec <virt-launcher-pod> -- virsh <cmd>
```

**Transport:** `oc exec` into virt-launcher pod → `virsh qemu-agent-command` → guest

**Example (from earlier):**
```bash
export VM="<vm-name>"
export NS="<namespace>"

# Trigger crash injection
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py psfile \
  src/scripts/crash-injector/setup-notmyfault.ps1
GA_VM=$VM GA_NS=$NS python3 src/scripts/host/guest-agent.py exec \
  powershell -Command 'C:\Temp\nmf\notmyfaultc64.exe /accepteula /crash 0x01'

# Watch for natural BSOD
./src/scripts/host/watch-crash.sh \
  --provider kubevirt --ns $NS --vm $VM --out ./evidence
```

---

### KVM/libvirt (Local Host)

**Use when:** Testing locally on KVM/libvirt infrastructure.

**CI Operator location:** The KVM host itself  
**Command pattern:**
```bash
export VM_NAME=bsod-test
export LIBVIRT_DEFAULT_URI=qemu:///system

src/scripts/host/guest-ssh.sh -c '<PowerShell command>'
# For disk path, use: virsh domblklist <vm> | grep vda | awk '{print $2}'
# or the dynamic resolution pattern (see "Resolving Disk Image Paths Dynamically" section)
./host-tools/run.sh --disk <resolved-disk-image> --out ./output
```

**Transport:** SSH to Windows guest or `virsh` on the host

**Example (local testing):**
```bash
export VM_NAME=bsod-test

# Trigger crash injection
src/scripts/host/guest-ssh.sh -f src/scripts/crash-injector/setup-notmyfault.ps1
src/scripts/host/guest-ssh.sh -c 'C:\Temp\nmf\notmyfaultc64.exe /accepteula /crash 0x01'

# Watch for natural BSOD
./src/scripts/host/watch-crash.sh \
  --provider kvm --vm $VM_NAME --out ./evidence

# Or extract from offline image directly
# Resolve disk path: virsh domblklist $VM_NAME | grep vda | awk '{print $2}'
DISK_IMAGE=$(virsh domblklist $VM_NAME | grep vda | awk '{print $2}')
./host-tools/run.sh --disk "$DISK_IMAGE" --out ./output
```

---

## Conventions

### Scripts as tooling

Deterministic operations live in scripts with clear stdin/stdout contracts.

- **Scripts produce facts; humans make decisions.** Data collection, parsing dump files, reading event logs, and formatting output belong in scripts. Interpreting a crash or deciding how to act on it is a human call.
- `src/scripts/` contains guest collection and configuration scripts. Host-side collectors (such as `collect-host-signals.sh`) also live here when they consume `src/data/` lookups and follow the same output contract. Each collector script does one thing and emits exactly one JSON object to stdout so downstream steps can consume it with `jq` or `json.loads()`. Helper scripts like `capture-vm-screen.sh` that produce file artifacts instead of JSON are excluded from this contract.
- Every script is documented in [`src/scripts/README.md`](src/scripts/README.md): what it does, its inputs, and its output shape.
- **No hardcoded duplicated data.** Bug-check code tables, driver mappings, and log source names come from a single source-of-truth file that scripts read; never copy the same lookup into multiple scripts.

### Style

- Windows-first. Scripts are PowerShell (`.ps1`) unless there is a reason to use another language; note the requirement at the top of each script.
- Keep functions small and testable. Fail loudly with clear error messages.
- Never require interactive input in a script that may run unattended after a crash.

## Quick start

```bash
# Run the unit test suite (no VM needed):
cd apps/bsod-detector && bash test/run-tests.sh

# Intentional BSOD — fully automated (KubeVirt/RHOV):
bash src/scripts/crash-injector/trigger-bsod-intentional.sh
# Custom crash type: bash src/scripts/crash-injector/trigger-bsod-intentional.sh 0x08

# Natural crash watcher (KubeVirt/RHOV):
bash src/scripts/host/watch-crash.sh \
  --ns windows-bsod --vm win2022-vm-hjoshi1 \
  --out ./evidence --interval 5 --miss 2

# Hard freeze recovery (when guest won't reboot):
bash src/scripts/host/recover-natural-crash.sh \
  --ns windows-bsod --vm win2022-vm-hjoshi1 --out ./evidence/recovery

# Collect evidence offline after a crash:
./src/scripts/host/collect-offline.sh --vm bsod-test --out ./output/evidence
```

See [**docs/integration.md**](docs/integration.md) for CI/CD patterns, JSON
contracts, and agentic usage.

---

## New Scripts (2026-09-24)

### `src/scripts/crash-injector/trigger-bsod-intentional.sh`

Fully automated end-to-end intentional BSOD trigger for KubeVirt/RHOV. Handles
the complete workflow from cleanup through evidence collection.

**Key design decisions:**
- **STEP 0** — deletes all BSOD/dump files from previous runs on host + guest
  (including `MEMORY.DMP` which must be gone before triggering or Windows writes
  only a partial differential dump — fast but incomplete)
- **STEP 0d** — runs `configure-dumps.ps1` and verifies `matchesRecommended:true`;
  dies if `rebootRequired:true` (settings won't apply until reboot)
- **STEP 6** — fires `notmyfaultc64.exe /crash <type>` as a **background process**;
  the `exec` call never returns when guest crashes (virsh blocks on dead QGA socket),
  so detection uses an independent ping loop instead
- **STEP 7** — polls ping every 5s; waits for DOWN (crash) then UP (reboot); retries
  the entire trigger if no crash is confirmed within 10 minutes
- **STEP 8** — verifies a fresh minidump was written on guest post-reboot; warns if
  dump is missing (indicates dump config problem)

```
STEP 0  Delete dump files from previous runs + configure-dumps.ps1
STEP 1  Verify watch-crash.sh + guest-agent.py present
STEP 2  Guest online re-verify
STEP 2b VM status snapshot + last 5 Windows events
STEP 3  NotMyFault confirmed
STEP 4  Create ./evidence/
STEP 5  Start watch-crash.sh in background (PID tracked)
STEP 6  Fire notmyfaultc64.exe /crash <type> in background
STEP 7  Poll ping: wait for DOWN (crash confirmed) → UP (reboot complete)
STEP 8  Final online check + verify fresh minidump on guest
STEP 9  Wait 180s for watch-crash.sh evidence collection
STEP 10 Terminate watch-crash.sh if still running
STEP 11 Report results + print evidence-summary.json
```

**Usage:**
```bash
# Default crash type 0x01 (High IRQL → 0xD1 DRIVER_IRQL_NOT_LESS_OR_EQUAL)
bash src/scripts/crash-injector/trigger-bsod-intentional.sh

# Other crash types
bash src/scripts/crash-injector/trigger-bsod-intentional.sh 0x08  # double free
bash src/scripts/crash-injector/trigger-bsod-intentional.sh 0x09  # HAL timer watchdog
```

**Crash types (`notmyfaultc64.exe /crash <type>`):**

| Type | Name | Bug Check |
|------|------|-----------|
| `0x01` | High IRQL fault (kernel) | `0xD1 DRIVER_IRQL_NOT_LESS_OR_EQUAL` |
| `0x02` | Buffer overflow | `0xD1` |
| `0x03` | Code overwrite | various |
| `0x04` | Stack trash | various |
| `0x06` | Stack overflow | `0x7F` |
| `0x07` | Hardcoded breakpoint | `0x80` |
| `0x08` | Double free | `0xC5` |
| `0x09` | HAL timer watchdog | `0x101` |

**Configuration (top of script):**
```bash
VM_NAME="win2022-vm-hjoshi1"   # target VM
NAMESPACE="windows-bsod"       # KubeVirt namespace
WATCH_CRASH_TIMEOUT=1800       # 30 min watcher timeout
REBOOT_WAIT=300                # 5 min per crash detection attempt
COLLECTION_WAIT=180            # 3 min evidence collection wait
```

---

### `src/scripts/host/recover-natural-crash.sh`

Evidence recovery for a hard-frozen VM — when `watch-crash.sh` reports
`hardFreeze:true` and the guest agent never returns.

Runs two parallel recovery paths:

**PATH 1 — `virsh dump --memory-only`**
Captures live QEMU/ELF memory image via `oc exec` into the virt-launcher pod.
Immediate; does not require powering off the VM. Output is NOT a Windows crash
dump — use `volatility3` to analyze.

**PATH 2 — ODF VolumeSnapshot → libguestfs pod**
1. Takes a CSI `VolumeSnapshot` of the guest PVC (`win2022-dv-hjoshi1`) via
   `ocs-storagecluster-rbdplugin-snapclass` — non-destructive, VM stays running
2. Creates a recovery PVC from the snapshot
3. Launches a libguestfs pod mounting the PVC read-only
4. Runs `virt-copy-out` to extract `MEMORY.DMP` + `Minidump\*.dmp`
5. Runs `parse-dump-header.sh` offline on extracted dumps
6. Cleans up: deletes snapshot, recovery PVC, recovery pod

```bash
# Full recovery (both paths)
bash src/scripts/host/recover-natural-crash.sh \
  --ns windows-bsod --vm win2022-vm-hjoshi1 --out ./evidence/recovery

# PATH 1 only (fast ELF dump)
bash src/scripts/host/recover-natural-crash.sh \
  --ns windows-bsod --vm win2022-vm-hjoshi1 \
  --out ./evidence/recovery --path1-only

# PATH 2 only (Windows dump via ODF snapshot)
bash src/scripts/host/recover-natural-crash.sh \
  --ns windows-bsod --vm win2022-vm-hjoshi1 \
  --out ./evidence/recovery --path2-only
```

**Output:**
```
evidence/recovery/
├── qemu-memory.dump         PATH 1: QEMU/ELF (volatility3)
├── MEMORY.DMP               PATH 2: Windows kernel dump (WinDbg/parse-dump-header.sh)
├── Minidump/*.dmp           PATH 2: Windows minidumps
├── parse-dump-header.json   bug check code + parameters
├── host-signals.json        split-lock detection, Hyper-V features
├── dom.xml                  VM domain XML at recovery time
├── kern.log                 worker node kernel log
└── recovery-summary.json    master recovery report
```

**When to call it:**
```bash
# After watch-crash.sh reports hardFreeze
if jq -e '.hardFreeze == true' ./evidence/evidence-summary.json >/dev/null 2>&1; then
  bash src/scripts/host/recover-natural-crash.sh \
    --ns windows-bsod --vm win2022-vm-hjoshi1 \
    --out ./evidence/recovery
fi
```

---

### `watch-crash.sh` — Fixes Applied (2026-09-24)

Two bugs fixed that caused crash detection to fail silently:

1. **`ping_ok` timeout** — now uses `timeout 10 python3 guest-agent.py ping`.
   Without this, if the guest crashes while virsh is mid-call, the orphaned QGA
   socket blocks for virsh's full 300s internal timeout. The missed-ping counter
   never increments and the crash is missed entirely.

2. **`powercfg` keep-awake exec** — now wrapped with `timeout 15`. A crash
   immediately after watcher startup would block this exec for 5 minutes before
   the poll loop even starts.

---

### `image/container/bsod-detector/` — Updated Container Image

The existing Dockerfile was extended to support three modes via the `MODE`
environment variable. Nothing is hardcoded — the same image works for any VM
in any cluster.

| Mode | Script | Use case |
|------|--------|----------|
| `watch` (default) | `watch-crash.sh` | Continuous natural crash detection |
| `recover` | `recover-natural-crash.sh` | Hard-freeze evidence recovery |
| `extract` | `extract-dump` | Original offline libguestfs dump pull |

Key environment variables for watch mode:

| Variable | Default | Description |
|----------|---------|-------------|
| `GA_VM` | required | KubeVirt VM name |
| `GA_NS` | required | Kubernetes namespace |
| `WATCH_INTERVAL` | `5` | QGA poll interval (seconds) |
| `WATCH_MISS` | `2` | Missed pings before crash declared |
| `EVIDENCE_DIR` | `/evidence` | Exact persistent mount target; each run gets a unique child |
| `BSOD_EVIDENCE_VOLUME_KIND` | required | `pvc`, `network`, or `csi` |
| `BSOD_EVIDENCE_STORAGE_ID` | required | Stable identity revalidated by recovery |
| `BSOD_SNAPSHOT_CLASS` | required | Compatible CSI snapshot class |
| `BSOD_RECOVERY_IMAGE` | required | Digest-pinned Bash/guestfish image |
| `BSOD_MEMORY_DUMP_PVC` | required | Dedicated Filesystem PVC for the KubeVirt memory-dump API |

```bash
# Watch a VM (natural crash detection)
printf '%s\n' shared-bsod-evidence > /mnt/persistent-bsod-evidence/.bsod-storage-identity
podman run --rm -e GA_VM=win2022-vm-hjoshi1 -e GA_NS=windows-bsod \
  -e BSOD_EVIDENCE_VOLUME_KIND=network -e BSOD_EVIDENCE_STORAGE_ID=shared-bsod-evidence \
  -e BSOD_SNAPSHOT_CLASS='<class>' -e BSOD_RECOVERY_IMAGE='<image@sha256:digest>' \
  -e BSOD_MEMORY_DUMP_PVC='<memory-dump-pvc>' \
  -v /mnt/persistent-bsod-evidence:/evidence quay.io/redhatqe/bsod-detector:latest

# Hard-freeze recovery
podman run --rm -e MODE=recover \
  -v /mnt/persistent-bsod-evidence:/evidence quay.io/redhatqe/bsod-detector:latest \
  --metadata /evidence/<run-id>/recovery-metadata.json --out /evidence/<run-id>

# Offline dump extraction (original behaviour unchanged)
podman run --rm -e MODE=extract \
  -v /path/to/guest.qcow2:/disk.qcow2:ro -v ./out:/out \
  quay.io/redhatqe/bsod-detector:latest --disk /disk.qcow2 --out /out

# Build
make -C image/container/bsod-detector build \
  BASE_IMAGE='<image@sha256:digest>' \
  OCP_CLIENT_URL='<url>' OCP_CLIENT_SHA256='<sha256>' \
  VIRTCTL_URL='<url>' VIRTCTL_SHA256='<sha256>'
```

---

## Hard Freeze Recovery Strategy

When the guest BSODs but does not reboot (`hardFreeze:true`), three options:

| Method | Tool | Format | Notes |
|--------|------|--------|-------|
| `virsh dump --memory-only` | `recover-natural-crash.sh --path1-only` | QEMU/ELF | Immediate; needs `volatility3` |
| ODF VolumeSnapshot → libguestfs | `recover-natural-crash.sh --path2-only` | Windows MEMORY.DMP | Non-destructive; real Windows dump |
| S3 / object storage | External agent (pre-crash) | Any | Pre-crash event logs only; agent dead during freeze |

S3 shipping cannot capture `MEMORY.DMP` in real-time — Windows writes the dump
after the kernel stops, so no agent can ship it mid-crash. Use S3 for
pre-crash event forwarding and post-reboot startup shipping.

---

## Layout

```
apps/bsod-detector/
├── src/
│   ├── scripts/
│   │   ├── host/                         # Host-side (Bash/Python)
│   │   │   ├── backends/                 # KVM/KubeVirt backend abstraction
│   │   │   ├── watch-crash.sh            # Natural crash detector (primary entry point)
│   │   │   ├── recover-natural-crash.sh  # Hard-freeze evidence recovery (NEW)
│   │   │   ├── guest-agent.py            # QGA bridge (all guest comms)
│   │   │   ├── collect-from-host.sh      # libvirt-native dump recovery
│   │   │   ├── collect-host-signals.sh   # Host kernel log + Hyper-V analysis
│   │   │   ├── parse-dump-header.sh      # Offline Windows dump header parser
│   │   │   ├── collect-offline.sh        # Full offline collection orchestrator
│   │   │   ├── capture-vm-screen.sh      # Framebuffer burst capture
│   │   │   ├── extract-evtx.py           # Offline .evtx event log parser
│   │   │   └── vmctl.sh                  # VM lifecycle control
│   │   ├── guest/                        # Guest-side (PowerShell) — one-time config
│   │   │   ├── configure-dumps.ps1       # CrashControl registry settings
│   │   │   ├── clear-dumps.ps1           # Delete existing dumps
│   │   │   └── stage-toolkit.ps1         # Create guest directory structure
│   │   └── crash-injector/               # Intentional BSOD triggers (The Pitcher)
│   │       ├── trigger-bsod-intentional.sh  # Automated KubeVirt crash + collection (NEW)
│   │       ├── trigger-bsod.ps1          # Driver-free crash (NtRaiseHardError)
│   │       ├── setup-notmyfault.ps1      # Download NotMyFault to guest
│   │       ├── sweep-crashme.sh          # Sweep all 19 crash types
│   │       └── sweep-chaos.sh            # Chaos crash sweep
│   └── data/                             # Source-of-truth lookups
│       ├── bugcheck-codes.json           # All Windows bug check codes
│       └── host-signals.json             # Split-lock patterns + Hyper-V features
├── host-tools/                           # Containerised guestfs extraction
├── test/                                 # bats unit tests
├── docs/                                 # Architecture, integration, tool selection
├── evidence/                             # Runtime output (gitignored)
└── .gitignore
```

## Notes

- BSOD dumps may contain host-identifying data. Never commit dumps to git.
  `evidence/` is in `.gitignore`.
- `MEMORY.DMP` must be deleted before each intentional crash run —
  if it exists, Windows writes only changed pages (fast but partial).
  `trigger-bsod-intentional.sh` STEP 0 handles this and verifies deletion.
- `configure-dumps.ps1` must be run before any crash. If it returns
  `rebootRequired:true`, reboot the VM before triggering — otherwise
  dump settings are not active and no dump will be written.
- The QGA ping mechanism (not ICMP) is used for all guest health checks.
  QGA dies instantly on kernel panic; ICMP can stay alive for several seconds
  after a BSOD, making it unreliable for crash detection.
