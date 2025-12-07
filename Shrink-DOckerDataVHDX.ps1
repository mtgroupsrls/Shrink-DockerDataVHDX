#Requires -Version 5.1

# Shrink-DockerDataVHDX.ps1
#
# .SYNOPSIS
#   Shrink-DockerDataVHDX.ps1 — Zero-fill free space inside Docker Desktop WSL2 (docker-desktop) and compact docker_data.vhdx.

# .DESCRIPTION
#   This script zero-fills free space in the Docker Desktop data disk (using the built-in docker-desktop WSL distro),
#   shuts down WSL so the VHDX is not in use, then compacts the VHDX using Optimize-VHD (if available) or DiskPart as a fallback.
#   If run without parameters, it runs an interactive mode selection menu with recommended mode display.
#
#   Available modes:
#   - Interactive: Shows menu with recommended mode based on system conditions
#   - Incremental: Writes N GB at a time, compacts, repeats (safer for limited disk space)
#   - Full: Single zero-fill operation (faster with sufficient disk space)
#   - Auto: Automatically selects best mode based on system conditions

# .PARAMETER Mode
#   Operation mode: Interactive, Incremental, Full, or Auto.
#   Default: Interactive (displays menu with recommended mode)

# .PARAMETER MinFreeSpaceGB
#   Minimum free space (in GB) to maintain during incremental cycles. In incremental mode, the script ensures
#   this much space remains free before starting each cycle. Set lower for tight disk space situations.
#   Default: 20 GB (auto-configures to 3-5 GB for low-space scenarios)

# .PARAMETER VhdxRelativePath
#   Relative path from LOCALAPPDATA to the Docker VHDX file.
#   Default: "Docker\wsl\disk\docker_data.vhdx"

# .PARAMETER Force
#   Skip interactive confirmation prompt and proceed automatically.
#   In automation scenarios, fails fast if not running as Administrator.

# .PARAMETER WhatIf
#   Simulation mode - shows what would happen without making any changes. Does not require Administrator privileges.
#   Displays [SIM] markers on all simulated operations for clarity.

# .PARAMETER MaxIncrementalSizeGB
#   If greater than 0, enables incremental mode where the script writes N GB at a time, then compacts, repeating up to MaxCycles.
#   Default: 0 (auto-configures to 2-10 GB based on available disk space)

# .PARAMETER MaxCycles
#   Maximum number of incremental cycles to perform when MaxIncrementalSizeGB > 0.
#   Default: 10

# .EXAMPLE
#   .\Shrink-DockerDataVHDX.ps1
#   Runs in interactive mode, showing recommended mode and menu for user selection.

# .EXAMPLE
#   .\Shrink-DockerDataVHDX.ps1 -WhatIf
#   Shows what the script would do without requiring admin privileges.

# .EXAMPLE
#   .\Shrink-DockerDataVHDX.ps1 -Mode Auto -WhatIf
#   Simulates Auto mode, which intelligently selects Full or Incremental based on system conditions.

# .EXAMPLE
#   .\Shrink-DockerDataVHDX.ps1 -Mode Incremental -MaxIncrementalSizeGB 5 -MaxCycles 3 -Force
#   Incremental mode with 5GB per cycle, max 3 cycles, non-interactive execution.

# .EXAMPLE
#   .\Shrink-DockerDataVHDX.ps1 -MaxIncrementalSizeGB 2 -MinFreeSpaceGB 3 -Force
#   Low disk space mode - writes 2GB per cycle with only 3GB safety margin, ideal when disk is nearly full.

# .NOTES
#   - Run PowerShell "As Administrator" for actual execution (not required for -WhatIf).
#   - The script uses the standard Windows environment variable $env:LOCALAPPDATA to locate Docker's VHDX by default.
#   - Auto mode analyzes disk space and VHDX size to intelligently select the safest, most efficient mode.
#   - All compaction operations display critical warnings - DO NOT interrupt during VHDX compaction phase.
#   - Author: generated/verified for user request. Keep a backup of important data before running.
#
[CmdletBinding()]
param(
    [Parameter(Mandatory=$false, Position=0)]
    [ValidateSet("Interactive", "Incremental", "Full", "Auto")]
    [string]$Mode = "Interactive",

    [Parameter(Mandatory=$false, Position=1)]
    [int]$MinFreeSpaceGB = 20,

    [Parameter(Mandatory=$false, Position=2)]
    [string]$VhdxRelativePath = "Docker\wsl\disk\docker_data.vhdx",

    [Parameter(Mandatory=$false)]
    [switch]$Force,

    [Parameter(Mandatory=$false)]
    [switch]$WhatIf,

    [Parameter(Mandatory=$false)]
    [int]$MaxIncrementalSizeGB = 0, # 0 implies default/unset

    [Parameter(Mandatory=$false)]
    [int]$MaxCycles = 10
)

# Flag to track if the mode was set via the interactive menu
$modeWasSelectedInteractively = $false

# =============================================================================
# SIGNAL HANDLING & PHASE TRACKING
# =============================================================================

# Global variable to track current operation phase for safe interruption control
# Values: 'Safe', 'ZeroFill', 'Compaction', 'Cleanup'
$script:OperationPhase = 'Safe'

# Signal handler for CTRL+C and PowerShell exit events
$script:ExitHandler = {
    $currentPhase = $script:OperationPhase

    # Display appropriate message based on current phase
    if ($currentPhase -eq 'Compaction') {
        Write-Host "`n`n╔═══════════════════════════════════════════════════════════════════╗" -ForegroundColor Red
        Write-Host "║                    ⚠️  CRITICAL OPERATION IN PROGRESS  ⚠️             ║" -ForegroundColor Red
        Write-Host "╠═══════════════════════════════════════════════════════════════════╣" -ForegroundColor Red
        Write-Host "║                                                                   ║" -ForegroundColor Red
        Write-Host "║  VHDX compaction is actively modifying your Docker VHDX file!    ║" -ForegroundColor Red
        Write-Host "║                                                                   ║" -ForegroundColor Red
        Write-Host "║  INTERRUPTING NOW WILL:                                           ║" -ForegroundColor Red
        Write-Host "║  • Corrupt the VHDX file structure                                ║" -ForegroundColor Red
        Write-Host "║  • Make Docker Desktop unable to start                            ║" -ForegroundColor Red
        Write-Host "║  • Potentially lose all Docker containers and data                ║" -ForegroundColor Red
        Write-Host "║                                                                   ║" -ForegroundColor Red
        Write-Host "║  PLEASE WAIT for the operation to complete (5-30 minutes typical)  ║" -ForegroundColor Red
        Write-Host "╚═══════════════════════════════════════════════════════════════════╝" -ForegroundColor Red
        Write-Host "`nThe script will continue running to prevent VHDX corruption..." -ForegroundColor Yellow
        Write-Host "If you must exit, close this window after compaction completes.`n" -ForegroundColor Yellow

        # Block the exit by throwing a non-terminating error
        $Host.UI.WriteErrorLine("Exit blocked: Cannot terminate during VHDX compaction.")
        # Use this to prevent exit (though not guaranteed in all scenarios)
        [System.Threading.Thread]::Sleep([System.Threading.Timeout]::Infinite)
    } elseif ($currentPhase -eq 'ZeroFill') {
        Write-Host "`n`n[INFO] Zero-fill interrupted. Safe to exit." -ForegroundColor Green
        Write-Host "Cleanup: Docker will remove any temporary files on next start.`n" -ForegroundColor Cyan
    } elseif ($currentPhase -eq 'Cleanup') {
        Write-Host "`n`n[INFO] Cleanup interrupted. Exiting...`n" -ForegroundColor Yellow
    } else {
        Write-Host "`n`n[INFO] Operation cancelled by user.`n" -ForegroundColor Yellow
    }
}

# Register CTRL+C and exit event handlers
try {
    $null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action $script:ExitHandler
    Write-Debug "Exit event handler registered"
} catch {
    Write-Debug "Failed to register exit event handler: $_"
}

# Add Ctrl+C keyboard interceptor (more immediate than engine event)
# This sets up a console cancel handler
Add-Type -TypeDefinition @"
using System;
using System.Management.Automation;
using System.Runtime.InteropServices;

public class ConsoleCancel {
    [DllImport("Kernel32.dll", SetLastError = true)]
    public static extern bool SetConsoleCtrlHandler(ConsoleCtrlHandler handler, bool add);

    public delegate bool ConsoleCtrlHandler(uint ctrlType);

    public static ConsoleCtrlHandler currentHandler = null;

    public static bool HandlerRoutine(uint ctrlType) {
        // This is called when Ctrl+C is pressed
        // Return false to allow default action (termination)
        // Return true to prevent default action (block)
        return true;
    }

    public static bool SetHandler() {
        if (currentHandler == null) {
            currentHandler = new ConsoleCtrlHandler(HandlerRoutine);
        }
        return SetConsoleCtrlHandler(currentHandler, true);
    }
}
"@ -Language CSharp

try {
    [ConsoleCancel]::SetHandler() | Out-Null
    Write-Debug "Console Ctrl+C handler installed"
} catch {
    Write-Debug "Failed to install console handler: $_"
}

# =============================================================================
# DOCKER DESKTOP MONITORING
# =============================================================================

function Start-DockerMonitoring {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if ($PSCmdlet.ShouldProcess("Starting Docker Desktop monitoring job", "Are you sure you want to start monitoring?", "Start Docker Monitoring")) {
        $dockerProcessName = "Docker Desktop"  # Common process name
        $script:DockerMonitoringActive = $true

    # Start monitoring in background job
    $monitorJob = Start-Job -ScriptBlock {
        $checkIntervalSeconds = 2
        $dockerDetected = $false

        while ($true) {
            # Check if Docker Desktop is running
            $dockerProcess = Get-Process -Name $using:dockerProcessName -ErrorAction SilentlyContinue

            if ($dockerProcess -and -not $dockerDetected) {
                $dockerDetected = $true
                Write-Output "DOCKER_DETECTED:$($dockerProcess.Id)"

                # Also check if WSL is running
                try {
                    $wslCheck = wsl --status 2>$null
                    if ($wslCheck) {
                        Write-Output "WSL_RUNNING"
                    }
                } catch {
                    # WSL not running - ignore error
                    $null = $_
                }
            }

            Start-Sleep -Seconds $checkIntervalSeconds
        }
    }

    return $monitorJob
    } else {
        return $null
    }
}

