# Test checklist — Shrink-DockerDataVHDX.ps1

Use this checklist to safely validate the script before using on critical systems.

## Pre-checks (before running)
- [ ] Ensure you have a recent backup of important data.
- [ ] Open PowerShell **As Administrator**.
- [ ] Confirm Docker Desktop is installed and `docker-desktop` WSL distro exists:
  ```powershell
  wsl -l -v
