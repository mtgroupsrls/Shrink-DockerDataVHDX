# Run-PSScriptAnalyzer.ps1
#
# .SYNOPSIS
#   Runs PSScriptAnalyzer on the project's main script and reports issues.
#
# .DESCRIPTION
#   This utility script installs PSScriptAnalyzer (if missing) and runs it against 
#   Shrink-DockerDataVHDX.ps1. It reports errors, warnings, and informational messages.
#
# .EXAMPLE
#   .\Run-PSScriptAnalyzer.ps1
#

[CmdletBinding()]
param()

# Check if PSScriptAnalyzer is installed
if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
    Write-Warning "PSScriptAnalyzer module not found."
    $confirm = Read-Host "Do you want to install it now? (Y/N)"
    if ($confirm -eq 'Y') {
        Write-Host "Installing PSScriptAnalyzer..." -ForegroundColor Cyan
        Install-Module -Name PSScriptAnalyzer -Force -Scope CurrentUser -SkipPublisherCheck
    } else {
        Write-Error "PSScriptAnalyzer is required to run this check."
        exit 1
    }
}

$targetScript = ".\Shrink-DockerDataVHDX.ps1"

if (-not (Test-Path $targetScript)) {
    Write-Error "Target script not found: $targetScript"
    exit 1
}

Write-Host "Running PSScriptAnalyzer on $targetScript..." -ForegroundColor Cyan
Write-Host "===========================================================" -ForegroundColor Cyan

# Run the analyzer (exclude PSAvoidUsingWriteHost - Write-Host is intentionally used for user-facing messages)
$results = Invoke-ScriptAnalyzer -Path $targetScript -Recurse -ExcludeRule PSAvoidUsingWriteHost

# Display results
if ($results) {
    $results | Select-Object RuleName, Severity, Line, Message | Format-Table -AutoSize
    
    Write-Host "===========================================================" -ForegroundColor Cyan
    
    # Summary
    $errors = ($results | Where-Object { $_.Severity -like '*Error*' }).Count
    $warnings = ($results | Where-Object { $_.Severity -like '*Warning*' }).Count
    $infos = ($results | Where-Object { $_.Severity -like '*Information*' }).Count
    
    Write-Host "Summary:" -ForegroundColor Yellow
    
    if ($errors -gt 0) {
        Write-Host "  Errors:       $errors" -ForegroundColor Red
    } else {
        Write-Host "  Errors:       $errors" -ForegroundColor Green
    }

    if ($warnings -gt 0) {
        Write-Host "  Warnings:     $warnings" -ForegroundColor Yellow
    } else {
        Write-Host "  Warnings:     $warnings" -ForegroundColor Green
    }

    Write-Host "  Information:  $infos"
    
    if ($errors -gt 0) {
        exit 1
    }
} else {
    Write-Host "No issues found! The script is clean." -ForegroundColor Green
}
