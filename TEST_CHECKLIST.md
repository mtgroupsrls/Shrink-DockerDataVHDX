# Test checklist — Shrink-DockerDataVHDX.ps1

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

## 3. Simulation Mode (`-WhatIf`)
- [ ] **Basic Simulation**:
  ```powershell
  .\Shrink-DockerDataVHDX.ps1 -WhatIf
  ```
  *Expected result: Script runs without admin prompt, shows plan summary, and exits.*

- [ ] **Incremental Simulation**:
  ```powershell
  .\Shrink-DockerDataVHDX.ps1 -WhatIf -IncrementalSizeGB 5
  ```
  *Expected result: Plan shows "Incremental mode" with 5GB cycle size.*

## 4. Interactive Mode
- [ ] **Menu Selection**:
  ```powershell
  .\Shrink-DockerDataVHDX.ps1
  ```
  *Expected result:
  1. Self-elevates (asking for Admin rights).
  2. Displays a menu with options (Full, Incremental, Simulation, Abort).
  3. Select option "3" (Simulation) -> Script should display plan and exit.*

## 5. Functional Test (Incremental Mode)
*Recommended for first real run*
- [ ] **Run with limits**:
  ```powershell
  .\Shrink-DockerDataVHDX.ps1 -IncrementalSizeGB 5 -MaxCycles 2
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