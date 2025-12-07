# Changelog

All notable changes to this project will be documented in this file.

## [1.0.0] - 2025-12-07

### Major Release: Production-Ready with Intelligent Automation

This release represents a significant evolution with Auto mode, architectural refactoring, and comprehensive UX improvements.

### Added
- **Auto Mode**: Intelligent mode selection that analyzes system conditions (disk space, VHDX size) and automatically chooses between Full and Incremental modes.
- **Interactive Mode Enhancements**: Shows recommended mode with reasoning before displaying menu, helping users make informed decisions.
- **Simulation Clarity**: All simulation operations now display `[SIM]` markers for clear distinction from real operations.
- **Auto-Configuration**: Automatically adjusts safety parameters when free disk space is limited (< 10 GB):
  - Reduces `MinFreeSpaceGB` to 3-5 GB
  - Reduces `MaxIncrementalSizeGB` to 2 GB
  - Provides warnings about tight disk space
- **Unified Architecture**: Refactored Full mode to use Incremental logic with MaxCycles=1, eliminating code duplication.
- **Host Volume Statistics**: Before/after summary now includes host disk space statistics (initial vs final free space).
- **Cycle Display Accuracy**: Changed from misleading "Cycle X of Y" to accurate "Cycle X (max Y)" to reflect that actual cycles may be fewer.
- **Critical Disk Space Handling**: In `-Force` mode with critical disk space (< 2x MinFreeSpaceGB), script auto-skips to compaction instead of failing.
- **Interactive Mode**: New menu system allows selecting Full, Incremental, or Simulation mode without typing arguments.
- **Safety Warnings**: Interactive menu clearly communicates the risks (host disk usage) of Full vs. Incremental mode.
- **Pre-flight Validation**: robust checks for `wsl.exe`, `docker-desktop` distro existence, and mount point accessibility.
- **Space Analysis**: `-WhatIf` and interactive mode now estimate potential reclaimable space (and handle sparse file reporting intelligently).
- **Progress Bars**: Improved visual feedback with elapsed time tracking for long-running operations.
- **Developer Tools**: Added `Run-PSScriptAnalyzer.ps1` for local static analysis.

### Changed
- **User Experience**: Script now pauses and asks for confirmation *before* triggering the UAC Admin prompt.
- **Parameter Rename**: `-IncrementalSizeGB` has been renamed to `-MaxIncrementalSizeGB` to better reflect its behavior (capping the write size).
- **Documentation**: Comprehensive updates to `README.md` including troubleshooting, FAQ, testing guides, and detailed CI/CD workflow documentation.
- **CI/CD**: Enhanced GitHub Actions workflow to perform strict linting and parameter testing with comprehensive documentation.
- **Simulation Output**: Updated simulation examples in documentation to reflect `[SIM]` markers and accurate cycle displays.

## [0.1.0] - Initial Release

* Initial setup of GitHub repository.
* Added `Shrink-DockerDataVHDX.ps1` script with `-Force` and `-WhatIf` support.
* Implemented incremental zero-fill and compaction logic.
* Added GitHub Actions workflows for linting and dry-run testing.
* Created `README.md`, `LICENSE`, `TEST_CHECKLIST.md`
