#Requires -Version 7.0

Set-StrictMode -Version Latest

$script:FixtureRoot = $PSScriptRoot
$script:TestsDir = Split-Path -Parent $script:FixtureRoot
$script:SkillDir = Split-Path -Parent $script:TestsDir
$script:ScriptsDir = Join-Path -Path $script:SkillDir -ChildPath 'scripts'
$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Write-FixtureFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $parent = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Content, $script:Utf8NoBom)
}

function New-FixtureWorkspace {
    param([Parameter(Mandatory = $true)][string]$Name)

    $root = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('llmwiki-ingest-' + $Name + '-' + [guid]::NewGuid().ToString('N'))
    $paths = [ordered]@{
        Root       = $root
        Inbox      = Join-Path -Path $root -ChildPath 'inbox'
        Archive    = Join-Path -Path $root -ChildPath 'archive'
        Raw        = Join-Path -Path $root -ChildPath 'raw'
        Review     = Join-Path -Path $root -ChildPath 'review'
        ConfigDir  = Join-Path -Path $root -ChildPath '.llmwiki-ingest'
        RunDir     = Join-Path -Path (Join-Path -Path $root -ChildPath 'review') -ChildPath '20260627-120000-a1b2c3'
        ConfigPath = Join-Path -Path (Join-Path -Path $root -ChildPath '.llmwiki-ingest') -ChildPath 'config.json'
    }

    foreach ($path in @($paths.Inbox, $paths.Archive, $paths.Raw, $paths.Review, $paths.ConfigDir, $paths.RunDir)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }

    $config = [ordered]@{
        inboxRoot      = $paths.Inbox
        archiveRoot    = $paths.Archive
        rawSourcesRoot = $paths.Raw
        reviewRoot     = $paths.Review
        themeList      = @('ThemeA', 'ThemeB')
        scope          = 'root_inbox_recursive'
    }
    Write-FixtureFile -Path $paths.ConfigPath -Content ($config | ConvertTo-Json -Depth 8)

    return [pscustomobject]$paths
}

function Remove-FixtureWorkspace {
    param([Parameter(Mandatory = $true)][object]$Workspace)

    if ($Workspace.Root -and (Test-Path -LiteralPath ([string]$Workspace.Root))) {
        Remove-Item -LiteralPath ([string]$Workspace.Root) -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-SkillScript {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptName,
        [Parameter(Mandatory = $true)][object]$Workspace,
        [string[]]$ExtraArgs = @()
    )

    $scriptPath = Join-Path -Path $script:ScriptsDir -ChildPath $ScriptName
    $arguments = @('-NoProfile', '-File', $scriptPath, '-ConfigPath', [string]$Workspace.ConfigPath, '-RunDir', [string]$Workspace.RunDir) + $ExtraArgs
    $output = & pwsh @arguments 2>&1
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = @($output) }
}

function Assert-ExitCode {
    param(
        [Parameter(Mandatory = $true)][object]$Result,
        [Parameter(Mandatory = $true)][int]$Expected,
        [Parameter(Mandatory = $true)][string]$Step
    )

    if ([int]$Result.ExitCode -ne $Expected) {
        throw "$Step expected exit $Expected but got $($Result.ExitCode). Output: $($Result.Output -join ' | ')"
    }
}

function Assert-FileExists {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label missing: $Path"
    }
}

function Assert-FileContains {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if (-not $text.Contains($Pattern)) {
        throw "$Label did not contain '$Pattern': $Path"
    }
}

function Initialize-HappyPathSource {
    param([Parameter(Mandatory = $true)][object]$Workspace)

    $source = Join-Path -Path ([string]$Workspace.Inbox) -ChildPath (Join-Path -Path 'ThemeA' -ChildPath (Join-Path -Path '2026' -ChildPath 'weekly-report.pdf'))
    Write-FixtureFile -Path $source -Content ('fixture pdf bytes for weekly report ' * 20)
    return $source
}

function Invoke-ScanAndProposal {
    param([Parameter(Mandatory = $true)][object]$Workspace)

    $scan = Invoke-SkillScript -ScriptName 'scan-inbox.ps1' -Workspace $Workspace
    Assert-ExitCode -Result $scan -Expected 0 -Step 'scan-inbox'
    $proposal = Invoke-SkillScript -ScriptName 'build-proposal.ps1' -Workspace $Workspace
    Assert-ExitCode -Result $proposal -Expected 0 -Step 'build-proposal'
}