function Stop-DockerMonitoring {
    [CmdletBinding(SupportsShouldProcess)]
    param($MonitorJob)

    if ($PSCmdlet.ShouldProcess("Stopping Docker Desktop monitoring job", "Are you sure you want to stop monitoring?", "Stop Docker Monitoring")) {
        if ($MonitorJob) {
            Stop-Job -Job $MonitorJob -ErrorAction SilentlyContinue
            Remove-Job -Job $MonitorJob -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-DockerDesktopRunning {
    param()

    # Check for Docker Desktop process (various possible names)
    $dockerProcesses = @(
        "Docker Desktop",
        "Docker",
        "com.docker.docker",
        "Docker Desktop.exe"
    )

    foreach ($procName in $dockerProcesses) {
        $proc = Get-Process -Name $procName -ErrorAction SilentlyContinue
        if ($proc) {
            return $true
        }
    }
    return $false
}

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

function Get-HostFreeGB {
    $drv = Get-PSDrive -Name $script:driveLetter -PSProvider FileSystem -ErrorAction SilentlyContinue
    if ($drv) {
        return [math]::Round($drv.Free / 1GB, 2)
    }
    return 0
}

function Get-VhdxSizeGB {
    param([string]$Path)
    try {
        $file = Get-Item -LiteralPath $Path -ErrorAction Stop
        return [math]::Round($file.Length / 1GB, 2)
    } catch {
        return 0
    }
}

function Format-ElapsedTime {
    param([TimeSpan]$TimeSpan)
    if ($TimeSpan.TotalHours -ge 1) {
        return "{0:hh\:mm\:ss}" -f $TimeSpan
    } else {
        return "{0:mm\:ss}" -f $TimeSpan
    }
}

function Invoke-OperationWithProgress {
    param(
        [ScriptBlock]$Operation,
        [string]$Activity,
        [string]$Status,
        [int]$UpdateIntervalSeconds = 5
    )

    $job = Start-Job -ScriptBlock $Operation
    $startTime = Get-Date
    $lastUpdate = Get-Date

    while ($job.State -eq 'Running') {
        $elapsed = (Get-Date) - $startTime
        $elapsedStr = Format-ElapsedTime -TimeSpan $elapsed
        Write-Progress -Activity $Activity -Status "$Status (Elapsed: $elapsedStr)" -PercentComplete -1

        if (((Get-Date) - $lastUpdate).TotalSeconds -ge $UpdateIntervalSeconds) {
            Write-Verbose "[$elapsedStr] $Activity - $Status"
            $lastUpdate = Get-Date
        }
        Start-Sleep -Seconds 1
    }

    Write-Progress -Activity $Activity -Completed
    $result = Receive-Job -Job $job
    Remove-Job -Job $job -Force
    $totalElapsed = (Get-Date) - $startTime
    Write-Information "Completed in $(Format-ElapsedTime -TimeSpan $totalElapsed)" -InformationAction Continue
    return $result
}

function New-ZeroFillMonitor {
    [CmdletBinding(SupportsShouldProcess)]
    <#
    .SYNOPSIS
    Creates a background job to monitor zero-fill progress by tracking file size growth.

    .DESCRIPTION
    Starts a monitoring job that periodically checks the size of the zero-fill file
    inside the WSL docker-desktop distro and reports progress as a percentage.

    .PARAMETER FillGB
    The target size in GB to write

    .OUTPUTS
    Returns the monitoring job object
    #>
    param(
        [Parameter(Mandatory=$true)]
        [int]$FillGB
    )

    if ($PSCmdlet.ShouldProcess("Creating zero-fill monitor job for $FillGB GB", "Are you sure?", "Create Zero-Fill Monitor")) {
        $targetSizeBytes = $FillGB * 1024 * 1024 * 1024  # Convert GB to bytes
        $lastSize = 0

    $monitorJob = Start-Job -ScriptBlock {
        $targetPath = "/mnt/docker-desktop-disk/zero.fill"
        $targetSizeBytes = $using:targetSizeBytes
        $lastSize = 0

        while ($true) {
            try {
                # Get current file size from WSL
                $sizeOutput = wsl -d docker-desktop -- sh -c "stat -c %s $targetPath 2>/dev/null" 2>$null
                if ($sizeOutput) {
                    $currentSize = [convert]::ToInt64($sizeOutput.Trim(), 10)
                    if ($currentSize -gt $lastSize) {
                        $percent = [math]::Round(($currentSize / $targetSizeBytes) * 100, 1)
                        $mbWritten = [math]::Round($currentSize / 1MB, 2)
                        Write-Output "Progress: $percent% ($mbWritten MB / $($using:FillGB) GB written)"
                        $lastSize = $currentSize
                    }
                }
            } catch {
                # Ignore errors (file might not exist yet or WSL busy)
                $null = $_
            }
            Start-Sleep -Seconds 1
        }
    }

    return $monitorJob
    } else {
        return $null
    }
}

function Stop-ZeroFillMonitor {
    [CmdletBinding(SupportsShouldProcess)]
    <#
    .SYNOPSIS
    Stops and cleans up a zero-fill monitor job, displaying final progress.

    .DESCRIPTION
    Receives the final progress output from the monitor job and displays it,
    then stops and removes the job cleanly.

    .PARAMETER MonitorJob
    The monitoring job to stop
    #>
    param([Parameter(Mandatory=$true)]$MonitorJob)

    if ($PSCmdlet.ShouldProcess("Stopping zero-fill monitor job", "Are you sure?", "Stop Zero-Fill Monitor")) {
        # Display final progress update
        $finalProgress = Receive-Job -Job $MonitorJob -Keep -ErrorAction SilentlyContinue | Select-Object -Last 1
        if ($finalProgress) {
            Write-Host $finalProgress -ForegroundColor Cyan
        }

        # Stop and cleanup monitor
        Stop-Job -Job $MonitorJob -Force -ErrorAction SilentlyContinue
        Remove-Job -Job $MonitorJob -Force -ErrorAction SilentlyContinue
    }
}

function New-HostDiskMonitor {
    <#
    .SYNOPSIS
    Creates a background monitor for host disk space during zero-fill operations.

    .DESCRIPTION
    Monitors the host drive's free disk space in real-time and alerts if it drops
    below the minimum threshold. This prevents disk exhaustion during zero-fill
    operations that could corrupt the VHDX or leave the system in an inconsistent state.

    .PARAMETER MinFreeSpaceGB
    Minimum free space threshold in GB

    .PARAMETER DriveLetter
    Host drive letter to monitor (e.g., 'C')

    .PARAMETER CheckIntervalSeconds
    How often to check disk space (default: 2 seconds)

    .OUTPUTS
    Returns the monitoring job object
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification='Parameters are used via $using: in script block')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='Function creates internal monitoring job, no state change to external system')]
    param(
        [Parameter(Mandatory=$true)]
        [int]$MinFreeSpaceGB,

        [Parameter(Mandatory=$true)]
        [string]$DriveLetter,

        [Parameter(Mandatory=$false)]
        [int]$CheckIntervalSeconds = 2
    )

    $monitorJob = Start-Job -ScriptBlock {
        $minFree = $using:MinFreeSpaceGB
        $driveLetter = $using:DriveLetter
        $interval = $using:CheckIntervalSeconds

        while ($true) {
            try {
                $drive = Get-PSDrive -Name $driveLetter -PSProvider FileSystem -ErrorAction SilentlyContinue
                if ($drive) {
                    $currentFreeGB = [math]::Round($drive.Free / 1GB, 2)

                    if ($currentFreeGB -lt $minFree) {
                        $criticalThreshold = $minFree * 0.5  # Critical = 50% of MinFreeSpaceGB
                        if ($currentFreeGB -lt $criticalThreshold) {
                            Write-Output "CRITICAL_DISK:$currentFreeGB"
                        } else {
                            Write-Output "LOW_DISK:$currentFreeGB"
                        }
                    }
                }
            } catch {
                # Ignore errors (drive might be temporarily unavailable)
                $null = $_
            }
            Start-Sleep -Seconds $interval
        }
    }

    return $monitorJob
}

function Remove-HostDiskMonitor {
    <#
    .SYNOPSIS
    Stops and cleans up a host disk monitor job.

    .DESCRIPTION
    Properly stops and removes the host disk monitoring job.

    .PARAMETER MonitorJob
    The monitoring job to stop
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='Function only stops/cleans up, no state change to external system')]
    param([Parameter(Mandatory=$true)]$MonitorJob)

    if ($MonitorJob) {
        Stop-Job -Job $MonitorJob -Force -ErrorAction SilentlyContinue
        Remove-Job -Job $MonitorJob -Force -ErrorAction SilentlyContinue
    }
}

function Wait-DockerDesktopToClose {
    <#
    .SYNOPSIS
    Waits for Docker Desktop to be closed by the user, with optional auto-close.

    .DESCRIPTION
    Displays a blocking prompt asking the user to close Docker Desktop.
    Optionally can force-close Docker Desktop if it's still running.

    .PARAMETER Mode
    The operation mode (Interactive, Full, or Incremental)

    .PARAMETER Force
    If true, will attempt to force-close Docker Desktop

    .OUTPUTS
    Returns $true if Docker is successfully closed, $false otherwise
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$Mode,

        [Parameter(Mandatory=$false)]
        [switch]$Force
    )

    Write-Host "`n`n╔════════════════════════════════════════════════════════════════════╗" -ForegroundColor Red -NoNewline
    Write-Host "`n║                🚨 DOCKER DESKTOP IS RUNNING! 🚨                   ║" -ForegroundColor Red
    Write-Host "╠════════════════════════════════════════════════════════════════════╣" -ForegroundColor Red
    Write-Host "║                                                               ║" -ForegroundColor Red
    Write-Host "║  Docker Desktop must be CLOSED before running this script.       ║" -ForegroundColor Red
    Write-Host "║                                                               ║" -ForegroundColor Red
    Write-Host "║  Why?                                                         ║" -ForegroundColor Red
    Write-Host "║  • Docker has the VHDX file locked                             ║" -ForegroundColor Red
    Write-Host "║  • The script needs exclusive access to compact it              ║" -ForegroundColor Red
    Write-Host "║  • Running Docker + compaction = VHDX corruption risk           ║" -ForegroundColor Red
    Write-Host "║                                                               ║" -ForegroundColor Red
    Write-Host "║  Solution:                                                    ║" -ForegroundColor Red
    Write-Host "║  1. Close Docker Desktop (exit completely)                     ║" -ForegroundColor Red
    Write-Host "║  2. Wait 5 seconds                                            ║" -ForegroundColor Red
    Write-Host "║  3. Run this script again                                     ║" -ForegroundColor Red
    Write-Host "╚════════════════════════════════════════════════════════════════════╝" -ForegroundColor Red

    if ($Mode -eq "Interactive" -or -not $Force) {
        Write-Host "`nPress any key after closing Docker Desktop..." -ForegroundColor Yellow
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }

    # Check again
    if (Test-DockerDesktopRunning) {
        if ($Force -and $Mode -ne "Interactive") {
            Write-Error "Docker Desktop is still running. Use -Force to auto-close (risky) or close Docker manually."
            return $false
        } else {
            Write-Host "`n⚠️ Docker Desktop still detected. Forcing close... ⚠️" -ForegroundColor Yellow
            Get-Process -Name "Docker Desktop" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 5

            if (Test-DockerDesktopRunning) {
                Write-Error "Failed to close Docker Desktop. Please close it manually and try again."
                return $false
            }
            Write-Host "✅ Docker Desktop closed successfully." -ForegroundColor Green
            return $true
        }
    } else {
        Write-Host "✅ Docker Desktop closed." -ForegroundColor Green
        return $true
    }
}

