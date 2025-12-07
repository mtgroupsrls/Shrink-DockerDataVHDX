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
- **Running PSScriptAnalyzer**: Always use PowerShell to execute the analyzer:
  *   **Correct**: `pwsh -File "Run-PSScriptAnalyzer.ps1"`
  *   **Incorrect**: `.\Run-PSScriptAnalyzer.ps1` (in bash/cmd, causes parsing errors)
  *   The script must be invoked by PowerShell interpreter, not the system shell.
- **VHDX Compaction Interruption Risk**: Killing the script during VHDX compaction (Optimize-VHD or diskpart operations) can corrupt the VHDX and make Docker unusable. The compaction phase modifies VHDX internal structures (block allocation, metadata) and must complete atomically. Zero-fill phase is safer to interrupt if necessary, but always let compaction complete fully.
- **Signal Handling Protection**: The script implements comprehensive signal handling:
  *   Tracks operation phases: Safe, ZeroFill, Compaction, Cleanup
  *   Intercepts CTRL+C and window close events
  *   During Compaction phase: Displays critical warning and blocks exit attempts
  *   During ZeroFill phase: Allows graceful exit with cleanup message
  *   Uses PowerShell Exiting event and Win32 SetConsoleCtrlHandler for robust interception
  *   Phase-based warnings help users understand when it's safe vs dangerous to interrupt
- **Docker Desktop Protection**: The script actively protects against Docker Desktop interference:
  *   Pre-execution check: Detects and blocks if Docker Desktop is running
  *   During compaction: Monitors for Docker Desktop starting (checks every 3-5 seconds)
  *   Critical error handling: Immediately stops compaction if Docker starts
  *   Auto-close option: Can force-close Docker Desktop in non-interactive mode (risky)
  *   Background monitoring: Uses PowerShell jobs to detect Docker process changes
  *   Multiple Docker process names supported: "Docker Desktop", "Docker", "com.docker.docker"
  *   If Docker starts during compaction: Displays critical error and aborts to prevent VHDX corruption
- **Debugging ParseErrors**: If `PSScriptAnalyzer` reports `MissingEndCurlyBrace`, the actual error is often *after* the reported line (where the parser expected a closure). Check the indentation and closure of subsequent blocks, especially those recently edited via `replace`.
- **GitHub Workflow Pattern**: Multi-layer CI/CD validation:
  *   **Error-only check** (fails build) + **full scan** (reporting only) for balanced quality gates
  *   **Functional testing** with automated parameter combination testing
  *   **Quality gates**: Syntax validation → PSScriptAnalyzer → simulation execution
  *   **Windows Runner**: `windows-latest` essential for PowerShell testing
- **PSScriptAnalyzer Rules Management**:
  *   **PSAvoidUsingWriteHost**: Intentionally ignored for user-facing messages (Write-Host appropriate for interactive output)
  *   **PSPossibleIncorrectComparisonWithNull**: Use `$null -eq $variable` not `$variable -eq $null`
  *   **Rule suppression**: Use `# noqa: RuleName` for intentional exceptions with justification
- **Early Return Patterns**: Clean separation of simulation vs execution:
  *   Single controller function with `-Simulate` switch
  *   Avoids code duplication between simulation and real execution paths
  *   Makes behavior consistent across all entry points (CLI, Interactive, Auto)
- **PowerShell Scope Management**:
  *   Use `$script:` prefix for global variables shared across functions
  *   `$using:` prefix for passing variables to background jobs
  *   Proper scoping prevents variable leakage and unexpected behavior
- **Background Jobs for Monitoring**:
  *   `Start-Job -ScriptBlock { ... }` for async operations
  *   `Receive-Job -Job $job -Timeout 1` for non-blocking output retrieval
  *   Cleanup with `Stop-Job -Job $job; Remove-Job -Job $job`
- **Parameter Design Best Practices**:
  *   Use `[ValidateSet(...)]` for enum-like parameters
  *   Provide sensible defaults (e.g., `$MinFreeSpaceGB = 20`)
  *   Use `[switch]` for boolean flags
  *   Document all parameters in comment-based help with examples
- **Version Release Criteria**:
  *   **Code Quality**: PSScriptAnalyzer clean (0/0/0) - no errors, warnings, or information
  *   **Architecture**: Unified, well-structured, no code duplication
  *   **Feature Completeness**: All modes documented and working
  *   **Safety**: Comprehensive error handling and validation
  *   **Backward Compatibility**: No breaking changes for existing users
  *   **Documentation**: Complete and accurate (README, CHANGELOG, examples)