function Approve-FixtureRun {
    param([Parameter(Mandatory = $true)][object]$Workspace)

    $runDir = [string]$Workspace.RunDir
    $approvalPath = Join-Path -Path $runDir -ChildPath 'approval.md'
    $runId = Split-Path -Path $runDir -Leaf
    $configHash = (Get-FileHash -Algorithm SHA256 -LiteralPath ([string]$Workspace.ConfigPath)).Hash.ToLowerInvariant()
    $inventoryHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path -Path $runDir -ChildPath 'inventory.jsonl')).Hash.ToLowerInvariant()
    $snapshotHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path -Path $runDir -ChildPath 'source_snapshot_before.csv')).Hash.ToLowerInvariant()
    $planHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path -Path $runDir -ChildPath 'classification-plan.jsonl')).Hash.ToLowerInvariant()
    $proposalHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path -Path $runDir -ChildPath 'proposal-manifest.json')).Hash.ToLowerInvariant()

    $content = @(
        '---',
        'status: approved',
        'allow_apply: true',
        'approved_by: "fixture-human"',
        'approved_at: "2026-06-27T12:10:00Z"',
        "run_id: `"$runId`"",
        'scope: "root_inbox_recursive"',
        "config_sha256: `"$configHash`"",
        "inventory_sha256: `"$inventoryHash`"",
        "source_snapshot_before_sha256: `"$snapshotHash`"",
        "classification_plan_sha256: `"$planHash`"",
        "proposal_manifest_sha256: `"$proposalHash`"",
        '---',
        '',
        '# Fixture approval',
        '',
        'This approval is written by the test fixture to simulate a human approval gate.'
    ) -join "`n"
    Write-FixtureFile -Path $approvalPath -Content $content
    return $approvalPath
}

function Invoke-FullHappyPathPipeline {
    param([Parameter(Mandatory = $true)][object]$Workspace)

    Initialize-HappyPathSource -Workspace $Workspace | Out-Null
    Invoke-ScanAndProposal -Workspace $Workspace
    Approve-FixtureRun -Workspace $Workspace | Out-Null

    $apply = Invoke-SkillScript -ScriptName 'apply-approved-plan.ps1' -Workspace $Workspace
    Assert-ExitCode -Result $apply -Expected 0 -Step 'apply-approved-plan'

    $batch = Invoke-SkillScript -ScriptName 'prepare-mineru-batch.ps1' -Workspace $Workspace
    Assert-ExitCode -Result $batch -Expected 0 -Step 'prepare-mineru-batch'

    $ingest = Invoke-SkillScript -ScriptName 'ingest-mineru-output.ps1' -Workspace $Workspace -ExtraArgs @('-MockMode')
    Assert-ExitCode -Result $ingest -Expected 0 -Step 'ingest-mineru-output -MockMode'

    $evidenceDir = Join-Path -Path ([string]$Workspace.RunDir) -ChildPath 'evidence'
    New-Item -ItemType Directory -Path $evidenceDir -Force | Out-Null
    Write-FixtureFile -Path (Join-Path -Path $evidenceDir -ChildPath 'fixture.md') -Content '# Fixture evidence'

    $validate = Invoke-SkillScript -ScriptName 'validate-run.ps1' -Workspace $Workspace
    Assert-ExitCode -Result $validate -Expected 0 -Step 'validate-run'
}

function Get-InventoryRows {
    param([Parameter(Mandatory = $true)][object]$Workspace)

    $inventoryPath = Join-Path -Path ([string]$Workspace.RunDir) -ChildPath 'inventory.jsonl'
    return @(Get-Content -LiteralPath $inventoryPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
}

function Get-ApplyRows {
    param([Parameter(Mandatory = $true)][object]$Workspace)

    $applyPath = Join-Path -Path ([string]$Workspace.RunDir) -ChildPath 'apply-manifest.jsonl'
    return @(Get-Content -LiteralPath $applyPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
}

function Complete-Fixture {
    param([Parameter(Mandatory = $true)][scriptblock]$Body)

    try {
        & $Body
        Write-Output 'PASS'
        exit 0
    } catch {
        Write-Error $_.Exception.Message
        exit 1
    }
}