function Test-DockerDesktopDuringCompaction {
    <#
    .SYNOPSIS
    Checks if Docker Desktop has started during compaction and handles the critical error.

    .DESCRIPTION
    Monitors for Docker Desktop process starting during compaction operations.
    If detected, displays critical error message and aborts to prevent VHDX corruption.

    .PARAMETER Job
    The compaction job being monitored

    .PARAMETER MonitorJob
    Optional Docker monitor job to stop

    .PARAMETER ElapsedSeconds
    Current elapsed time in seconds for periodic checking

    .OUTPUTS
    Returns $true if Docker detected (aborting), $false if safe to continue
    #>
    param(
        [Parameter(Mandatory=$true)]$Job,
        [Parameter(Mandatory=$false)]$MonitorJob,
        [Parameter(Mandatory=$true)][int]$ElapsedSeconds
    )

    # Check every 5 seconds (only on 5-second intervals)
    if ($ElapsedSeconds -gt 0 -and $ElapsedSeconds % 5 -eq 0) {
        # Check for Docker process
        $dockerProc = Get-Process -Name "Docker Desktop" -ErrorAction SilentlyContinue
        if ($dockerProc) {
            Write-Host "`n`n╔════════════════════════════════════════════════════════════════════╗" -ForegroundColor Red -NoNewline
            Write-Host "`n║  🚨 DOCKER DESKTOP STARTED DURING COMPACTION! 🚨                  ║" -ForegroundColor Red
            Write-Host "╠════════════════════════════════════════════════════════════════════╣" -ForegroundColor Red
            Write-Host "║                                                               ║" -ForegroundColor Red
            Write-Host "║  This is a CRITICAL ERROR!                                      ║" -ForegroundColor Red
            Write-Host "║                                                               ║" -ForegroundColor Red
            Write-Host "║  Docker Desktop starting during VHDX compaction can:            ║" -ForegroundColor Red
            Write-Host "║  • Corrupt the VHDX file beyond repair                          ║" -ForegroundColor Red
            Write-Host "║  • Make Docker completely unusable                              ║" -ForegroundColor Red
            Write-Host "║  • Cause permanent data loss                                    ║" -ForegroundColor Red
            Write-Host "║                                                               ║" -ForegroundColor Red
            Write-Host "║  Stopping compaction attempt...                                 ║" -ForegroundColor Red
            Write-Host "╚════════════════════════════════════════════════════════════════════╝" -ForegroundColor Red

            # Stop all jobs
            Stop-Job -Job $Job -Force -ErrorAction SilentlyContinue
            if ($MonitorJob) {
                Stop-Job -Job $MonitorJob -Force -ErrorAction SilentlyContinue
            }

            Write-Error "CRITICAL: Docker Desktop started during VHDX compaction. VHDX may be corrupted!"
            Write-Error "You should: 1) Close Docker Desktop immediately, 2) Check VHDX integrity, 3) Restore from backup if needed."
            Stop-DockerMonitoring -MonitorJob $script:DockerMonitorJob
            $script:OperationPhase = 'Safe'
            exit 1
        }
    }

    return $false
}

function Set-OperationPhase {
    [CmdletBinding(SupportsShouldProcess)]
    <#
    .SYNOPSIS
    Sets the current operation phase and provides debug output.

    .DESCRIPTION
    Centralizes phase management with consistent logging.
    Valid phases: Safe, ZeroFill, Compaction, Cleanup

    .PARAMETER Phase
    The new operation phase

    .PARAMETER Context
    Optional context information (e.g., "Cycle 3", "Full Mode")
    #>
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet("Safe", "ZeroFill", "Compaction", "Cleanup")]
        [string]$Phase,

        [Parameter(Mandatory=$false)]
        [string]$Context = ""
    )

    if ($PSCmdlet.ShouldProcess("Setting operation phase to '$Phase'", "Are you sure?", "Set Operation Phase")) {
        $script:OperationPhase = $Phase
        if ($Context) {
            Write-Debug "Phase set to: $Phase ($Context)"
        } else {
            Write-Debug "Phase set to: $Phase"
        }
    }
}

function Stop-MonitorJob {
    [CmdletBinding(SupportsShouldProcess)]
    <#
    .SYNOPSIS
    Stops and cleans up a monitor job with standardized error handling.

    .DESCRIPTION
    Consolidates job cleanup logic to ensure consistency across the script.

    .PARAMETER Job
    The job to stop and remove

    .PARAMETER JobName
    Optional name for logging purposes
    #>
    param(
        [Parameter(Mandatory=$true)]$Job,
        [Parameter(Mandatory=$false)][string]$JobName = "Monitor"
    )

    if ($PSCmdlet.ShouldProcess("Stopping and removing $JobName job", "Are you sure?", "Stop Monitor Job")) {
        Stop-Job -Job $Job -Force -ErrorAction SilentlyContinue
        Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue
        Write-Debug "Stopped and removed $JobName job"
    }
}

function Invoke-VhdxCompaction {
    param([string]$Path)

    # Set phase to Compaction (dangerous - do not interrupt)
    Set-OperationPhase -Phase "Compaction"

    # Display critical warning
    Write-Host "`n`n" -NoNewline
    Write-Host "╔═══════════════════════════════════════════════════════════════════╗" -ForegroundColor Red
    Write-Host "║                    ⚠️  VHDX COMPACTION STARTED  ⚠️                 ║" -ForegroundColor Red
    Write-Host "╠═══════════════════════════════════════════════════════════════════╣" -ForegroundColor Red
    Write-Host "║                                                                   ║" -ForegroundColor Red
    Write-Host "║  DO NOT:                                                           ║" -ForegroundColor Red
    Write-Host "║  • Press Ctrl+C                                                   ║" -ForegroundColor Red
    Write-Host "║  • Close this window                                              ║" -ForegroundColor Red
    Write-Host "║  • Start Docker Desktop                                           ║" -ForegroundColor Red
    Write-Host "║  • Run any Docker commands                                        ║" -ForegroundColor Red
    Write-Host "║                                                                   ║" -ForegroundColor Red
    Write-Host "║  ⚠️  CRITICAL: Starting Docker during compaction WILL              ║" -ForegroundColor Red
    Write-Host "║      corrupt your VHDX and make Docker unusable!                  ║" -ForegroundColor Red
    Write-Host "╚═══════════════════════════════════════════════════════════════════╝" -ForegroundColor Red
    Write-Host "" -NoNewline

    # Check if Docker Desktop is already running (shouldn't be, but check anyway)
    if (Test-DockerDesktopRunning) {
        Write-Host "`n`n🚨 DOCKER DESKTOP IS RUNNING!" -ForegroundColor Red
        Write-Host "This will conflict with VHDX compaction!" -ForegroundColor Red
        Write-Host "Please close Docker Desktop before continuing.`n" -ForegroundColor Yellow

        if ($Mode -eq "Interactive") {
            $confirm = Read-Host "Type 'YES' to force close Docker Desktop and continue (risky)"
            if ($confirm -ne 'YES') {
                Write-Host "Aborting for safety." -ForegroundColor Yellow
                Set-OperationPhase -Phase "Safe"
                exit 1
            }

            # Force close Docker Desktop
            Write-Host "Closing Docker Desktop..." -ForegroundColor Yellow
            Get-Process -Name "Docker Desktop" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
        } else {
            Write-Error "Docker Desktop is running. Close it before running the script."
            Set-OperationPhase -Phase "Safe"
            exit 1
        }
    }

    # Start Docker monitoring (detect if it starts during compaction)
    Write-Verbose "Starting Docker Desktop monitor..."
    $script:DockerMonitorJob = Start-DockerMonitoring

    $initialSizeGB = Get-VhdxSizeGB -Path $Path
    Write-Information "VHDX current size: $initialSizeGB GB" -InformationAction Continue

    if (Get-Command -Name Optimize-VHD -ErrorAction SilentlyContinue) {
        Write-Verbose "Using Optimize-VHD for compaction..."

        $compactOperation = {
            param($VhdxPath)
            try {
                Optimize-VHD -Path $VhdxPath -Mode Full -ErrorAction Stop
                return @{ Success = $true; Error = $null }
            } catch {
                return @{ Success = $false; Error = $_.Exception.Message }
            }
        }

        $monitorJob = Start-Job -ScriptBlock {
            $lastSize = $using:initialSizeGB
            $monitorPath = $using:Path
            while ($true) {
                Start-Sleep -Seconds 2
                try {
                    $currentSize = [math]::Round((Get-Item -LiteralPath $monitorPath -ErrorAction Stop).Length / 1GB, 2)
                    if ($currentSize -ne $lastSize) {
                        $reduction = $lastSize - $currentSize
                        Write-Output "Size: $currentSize GB (reduced $reduction GB)"
                        $lastSize = $currentSize
                    }
                } catch {
                    # Ignore errors (e.g. file lock) during monitoring
                    $null = $_
                }
            }
        }

        $startTime = Get-Date
        $compactJob = Start-Job -ScriptBlock $compactOperation -ArgumentList $Path

        while ($compactJob.State -eq 'Running') {
            $elapsed = (Get-Date) - $startTime
            $elapsedStr = Format-ElapsedTime -TimeSpan $elapsed
            $sizeUpdate = Receive-Job -Job $monitorJob -Keep | Select-Object -Last 1
            if ($sizeUpdate) {
                Write-Progress -Activity "Compacting VHDX" -Status "$sizeUpdate (Elapsed: $elapsedStr)" -PercentComplete -1
            } else {
                Write-Progress -Activity "Compacting VHDX" -Status "In progress (Elapsed: $elapsedStr)" -PercentComplete -1
            }

            # Check for Docker Desktop starting during compaction
            Test-DockerDesktopDuringCompaction -Job $compactJob -MonitorJob $monitorJob -ElapsedSeconds ([math]::Floor($elapsed.TotalSeconds))

            # Check Docker monitor job output
            $monitorOutput = Receive-Job -Job $script:DockerMonitorJob -Timeout 1 -ErrorAction SilentlyContinue
            if ($monitorOutput -and $monitorOutput -like "*DOCKER_DETECTED*") {
                Write-Host "`n`n⚠️ Docker Desktop detected starting! ⚠️`n" -ForegroundColor Red
            }

            Start-Sleep -Seconds 1
        }

        Write-Progress -Activity "Compacting VHDX" -Completed
        Stop-MonitorJob -Job $monitorJob -JobName "Size Monitor"

        $result = Receive-Job -Job $compactJob
        Stop-MonitorJob -Job $compactJob -JobName "Compaction"
        $totalElapsed = (Get-Date) - $startTime

        if (-not $result.Success) {
            Write-Error "Optimize-VHD failed: $($result.Error)"
            exit 1
        }

        $finalSizeGB = Get-VhdxSizeGB -Path $Path
        $savedGB = [math]::Round($initialSizeGB - $finalSizeGB, 2)
        Write-Information "Optimize-VHD completed in $(Format-ElapsedTime -TimeSpan $totalElapsed)" -InformationAction Continue
        Write-Information "VHDX final size: $finalSizeGB GB (saved $savedGB GB)" -InformationAction Continue

    } else {
        Write-Verbose "Using diskpart for compaction..."
        $tmpFile = [IO.Path]::GetTempFileName()
        $dpScript = @"
select vdisk file="$Path"
attach vdisk readonly
compact vdisk
detach vdisk
exit
"@
        Set-Content -LiteralPath $tmpFile -Value $dpScript -Encoding ASCII
        $diskpartOperation = {
            param($ScriptFile)
            try {
                diskpart /s $ScriptFile 2>&1
                return @{ Success = $true; Error = $null }
            } catch {
                return @{ Success = $false; Error = $_.Exception.Message }
            }
        }

        # Start monitoring for Docker Desktop during diskpart operation
        $monitorStartTime = Get-Date
        $diskpartJob = Start-Job -ScriptBlock {
            & $using:diskpartOperation -ScriptFile $using:tmpFile
        }

        # Monitor while diskpart is running
        while ($diskpartJob.State -eq 'Running') {
            # Check for Docker Desktop every 3 seconds
            $elapsed = (Get-Date) - $monitorStartTime
            if ($elapsed.TotalSeconds -gt 0 -and [math]::Floor($elapsed.TotalSeconds) % 3 -eq 0) {
                Test-DockerDesktopDuringCompaction -Job $diskpartJob -ElapsedSeconds ([math]::Floor($elapsed.TotalSeconds))
            }
            Start-Sleep -Seconds 1
        }

        # Get result
        $result = Receive-Job -Job $diskpartJob
        Stop-MonitorJob -Job $diskpartJob -JobName "DiskPart"

        Remove-Item -Force $tmpFile -ErrorAction SilentlyContinue
        if (-not $result.Success) {
            Write-Error "diskpart failed: $($result.Error)"
            exit 1
        }
        $finalSizeGB = Get-VhdxSizeGB -Path $Path
        $savedGB = [math]::Round($initialSizeGB - $finalSizeGB, 2)
        Write-Information "VHDX final size: $finalSizeGB GB (saved $savedGB GB)" -InformationAction Continue
    }

    # Stop Docker monitoring
    Stop-DockerMonitoring -MonitorJob $script:DockerMonitorJob

    # Reset phase back to Safe (compaction complete)
    Set-OperationPhase -Phase "Safe"

    # Show completion message
    Write-Host "`nVHDX compaction completed successfully!" -ForegroundColor Green
    Write-Host "It is now safe to close this window or restart Docker Desktop.`n" -ForegroundColor Green
}

