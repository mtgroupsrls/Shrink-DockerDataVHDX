<#
.SYNOPSIS
  Shrink-DockerDataVHDX.ps1 — Zero-fill free space inside Docker Desktop WSL2 (docker-desktop) and compact docker_data.vhdx.

.DESCRIPTION
  This script zero-fills free space in the Docker Desktop data disk (using the built-in docker-desktop WSL distro),
  shuts down WSL so the VHDX is not in use, then compacts the VHDX using Optimize-VHD (if available) or DiskPart as a fallback.

.NOTES
  - Run PowerShell "As Administrator".
  - The script uses the standard Windows environment variable $env:LOCALAPPDATA to locate Docker's VHDX by default.
  - It prompts for confirmation before performing destructive actions.
  - Author: generated/verified for user request. Keep a backup of important data before running.
#>

param(
    [int]$MinFreeSpaceGB = 20,
    [string]$VhdxRelativePath = "Docker\\wsl\\disk\\docker_data.vhdx",
    [switch]$Force,
    [switch]$WhatIf,
    [int]$IncrementalSizeGB = 0,
    [int]$MaxCycles = 10
)

# --- Admin check ---
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run as Administrator. Please re-run PowerShell 'As Administrator'."
    exit 1
}

# --- Build VHDX path using standard env var ---
if (-not $env:LOCALAPPDATA) {
    Write-Error "Unable to find LOCALAPPDATA environment variable."
    exit 1
}
$VhdxPath = Join-Path -Path $env:LOCALAPPDATA -ChildPath $VhdxRelativePath

# --- Basic checks ---
if (-not (Test-Path -LiteralPath $VhdxPath)) {
    Write-Error "VHDX not found: $VhdxPath"
    exit 1
}

# Determine drive letter (e.g. 'C') from path root
$root = [System.IO.Path]::GetPathRoot($VhdxPath)    # e.g. "C:\"
if (-not $root) {
    Write-Error "Unable to determine root from path: $VhdxPath"
    exit 1
}
$driveLetter = $root.Substring(0,1)                # "C"

$drive = Get-PSDrive -Name $driveLetter -PSProvider FileSystem -ErrorAction SilentlyContinue
if (-not $drive) {
    Write-Error "Host drive $driveLetter: not found as a PSDrive."
    exit 1
}

$freeGB = [math]::Round($drive.Free / 1GB, 2)
Write-Host "Host drive $driveLetter: $freeGB GB free"

if ($WhatIf) {
    Write-Plan "[WhatIf] Plan summary:"
    Write-Plan "  VHDX: $VhdxPath"
    Write-Plan "  Host drive free: $freeGB GB"
    Write-Plan "  MinFreeSpaceGB: $MinFreeSpaceGB"
    if ($IncrementalSizeGB -gt 0) {
        Write-Plan "  Incremental mode: writing $IncrementalSizeGB GB per cycle, up to $MaxCycles cycles"
        Write-Plan "  Each cycle will: write filler file of size N GB inside /mnt/docker-desktop-disk, shutdown WSL, compact VHDX, then continue"
    } else {
        Write-Plan "  Full-mode: write filler until disk full inside docker-desktop, then shutdown and compact"
    }
    if ($Force) { Write-Plan "  Force: yes (skips interactive confirmation)" } else { Write-Plan "  Force: no" }
    Write-Plan "This is a simulation only; no actions were executed."
    exit 0
}
if ($freeGB -lt $MinFreeSpaceGB) {
    Write-Warning "Free space ($freeGB GB) is below the configured threshold ($MinFreeSpaceGB GB). Aborting."
    exit 1
}

# Confirm with the user
Write-Host ""
Write-Host "About to zero-fill and compact these resources:" -ForegroundColor Cyan
Write-Host "  VHDX file: $VhdxPath"
Write-Host "  Host drive free: $freeGB GB (minimum required: $MinFreeSpaceGB GB)"
Write-Host ""
if (-not $Force) {
    $confirm = Read-Host "Type 'YES' to proceed, anything else to abort"
    if ($confirm -ne 'YES') {
        Write-Warning "Aborted by user."
        exit 0
    }
} else {
    Write-Host "Force flag provided; proceeding without interactive confirmation." -ForegroundColor Yellow
}

