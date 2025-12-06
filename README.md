# Shrink-DockerDataVHDX

> Compact Docker Desktop's VHDX safely on Windows with PowerShell automation.

Reclaim disk space by compacting Docker Desktop's `docker_data.vhdx` safely through zero-filling free space inside the Docker WSL distro and then running a host-side compaction. This script **does not** install any distro — it uses Docker Desktop's built-in `docker-desktop` WSL distro.

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue.svg)](https://github.com/PowerShell/PowerShell)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

## Table of Contents

- [What it does](#what-it-does)
- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
- [Examples](#examples)
- [How incremental mode works](#how-incremental-mode-works)
- [Safety & Notes](#safety--notes)
- [Troubleshooting](#troubleshooting)
- [License](#license)

---

## What it does

1. **Validates** the environment and checks host drive free space
2. Optionally **simulates** the plan (`-WhatIf`) or prompts for confirmation (unless `-Force`)
3. **Zero-fills** free space inside the Docker data disk using incremental cycles (write *N* GB at a time) or a single full zero-fill
4. **Shuts down** WSL so the VHDX is not in use
5. **Compacts** the VHDX using `Optimize-VHD` (Hyper-V module) if available, otherwise falls back to `diskpart compact vdisk`
6. **Displays comprehensive progress** with real-time updates, elapsed time tracking, and final summary statistics

---

## Requirements

* **Windows** with PowerShell 5.1 or later
* **Docker Desktop** with WSL2 backend (includes the `docker-desktop` distro by default)
* **Sufficient host free disk space** for temporary VHDX growth during zero-filling
  * Incremental mode available to limit peak space usage
* **Optional**: Hyper-V PowerShell module for `Optimize-VHD` (recommended but not required — `diskpart` is used as fallback)

**Admin privileges:** The script automatically elevates itself when needed (except in `-WhatIf` simulation mode)

---

## Installation

1. Download or save the script as `Shrink-DockerDataVHDX.ps1`

2. **No need to "Run as Administrator"** — the script will automatically elevate itself when needed

3. If your execution policy prevents running scripts, use:

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

Or run with bypass:

```powershell
powershell -ExecutionPolicy Bypass -File .\Shrink-DockerDataVHDX.ps1
```

**Note:** When the script needs admin privileges, Windows will show a UAC prompt asking for permission to elevate.

---

## Usage

```powershell
.\Shrink-DockerDataVHDX.ps1 [-MinFreeSpaceGB <int>] [-VhdxRelativePath <string>] 
                            [-Force] [-WhatIf] [-IncrementalSizeGB <int>] [-MaxCycles <int>]
```

### Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-MinFreeSpaceGB` | int | `20` | Minimum free space (GB) required on host drive before proceeding |
| `-VhdxRelativePath` | string | `Docker\wsl\disk\docker_data.vhdx` | Path relative to `%LOCALAPPDATA%` |
| `-Force` | switch | - | Skip the interactive `YES` confirmation prompt |
| `-WhatIf` | switch | - | Simulation mode — show plan without making changes (no admin required) |
| `-IncrementalSizeGB` | int | `0` | If `> 0`, write N GB per cycle and compact between cycles |
| `-MaxCycles` | int | `10` | Maximum cycles to run in incremental mode |

---

## Examples

### 1. Dry run (simulation) — No admin required

```powershell
.\Shrink-DockerDataVHDX.ps1 -WhatIf
```

**Output example:**
```
[WhatIf] Plan summary:
  VHDX: C:\Users\YourName\AppData\Local\Docker\wsl\disk\docker_data.vhdx
  Host drive free: 45.23 GB
  MinFreeSpaceGB: 20
  Full-mode: write filler until disk full inside docker-desktop, then shutdown and compact
  Force: no
This is a simulation only; no actions were executed.
```

### 2. Full (single-shot) run with confirmation

```powershell
.\Shrink-DockerDataVHDX.ps1
```

The script will automatically request admin elevation (UAC prompt), then prompt:
```
Type 'YES' to proceed, anything else to abort:
```

### 3. Force non-interactive full run

```powershell
.\Shrink-DockerDataVHDX.ps1 -Force
```

### 4. Incremental mode — 10 GB per cycle, up to 5 cycles

```powershell
.\Shrink-DockerDataVHDX.ps1 -IncrementalSizeGB 10 -MaxCycles 5 -Force
```

**Best for:** Systems with limited free space or when you want more control over the process.

### 5. Custom VHDX location with lower safety threshold

```powershell
.\Shrink-DockerDataVHDX.ps1 -VhdxRelativePath "CustomPath\docker.vhdx" -MinFreeSpaceGB 10
```

---

## How incremental mode works

Incremental mode helps avoid large temporary spikes in host disk usage. Each cycle:

1. **Measures** host free space and ensures at least `MinFreeSpaceGB` remains
2. **Writes** a zero-filled file of N GB inside `/mnt/docker-desktop-disk/zero.fill` (in `docker-desktop` distro)
3. **Syncs** and removes the filler file
4. **Shuts down** WSL with `wsl --shutdown`
5. **Compacts** the VHDX using Optimize-VHD or diskpart
6. **Re-measures** host free space and repeats until `MaxCycles` reached or insufficient headroom

**Progress tracking**: Each cycle displays elapsed time, space saved, and overall progress (e.g., "Cycle 3 of 5").

```
┌─────────────────────────────────────────────────────────────┐
│ Cycle 1: Write 10GB → Compact → Reclaim space              │
│ Cycle 2: Write 10GB → Compact → Reclaim space              │
│ Cycle 3: Write 10GB → Compact → Reclaim space              │
│ ...                                                          │
└─────────────────────────────────────────────────────────────┘
```

---

## Progress Indicators

The script provides comprehensive progress feedback:

- **PowerShell progress bars** showing current operation and elapsed time
- **Real-time VHDX size monitoring** during compaction (when using Optimize-VHD)
- **Per-cycle statistics** in incremental mode (space saved, time taken)
- **Periodic console updates** so you know the script is still working
- **Final summary report** showing:
  - Initial vs final VHDX size
  - Total space saved (GB and percentage)
  - Operation completion time

Example output:
```
========================================
         COMPACTION COMPLETE
========================================
Initial VHDX size:  85.3 GB
Final VHDX size:    52.1 GB
Space saved:        33.2 GB (38.9%)
========================================
```

---

## Safety & Notes

* 🔐 **Self-elevation**: Script automatically requests admin privileges when needed via UAC prompt
* 💾 **Host disk space**: Zero-filling temporarily expands the VHDX. Ensure sufficient free space or use incremental mode
* 🔒 **Backup first**: Always backup important data before manipulating VHDX files
* ⚡ **Optimize-VHD vs diskpart**: `Optimize-VHD` (Hyper-V module) is faster and preferred; `diskpart` is used as automatic fallback
* 🐧 **Minimal environment**: The `docker-desktop` distro is minimal — the script only writes to `/mnt/docker-desktop-disk`, no package installation needed
* 📊 **Space monitoring**: Script checks host free space and aborts if below `-MinFreeSpaceGB`
* 🛑 **Docker Desktop impact**: Docker Desktop will be stopped during the process (WSL shutdown required for compaction)

---

## Troubleshooting

### "VHDX not found"
**Cause:** Docker Desktop not installed or VHDX at non-default location  
**Solution:** Verify Docker Desktop installation. Check VHDX location at `%LOCALAPPDATA%\Docker\wsl\disk\docker_data.vhdx` or specify custom path with `-VhdxRelativePath`

### "This script must be run as Administrator"
**Cause:** Self-elevation failed or was cancelled  
**Solution:** 
- If you cancelled the UAC prompt, run the script again and approve the elevation request
- Alternatively, manually run PowerShell as Administrator before running the script
- Note: `-WhatIf` simulation mode doesn't require admin privileges

### Optimize-VHD not available
**Status:** Not an error — the script automatically uses `diskpart` fallback  
**To enable Optimize-VHD:** Install Hyper-V PowerShell module:
```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Management-PowerShell
```

### DiskPart errors
**Cause:** Process locking the VHDX (WSL still running or Docker Desktop active)  
**Solution:** Ensure WSL is stopped. The script calls `wsl --shutdown` automatically, but verify with:
```powershell
wsl --list --running
```

### Host drive fills during run
**Cause:** Insufficient free space for full zero-fill operation  
**Solution:** 
- Stop script immediately (Ctrl+C)
- Use smaller `-IncrementalSizeGB` value (e.g., 5 or 10 GB)
- Increase `-MinFreeSpaceGB` threshold for more safety margin
- Move VHDX to larger drive (requires Docker Desktop reconfiguration)

### Script hangs during zero-fill
**Cause:** Normal behavior — zero-filling large amounts of space takes time  
**Expected duration:** Can take 15-60+ minutes depending on disk size and speed  
**Monitor:** The script shows progress bars and periodic status updates. If you see the progress bar and elapsed time updating, the script is working correctly.

---

## FAQ

**Q: Do I need to run PowerShell as Administrator?**  
A: No! The script automatically elevates itself when needed. Just double-click or run normally, and approve the UAC prompt when it appears.

**Q: How much space can I reclaim?**  
A: Depends on how much unused space is in your Docker containers/images. Typical savings: 10-50% of current VHDX size.

**Q: Will this delete my Docker images/containers?**  
A: No, this only compacts free space. Your Docker data remains intact.

**Q: How long does it take?**  
A: Typically 15-60 minutes depending on VHDX size and disk speed. Incremental mode is slower but safer.

**Q: Can I run this on a schedule?**  
A: Yes, use Windows Task Scheduler with the `-Force` parameter for automated runs. Configure the task to run with highest privileges.

**Q: Does this work with Docker Desktop using Hyper-V backend?**  
A: This script is designed for WSL2 backend. Hyper-V backend uses different VHDX locations.

---

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request. For major changes, please open an issue first to discuss what you would like to change.

---

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

## Acknowledgments

- Inspired by the need to manage Docker Desktop's disk usage on Windows
- Uses standard Windows tools (WSL, diskpart, Optimize-VHD) for maximum compatibility

---

**Made with ❤️ for Docker Desktop users fighting disk space issues**