function Test-WslAccess {
    param()
    Write-Verbose "Verifying access to /mnt/docker-desktop-disk inside WSL..."
    try {
        $mountCheck = wsl -d docker-desktop -- sh -c "test -d /mnt/docker-desktop-disk && echo OK" 2>$null
        if ($mountCheck -ne "OK") {
            Write-Warning "Target directory '/mnt/docker-desktop-disk' not found inside docker-desktop distro."
            Write-Warning "This path is required for zero-filling. Docker Desktop structure might have changed."
            if ($Mode -eq "Interactive") {
                $confirm = Read-Host "Do you want to proceed anyway? (Y/N)"
                if ($confirm -ne 'Y') { exit 1 }
            } else {
                exit 1
            }
        }
    } catch {
        Write-Warning "Failed to verify mount point inside WSL: $_"
    }
}

function Get-VhdxStat {
    param($VhdxFileSize)

    Write-Information "`nAnalyzing VHDX to estimate reclaimable space..." -InformationAction Continue
    Write-Information "Current VHDX file size: $VhdxFileSize GB" -InformationAction Continue

    $result = @{
        PotentialSavingsGB = 0
        UsedGB = 0
        AvailableGB = 0
    }

    try {
        $dockerDesktopStatus = wsl -l --running 2>$null | Select-String -Pattern "docker-desktop"
        if (-not $dockerDesktopStatus) {
            Write-Verbose "Starting docker-desktop distro to check disk usage..."
            $null = wsl -d docker-desktop -- echo "test" 2>$null
            Start-Sleep -Seconds 2
        }

        Write-Verbose "Querying disk usage inside docker-desktop..."
        $diskUsageRaw = wsl -d docker-desktop -- sh -c "df -h /mnt/docker-desktop-disk 2>/dev/null | tail -1" 2>$null

        if ($diskUsageRaw -and $diskUsageRaw -match '(\d+\.?\d*)G\s+(\d+\.?\d*)G\s+(\d+\.?\d*)G') {
            $result.UsedGB = [math]::Round([decimal]$matches[2], 2)
            $result.AvailableGB = [math]::Round([decimal]$matches[3], 2)
            $savings = $VhdxFileSize - $result.UsedGB

            Write-Information -MessageData "Disk usage inside VHDX:" -InformationAction Continue
            Write-Information -MessageData "  Used: $($result.UsedGB) GB (Logical)" -InformationAction Continue
            Write-Information -MessageData "  Physical VHDX: $VhdxFileSize GB" -InformationAction Continue
            Write-Information -MessageData "  Available: $($result.AvailableGB) GB" -InformationAction Continue

            if ($savings -lt 0) { $savings = 0 }
            $result.PotentialSavingsGB = [math]::Round($savings, 2)

            if ($result.PotentialSavingsGB -lt 0.01) {
                 Write-Information -MessageData "  Potential savings: ~0 GB (VHDX is smaller than logical data - likely sparse/compressed)" -InformationAction Continue
            } else {
                 Write-Information -MessageData "  Potential savings: ~$($result.PotentialSavingsGB) GB ($([math]::Round(($result.PotentialSavingsGB / $VhdxFileSize) * 100, 1))% of current size)" -InformationAction Continue
            }
        } else {
            Write-Warning "Unable to parse disk usage from docker-desktop distro."
        }
    } catch {
        Write-Warning "Could not query docker-desktop disk usage: $_"
    }

    return $result
}

function Show-SimulationReport {
    param(
        $VhdxPath,
        $potentialSavingsGB,
        $freeGB,
        $MinFreeSpaceGB,
        $Mode,
        $MaxIncrementalSizeGB,
        $MaxCycles,
        $Force,
        $isAdmin
    )

    Write-Information "[Simulation] Plan Summary:" -InformationAction Continue
    Write-Information "  VHDX: $VhdxPath" -InformationAction Continue
    if ($potentialSavingsGB -gt 0) {
        Write-Information "  Potential Savings: ~$potentialSavingsGB GB" -InformationAction Continue
    }
    Write-Information "  Host drive free: $freeGB GB" -InformationAction Continue
    Write-Information "  MinFreeSpaceGB: $MinFreeSpaceGB" -InformationAction Continue

    # Display plan based on Resolved Mode
    if ($Mode -eq "Incremental" -or ($Mode -eq "Interactive" -and $MaxIncrementalSizeGB -gt 0)) {
         Write-Information "  Mode: Incremental (simulated: $MaxIncrementalSizeGB GB per cycle, up to $MaxCycles cycles)" -InformationAction Continue
         Write-Information "  Each cycle will: write filler file of size N GB inside /mnt/docker-desktop-disk, shutdown WSL, compact VHDX, then continue" -InformationAction Continue
    } else {
         # Default simulation is Full if not specified
         Write-Information "  Mode: Full (simulated: write filler until disk full)" -InformationAction Continue
    }

    if ($Force) {
        Write-Information "  Force: yes (skips interactive confirmation)" -InformationAction Continue
    } else {
        Write-Information "  Force: no" -InformationAction Continue
    }

    # Predict Elevation Behavior
    if (-not $isAdmin) {
        if ($Force) {
            Write-Information "  Privileges: Non-Admin (WARNING: Execution with -Force would FAIL)" -InformationAction Continue
        } else {
            Write-Information "  Privileges: Non-Admin (Execution would request UAC Elevation)" -InformationAction Continue
        }
    } else {
        Write-Information "  Privileges: Administrator (Ready to run)" -InformationAction Continue
    }

    Write-Information "This is a simulation only; no actions were executed." -InformationAction Continue
}

function Show-ExecutionPlan {
    param(
        $VhdxPath,
        $freeGB,
        $MaxIncrementalSizeGB,
        $vhdxFileSize,
        $isAdmin
    )

    if ($MaxIncrementalSizeGB -gt 0) {
        $maxGrowthGB = $MaxIncrementalSizeGB
        $modeDesc = "Incremental ($MaxIncrementalSizeGB GB per cycle)"
    } else {
        $maxGrowthGB = [math]::Min($freeGB - 2, $vhdxFileSize * 0.5)
        $modeDesc = "Full (write until disk full)"
    }

    Write-Information -MessageData "" -InformationAction Continue
    Write-Information "===========================================================" -InformationAction Continue
    Write-Information "         EXECUTION PLAN" -InformationAction Continue
    Write-Information "===========================================================" -InformationAction Continue
    Write-Information "  VHDX file: $VhdxPath" -InformationAction Continue
    Write-Information "  Host drive free: $freeGB GB" -InformationAction Continue
    Write-Information "  Mode: $modeDesc" -InformationAction Continue
    Write-Information "  Estimated peak disk usage: ~$([math]::Round($maxGrowthGB, 2)) GB temporary growth" -InformationAction Continue

    if ($freeGB -lt 2) {
        Write-Error "Insufficient free space ($freeGB GB) to safely proceed. Need at least 2 GB free."
        Write-Error "Please free up some disk space first, or use incremental mode with a smaller chunk size."
        exit 1
    }

    Write-Information -MessageData "" -InformationAction Continue
    Write-Warning "During this operation, Docker Desktop and WSL2 distributions will be shut down."
    Write-Information "You can continue using your system normally otherwise." -InformationAction Continue
    Write-Information "This process may take some time depending on disk speed and size." -InformationAction Continue
    Write-Information -MessageData "" -InformationAction Continue

    if (-not $isAdmin) {
        Write-Warning "Administrator privileges are required to perform compaction."
        Write-Warning "The script will attempt to restart with Admin rights via UAC."
    }
}

# =============================================================================
# INITIAL SETUP AND VALIDATION
# =============================================================================

if ($VhdxRelativePath -match ":") {
    $VhdxPath = $VhdxRelativePath
} else {
    if (-not $env:LOCALAPPDATA) {
        Write-Error "Unable to find LOCALAPPDATA environment variable."
        exit 1
    }
    $VhdxPath = Join-Path -Path $env:LOCALAPPDATA -ChildPath $VhdxRelativePath
}

if (-not (Test-Path -LiteralPath $VhdxPath)) {
    Write-Error "VHDX not found: $VhdxPath"
    exit 1
}

# --- WSL Checks (Fast) ---
if (-not (Get-Command "wsl" -ErrorAction SilentlyContinue)) {
    Write-Error "WSL executable (wsl.exe) not found in PATH. Please install WSL."
    exit 1
}
$wslOutput = (wsl -l --quiet 2>$null) -join " "
$cleanOutput = $wslOutput -replace "`0", ""
if ($cleanOutput -notmatch "docker-desktop") {
    Write-Error "WSL distribution 'docker-desktop' not found."
    Write-Error "Please verify Docker Desktop is installed and using the WSL 2 backend."
    exit 1
}

# Host drive info (Fast)
$root = [System.IO.Path]::GetPathRoot($VhdxPath)
if (-not $root) {
    Write-Error "Unable to determine root from path: $VhdxPath"
    exit 1
}
$script:driveLetter = $root.Substring(0,1)
$drive = Get-PSDrive -Name $script:driveLetter -PSProvider FileSystem -ErrorAction SilentlyContinue
if (-not $drive) {
    Write-Error "Host drive ${script:driveLetter}: not found as a PSDrive."
    exit 1
}
$freeGB = [math]::Round($drive.Free / 1GB, 2)
$vhdxFileSize = Get-VhdxSizeGB -Path $VhdxPath

# =============================================================================
# ADMIN CHECK AND SAFETY VALIDATIONS
# =============================================================================

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# =============================================================================
# SHARED WORKFLOW HELPERS
# =============================================================================

function Measure-FillSize {
    param(
        [string]$Mode,
        [int]$FreeGB,
        [int]$MinFreeSpaceGB,
        [int]$MaxIncrementalSizeGB
    )

    if ($Mode -eq "Incremental") {
        $availableForFill = [math]::Floor($FreeGB - $MinFreeSpaceGB)
        if ($availableForFill -lt 1) {
            return 0
        }
        return [math]::Min($MaxIncrementalSizeGB, $availableForFill)
    } else {
        # Full mode
        return [math]::Max(1, $FreeGB - $MinFreeSpaceGB)
    }
}

function Initialize-ProgressTracking {
    param(
        [string]$Mode,
        [int]$MaxCycles,
        [int]$FillGB
    )

    if ($Mode -eq "Incremental") {
        $activity = "Incremental Compaction - Cycle 1 of $MaxCycles"
    } else {
        $activity = "Full Compaction - Writing $FillGB GB"
    }

    return $activity
}