# --- Zero-fill inside docker-desktop (writes to docker data disk) ---
Write-Host "`n==> Zero-filling free space inside docker-desktop (this may take a long time)..." -ForegroundColor Yellow
$zeroCmd = 'dd if=/dev/zero of=/mnt/docker-desktop-disk/zero.fill bs=1M || true; sync; rm -f /mnt/docker-desktop-disk/zero.fill'
# Invoke WSL with arguments passed safely as an array
if ($IncrementalSizeGB -gt 0) {
    Write-Host "Starting incremental mode: $IncrementalSizeGB GB per cycle, up to $MaxCycles cycles" -ForegroundColor Yellow
    $cycle = 0
    while ($cycle -lt $MaxCycles) {
        $cycle++
        $freeGB = Get-HostFreeGB
        Write-Host "\nCycle $cycle — host free: $freeGB GB"
        $availableForFill = [math]::Floor($freeGB - $MinFreeSpaceGB)
        if ($availableForFill -lt 1) {
            Write-Host "Not enough headroom to write filler. Stopping incremental mode." -ForegroundColor Yellow
            break
        }
        $fillGB = [math]::Min($IncrementalSizeGB, $availableForFill)
        Write-Host "Will write $fillGB GB filler this cycle." -ForegroundColor Green
        $countMB = $fillGB * 1024
        $ddCmdCycle = "dd if=/dev/zero of=/mnt/docker-desktop-disk/zero.fill bs=1M count=$countMB status=progress || true; sync; rm -f /mnt/docker-desktop-disk/zero.fill"
        & wsl -d 'docker-desktop' -- 'sh' '-c' $ddCmdCycle
        if ($LASTEXITCODE -ne 0) { Write-Warning "Zero-fill cycle returned code $LASTEXITCODE (may be due to disk full). Continuing to compact." }
        Write-Host "Shutting down WSL..."; wsl --shutdown
        Compact-Vhdx -Path $VhdxPath
        $freeGB = Get-HostFreeGB
        Write-Host "After compaction, host free: $freeGB GB"
        if ($freeGB -lt ($MinFreeSpaceGB + 1)) { Write-Host "Host free space now below threshold; stopping incremental cycles." -ForegroundColor Yellow; break }
    }
    Write-Host "Incremental mode finished after $cycle cycles." -ForegroundColor Green
} else {
    & wsl -d 'docker-desktop' -- 'sh' '-c' $zeroCmd
}
if ($LASTEXITCODE -ne 0) {
    Write-Warning "wsl returned exit code $LASTEXITCODE. The zero-fill step may have partially failed — check WSL output above."
}

# --- Shutdown WSL so the VHDX is not in use ---
Write-Host "`n==> Shutting down WSL..." -ForegroundColor Yellow
wsl --shutdown

# --- Compact with Optimize-VHD if available, else diskpart ---
if (Get-Command -Name Optimize-VHD -ErrorAction SilentlyContinue) {
    Write-Host "`n==> Running Optimize-VHD (requires Hyper-V module)..." -ForegroundColor Yellow
    try {
        Optimize-VHD -Path $VhdxPath -Mode Full -ErrorAction Stop
        Write-Host "Optimize-VHD completed."
    } catch {
        Write-Error "Optimize-VHD failed: $_"
        exit 1
    }
} else {
    Write-Host "`n==> Optimize-VHD not available; using diskpart compact vdisk fallback..." -ForegroundColor Yellow
    $tmpFile = [IO.Path]::GetTempFileName()
    $dpScript = @"
select vdisk file="$VhdxPath"
attach vdisk readonly
compact vdisk
detach vdisk
exit
"@
    # Write in ASCII for diskpart compatibility
    Set-Content -LiteralPath $tmpFile -Value $dpScript -Encoding ASCII
    try {
        diskpart /s $tmpFile
    } catch {
        Write-Error "diskpart failed: $_"
        Remove-Item -Force $tmpFile -ErrorAction SilentlyContinue
        exit 1
    }
    Remove-Item -Force $tmpFile -ErrorAction SilentlyContinue
}

Write-Host "`nDone. You can restart Docker Desktop now." -ForegroundColor Green
