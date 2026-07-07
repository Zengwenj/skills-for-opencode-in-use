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

function Test-FixtureJsonProperty {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    return $null -ne $Object.PSObject.Properties[$Name]
}

function Get-FixtureJsonPropertyValue {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-MineruBatchItemLabel {
    param([Parameter(Mandatory = $true)][object]$Item)

    $sourceId = Get-FixtureJsonPropertyValue -Object $Item -Name 'source_id'
    if ([string]::IsNullOrWhiteSpace([string]$sourceId)) { return '<missing-source-id>' }
    return [string]$sourceId
}

function Assert-NullOrMissingRouteField {
    param(
        [Parameter(Mandatory = $true)][object]$Item,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if ((Test-FixtureJsonProperty -Object $Item -Name $Name) -and $null -ne (Get-FixtureJsonPropertyValue -Object $Item -Name $Name)) {
        throw "mineru-batch item $Label expected $Name to be null or missing"
    }
}

function Assert-RequiredRouteField {
    param(
        [Parameter(Mandatory = $true)][object]$Item,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][object]$Expected,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if (-not (Test-FixtureJsonProperty -Object $Item -Name $Name)) {
        throw "mineru-batch item $Label missing required $Name"
    }

    $actual = Get-FixtureJsonPropertyValue -Object $Item -Name $Name
    if ($actual -ne $Expected) {
        throw "mineru-batch item $Label expected $Name '$Expected' but got '$actual'"
    }
}

function Assert-ForbiddenProcessors {
    param(
        [Parameter(Mandatory = $true)][object]$Item,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if (-not (Test-FixtureJsonProperty -Object $Item -Name 'forbidden_processors')) {
        throw "mineru-batch item $Label missing required forbidden_processors"
    }

    $values = @(Get-FixtureJsonPropertyValue -Object $Item -Name 'forbidden_processors')
    if ($values.Count -eq 0) {
        throw "mineru-batch item $Label forbidden_processors must be a non-empty array"
    }

    foreach ($required in @('mcp', 'agent_lightweight_api', 'flash', 'pipeline')) {
        if ($values -notcontains $required) {
            throw "mineru-batch item $Label forbidden_processors missing '$required'"
        }
    }
}

function Assert-MineruBatchRouteItem {
    param([Parameter(Mandatory = $true)][object]$Item)

    $label = Get-MineruBatchItemLabel -Item $Item
    $allowedProcessors = @('convert_with_mineru', 'convert_with_mineru_html', 'lifecycle_runner', 'multimodal_looker', 'mock', 'skip_unsupported')

    if ((Test-FixtureJsonProperty -Object $Item -Name 'model_version') -and (Get-FixtureJsonPropertyValue -Object $Item -Name 'model_version') -eq 'pipeline') {
        throw "mineru-batch item $label must not use model_version 'pipeline'"
    }

    if (-not (Test-FixtureJsonProperty -Object $Item -Name 'processor')) {
        $legacyRoute = Get-FixtureJsonPropertyValue -Object $Item -Name 'mineru_route'
        if ($legacyRoute -eq 'mock' -or $legacyRoute -eq 'skip_unsupported') { return }
        throw "mineru-batch item $label missing required processor"
    }

    $processor = [string](Get-FixtureJsonPropertyValue -Object $Item -Name 'processor')
    if ($allowedProcessors -notcontains $processor) {
        throw "mineru-batch item $label has unsupported processor '$processor'"
    }

    if ($processor -eq 'convert_with_mineru' -or $processor -eq 'convert_with_mineru_html' -or $processor -eq 'lifecycle_runner') {
        $expectedModel = if ($processor -eq 'convert_with_mineru_html') { 'MinerU-HTML' } else { 'vlm' }
        Assert-RequiredRouteField -Item $Item -Name 'api_family' -Expected 'precision_api' -Label $label
        Assert-RequiredRouteField -Item $Item -Name 'model_version' -Expected $expectedModel -Label $label
        Assert-RequiredRouteField -Item $Item -Name 'requires_token_env' -Expected 'MINERU_TOKEN' -Label $label
        Assert-ForbiddenProcessors -Item $Item -Label $label
        return
    }

    Assert-NullOrMissingRouteField -Item $Item -Name 'api_family' -Label $label
    Assert-NullOrMissingRouteField -Item $Item -Name 'model_version' -Label $label
    Assert-NullOrMissingRouteField -Item $Item -Name 'requires_token_env' -Label $label

    if ($processor -eq 'multimodal_looker') {
        Assert-ForbiddenProcessors -Item $Item -Label $label
    }
}

function Assert-MineruBatchRouteSchema {
    param([Parameter(Mandatory = $true)][string]$Path)

    Assert-FileExists -Path $Path -Label 'mineru-batch.json'
    $batch = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not (Test-FixtureJsonProperty -Object $batch -Name 'items')) {
        throw "mineru-batch missing items array: $Path"
    }
    foreach ($field in @('state_path', 'polling_budget_seconds', 'output_stem_mapping', 'quality_gate_policy')) {
        if (-not (Test-FixtureJsonProperty -Object $batch -Name $field)) {
            throw "mineru-batch missing lifecycle root field $field"
        }
    }
    if ([string]::IsNullOrWhiteSpace([string]$batch.state_path) -or -not ([string]$batch.state_path).EndsWith('lifecycle-state.jsonl', [System.StringComparison]::Ordinal)) {
        throw "mineru-batch state_path must point to lifecycle-state.jsonl"
    }
    if ([int]$batch.polling_budget_seconds -le 0) {
        throw "mineru-batch polling_budget_seconds must be positive"
    }
    if ([string]$batch.output_stem_mapping.markdown -ne '<source_id>.md') {
        throw "mineru-batch output_stem_mapping.markdown must be <source_id>.md"
    }
    if ([string]$batch.quality_gate_policy.pending_stub.status -ne 'pending_stub') {
        throw "mineru-batch quality_gate_policy must document pending_stub"
    }
    if ([string]$batch.quality_gate_policy.missing_heading_contentful.status -ne 'missing_heading_contentful') {
        throw "mineru-batch quality_gate_policy must document missing_heading_contentful"
    }

    foreach ($item in @($batch.items)) {
        Assert-MineruBatchRouteItem -Item $item
    }
}

function Assert-RouteAssertionThrows {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Body,
        [Parameter(Mandatory = $true)][string]$Label
    )

    try {
        & $Body
    } catch {
        return
    }

    throw "expected MinerU route assertion failure for $Label"
}

function Assert-MineruBatchRouteAssertionsRejectInvalidItems {
    $forbidden = @('mcp', 'agent_lightweight_api', 'flash', 'pipeline')

    $missingApiFamily = [pscustomobject]@{
        source_id             = 'fixture_missing_api_family'
        processor             = 'convert_with_mineru'
        model_version         = 'vlm'
        requires_token_env    = 'MINERU_TOKEN'
        forbidden_processors  = $forbidden
    }
    Assert-RouteAssertionThrows -Label 'missing api_family' -Body { Assert-MineruBatchRouteItem -Item $missingApiFamily }

    $pipelineModel = [pscustomobject]@{
        source_id             = 'fixture_pipeline_model'
        processor             = 'convert_with_mineru'
        api_family            = 'precision_api'
        model_version         = 'pipeline'
        requires_token_env    = 'MINERU_TOKEN'
        forbidden_processors  = $forbidden
    }
    Assert-RouteAssertionThrows -Label 'model_version pipeline' -Body { Assert-MineruBatchRouteItem -Item $pipelineModel }
}

function Get-MineruBatch {
    param([Parameter(Mandatory = $true)][object]$Workspace)

    $batchPath = Join-Path -Path ([string]$Workspace.RunDir) -ChildPath 'mineru-batch.json'
    Assert-FileExists -Path $batchPath -Label 'mineru-batch.json'
    return Get-Content -LiteralPath $batchPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-SingleMineruBatchItem {
    param([Parameter(Mandatory = $true)][object]$Workspace)

    $batch = Get-MineruBatch -Workspace $Workspace
    $items = @($batch.items)
    if ($items.Count -ne 1) { throw "expected exactly one mineru-batch item, found $($items.Count)" }
    return $items[0]
}

function Write-FixtureLifecycleState {
    param(
        [Parameter(Mandatory = $true)][object]$Workspace,
        [Parameter(Mandatory = $true)][string]$SourceId,
        [Parameter(Mandatory = $true)][string]$Status,
        [string]$NextAction = ''
    )

    $statePath = Join-Path -Path ([string]$Workspace.RunDir) -ChildPath 'lifecycle-state.jsonl'
    $record = [ordered]@{
        source_id = $SourceId
        batch_id = 'fixture-batch'
        task_id = 'fixture-task'
        status = $Status
    }
    if (-not [string]::IsNullOrWhiteSpace($NextAction)) {
        $record.next_action = $NextAction
    }
    Write-FixtureFile -Path $statePath -Content ($record | ConvertTo-Json -Compress -Depth 6)
}

function Write-FixtureMineruOutput {
    param(
        [Parameter(Mandatory = $true)][object]$Workspace,
        [Parameter(Mandatory = $true)][string]$SourceId,
        [Parameter(Mandatory = $true)][string]$Markdown
    )

    $outputDir = Join-Path -Path ([string]$Workspace.RunDir) -ChildPath (Join-Path -Path 'mineru-output' -ChildPath $SourceId)
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    Write-FixtureFile -Path (Join-Path -Path $outputDir -ChildPath "$SourceId.md") -Content $Markdown
}

function Initialize-PreparedMineruRun {
    param([Parameter(Mandatory = $true)][object]$Workspace)

    Initialize-HappyPathSource -Workspace $Workspace | Out-Null
    Invoke-ScanAndProposal -Workspace $Workspace
    Approve-FixtureRun -Workspace $Workspace | Out-Null

    $apply = Invoke-SkillScript -ScriptName 'apply-approved-plan.ps1' -Workspace $Workspace
    Assert-ExitCode -Result $apply -Expected 0 -Step 'apply-approved-plan'

    $batch = Invoke-SkillScript -ScriptName 'prepare-mineru-batch.ps1' -Workspace $Workspace
    Assert-ExitCode -Result $batch -Expected 0 -Step 'prepare-mineru-batch'

    $evidenceDir = Join-Path -Path ([string]$Workspace.RunDir) -ChildPath 'evidence'
    New-Item -ItemType Directory -Path $evidenceDir -Force | Out-Null
    Write-FixtureFile -Path (Join-Path -Path $evidenceDir -ChildPath 'fixture.md') -Content '# Fixture evidence'
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