function Show-CompactionSummary {
    param(
        [double]$InitialSizeGB,
        [double]$FinalSizeGB,
        [int]$ElapsedSeconds,
        [string]$Mode,
        [int]$CyclesCompleted = 0,
        [switch]$Simulate,
        [double]$InitialFreeGB = 0,
        [double]$FinalFreeGB = 0,
        [string]$DriveLetter = "C"
    )

    $totalSaved = [math]::Round($InitialSizeGB - $FinalSizeGB, 2)
    $elapsedMinutes = [math]::Round($ElapsedSeconds / 60, 1)

    Write-Host "`n========================================" -ForegroundColor Cyan
    if ($Simulate) {
        Write-Host "     SIMULATION COMPLETE" -ForegroundColor Cyan
    } else {
        Write-Host "     COMPACTION COMPLETE" -ForegroundColor Cyan
    }
    Write-Host "========================================" -ForegroundColor Cyan

    if ($Mode -eq "Incremental") {
        Write-Host "Cycles completed:     $CyclesCompleted" -ForegroundColor White
    } else {
        Write-Host "Mode:                 Full" -ForegroundColor White
    }

    if ($Simulate) {
        Write-Host "VHDX File:" -ForegroundColor Cyan
        Write-Host "  Initial size:       $InitialSizeGB GB" -ForegroundColor White
        Write-Host "  Final size:         $FinalSizeGB GB" -ForegroundColor White
        Write-Host "  Space saved:        ~$totalSaved GB (simulated)" -ForegroundColor Green

        if ($InitialFreeGB -gt 0 -and $FinalFreeGB -gt 0) {
            $freeSpaceRecovered = [math]::Round($FinalFreeGB - $InitialFreeGB, 2)
            Write-Host ""
            Write-Host "Host Disk ($DriveLetter):" -ForegroundColor Cyan
            Write-Host "  Initial free:       $InitialFreeGB GB" -ForegroundColor White
            Write-Host "  Final free:         $FinalFreeGB GB" -ForegroundColor White
            if ($freeSpaceRecovered -gt 0) {
                Write-Host "  Space recovered:    ~$freeSpaceRecovered GB (simulated)" -ForegroundColor Green
            }
        }
    } else {
        Write-Host "VHDX File:" -ForegroundColor Cyan
        Write-Host "  Initial size:       $InitialSizeGB GB" -ForegroundColor White
        Write-Host "  Final size:         $FinalSizeGB GB" -ForegroundColor White
        Write-Host "  Space saved:        $totalSaved GB" -ForegroundColor Green

        if ($InitialFreeGB -gt 0 -and $FinalFreeGB -gt 0) {
            $freeSpaceRecovered = [math]::Round($FinalFreeGB - $InitialFreeGB, 2)
            Write-Host ""
            Write-Host "Host Disk ($DriveLetter):" -ForegroundColor Cyan
            Write-Host "  Initial free:       $InitialFreeGB GB" -ForegroundColor White
            Write-Host "  Final free:         $FinalFreeGB GB" -ForegroundColor White
            if ($freeSpaceRecovered -gt 0) {
                Write-Host "  Space recovered:    $freeSpaceRecovered GB" -ForegroundColor Green
            }
        }
    }

    Write-Host "Time elapsed:         $elapsedMinutes minutes" -ForegroundColor White
    Write-Host "========================================`n" -ForegroundColor Cyan

    if ($Simulate) {
        Write-Host "[SIMULATION MODE] No actual changes were made.`n" -ForegroundColor Yellow
    } else {
        Write-Host "You can restart Docker Desktop now.`n" -ForegroundColor Green
    }
}

function Get-ExecutionContext {
    <#
    .SYNOPSIS
    Creates a unified parameter object for simulation and execution functions.

    .DESCRIPTION
    Consolidates all common parameters into a single hash table to eliminate
    parameter list duplication between Invoke-Simulation and Invoke-Execution.
    #>
    param(
        [string]$Mode,
        [string]$VhdxPath,
        [int]$freeGB,
        [int]$vhdxFileSize,
        [bool]$isAdmin,
        [bool]$Force,
        [int]$MinFreeSpaceGB,
        [int]$MaxIncrementalSizeGB,
        [int]$MaxCycles
    )

    return @{
        Mode = $Mode
        VhdxPath = $VhdxPath
        FreeGB = $freeGB
        VhdxFileSize = $vhdxFileSize
        IsAdmin = $isAdmin
        Force = $Force
        MinFreeSpaceGB = $MinFreeSpaceGB
        MaxIncrementalSizeGB = $MaxIncrementalSizeGB
        MaxCycles = $MaxCycles
    }
}

function Build-ZeroFillCommand {
    <#
    .SYNOPSIS
    Constructs a WSL command for zero-filling disk space.

    .DESCRIPTION
    Builds a standardized dd command for zero-filling inside the docker-desktop
    WSL distro with progress reporting and cleanup.

    .PARAMETER CountMB
    Optional explicit count in MB (for incremental mode)

    .OUTPUTS
    Returns the WSL dd command as a string
    #>
    param(
        [int]$CountMB = 0
    )

    if ($CountMB -gt 0) {
        return "dd if=/dev/zero of=/mnt/docker-desktop-disk/zero.fill bs=1M count=$CountMB status=progress 2>&1 || true; sync; rm -f /mnt/docker-desktop-disk/zero.fill"
    } else {
        return "dd if=/dev/zero of=/mnt/docker-desktop-disk/zero.fill bs=1M status=progress 2>&1 || true; sync; rm -f /mnt/docker-desktop-disk/zero.fill"
    }
}

function Invoke-WslShutdown {
    <#
    .SYNOPSIS
    Shuts down WSL and waits for cleanup.

    .DESCRIPTION
    Performs a standardized WSL shutdown sequence with sleep to ensure
    the VHDX is fully released before compaction.

    .PARAMETER WaitSeconds
    Seconds to wait after shutdown (default: 2)
    #>
    param([int]$WaitSeconds = 2)

    Write-Information "Shutting down WSL..." -InformationAction Continue
    wsl --shutdown
    Start-Sleep -Seconds $WaitSeconds
}

function Initialize-AutoConfiguration {
    <#
    .SYNOPSIS
    Applies automatic configuration adjustments based on available disk space.

    .DESCRIPTION
    Intelligently adjusts safety buffers and chunk sizes for incremental mode
    when running in low-disk-space scenarios. Provides defaults for simulation.

    .PARAMETER Mode
    The operation mode (Incremental or Full)

    .PARAMETER FreeGB
    Available free space in GB

    .PARAMETER MinFreeSpaceGB
    Current minimum free space setting

    .PARAMETER MaxIncrementalSizeGB
    Current incremental chunk size

    .PARAMETER IsSimulation
    If true, applies simulation-friendly defaults

    .OUTPUTS
    Returns a hash table with adjusted MinFreeSpaceGB and MaxIncrementalSizeGB
    #>
    param(
        [string]$Mode,
        [int]$FreeGB,
        [int]$MinFreeSpaceGB,
        [int]$MaxIncrementalSizeGB,
        [bool]$IsSimulation = $false
    )

    $result = @{
        MinFreeSpaceGB = $MinFreeSpaceGB
        MaxIncrementalSizeGB = $MaxIncrementalSizeGB
        IsAdjusted = $false
    }

    if ($Mode -ne "Incremental") {
        return $result
    }

    # Low disk space auto-configuration
    if ($FreeGB -lt 10) {
        if ($MinFreeSpaceGB -gt 2) {
            $result.MinFreeSpaceGB = 2
            $result.IsAdjusted = $true
        }
        if ($MaxIncrementalSizeGB -eq 0 -or $MaxIncrementalSizeGB -gt 1) {
            $result.MaxIncrementalSizeGB = 1
            $result.IsAdjusted = $true
        }
        if ($result.IsAdjusted) {
            Write-Warning "Low disk space detected ($FreeGB GB). Auto-configuring for safety:"
            Write-Warning "  - Safety Buffer adjusted to $($result.MinFreeSpaceGB) GB"
            Write-Warning "  - Chunk Size adjusted to $($result.MaxIncrementalSizeGB) GB"
        }
    } elseif ($MaxIncrementalSizeGB -eq 0 -and $IsSimulation) {
        # Default simulation values
        $result.MinFreeSpaceGB = 5
        $result.MaxIncrementalSizeGB = 5
        Write-Information "Using default simulation values (Safety Buffer: 5 GB, Chunk: 5 GB)." -InformationAction Continue
    } elseif ($MaxIncrementalSizeGB -eq 0) {
        # Default execution values for normal disk space
        $result.MinFreeSpaceGB = 5
        $result.MaxIncrementalSizeGB = 5
        Write-Information "Using default Incremental values (Safety Buffer: 5 GB, Chunk: 5 GB)." -InformationAction Continue
    }

    return $result
}

function Show-InteractiveMenu {
    <#
    .SYNOPSIS
    Displays the interactive mode selection menu.

    .DESCRIPTION
    Standardizes the display of the interactive menu with consistent formatting
    and returns the user's selection. Highlights the recommended mode.

    .PARAMETER FreeGB
    Available free space for display

    .PARAMETER IsAdmin
    Whether running as Administrator

    .PARAMETER RecommendedMode
    The recommended mode to highlight (Full or Incremental)

    .OUTPUTS
    Returns the selected menu option as a string
    #>
    param(
        [int]$FreeGB,
        [bool]$IsAdmin,
        [string]$RecommendedMode = ""
    )

    $adminSuffix = if (-not $IsAdmin) { " [Requires Admin]" } else { "" }

    # Determine which option numbers correspond to the recommended mode
    $recommendedIncremental = ($RecommendedMode -eq "Incremental")
    $recommendedFull = ($RecommendedMode -eq "Full")

    $incMarker = if ($recommendedIncremental) { " ← RECOMMENDED" } else { "" }
    $fullMarker = if ($recommendedFull) { " ← RECOMMENDED" } else { "" }

    Write-Information -MessageData "" -InformationAction Continue
    Write-Information "===========================================================" -InformationAction Continue
    Write-Information "         SELECT OPERATION MODE" -InformationAction Continue
    Write-Information "===========================================================" -InformationAction Continue
    Write-Information "Host Free Space: $FreeGB GB" -InformationAction Continue
    Write-Information "-----------------------------------------------------------" -InformationAction Continue
    Write-Information "1. SIMULATE Incremental Mode" -InformationAction Continue
    Write-Information "2. SIMULATE Full Mode" -InformationAction Continue
    Write-Information "3. INCREMENTAL Mode (Slower but Safe. Prevents filling up your host drive.)$adminSuffix$incMarker" -InformationAction Continue
    Write-Information "4. FULL Mode        (Fastest. WARNING: Host disk usage will spike significantly.)$adminSuffix$fullMarker" -InformationAction Continue
    Write-Information "5. AUTO Mode        (Automatically selects best mode for your system)$adminSuffix" -InformationAction Continue
    Write-Information -MessageData "6. Abort" -InformationAction Continue

    return Read-Host "Enter selection (1-6)"
}