## CI/CD Workflow Knowledge

### GitHub Actions Pattern for PowerShell Projects
```yaml
name: PowerShell Lint & Dry Run
on: [push, pull_request, workflow_dispatch]
jobs:
  lint-and-test:
    runs-on: windows-latest
    steps:
    - PSScriptAnalyzer (Errors only) → FAIL on errors
    - PSScriptAnalyzer (All severities) → REPORT only
    - Syntax validation → FAIL on syntax errors
    - Functional testing (-WhatIf) → FAIL on crashes
    - Parameter combination testing → Multiple scenarios
    - TODO/FIXME detection → REPORT technical debt
```

### Quality Gates Strategy
1. **Hard Fail**: Syntax errors, PSScriptAnalyzer Errors, runtime crashes
2. **Soft Fail**: PSScriptAnalyzer Warnings/Info (report but don't block)
3. **Report Only**: TODO/FIXME comments, code complexity metrics

### Automated Testing Patterns
- **Dry-run testing**: Always test with `-WhatIf` flag for safe validation
- **Parameter matrix**: Test combinations of critical parameters
- **Mode coverage**: Ensure all modes (Interactive, Incremental, Full, Auto) are tested
- **Error scenarios**: Test low disk space, missing Docker, WSL errors

## User Experience & Documentation Patterns

### Simulation Clarity
- **Visual markers**: `[SIM]` prefix on ALL simulated operations
- **Consistent messaging**: "COMPACTION COMPLETE (SIMULATED)" vs real completion
- **Progress indication**: Show simulated progress bars and statistics
- **Clear distinction**: Users must never mistake simulation for real execution

### Cycle Display Accuracy
- **"Cycle X (max Y)"** not "Cycle X of Y" because:
  *   Actual cycles may be fewer based on disk space
  *   Prevents confusion when script stops early
  *   Sets proper expectations about maximum vs guaranteed iterations
- **Progress bars**: Show overall progress with elapsed time
- **Per-cycle statistics**: Space saved, time taken, remaining cycles

### Documentation Synchronization
- **README.md**: User-facing documentation with examples matching actual output
- **CHANGELOG.md**: Version history with breaking changes clearly marked
- **Comment-based help**: `Get-Help .\Script.ps1` shows parameter documentation
- **Examples**: Must be tested and verified, not just written

### Interactive Mode UX
- **Show analysis first**: Display recommended mode with reasoning before menu
- **Menu clarity**: Each option clearly labeled with risks and requirements
- **Confirmation prompts**: "Type 'YES' to proceed" for destructive operations
- **Progress feedback**: Real-time updates during long operations

## PowerShell Best Practices

### Write-Host vs Write-Information
- **Write-Host**: User-facing messages, formatted output, progress indicators
- **Write-Information**: Debug/info messages, can be suppressed with `-InformationAction`
- **Rule**: If user needs to see it → Write-Host; If it's diagnostic → Write-Information

### Error Handling Patterns
```powershell
try {
    # Risky operation
    $result = Some-Operation
}
catch {
    Write-Error "Operation failed: $($_.Exception.Message)"
    # Cleanup if needed
    return $false
}
```

### Event Handling for Signals
```powershell
# Register exit handler
$script:ExitHandler = {
    $currentPhase = $script:OperationPhase
    if ($currentPhase -eq 'Compaction') {
        # Show critical warning, block exit
    }
}
Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action $script:ExitHandler
```

### Parameter Validation
```powershell
param(
    [Parameter(Mandatory=$false)]
    [ValidateSet("Interactive", "Incremental", "Full", "Auto")]
    [string]$Mode = "Interactive",

    [Parameter(Mandatory=$false)]
    [int]$MinFreeSpaceGB = 20,

    [Parameter(Mandatory=$false)]
    [switch]$Force
)
```

## Architectural Principles

### Unified Architecture > Code Duplication
- **Single source of truth**: One function handles both Incremental and Full modes
- **Eliminate duplication**: Full = Incremental with MaxCycles=1
- **Shared components**: `Invoke-CompactionCycle` used by all modes
- **Maintainability**: Changes in one place affect all modes consistently

### Controller Pattern for Complex Flows
- **Invoke-Execution**: Single entry point for all modes
- **Invoke-IncrementalWorkflow**: Handles cycle logic
- **Invoke-CompactionCycle**: Core zero-fill + compact operation
- **Clear separation**: Each function has single responsibility

### Refactoring vs Patching
- **Refactor**: Change structure to support new requirements elegantly
- **Patch**: Add conditional logic to existing flow (leads to spaghetti code)
- **Example**: Instead of `if ($mode -eq 'Full') { doFull() } else { doIncremental() }`,
  create unified function and call appropriately

## Safety & Critical Operations

### VHDX Compaction Risks
- **Never interrupt**: During Optimize-VHD or diskpart operations
- **Atomic operation**: Compaction must complete or VHDX becomes corrupted
- **Warning display**: Clear, prominent warnings before compaction phase
- **Phase tracking**: Track Safe/ZeroFill/Compaction/Cleanup phases

### Docker Desktop Protection
- **Pre-execution**: Block if Docker Desktop running
- **During compaction**: Monitor for Docker starting (every 3-5 seconds)
- **Critical abort**: Stop compaction immediately if Docker starts
- **Process names**: Check "Docker Desktop", "Docker", "com.docker.docker"

### Disk Space Management
- **Auto-configuration**: Adjust safety parameters based on available space
- **Critical thresholds**: < 2x MinFreeSpaceGB = critical (auto-skip in -Force mode)
- **Monitoring**: Background jobs track free space continuously
- **Safe aborts**: Exit gracefully when space runs low

## Release Management

### Semantic Versioning
- **0.1.0 → 1.0.0**: Major architectural changes, new features, production-ready
- **Breaking changes**: Increment major version
- **New features**: Increment minor version
- **Bug fixes**: Increment patch version

### Changelog Format
```markdown
## [1.0.0] - 2025-12-07
### Major Release: Production-Ready with Intelligent Automation
### Added
- Auto Mode
- Interactive Mode Enhancements
- [SIM] markers for clarity
### Changed
- User Experience improvements
### Security
- Enhanced safety mechanisms
```

### Git Workflow for Releases
1. Update CHANGELOG.md with version and date
2. `git add .`
3. `git commit -m "Release 1.0.0: Production-ready with intelligent automation"`
4. `git tag v1.0.0`
5. `git push origin main --tags`

## Code Quality Standards

### PSScriptAnalyzer Compliance
- **Target**: 0 errors, 0 warnings, 0 information
- **Critical rules**: Never suppress without justification
- **Style rules**: PSAvoidUsingWriteHost (documented exceptions only)
- **Running**: Always via PowerShell (`pwsh -File Run-PSScriptAnalyzer.ps1`)

### Documentation Requirements
- **Comment-based help**: All functions with complex logic
- **Inline comments**: Explain non-obvious code sections
- **Section headers**: Organize code with visual separators
- **No TODO/FIXME**: Track technical debt separately

### Function Design
- **Verb-Noun naming**: Invoke-*, Show-*, Get-*, Test-*
- **Single responsibility**: One clear purpose per function
- **Parameters**: Typed, validated, with defaults
- **Error handling**: Try-catch with meaningful messages

## Memories
- When performing a task, I will not stop to announce the next step; I will proceed continuously until the task is complete.
- I will treat Gemini.md in project root folder as my dynamic knowledge base and I'll keep it updated.
- I will NOT perform git commits. I will stage files and inform the user, but I will leave the actual `git commit` execution to the user.
- After editing the main script, I will ALWAYS run `Run-PSScriptAnalyzer.ps1`, fix ALL reported issues (Errors, Warnings, Information), and repeat until the report is clean before declaring the task complete.
- **Refactoring vs Patching**: When the user requests a change in application flow (e.g., "Show menu immediately, do checks later"), I must **refactor** the code structure (e.g., defer logic into functions) rather than just suppressing/muting the output of the existing linear flow. Muting output is not the same as deferring execution.
- **Architectural Integrity**: Do not fear complexity or scraping existing code if the architectural requirement calls for it. When asked for consistent behavior across multiple entry points (e.g., CLI vs Interactive), create shared controller functions (`Invoke-Logic`) immediately. Maintaining parallel linear flows with conditional patches is a trap. Note: "Patching" linear scripts to behave like event-driven apps rarely works well.
