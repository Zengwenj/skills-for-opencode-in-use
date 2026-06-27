#Requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$Case
)

Set-StrictMode -Version Latest

$script:SkillDir = Split-Path -Parent $PSScriptRoot
$script:FixtureDir = Join-Path -Path $PSScriptRoot -ChildPath 'fixtures'
$script:Cases = @(
    'e2e_happy_path',
    'missing_config',
    'approval_default_pending',
    'approval_hash_mismatch',
    'target_exists',
    'source_changed',
    'obsidian_artifacts_excluded',
    'already_committed_idempotent'
)

function Write-TestResult {
    param(
        [Parameter(Mandatory = $true)][string]$CaseName,
        [Parameter(Mandatory = $true)][bool]$Passed,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $status = if ($Passed) { 'PASS' } else { 'FAIL' }
    [Console]::Out.WriteLine("[$status] $CaseName : $Message")
}

function Invoke-FixtureCase {
    param([Parameter(Mandatory = $true)][string]$CaseName)

    $scriptPath = Join-Path -Path $script:FixtureDir -ChildPath ($CaseName + '.ps1')
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        Write-TestResult -CaseName $CaseName -Passed $false -Message "Fixture script not found: $scriptPath"
        return $false
    }

    $output = & pwsh -NoProfile -File $scriptPath 2>&1
    $exitCode = $LASTEXITCODE
    foreach ($line in $output) { [Console]::Out.WriteLine([string]$line) }

    if ($exitCode -eq 0) {
        Write-TestResult -CaseName $CaseName -Passed $true -Message 'fixture passed'
        return $true
    }

    Write-TestResult -CaseName $CaseName -Passed $false -Message "fixture failed with exit code $exitCode"
    return $false
}

Write-Output '=== llmwiki-inbox-ingest test runner ==='
Write-Output "Skill dir: $script:SkillDir"
Write-Output ''

if ([string]::IsNullOrWhiteSpace($Case)) {
    Write-Output 'Usage: pwsh -File tests/run-tests.ps1 -Case <case-name>'
    Write-Output ''
    Write-Output 'Available cases:'
    foreach ($caseName in $script:Cases) {
        Write-Output "  $caseName"
    }
    exit 0
}

if ($Case -eq 'all') {
    $failed = @()
    foreach ($caseName in $script:Cases) {
        if (-not (Invoke-FixtureCase -CaseName $caseName)) {
            $failed += $caseName
        }
    }

    if ($failed.Count -gt 0) {
        Write-Output "Failed cases: $($failed -join ', ')"
        exit 1
    }

    exit 0
}

if ($script:Cases -notcontains $Case) {
    Write-TestResult -CaseName $Case -Passed $false -Message 'Unknown fixture case'
    exit 1
}

if (Invoke-FixtureCase -CaseName $Case) { exit 0 }
exit 1