function Resolve-OperationMode {
    <#
    .SYNOPSIS
    Resolves the actual operation mode from CLI parameters.

    .DESCRIPTION
    Handles implicit mode resolution based on MaxIncrementalSizeGB parameter
    and validates the resolved mode. For Auto mode, calls Select-AutomaticMode.

    .PARAMETER Mode
    The initially specified mode (Interactive, Incremental, Full, or Auto)

    .PARAMETER MaxIncrementalSizeGB
    The incremental size parameter

    .PARAMETER FreeGB
    Available free space in GB

    .PARAMETER MinFreeSpaceGB
    Minimum required free space

    .PARAMETER VhdxFileSize
    VHDX file size in GB

    .OUTPUTS
    Returns the resolved mode as a string
    #>
    param(
        [string]$Mode,
        [int]$MaxIncrementalSizeGB,
        [int]$FreeGB = 0,
        [int]$MinFreeSpaceGB = 0,
        [int]$VhdxFileSize = 0
    )

    # Auto mode - determine best mode based on system conditions
    if ($Mode -eq "Auto") {
        return Select-AutomaticMode -FreeGB $FreeGB -MinFreeSpaceGB $MinFreeSpaceGB -VhdxFileSize $VhdxFileSize
    }

    # Resolve mode implicits
    if ($MaxIncrementalSizeGB -gt 0 -and $Mode -eq "Interactive") {
        return "Incremental"
    }

    return $Mode
}

function Select-AutomaticMode {
    <#
    .SYNOPSIS
    Intelligently selects the best compaction mode based on system conditions.

    .DESCRIPTION
    Analyzes available disk space and system resources to automatically choose
    between Incremental and Full modes for optimal performance and safety.

    .PARAMETER FreeGB
    Available free space in GB

    .PARAMETER MinFreeSpaceGB
    Minimum required free space

    .PARAMETER VhdxFileSize
    Current VHDX file size in GB

    .OUTPUTS
    Returns "Full" or "Incremental" based on analysis
    #>
    param(
        [int]$FreeGB,
        [int]$MinFreeSpaceGB,
        [int]$VhdxFileSize
    )

    Write-Host "`n[Auto-Select] Analyzing system conditions..." -ForegroundColor Cyan
    Write-Host "  Free space: $FreeGB GB" -ForegroundColor Gray
    Write-Host "  Minimum required: $MinFreeSpaceGB GB" -ForegroundColor Gray
    Write-Host "  VHDX size: $VhdxFileSize GB" -ForegroundColor Gray

    # Calculate space ratio (how much buffer we have beyond minimum)
    $spaceRatio = $FreeGB / $MinFreeSpaceGB

    # Decision logic:
    # - If space ratio > 2.0 (100% buffer), Full mode is safe and faster
    # - If space ratio <= 2.0 (tight buffer), Incremental is safer
    # - Special case: if VHDX is very large (> 100 GB) and space < 50 GB, use Incremental

    if ($spaceRatio -gt 2.0 -and $FreeGB -gt 50) {
        # Plenty of space - Full mode is safe and faster
        Write-Host "`n[Auto-Select] → **FULL MODE** (Plenty of disk space - optimal for speed)" -ForegroundColor Green
        Write-Host "  Reason: Free space ($FreeGB GB) >> Minimum required ($MinFreeSpaceGB GB)" -ForegroundColor Gray
        return "Full"
    } elseif ($VhdxFileSize -gt 100 -and $FreeGB -lt 50) {
        # Large VHDX with limited space - Incremental is safer
        Write-Host "`n[Auto-Select] → **INCREMENTAL MODE** (Large VHDX, conservative approach)" -ForegroundColor Yellow
        Write-Host "  Reason: Large VHDX ($VhdxFileSize GB) + Limited space ($FreeGB GB) = Safer in chunks" -ForegroundColor Gray
        return "Incremental"
    } elseif ($spaceRatio -le 2.0) {
        # Tight on space - Incremental is safer
        Write-Host "`n[Auto-Select] → **INCREMENTAL MODE** (Limited disk space - safer approach)" -ForegroundColor Yellow
        Write-Host "  Reason: Free space ratio ($([math]::Round($spaceRatio, 2))) indicates tight disk space" -ForegroundColor Gray
        return "Incremental"
    } else {
        # Default to Incremental for safety
        Write-Host "`n[Auto-Select] → **INCREMENTAL MODE** (Conservative default)" -ForegroundColor Yellow
        Write-Host "  Reason: Defaulting to safer incremental approach" -ForegroundColor Gray
        return "Incremental"
    }
}

function Invoke-IncrementalWorkflow {
    param(
        [string]$VhdxPath,
        [int]$FreeGB,
        [int]$MinFreeSpaceGB,
        [int]$MaxIncrementalSizeGB,
        [int]$MaxCycles,
        [string]$Mode = "Incremental",
        [switch]$Simulate
    )

    $startTime = Get-Date
    $totalSavedGB = 0
    $initialVhdxSize = Get-VhdxSizeGB -Path $VhdxPath
    $initialFreeGB = Get-HostFreeGB
    $cycle = 0

    if ($Simulate) {
        Write-Host "`n========================================" -ForegroundColor Cyan
        Write-Host "   SIMULATED INCREMENTAL EXECUTION" -ForegroundColor Cyan
        Write-Host "========================================`n" -ForegroundColor Cyan
    }

    while ($cycle -lt $MaxCycles) {
        $cycle++
        $overallProgress = [math]::Round(($cycle / $MaxCycles) * 100, 0)

        if (-not $Simulate) {
            Write-Progress -Id 1 -Activity "Incremental Compaction" -Status "Cycle $cycle (max $MaxCycles)" -PercentComplete $overallProgress
        } else {
            Write-Host "┌────────────────────────────────────────┐" -ForegroundColor Cyan
            Write-Host "│ [SIM] Cycle $cycle (max $MaxCycles) - Writing $MaxIncrementalSizeGB GB │" -ForegroundColor Cyan
            Write-Host "└────────────────────────────────────────┘" -ForegroundColor Cyan
        }

        $currentFree = if ($Simulate) { $FreeGB - $totalSavedGB } else { Get-HostFreeGB }

        if (-not $Simulate) {
            Write-Information "`n========== Cycle $cycle of $MaxCycles ==========" -InformationAction Continue
            Write-Information "Host free space: $currentFree GB" -InformationAction Continue
        } else {
            Write-Host "`n[SIM] Checking WSL access..." -ForegroundColor Gray
            Start-Sleep -Milliseconds 200
            Write-Host "[SIM] ✓ WSL distro 'docker-desktop' is running`n" -ForegroundColor Green
        }

        $fillGB = Measure-FillSize -Mode $Mode -FreeGB $currentFree -MinFreeSpaceGB $MinFreeSpaceGB -MaxIncrementalSizeGB $MaxIncrementalSizeGB

        if ($fillGB -lt 1) {
            if ($Simulate) {
                Write-Host "[SIM] Not enough headroom to write filler. Stopping $Mode mode." -ForegroundColor Yellow
            } else {
                Write-Verbose "Not enough headroom to write filler. Stopping $Mode mode."
            }
            break
        }

        # Execute one compaction cycle (zero-fill → shutdown → compact)
        $cycleSuccess = Invoke-CompactionCycle -VhdxPath $VhdxPath -FillSizeGB $fillGB -CycleNum $cycle -MaxCycles $MaxCycles -MinFreeSpaceGB $MinFreeSpaceGB -IsFullMode $false -Simulate:$Simulate

        # Check if cycle was aborted
        if (-not $cycleSuccess) {
            Write-Host "`n[INFO] Operation aborted by user due to low disk space." -ForegroundColor Yellow
            Write-Host "[INFO] You can free up disk space and retry the operation." -ForegroundColor Yellow
            return
        }

        if ($Simulate) {
            $cycleSaved = Get-Random -Minimum 0.5 -Maximum 2.0
            $totalSavedGB += $cycleSaved
        }

        # Calculate free space for next iteration
        $currentFree = if ($Simulate) { $FreeGB - $totalSavedGB } else { Get-HostFreeGB }

        if ($currentFree -lt $MinFreeSpaceGB) {
            if ($Simulate) {
                Write-Host "[SIM] Low disk space warning. Stopping." -ForegroundColor Yellow
            }
            break
        }

        $remainingCycles = $MaxCycles - $cycle
        if ($remainingCycles -gt 0 -and $Simulate) {
            Write-Host "`n[SIM] Cycle $cycle completed. $remainingCycles cycles remaining." -ForegroundColor Cyan
            Write-Host "[SIM] Current disk usage: $([math]::Round($currentFree, 2)) GB free`n" -ForegroundColor Gray
            Start-Sleep -Milliseconds 500
        }
    }

    if (-not $Simulate) {
        Write-Progress -Id 1 -Activity "Incremental Compaction" -Completed
    }

    $elapsedSeconds = (Get-Date) - $startTime | Select-Object -ExpandProperty TotalSeconds

    if ($Simulate) {
        Show-CompactionSummary -InitialSizeGB $initialVhdxSize -FinalSizeGB ($initialVhdxSize - $totalSavedGB) -ElapsedSeconds $elapsedSeconds -Mode "Incremental" -CyclesCompleted $cycle -Simulate -InitialFreeGB $initialFreeGB -FinalFreeGB $initialFreeGB -DriveLetter $script:driveLetter
    } else {
        $finalVhdxSize = Get-VhdxSizeGB -Path $VhdxPath
        $finalFreeGB = Get-HostFreeGB
        Show-CompactionSummary -InitialSizeGB $initialVhdxSize -FinalSizeGB $finalVhdxSize -ElapsedSeconds $elapsedSeconds -Mode "Incremental" -CyclesCompleted $cycle -InitialFreeGB $initialFreeGB -FinalFreeGB $finalFreeGB -DriveLetter $script:driveLetter
    }
}

# =============================================================================
# UNIFIED COMPACTION CYCLE - Used by both Incremental and Full modes
# =============================================================================

