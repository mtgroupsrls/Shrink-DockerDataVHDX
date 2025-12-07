# Test checklist â€” Shrink-DockerDataVHDX.ps1

Use this checklist to safely validate the script before using on critical systems.

## 1. Static Analysis & Code Quality
- [ ] **Run PSScriptAnalyzer**: Ensure the script is free of syntax errors and bad practices.
  ```powershell
  .\Run-PSScriptAnalyzer.ps1
  ```
  *Expected result: "No issues found" (or only minor informational messages).*

## 2. Pre-checks (Environment)
- [ ] **Backup**: Ensure you have a recent backup of your Docker data.
- [ ] **WSL Check**: Confirm Docker Desktop is installed and the `docker-desktop` distro exists.
  ```powershell
  wsl -l -v
  ```
- [ ] **Docker Desktop Status**: **CLOSE Docker Desktop before running the script**. The script will check and block if Docker is running.
- [ ] **⚠️ CRITICAL WARNING**: **DO NOT KILL/INTERRUPT the script during VHDX compaction** (the Optimize-VHD or diskpart phase). This can corrupt the VHDX and make Docker unusable. Let the script complete fully.
- [ ] **⚠️ DO NOT START Docker Desktop while script is running**. The script monitors for Docker starting during compaction and will abort with a critical error if detected.


## 3. Simulation Mode (`-WhatIf`)
- [ ] **Basic Simulation**:
  ```powershell
  .\Shrink-DockerDataVHDX.ps1 -WhatIf
  ```
  *Expected result: Script runs without admin prompt, shows plan summary, and exits.*

- [ ] **Incremental Simulation**:
  ```powershell
  .\Shrink-DockerDataVHDX.ps1 -WhatIf -MaxIncrementalSizeGB 5
  ```
  *Expected result: Plan shows "Incremental mode" with 5GB cycle size.*

## 4. Interactive Mode
- [ ] **Menu Selection**:
  ```powershell
  .\Shrink-DockerDataVHDX.ps1
  ```
  *Expected result:
  1. Self-elevates (asking for Admin rights).
  2. Displays a menu with options (Simulate Inc/Full, Incremental, Full, Abort).
  3. Select option "1" or "2" (Simulation) -> Script should display plan and exit.*

## 5. Functional Test (Incremental Mode)
*Recommended for first real run*
- [ ] **Run with limits**:
  ```powershell
  .\Shrink-DockerDataVHDX.ps1 -MaxIncrementalSizeGB 5 -MaxCycles 2
  ```
  *Expected result:*
  - *Admin prompt appears.*
  - *Script writes 5GB filler -> Compacts -> Repeats once more.*
  - *Verify host disk space does not drop dangerously low during run.*

## 6. Functional Test (Full Mode)
*Only if you have plenty of free space*
- [ ] **Run Standard**:
  ```powershell
  .\Shrink-DockerDataVHDX.ps1
  ```
  *Expected result: Script zero-fills entire free space and performs one final compaction.*
