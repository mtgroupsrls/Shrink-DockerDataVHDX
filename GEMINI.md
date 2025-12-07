**IMPORTANT**: After editing `Shrink-DockerDataVHDX`, I will ALWAYS run `Run-PSScriptAnalyzer.ps1`, fix ALL reported issues (Errors, Warnings, Information), and repeat until the report is clean     
  ││    before declaring the task complete.  
# Gemini Knowledge Base

## Project: Shrink-DockerDataVHDX

### Overview
A PowerShell script (`Shrink-DockerDataVHDX.ps1`) designed to safely reclaim disk space used by Docker Desktop's `docker_data.vhdx` on Windows.

### Key Features
- **Compaction Methods**:
  - **Full Mode**: Single zero-fill operation (faster with sufficient disk space). Implemented as Incremental with MaxCycles=1.
  - **Incremental Mode**: Zero-fills in chunks (e.g., 5GB), compacting after each chunk to avoid filling the host disk.
  - **Auto Mode**: Intelligently selects between Full and Incremental based on system conditions (disk space ratio, VHDX size).
  - **Interactive Mode**: Shows recommended mode with reasoning, then displays menu for user selection.
- **Smart Auto-Configuration**:
  - Automatically detects low disk space (<10GB) and adjusts buffer/chunk sizes (2-3GB/1-2GB) for safety.
  - Reduces `MinFreeSpaceGB` to 3-5 GB when disk space is tight
  - Reduces `MaxIncrementalSizeGB` to 2 GB in low-disk scenarios
- **Safety**:
  - Explicit `-Mode` parameter (`Incremental`, `Full`, `Interactive`, `Auto`) prevents accidental runs.
  - **Automation Safety**: `-Force` mode skips interactive prompts but auto-skips to compaction when disk space is critical (< 2x MinFreeSpaceGB).
  - **Self-elevation**: Automatically requests admin privileges via UAC when needed (except in `-WhatIf` mode).
  - Checks host disk space (`-MinFreeSpaceGB`).
  - `-WhatIf` simulation mode with `[SIM]` markers for clarity.
  - Critical warnings about VHDX compaction interruption risks.
  - Backup warnings.
- **Simulation Features**:
  - `[SIM]` markers on all simulated operations for clear distinction
  - Accurate cycle display: "Cycle X (max Y)" instead of misleading "Cycle X of Y"
  - Realistic simulation of compaction progress and space savings
- **Dependencies**:
  - Windows (PowerShell 5.1+).
  - Docker Desktop (WSL2 backend).
  - `Optimize-VHD` (Hyper-V module, preferred) or `diskpart` (fallback).

### Architecture
- **Script**: `Shrink-DockerDataVHDX.ps1` (Monolithic script with helper functions).
- **CI/CD**: GitHub Actions (`.github/workflows/ps1-test.yml`) runs PSScriptAnalyzer and `-WhatIf` tests.
- **Documentation**: Comprehensive `README.md` and `TEST_CHECKLIST.md`.

### Testing Tricks
- **Interactive Menu in CI/Agent**: To test the interactive menu without hanging, pipe the selection number to the script:
  `echo "1" | .\Shrink-DockerDataVHDX.ps1`
  (Selects option 1 - Simulation). **Note:** This only works if the script is *already elevated* or the Admin check is bypassed; otherwise, the self-elevation restart will disconnect the pipe.

### Technical Insights
- **WSL Output Encoding**: `wsl.exe` output often defaults to UTF-16 LE (UCS-2) with null bytes when piped in PowerShell.
  *   **Fix**: Capture output, join array, and strip nulls: `($out -join " ") -replace "\0", ""`.
- **VHDX Sparse Logic**: Logical usage (`df`) inside the VM can exceed physical VHDX size (sparse files/compression).
  *   **Handling**: If `Logical > Physical`, potential savings are effectively 0 or unknown without a zero-fill scan.
- **Hyper-V Support**: Intentionally omitted. Requires running a privileged container to access the filesystem, whereas WSL 2 allows direct access via `wsl -d distro`.
- **Automation Safety**: `Start-Process -Verb RunAs` hangs/fails in headless environments.
  *   **Fix**: If `-Force` is present (implying automation) and user is Non-Admin, explicit `exit 1` with error instead of attempting elevation.
- **Critical Disk Space Auto-Skip**: When `-Force` mode is used with critical disk space (< 2x MinFreeSpaceGB), the script automatically skips to VHDX compaction instead of attempting zero-fill. This prevents failure in automation scenarios while maintaining safety.
- **Auto Mode Decision Logic**: Auto mode uses a space ratio calculation (`FreeGB / MinFreeSpaceGB`) to decide:
  *   If ratio > 2.0 AND free space > 50 GB: Selects Full mode (faster)
  *   If ratio <= 2.0 OR VHDX > 100 GB with < 50 GB free: Selects Incremental mode (safer)
- **Unified Architecture**: Full mode is architecturally identical to Incremental mode with MaxCycles=1, using `Invoke-CompactionCycle` for shared logic. This eliminates ~200 lines of duplicated code while maintaining identical behavior.
- **Simulation Clarity**: Added `[SIM]` prefix to all simulation operations to make it immediately obvious when viewing simulated output vs real execution.
- **Cycle Display Accuracy**: Changed from "Cycle X of Y" to "Cycle X (max Y)" because actual cycles may be fewer based on available disk space. This prevents user confusion when script stops early due to low disk space.
- **Debugging ParseErrors**: If `PSScriptAnalyzer` reports `MissingEndCurlyBrace`, the actual error is often *after* the reported line (where the parser expected a closure). Check the indentation and closure of subsequent blocks, especially those recently edited via `replace`.

## Memories
- When performing a task, I will not stop to announce the next step; I will proceed continuously until the task is complete.
- I will treat Gemini.md in project root folder as my dynamic knowledge base and I'll keep it updated.
- I will NOT perform git commits. I will stage files and inform the user, but I will leave the actual `git commit` execution to the user.
- After editing the main script, I will ALWAYS run `Run-PSScriptAnalyzer.ps1`, fix ALL reported issues (Errors, Warnings, Information), and repeat until the report is clean before declaring the task complete.
- **Refactoring vs Patching**: When the user requests a change in application flow (e.g., "Show menu immediately, do checks later"), I must **refactor** the code structure (e.g., defer logic into functions) rather than just suppressing/muting the output of the existing linear flow. Muting output is not the same as deferring execution.
- **Architectural Integrity**: Do not fear complexity or scraping existing code if the architectural requirement calls for it. When asked for consistent behavior across multiple entry points (e.g., CLI vs Interactive), create shared controller functions (`Invoke-Logic`) immediately. Maintaining parallel linear flows with conditional patches is a trap. Note: "Patching" linear scripts to behave like event-driven apps rarely works well.