function Invoke-CompactionCycle {
    <#
    .SYNOPSIS
    Performs one compaction cycle: zero-fill → shutdown → compact.
    Shared logic used by both Incremental and Full workflows.
    #>
    param(
        [string]$VhdxPath,
        [int]$FillSizeGB,
        [int]$CycleNum,
        [int]$MaxCycles,
        [int]$MinFreeSpaceGB,
        [bool]$IsFullMode,  # True for Full mode, False for Incremental
        [switch]$Simulate
    )

    $cycleLabel = if ($IsFullMode) { "Full Mode" } else { "Cycle $CycleNum of $MaxCycles" }

    if (-not $Simulate) {
        Write-Information "`n========== $cycleLabel ==========" -InformationAction Continue
        Write-Information "Zero-filling $FillSizeGB GB..." -InformationAction Continue
        $countMB = $FillSizeGB * 1024
        $ddCmdCycle = Build-ZeroFillCommand -CountMB $countMB
    } else {
        Write-Host "┌────────────────────────────────────────┐" -ForegroundColor Cyan
        if ($IsFullMode) {
            Write-Host "│        [SIM] Full Mode - Writing $FillSizeGB GB         │" -ForegroundColor Cyan
        } else {
            Write-Host "│ [SIM] Cycle $CycleNum (max $MaxCycles) - Writing $FillSizeGB GB │" -ForegroundColor Cyan
        }
        Write-Host "└────────────────────────────────────────┘" -ForegroundColor Cyan
        Write-Host "[SIM] Creating zero-fill file: /mnt/docker-desktop-disk/zero.fill" -ForegroundColor Gray
        Write-Host "[SIM] Target size: $FillSizeGB GB`n" -ForegroundColor Gray
    }

    # Set phase to ZeroFill (safer to interrupt)
    if (-not $Simulate) {
        Set-OperationPhase -Phase "ZeroFill" -Context $cycleLabel
    }

    # Start progress monitoring
    if (-not $Simulate) {
        $zeroFillMonitor = New-ZeroFillMonitor -FillGB $FillSizeGB
        # Start host disk space monitoring (prevents disk exhaustion)
        $hostDiskMonitor = New-HostDiskMonitor -MinFreeSpaceGB $MinFreeSpaceGB -DriveLetter $script:driveLetter -CheckIntervalSeconds 2
    }

    # Run Zero Fill
    if ($Simulate) {
        # Simulated progress bar
        $activity = if ($IsFullMode) { "Zero-filling $FillSizeGB GB of free space" } else { "Zero-filling $FillSizeGB GB (Cycle $CycleNum of $MaxCycles)" }
        for ($i = 0; $i -le 100; $i += 3) {
            $progress = @{
                Activity         = $activity
                Status           = "Writing zeros... $i%"
                PercentComplete  = $i
                CurrentOperation = "$([math]::Round($FillSizeGB * $i / 100, 2)) GB / $FillSizeGB GB written"
            }
            Write-Progress @progress
            Start-Sleep -Milliseconds 40
        }
        Write-Progress -Activity $activity -Completed

        Write-Host "`n[SIM] ✓ Zero-fill complete! Reclaimed ~$(Get-Random -Minimum 0.5 -Maximum 2.0) GB" -ForegroundColor Green
    } else {
        # Start monitoring for disk space alerts during zero-fill
        $diskAlertDetected = $false
        $wslProcess = Start-Process -FilePath "wsl" -ArgumentList @("-d", "docker-desktop", "--", "sh", "-c", $ddCmdCycle) -NoNewWindow -PassThru

        # Monitor while zero-fill is running
        while (-not $wslProcess.HasExited) {
            # Check for host disk alerts
            $alert = Receive-Job -Job $hostDiskMonitor -Timeout 0 -ErrorAction SilentlyContinue | Where-Object { $_ -match "LOW_DISK|CRITICAL_DISK" } | Select-Object -Last 1

            if ($alert) {
                $diskAlertDetected = $true
                if ($alert -match "CRITICAL") {
                    Write-Host "`n`n⚠️ CRITICAL: Host disk space critically low! ⚠️`n" -ForegroundColor Red
                    Write-Host "Current free space: $([math]::Round([decimal]($alert.Split(':')[1]), 2)) GB" -ForegroundColor Red
                    Write-Host "Required minimum: $MinFreeSpaceGB GB" -ForegroundColor Red
                    Write-Host "`n[INFO] Since you're running this to reclaim disk space, you have these options:" -ForegroundColor Cyan
                    Write-Host "  1. Skip zero-fill and proceed to compaction (RECOMMENDED - you'll reclaim SOME space)" -ForegroundColor Green
                    Write-Host "  2. Continue anyway with monitoring (RISKY - may corrupt VHDX)" -ForegroundColor Yellow
                    Write-Host "  3. Abort operation (NOT RECOMMENDED - you'll have no extra space)" -ForegroundColor Red

                    if ($Force) {
                        # Auto-skip to compaction in -Force mode (automation scenario)
                        Write-Host "`n[INFO] -Force mode: Auto-skipping zero-fill due to critical disk space." -ForegroundColor Cyan
                        Write-Host "[INFO] Proceeding directly to compaction (less efficient but safer)." -ForegroundColor Cyan
                        $wslProcess.Kill()
                        # Continue to compaction
                    } else {
                        $choice = Read-Host "`nEnter choice (1-3, default: 1)"

                        if ($choice -eq "2") {
                            Write-Host "`n[WARNING] Continuing despite low disk space. Risk of corruption!" -ForegroundColor Red
                            Write-Host "The script will monitor disk space and abort if it gets worse." -ForegroundColor Yellow
                            # Continue monitoring but don't auto-kill
                            $continueAnyway = $true
                        } elseif ($choice -eq "3") {
                            Write-Host "`n[INFO] Aborting operation." -ForegroundColor Yellow
                            $wslProcess.Kill()
                            return $false  # Abort
                        } else {
                            # Default: Skip to compaction (option 1)
                            Write-Host "`n[INFO] Skipping zero-fill to preserve host disk space." -ForegroundColor Cyan
                            Write-Host "[INFO] Proceeding directly to compaction (less efficient but safer)." -ForegroundColor Cyan
                            $wslProcess.Kill()
                            # Continue to compaction
                        }
                    }
                } elseif ($alert -match "LOW_DISK" -and $continueAnyway -eq $true) {
                    Write-Host "`n`n⚠️ WARNING: Disk space still low ($([math]::Round([decimal]($alert.Split(':')[1]), 2)) GB free). ⚠️`n" -ForegroundColor Yellow
                    $choice = Read-Host "Continue monitoring? (y/n, default: n)"
                    if ($choice -ne "y") {
                        $wslProcess.Kill()
                        return $false  # Abort
                    }
                } elseif ($alert -match "LOW_DISK") {
                    Write-Host "`n`n⚠️ WARNING: Host disk space running low ($([math]::Round([decimal]($alert.Split(':')[1]), 2)) GB free). ⚠️`n" -ForegroundColor Yellow
                }
            }
            Start-Sleep -Seconds 1
        }

        $wslProcess.WaitForExit()
        if ($wslProcess.ExitCode -ne 0) {
            Write-Warning "Zero-fill process returned code $($wslProcess.ExitCode)."
        }
    }

    # Stop monitoring
    if (-not $Simulate) {
        Stop-ZeroFillMonitor -MonitorJob $zeroFillMonitor
        Remove-HostDiskMonitor -MonitorJob $hostDiskMonitor

        if ($diskAlertDetected) {
            if ($IsFullMode) {
                Write-Host "`n[IMPORTANT] Host disk monitoring detected low space during zero-fill." -ForegroundColor Yellow
                Write-Host "Consider using Incremental mode for better disk space management.`n" -ForegroundColor Yellow
            } else {
                Write-Host "`n[IMPORTANT] Host disk monitoring detected low space during zero-fill." -ForegroundColor Yellow
                Write-Host "Consider using smaller MaxIncrementalSizeGB values to avoid this issue.`n" -ForegroundColor Yellow
            }
        }
    }

    # Reset phase to Safe (before compaction)
    if (-not $Simulate) {
        Set-OperationPhase -Phase "Safe"
    }

    # Shutdown and compact
    if ($Simulate) {
        Write-Host "[SIM] Shutting down WSL for compaction..." -ForegroundColor Yellow
        Start-Sleep -Milliseconds 300
        Write-Host "[SIM] ✓ WSL shutdown complete`n" -ForegroundColor Green

        Write-Host "[SIM] Starting VHDX compaction (Optimize-VHD)..." -ForegroundColor Yellow
        Write-Host "[SIM] Compacting... (this may take several minutes)`n" -ForegroundColor Gray

        # Simulated compaction progress
        for ($i = 0; $i -le 100; $i += 10) {
            $sizeReduction = [math]::Round((Get-Random -Minimum 0.5 -Maximum 2.0) * $i / 100, 2)
            Write-Host "`r[SIM] Optimization: $i% - Reduced by $sizeReduction GB" -NoNewline -ForegroundColor Gray
            Start-Sleep -Milliseconds 150
        }
        Write-Host "`n`n[SIM] ✓ VHDX compaction complete!" -ForegroundColor Green
    } else {
        Invoke-WslShutdown -WaitSeconds 2
        Invoke-VhdxCompaction -Path $VhdxPath
    }

    return $true  # Success
}

function Invoke-FullWorkflow {
    <#
    .SYNOPSIS
    Full mode is implemented as Incremental mode with a single cycle and maximum fill size.
    This eliminates code duplication while maintaining the same behavior.
    #>
    param(
        [string]$VhdxPath,
        [int]$FreeGB,
        [int]$MinFreeSpaceGB,
        [switch]$Simulate
    )

    # Calculate maximum fill size for Full mode (all free space)
    $maxIncrementalSizeGB = Measure-FillSize -Mode "Full" -FreeGB $FreeGB -MinFreeSpaceGB $MinFreeSpaceGB -MaxIncrementalSizeGB 0

    # Call IncrementalWorkflow with MaxCycles=1 (single cycle = Full mode)
    Invoke-IncrementalWorkflow -VhdxPath $VhdxPath -FreeGB $FreeGB -MinFreeSpaceGB $MinFreeSpaceGB -MaxIncrementalSizeGB $maxIncrementalSizeGB -MaxCycles 1 -Mode "Full" -Simulate:$Simulate
}

# =============================================================================
# UNIFIED EXECUTION LOGIC
# =============================================================================

# Invoke-Simulation has been removed - use Invoke-Execution -Simulate instead

