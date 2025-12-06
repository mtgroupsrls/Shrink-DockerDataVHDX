# Shrink-DockerDataVHDX

Compact Docker Desktop's VHDX safely on Windows with PowerShell automation.

Compact Docker Desktop's `docker_data.vhdx` safely by zero-filling free space inside the Docker WSL distro and then running a host-side compaction. This script **does not** install any distro — it uses Docker Desktop's built-in `docker-desktop` WSL distro.

> Script file: `Shrink-DockerDataVHDX.ps1`

---

## What it does

1. Optionally simulates the plan (`-WhatIf`) or prompts for confirmation (unless `-Force`).
2. Optionally runs **incremental** zero-fill cycles (write *N* GB at a time) or does a single full zero-fill until the guest disk is full.
3. Shuts down WSL so the VHDX is not in use.
4. Compacts the VHDX using `Optimize-VHD` (Hyper-V module) if available, otherwise falls back to `diskpart compact vdisk`.

---

## Requirements

* Windows (PowerShell) — **run as Administrator**.
* Docker Desktop with the `docker-desktop` WSL distro (default for Docker Desktop + WSL2).
* Enough host free disk space for temporary growth (incremental mode is available to limit peak usage).
* `Optimize-VHD` (Hyper-V module) recommended but not required — if missing, `diskpart` is used.

---

## Installation

Save the provided script as:

```text
Shrink-DockerDataVHDX.ps1
```

Run from an Administrator PowerShell prompt. If your execution policy prevents running scripts:

```powershell
powershell -ExecutionPolicy Bypass -File .\Shrink-DockerDataVHDX.ps1
```

---

## Usage

```
.\Shrink-DockerDataVHDX.ps1 [-MinFreeSpaceGB <int>] [-VhdxRelativePath <string>] [-Force] [-WhatIf] [-IncrementalSizeGB <int>] [-MaxCycles <int>]
```

### Parameters (defaults)

* `-MinFreeSpaceGB` (default: `20`)
  Minimum free space (GB) on the host drive required before proceeding.
* `-VhdxRelativePath` (default: `Docker\wsl\disk\docker_data.vhdx`)
  Path relative to `%LOCALAPPDATA%` to locate the Docker data VHDX.
* `-Force` (switch)
  Skip the interactive `YES` confirmation prompt.
* `-WhatIf` (switch)
  Simulation mode — prints the planned actions and exits without changing anything.
* `-IncrementalSizeGB` (default: `0`)
  If `> 0`, uses incremental mode: writes this many GB per cycle and compacts between cycles.
* `-MaxCycles` (default: `10`)
  Maximum cycles to run in incremental mode.

---

## Examples

### Dry run (simulation)

```powershell
.\Shrink-DockerDataVHDX.ps1 -WhatIf
```

### Full (single-shot) run with confirmation

```powershell
.\Shrink-DockerDataVHDX.ps1
# then type YES when prompted
```

### Force non-interactive full run

```powershell
.\Shrink-DockerDataVHDX.ps1 -Force
```

### Incremental mode, write 10 GB per cycle, up to 5 cycles

```powershell
.\Shrink-DockerDataVHDX.ps1 -IncrementalSizeGB 10 -MaxCycles 5 -Force
```

---

## How incremental mode works

Incremental mode is intended to avoid a large temporary spike in host disk usage. For each cycle:

1. Measure host free space and ensure at least `MinFreeSpaceGB` remains.
2. Write a zero-filled file of size N GB on the docker data disk (`/mnt/docker-desktop-disk/zero.fill`) inside `docker-desktop`.
3. `sync`, remove the filler file.
4. `wsl --shutdown`
5. Compact the VHDX (Optimize-VHD / DiskPart).
6. Re-measure host free space and repeat until `MaxCycles` or no headroom.

---

## Safety & Notes

* **Run as Administrator** — `Optimize-VHD` and `diskpart` require elevated privileges.
* **Host disk space**: zero-filling expands the VHDX temporarily. If the host drive lacks free space, you can run out of host space — incremental mode exists to mitigate this.
* **Backup**: always ensure important data is backed up before manipulating VHDX files.
* **`Optimize-VHD` vs `diskpart`**: `Optimize-VHD` (Hyper-V module) is preferred and typically faster. If absent, the script uses `diskpart` fallback.
* **`docker-desktop` environment is minimal**: no package installs; the script writes the filler file to `/mnt/docker-desktop-disk`.
* The script checks host free space and aborts if below `-MinFreeSpaceGB` unless you override behaviors.

---

## Troubleshooting

* **“VHDX not found”** — verify Docker Desktop is installed and the VHDX is at `%LOCALAPPDATA%\Docker\wsl\disk\docker_data.vhdx`. You can override location with `-VhdxRelativePath`.
* **Optimize-VHD missing** — the script will automatically use `diskpart` fallback.
* **DiskPart errors** — ensure no process is locking the VHDX (WSL must be stopped; the script calls `wsl --shutdown` before compaction).
* **Host drive fills during run** — stop the script (Ctrl+C) if host free space drops dangerously low; consider smaller `-IncrementalSizeGB` or moving the VHDX to a larger drive.

---

## License

This repository is provided under the MIT License. See the `LICENSE` file.

---

If you want, I can also add a `CONTRIBUTING.md` or small `CHANGELOG.md`.
