# Contributing to Shrink-DockerDataVHDX

Thank you for your interest in contributing! This project aims to provide a safe and efficient way to shrink Docker's WSL2 VHDX data files on Windows.

## How to Contribute

### Reporting Issues

* Use the GitHub [Issues](https://github.com/your-username/Shrink-DockerDataVHDX/issues) page.
* Provide a clear description of the problem and steps to reproduce it.
* Include logs or screenshots if relevant.

### Suggesting Enhancements

* Use the Issues page to propose new features or improvements.
* Describe the benefit and any potential side effects.

### Submitting Pull Requests

1. Fork the repository.
2. Create a branch for your feature or fix: `git checkout -b my-feature`.
3. Make your changes.
4. Ensure your changes do not break existing functionality.
5. Run PSScriptAnalyzer locally on `Shrink-DockerDataVHDX.ps1` to ensure code quality.
6. Commit your changes: `git commit -m 'Add feature or fix issue'`
7. Push to your branch: `git push origin my-feature`
8. Open a pull request against the `main` branch of the original repository.

### Coding Guidelines

* Follow PowerShell best practices and use `Option Strict`-style rigor where applicable.
* Keep the script compatible with Windows 10/11 PowerShell Core (`pwsh`) and legacy Windows PowerShell.
* Include `-WhatIf` support for destructive operations.
* Write clear, commented, and maintainable code.

### Testing

* Always test scripts in a safe environment before submitting PRs.
* Use the GitHub Actions workflows as reference for linting and dry-run.

### License

* By contributing, you agree that your contributions will be licensed under the same license as this repository (MIT).