function Invoke-Execution {
    param(
        [string]$Mode,
        [string]$VhdxPath,
        [int]$freeGB,
        [int]$vhdxFileSize,
        [bool]$isAdmin,
        [bool]$Force,
        [int]$MinFreeSpaceGB,
        [int]$MaxIncrementalSizeGB,
        [int]$MaxCycles,
        [switch]$Simulate
    )

    # Early return for simulation - show plan and run simulated execution
    if ($Simulate) {
        # 1. Run Analysis (Needed for simulation report)
        Test-WslAccess
        $stats = Get-VhdxStat -VhdxFileSize $vhdxFileSize
        $potentialSavingsGB = $stats.PotentialSavingsGB

        # 2. Apply Auto-Configuration
        $config = Initialize-AutoConfiguration -Mode $Mode -FreeGB $freeGB -MinFreeSpaceGB $MinFreeSpaceGB -MaxIncrementalSizeGB $MaxIncrementalSizeGB -IsSimulation $true

        # 3. Show Plan Summary
        Show-SimulationReport `
            -VhdxPath $VhdxPath `
            -potentialSavingsGB $potentialSavingsGB `
            -freeGB $freeGB `
            -MinFreeSpaceGB $config.MinFreeSpaceGB `
            -Mode $Mode `
            -MaxIncrementalSizeGB $config.MaxIncrementalSizeGB `
            -MaxCycles $MaxCycles `
            -Force $Force `
            -isAdmin $isAdmin

        # 4. Run Realistic Simulation
        Write-Host "`n[SIMULATION] Starting simulated execution..." -ForegroundColor Cyan
        Start-Sleep -Milliseconds 500

        if ($Mode -eq "Incremental") {
            Invoke-IncrementalWorkflow -VhdxPath $VhdxPath -FreeGB $freeGB -MinFreeSpaceGB $config.MinFreeSpaceGB -MaxIncrementalSizeGB $config.MaxIncrementalSizeGB -MaxCycles $MaxCycles -Mode "Incremental" -VhdxFileSize $vhdxFileSize -Simulate
        } elseif ($Mode -eq "Full") {
            Invoke-FullWorkflow -VhdxPath $VhdxPath -FreeGB $freeGB -MinFreeSpaceGB $config.MinFreeSpaceGB -Simulate
        } elseif ($Mode -eq "Auto") {
            # Auto mode - determine best mode and simulate it
            $autoMode = Select-AutomaticMode -FreeGB $freeGB -MinFreeSpaceGB $config.MinFreeSpaceGB -VhdxFileSize $vhdxFileSize
            if ($autoMode -eq "Incremental") {
                Invoke-IncrementalWorkflow -VhdxPath $VhdxPath -FreeGB $freeGB -MinFreeSpaceGB $config.MinFreeSpaceGB -MaxIncrementalSizeGB $config.MaxIncrementalSizeGB -MaxCycles $MaxCycles -Mode "Incremental" -VhdxFileSize $vhdxFileSize -Simulate
            } else {
                Invoke-FullWorkflow -VhdxPath $VhdxPath -FreeGB $freeGB -MinFreeSpaceGB $config.MinFreeSpaceGB -Simulate
            }
        }

        return
    }

    # =============================================================================
    # PRE-EXECUTION DOCKER DESKTOP CHECK (only for real execution)
    # =============================================================================
    Write-Information "`nChecking Docker Desktop status..." -InformationAction Continue

    if (Test-DockerDesktopRunning) {
        $dockerClosed = Wait-DockerDesktopToClose -Mode $Mode -Force:$Force
        if (-not $dockerClosed) {
            Write-Error "Cannot proceed: Docker Desktop must be closed."
            exit 1
        }
    } else {
        Write-Host "✅ Docker Desktop is not running." -ForegroundColor Green
    }

    # 1. Run Checks & Config
    $config = $null
    if ($Mode -eq "Incremental") {
        Test-WslAccess

        # Apply Auto-Configuration
        $config = Initialize-AutoConfiguration -Mode $Mode -FreeGB $freeGB -MinFreeSpaceGB $MinFreeSpaceGB -MaxIncrementalSizeGB $MaxIncrementalSizeGB -IsSimulation $false
        $MinFreeSpaceGB = $config.MinFreeSpaceGB
        $MaxIncrementalSizeGB = $config.MaxIncrementalSizeGB

        # Standard safety check
        if ($freeGB -lt $MinFreeSpaceGB) {
             Write-Warning "Available free space ($freeGB GB) is below the recommended threshold ($MinFreeSpaceGB GB)."
        }
    } elseif ($Mode -eq "Full") {
        Test-WslAccess

        # Apply auto-configuration for Full mode
        $config = Initialize-AutoConfiguration -Mode $Mode -FreeGB $freeGB -MinFreeSpaceGB $MinFreeSpaceGB -MaxIncrementalSizeGB $MaxIncrementalSizeGB -IsSimulation $false
        $MinFreeSpaceGB = $config.MinFreeSpaceGB
    }

    # Apply auto-configuration for simulation modes (if not already applied)
    if ($Simulate -and $null -eq $config) {
        $config = Initialize-AutoConfiguration -Mode $Mode -FreeGB $freeGB -MinFreeSpaceGB $MinFreeSpaceGB -MaxIncrementalSizeGB $MaxIncrementalSizeGB -IsSimulation $true
        $MinFreeSpaceGB = $config.MinFreeSpaceGB
    }

    # 2. Show Plan & Elevation Logic
    Show-ExecutionPlan `
        -VhdxPath $VhdxPath `
        -freeGB $freeGB `
        -MaxIncrementalSizeGB $MaxIncrementalSizeGB `
        -vhdxFileSize $vhdxFileSize `
        -isAdmin $isAdmin

    # Handle Elevation / Confirmation
    if (-not $isAdmin) {
        if ($Force) {
            Write-Error "Administrator privileges are required."
            Write-Error "You specified -Force, which disables interactive self-elevation."
            Write-Error "Please run this command from an elevated (Administrator) PowerShell session."
            exit 1
        }

        Write-Warning "Press any key to trigger UAC elevation and proceed..."
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")

        if (Get-Command "pwsh" -ErrorAction SilentlyContinue) {
            $pwshPath = "pwsh.exe"
        } elseif ($PSVersionTable.PSVersion.Major -ge 6) {
            $pwshPath = (Get-Process -Id $PID).Path
        } else {
            $pwshPath = "powershell.exe"
        }

        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")

        if ($PSBoundParameters.ContainsKey('Mode')) {
            $argList += '-Mode'
            $argList += $Mode
        }

        if ($PSBoundParameters.ContainsKey('MinFreeSpaceGB')) {
            $argList += '-MinFreeSpaceGB'
            $argList += $PSBoundParameters['MinFreeSpaceGB']
        }
        if ($PSBoundParameters.ContainsKey('VhdxRelativePath')) {
            $argList += '-VhdxRelativePath'
            $argList += "`"$VhdxRelativePath`""
        }

        $argList += '-Force'

        if ($PSBoundParameters.ContainsKey('MaxIncrementalSizeGB')) {
            $argList += '-MaxIncrementalSizeGB'
            $argList += $PSBoundParameters['MaxIncrementalSizeGB']
        }
        if ($PSBoundParameters.ContainsKey('MaxCycles')) {
            $argList += '-MaxCycles'
            $argList += $PSBoundParameters['MaxCycles']
        }

        try {
            Write-Verbose "Relaunching with: $pwshPath"
            Start-Process -FilePath $pwshPath -Verb RunAs -ArgumentList $argList -Wait
            exit $LASTEXITCODE
        } catch {
            Write-Error "Failed to elevate privileges: $_"
            Write-Error "Please run this script manually as Administrator."
            exit 1
        }
    } else {
        # Already Admin - Execute!
        if (-not $Force -and -not $modeWasSelectedInteractively) {
            Write-Information "Ready to start." -InformationAction Continue
            Write-Warning "Press any key to begin operation (or Ctrl+C to abort)..."
            $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        } elseif ($Force) {
            Write-Warning "Force flag provided; proceeding automatically."
        }

        # NOW RUN THE ACTUAL WORK using unified workflows
        if ($Mode -eq "Incremental") {
            Invoke-IncrementalWorkflow -VhdxPath $VhdxPath -FreeGB $freeGB -MinFreeSpaceGB $MinFreeSpaceGB -MaxIncrementalSizeGB $MaxIncrementalSizeGB -MaxCycles $MaxCycles -Mode "Incremental" -VhdxFileSize $vhdxFileSize
        } else {
            Invoke-FullWorkflow -VhdxPath $VhdxPath -FreeGB $freeGB -MinFreeSpaceGB $MinFreeSpaceGB
        }
    }
}

# =============================================================================
# MAIN CONTROL FLOW
# =============================================================================

if ($Mode -ne "Interactive") {
    # --- CLI MODE ---

    # 1. Resolve Mode implicits (including Auto mode selection)
    $Mode = Resolve-OperationMode -Mode $Mode -MaxIncrementalSizeGB $MaxIncrementalSizeGB -FreeGB $freeGB -MinFreeSpaceGB $MinFreeSpaceGB -VhdxFileSize $vhdxFileSize

    # 2. Host info (Fast) is already gathered at top of script
    if ($Mode -ne "Interactive") {
        Write-Information "Host drive ${script:driveLetter}: $freeGB GB free" -InformationAction Continue
    }

    # 3. Execute
    if ($WhatIf) {
        Invoke-Execution -Mode $Mode -VhdxPath $VhdxPath -freeGB $freeGB -vhdxFileSize $vhdxFileSize -isAdmin $isAdmin -Force $Force -MinFreeSpaceGB $MinFreeSpaceGB -MaxIncrementalSizeGB $MaxIncrementalSizeGB -MaxCycles $MaxCycles -Simulate
        exit 0
    } else {
        Invoke-Execution -Mode $Mode -VhdxPath $VhdxPath -freeGB $freeGB -vhdxFileSize $vhdxFileSize -isAdmin $isAdmin -Force $Force -MinFreeSpaceGB $MinFreeSpaceGB -MaxIncrementalSizeGB $MaxIncrementalSizeGB -MaxCycles $MaxCycles
    }

} else {
    # --- INTERACTIVE MODE ---

    # Analyze system and recommend the best mode before showing menu
    $recommendedMode = Select-AutomaticMode -FreeGB $freeGB -MinFreeSpaceGB $MinFreeSpaceGB -VhdxFileSize $vhdxFileSize

    Write-Host ""
    Write-Host "===========================================================" -ForegroundColor Cyan
    Write-Host "    SYSTEM ANALYSIS & RECOMMENDED MODE" -ForegroundColor Cyan
    Write-Host "===========================================================" -ForegroundColor Cyan
    Write-Host "Host Free Space: $freeGB GB" -ForegroundColor White
    Write-Host "VHDX File Size:  $vhdxFileSize GB" -ForegroundColor White
    Write-Host "Minimum Required: $MinFreeSpaceGB GB" -ForegroundColor White
    Write-Host "-----------------------------------------------------------" -ForegroundColor Cyan

    if ($recommendedMode -eq "Full") {
        Write-Host "Recommended Mode: **FULL** (Plenty of disk space)" -ForegroundColor Green
        Write-Host "Reason: Fastest mode with sufficient space available" -ForegroundColor Gray
    } else {
        Write-Host "Recommended Mode: **INCREMENTAL** (Limited disk space)" -ForegroundColor Yellow
        Write-Host "Reason: Safer approach prevents host disk exhaustion" -ForegroundColor Gray
    }

    Write-Host "===========================================================" -ForegroundColor Cyan
    Write-Host ""

    $modeWasSelectedInteractively = $true
    $menuLoopCount = 0
    $maxMenuRetries = 3
    $validSelection = $false

    do {
        $selection = Show-InteractiveMenu -FreeGB $freeGB -IsAdmin $isAdmin -RecommendedMode $recommendedMode

        if ([string]::IsNullOrWhiteSpace($selection)) {
            $menuLoopCount++
            if ($menuLoopCount -ge $maxMenuRetries) { exit 0 }
            continue
        }

        switch ($selection) {
            "1" {
                Invoke-Execution -Mode "Incremental" -VhdxPath $VhdxPath -freeGB $freeGB -vhdxFileSize $vhdxFileSize -isAdmin $isAdmin -Force $Force -MinFreeSpaceGB $MinFreeSpaceGB -MaxIncrementalSizeGB $MaxIncrementalSizeGB -MaxCycles $MaxCycles -Simulate
            }
            "2" {
                Invoke-Execution -Mode "Full" -VhdxPath $VhdxPath -freeGB $freeGB -vhdxFileSize $vhdxFileSize -isAdmin $isAdmin -Force $Force -MinFreeSpaceGB $MinFreeSpaceGB -MaxIncrementalSizeGB $MaxIncrementalSizeGB -MaxCycles $MaxCycles -Simulate
            }
            "3" {
                Invoke-Execution -Mode "Incremental" -VhdxPath $VhdxPath -freeGB $freeGB -vhdxFileSize $vhdxFileSize -isAdmin $isAdmin -Force $Force -MinFreeSpaceGB $MinFreeSpaceGB -MaxIncrementalSizeGB $MaxIncrementalSizeGB -MaxCycles $MaxCycles
                $validSelection = $true
                $Mode = "Incremental"
            }
            "4" {
                Invoke-Execution -Mode "Full" -VhdxPath $VhdxPath -freeGB $freeGB -vhdxFileSize $vhdxFileSize -isAdmin $isAdmin -Force $Force -MinFreeSpaceGB $MinFreeSpaceGB -MaxIncrementalSizeGB $MaxIncrementalSizeGB -MaxCycles $MaxCycles
                $validSelection = $true
                $Mode = "Full"
            }
            "5" {
                Invoke-Execution -Mode "Auto" -VhdxPath $VhdxPath -freeGB $freeGB -vhdxFileSize $vhdxFileSize -isAdmin $isAdmin -Force $Force -MinFreeSpaceGB $MinFreeSpaceGB -MaxIncrementalSizeGB $MaxIncrementalSizeGB -MaxCycles $MaxCycles
                $validSelection = $true
                $Mode = "Auto"
            }
            "6" { exit 0 }
        }
    } until ($validSelection)
}