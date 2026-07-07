#Requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RunDir,

    [Parameter(Mandatory = $true)]
    [string]$ConfigPath
)

Set-StrictMode -Version Latest

$script:RequiredApprovalFields = @(
    'status',
    'allow_apply',
    'approved_by',
    'approved_at',
    'run_id',
    'scope',
    'config_sha256',
    'inventory_sha256',
    'source_snapshot_before_sha256',
    'classification_plan_sha256',
    'proposal_manifest_sha256'
)
$script:ExpectedRunFiles = @(
    'inventory.jsonl',
    'source_snapshot_before.csv',
    'source_snapshot_after.csv',
    'source_snapshot_diff.csv',
    'classification-proposal.md',
    'classification-plan.jsonl',
    'proposal-manifest.json',
    'approval.md',
    'apply-log.md',
    'apply-manifest.jsonl',
    'mineru-batch.json',
    'parse-manifest.csv',
    'raw-output-manifest.csv',
    'failures.csv'
)
$script:InventoryFields = @('source_id', 'run_id', 'abs_path', 'rel_path', 'size', 'mtime', 'sha256', 'parent_dir', 'extension', 'inferred_theme', 'inferred_year', 'confidence', 'review_needed')
$script:PlanFields = @('source_id', 'run_id', 'action', 'source_abs_path', 'source_rel_path', 'source_sha256', 'target_archive_path', 'target_theme', 'target_year', 'enter_raw_sources', 'mineru_candidate', 'confidence', 'review_needed', 'reason_codes')
$script:ManifestFields = @('schema_version', 'run_id', 'scope', 'created_at', 'config_sha256', 'inventory_sha256', 'source_snapshot_before_sha256', 'classification_plan_sha256', 'item_count', 'review_needed_count', 'actions', 'artifact_paths')
$script:ApplyFields = @('source_id', 'run_id', 'state', 'source_path', 'source_sha256', 'archive_path', 'archive_sha256', 'attempt', 'timestamp')
$script:ApplyStates = @('planned', 'copied_temp', 'committed', 'failed', 'skipped_existing_committed', 'preflight_failed', 'verified_temp', 'failed_partial_deleted', 'failed_divergent', 'skipped')
$script:BatchRootFields = @('schema_version', 'run_id', 'created_at', 'state_path', 'polling_budget_seconds', 'output_stem_mapping', 'quality_gate_policy', 'items')
$script:BatchFields = @('source_id', 'archive_path', 'archive_sha256', 'extension', 'mineru_route', 'processor', 'api_family', 'model_version', 'requires_token_env', 'forbidden_processors', 'output_dir', 'raw_target_hint')
$script:BatchRoutes = @('convert_with_mineru', 'convert_with_mineru_html', 'lifecycle_runner', 'mock', 'skip_unsupported', 'conditional')
$script:AllowedProcessors = @('convert_with_mineru', 'convert_with_mineru_html', 'lifecycle_runner', 'mock', 'skip_unsupported', 'multimodal_looker')
$script:PrecisionProcessors = @('convert_with_mineru', 'convert_with_mineru_html', 'lifecycle_runner')
$script:ForbiddenProcessors = @('mcp', 'agent_lightweight_api', 'flash', 'pipeline')
$script:RequiredForbiddenProcessors = @('mcp', 'agent_lightweight_api', 'flash', 'pipeline')
$script:PendingLifecycleStatuses = @('prepared', 'submitted', 'uploaded', 'waiting-file', 'pending', 'running', 'converting', 'pending_timeout', 'stale_pending')
$script:ParseStatuses = @('parsed', 'failed', 'skipped', 'pending', 'pending_stub', 'quality_failed', 'missing_heading_contentful')
$script:RawStatuses = @('written', 'skipped', 'failed', 'pending', 'pending_stub', 'quality_failed', 'missing_heading_contentful')
$script:SnapshotFields = @('source_id', 'rel_path', 'abs_path', 'sha256', 'size', 'mtime', 'exists')
$script:DiffFields = @('source_id', 'rel_path', 'before_sha256', 'after_sha256', 'change_type', 'allowed')
$script:ParseFields = @('source_id', 'run_id', 'archive_path', 'archive_sha256', 'route', 'status', 'output_path', 'content_bytes', 'has_heading', 'retry_count')
$script:RawFields = @('source_id', 'run_id', 'archive_path', 'archive_sha256', 'raw_path', 'raw_sha256', 'status')
$script:FailureFields = @('run_id', 'source_id', 'stage', 'error_code', 'message', 'retryable', 'next_action', 'artifact_path')

function Write-ValidationError {
    param(
        [Parameter(Mandatory = $true)][string]$What,
        [Parameter(Mandatory = $true)][string]$Where,
        [Parameter(Mandatory = $true)][string]$Expected,
        [Parameter(Mandatory = $true)][string]$Fix
    )

    [Console]::Error.WriteLine((@(
        "[ERROR] $What",
        "  File/Field: $Where",
        "  Expected: $Expected",
        "  Action: $Fix"
    ) -join "`n"))
}

function Convert-ValidationValueToString {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return '' }
    if ($Value -is [bool]) { return $Value.ToString().ToLowerInvariant() }

    $text = ([string]$Value).Trim()
    if (($text.StartsWith('"') -and $text.EndsWith('"')) -or ($text.StartsWith("'") -and $text.EndsWith("'"))) {
        if ($text.Length -le 2) { return '' }
        return $text.Substring(1, $text.Length - 2).Trim()
    }

    return $text
}

function Convert-YamlObjectToHashtable {
    param([Parameter(Mandatory = $true)][object]$YamlObject)

    $result = @{}
    if ($YamlObject -is [System.Collections.IDictionary]) {
        foreach ($key in $YamlObject.Keys) {
            $result[[string]$key] = Convert-ValidationValueToString -Value $YamlObject[$key]
        }
        return $result
    }

    foreach ($property in $YamlObject.PSObject.Properties) {
        $result[[string]$property.Name] = Convert-ValidationValueToString -Value $property.Value
    }
    return $result
}

function Parse-ApprovalFrontmatter {
    param([Parameter(Mandatory = $true)][string]$ApprovalPath)

    $raw = Get-Content -LiteralPath $ApprovalPath -Raw -Encoding UTF8
    $normalized = $raw -replace "`r`n", "`n" -replace "`r", "`n"
    $match = [regex]::Match($normalized, '^---\n(.*?)\n---', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $match.Success) {
        throw 'approval.md is missing YAML frontmatter delimited by ---. '
    }

    $yamlText = $match.Groups[1].Value
    $convertFromYaml = Get-Command -Name ConvertFrom-Yaml -ErrorAction SilentlyContinue
    if ($convertFromYaml) {
        try {
            $yamlObject = $yamlText | ConvertFrom-Yaml
            return Convert-YamlObjectToHashtable -YamlObject $yamlObject
        } catch {
            throw "approval.md YAML frontmatter could not be parsed: $($_.Exception.Message)"
        }
    }

    $fields = @{}
    foreach ($line in ($yamlText -split "`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $lineMatch = [regex]::Match($line, '^([A-Za-z0-9_]+):\s*(.*)$')
        if (-not $lineMatch.Success) {
            throw "approval.md YAML line is not a flat key-value pair: $line"
        }

        $fields[$lineMatch.Groups[1].Value] = Convert-ValidationValueToString -Value $lineMatch.Groups[2].Value
    }

    return $fields
}

function Test-RequiredFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-ValidationError -What 'Expected run artifact is missing' -Where $Path -Expected 'File exists in RunDir' -Fix 'Run the full scan, proposal, approval, apply, batch, and raw ingest pipeline again.'
        return $false
    }

    $item = Get-Item -LiteralPath $Path
    if ($item.Length -le 0) {
        Write-ValidationError -What 'Expected run artifact is empty' -Where $Path -Expected 'File has non-empty content' -Fix 'Regenerate this artifact with the producing script.'
        return $false
    }

    return $true
}

function Test-ObjectFields {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string[]]$RequiredFields,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ArtifactName
    )

    $valid = $true
    foreach ($field in $RequiredFields) {
        if ($Object.PSObject.Properties.Name -notcontains $field) {
            Write-ValidationError -What "$ArtifactName is missing a required field" -Where "$Path -> $field" -Expected 'Field must be present in the documented artifact schema' -Fix 'Regenerate the run artifacts with the current scripts.'
            $valid = $false
        }
    }

    return $valid
}

function Get-ValidationPropertyValue {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Resolve-RunArtifactPath {
    param(
        [Parameter(Mandatory = $true)][string]$RunDir,
        [AllowNull()][string]$Path,
        [Parameter(Mandatory = $true)][string]$DefaultLeaf
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return [System.IO.Path]::GetFullPath((Join-Path -Path $RunDir -ChildPath $DefaultLeaf))
    }

    $candidate = $Path.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
    if ([System.IO.Path]::IsPathRooted($candidate)) {
        return [System.IO.Path]::GetFullPath($candidate)
    }

    return [System.IO.Path]::GetFullPath((Join-Path -Path $RunDir -ChildPath $candidate.TrimStart('.', [System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)))
}

function Read-LifecycleStatesBySourceId {
    param([Parameter(Mandatory = $true)][string]$Path)

    $states = @{}
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $states }

    $lineNumber = 0
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        $lineNumber++
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $record = $line | ConvertFrom-Json
        } catch {
            Write-ValidationError -What 'lifecycle-state.jsonl contains invalid JSONL' -Where "$Path line $lineNumber" -Expected 'One valid JSON object per non-empty line' -Fix $_.Exception.Message
            continue
        }
        $sourceId = [string](Get-ValidationPropertyValue -Object $record -Name 'source_id')
        if ([string]::IsNullOrWhiteSpace($sourceId)) { continue }
        $states[$sourceId] = $record
    }

    return $states
}

function Test-PendingLifecycleStatus {
    param([AllowNull()][string]$Status)
    return -not [string]::IsNullOrWhiteSpace($Status) -and $script:PendingLifecycleStatuses -contains $Status
}

function Test-PendingStubMarkdown {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$SourceId,
        [Parameter(Mandatory = $true)][int]$ContentBytes
    )

    $normalized = ($Text -replace "`r`n", "`n" -replace "`r", "`n").TrimEnd()
    $expectedWithHeading = "# $SourceId`n`nMinerU processing pending - file not yet parsed."
    if ($normalized.Equals($expectedWithHeading, [System.StringComparison]::Ordinal)) { return $true }
    if ($normalized.Equals('MinerU processing pending - file not yet parsed.', [System.StringComparison]::Ordinal)) { return $true }
    return ($ContentBytes -le 128 -and $normalized.Contains('MinerU processing pending - file not yet parsed.'))
}

function Read-JsonlObjectsForValidation {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ArtifactName
    )

    $objects = [System.Collections.Generic.List[object]]::new()
    $valid = $true
    $lineNumber = 0
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        $lineNumber++
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $objects.Add(($line | ConvertFrom-Json))
        } catch {
            Write-ValidationError -What "$ArtifactName contains invalid JSONL" -Where "$Path line $lineNumber" -Expected 'One valid JSON object per non-empty line' -Fix $_.Exception.Message
            $valid = $false
        }
    }

    if ($objects.Count -eq 0) {
        Write-ValidationError -What "$ArtifactName has no records" -Where $Path -Expected 'At least one JSONL record for a completed run' -Fix 'Run this validation after the full fixture or production pipeline has produced records.'
        $valid = $false
    }

    return [pscustomobject]@{ Valid = $valid; Objects = @($objects) }
}

function Test-JsonlArtifact {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$RequiredFields,
        [Parameter(Mandatory = $true)][string]$ArtifactName
    )

    $result = Read-JsonlObjectsForValidation -Path $Path -ArtifactName $ArtifactName
    $valid = [bool]$result.Valid
    $index = 0
    foreach ($object in @($result.Objects)) {
        $index++
        if (-not (Test-ObjectFields -Object $object -RequiredFields $RequiredFields -Path "$Path record $index" -ArtifactName $ArtifactName)) {
            $valid = $false
        }
    }

    return [pscustomobject]@{ Valid = $valid; Objects = @($result.Objects) }
}

function Read-CsvRowsForValidation {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$RequiredFields,
        [Parameter(Mandatory = $true)][string]$ArtifactName,
        [switch]$AllowHeaderOnly
    )

    $valid = $true
    try {
        $headerLine = Get-Content -LiteralPath $Path -Encoding UTF8 -TotalCount 1
        if ([string]::IsNullOrWhiteSpace($headerLine)) {
            Write-ValidationError -What "$ArtifactName header is empty" -Where $Path -Expected 'CSV header with documented fields' -Fix 'Regenerate the CSV artifact.'
            return [pscustomobject]@{ Valid = $false; Rows = @() }
        }

        $names = @($headerLine -split ',' | ForEach-Object { ([string]$_).Trim().Trim('"') })
        foreach ($field in $RequiredFields) {
            if ($names -notcontains $field) {
                Write-ValidationError -What "$ArtifactName is missing a required CSV column" -Where "$Path -> $field" -Expected 'Documented CSV schema column' -Fix 'Regenerate the CSV artifact with the current schema.'
                $valid = $false
            }
        }

        $rows = @(Get-Content -LiteralPath $Path -Encoding UTF8 | ConvertFrom-Csv)
        if (-not $AllowHeaderOnly -and $rows.Count -eq 0) {
            Write-ValidationError -What "$ArtifactName has no data rows" -Where $Path -Expected 'At least one data row for a completed run' -Fix 'Run this validation after the relevant pipeline stage has produced records.'
            $valid = $false
        }

        return [pscustomobject]@{ Valid = $valid; Rows = @($rows) }
    } catch {
        Write-ValidationError -What "$ArtifactName could not be parsed as CSV" -Where $Path -Expected 'Valid CSV with documented columns' -Fix $_.Exception.Message
        return [pscustomobject]@{ Valid = $false; Rows = @() }
    }
}

function Test-Sha256Text {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Where
    )

    if ($Value -notmatch '^[0-9a-fA-F]{64}$') {
        Write-ValidationError -What 'SHA256 value is malformed' -Where $Where -Expected '64-character SHA256 hex string' -Fix 'Regenerate the artifact or copy the exact SHA256 from the producing stage.'
        return $false
    }

    return $true
}

function Test-ProposalManifest {
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][string]$RunDir
    )

    $valid = $true
    try {
        $manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-ValidationError -What 'proposal-manifest.json is invalid JSON' -Where $ManifestPath -Expected 'Valid JSON object' -Fix $_.Exception.Message
        return [pscustomobject]@{ Valid = $false; Manifest = $null }
    }

    if (-not (Test-ObjectFields -Object $manifest -RequiredFields $script:ManifestFields -Path $ManifestPath -ArtifactName 'proposal-manifest.json')) {
        $valid = $false
    }

    $hashChecks = [ordered]@{
        config_sha256                 = $ConfigPath
        inventory_sha256              = Join-Path -Path $RunDir -ChildPath 'inventory.jsonl'
        source_snapshot_before_sha256 = Join-Path -Path $RunDir -ChildPath 'source_snapshot_before.csv'
        classification_plan_sha256    = Join-Path -Path $RunDir -ChildPath 'classification-plan.jsonl'
    }

    foreach ($entry in $hashChecks.GetEnumerator()) {
        $field = [string]$entry.Key
        if ($manifest.PSObject.Properties.Name -notcontains $field) { continue }
        $path = [string]$entry.Value
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $expectedHash = [string]$manifest.$field
        if (-not (Test-Sha256Text -Value $expectedHash -Where "$ManifestPath -> $field")) {
            $valid = $false
            continue
        }

        $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash
        if (-not $actualHash.Equals($expectedHash, [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-ValidationError -What 'proposal-manifest hash does not match current artifact bytes' -Where "$ManifestPath -> $field" -Expected "$actualHash for $path" -Fix 'Regenerate proposal artifacts before approving or applying this run.'
            $valid = $false
        }
    }

    return [pscustomobject]@{ Valid = $valid; Manifest = $manifest }
}

function Test-Approval {
    param(
        [Parameter(Mandatory = $true)][string]$ApprovalPath,
        [Parameter(Mandatory = $true)][object]$ProposalManifest,
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][string]$RunDir
    )

    $valid = $true
    try {
        $fields = Parse-ApprovalFrontmatter -ApprovalPath $ApprovalPath
    } catch {
        Write-ValidationError -What 'Approval file could not be parsed' -Where $ApprovalPath -Expected 'YAML frontmatter with 11 flat key-value fields' -Fix $_.Exception.Message
        return $false
    }

    foreach ($field in $script:RequiredApprovalFields) {
        if (-not $fields.ContainsKey($field)) {
            Write-ValidationError -What 'Approval schema field is missing' -Where "$ApprovalPath -> $field" -Expected 'All 11 approval fields must be present' -Fix 'Regenerate approval.md from the template.'
            $valid = $false
        }
    }

    foreach ($field in $fields.Keys) {
        if ($script:RequiredApprovalFields -notcontains $field) {
            Write-ValidationError -What 'Approval schema contains an extra field' -Where "$ApprovalPath -> $field" -Expected 'Exactly the 11 approved schema fields and no alternatives' -Fix 'Remove the extra field and use only the documented approval schema.'
            $valid = $false
        }
    }

    if (-not $valid) { return $false }

    if ([string]$fields['status'] -cne 'approved') {
        Write-ValidationError -What 'Approval status is not approved for completed run validation' -Where "$ApprovalPath -> status" -Expected 'approved' -Fix 'Validate only after human approval and successful apply, or keep this run as proposal-only.'
        $valid = $false
    }

    if (-not ([string]$fields['allow_apply']).Equals('true', [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-ValidationError -What 'Approval allow_apply is not true for completed run validation' -Where "$ApprovalPath -> allow_apply" -Expected 'true' -Fix 'Have the human approver set allow_apply after reviewing the proposal.'
        $valid = $false
    }

    foreach ($field in @('approved_by', 'approved_at')) {
        if ([string]::IsNullOrWhiteSpace([string]$fields[$field])) {
            Write-ValidationError -What 'Approval metadata is empty' -Where "$ApprovalPath -> $field" -Expected 'Non-empty human approval metadata' -Fix "Fill $field with the human approver metadata."
            $valid = $false
        }
    }

    $runId = Split-Path -Path $RunDir -Leaf
    if (-not ([string]$fields['run_id']).Equals($runId, [System.StringComparison]::Ordinal)) {
        Write-ValidationError -What 'Approval run_id does not match RunDir' -Where "$ApprovalPath -> run_id" -Expected $runId -Fix 'Use the approval.md that belongs to this run directory.'
        $valid = $false
    }

    if ($null -ne $ProposalManifest -and -not ([string]$fields['scope']).Equals([string]$ProposalManifest.scope, [System.StringComparison]::Ordinal)) {
        Write-ValidationError -What 'Approval scope does not match proposal-manifest scope' -Where "$ApprovalPath -> scope" -Expected ([string]$ProposalManifest.scope) -Fix 'Regenerate proposal artifacts for the current config, then approve that run.'
        $valid = $false
    }

    $hashChecks = [ordered]@{
        config_sha256                 = $ConfigPath
        inventory_sha256              = Join-Path -Path $RunDir -ChildPath 'inventory.jsonl'
        source_snapshot_before_sha256 = Join-Path -Path $RunDir -ChildPath 'source_snapshot_before.csv'
        classification_plan_sha256    = Join-Path -Path $RunDir -ChildPath 'classification-plan.jsonl'
        proposal_manifest_sha256      = Join-Path -Path $RunDir -ChildPath 'proposal-manifest.json'
    }

    foreach ($entry in $hashChecks.GetEnumerator()) {
        $field = [string]$entry.Key
        $expectedHash = [string]$fields[$field]
        if (-not (Test-Sha256Text -Value $expectedHash -Where "$ApprovalPath -> $field")) {
            $valid = $false
            continue
        }

        $artifactPath = [string]$entry.Value
        if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) { continue }
        $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $artifactPath).Hash
        if (-not $actualHash.Equals($expectedHash, [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-ValidationError -What 'Approval hash does not match current artifact bytes' -Where "$ApprovalPath -> $field" -Expected "$actualHash for $artifactPath" -Fix 'Do not trust this run. Regenerate/review artifacts or update approval.md after human review.'
            $valid = $false
        }
    }

    return $valid
}

function Test-ApplyManifest {
    param([Parameter(Mandatory = $true)][string]$Path)

    $jsonl = Test-JsonlArtifact -Path $Path -RequiredFields $script:ApplyFields -ArtifactName 'apply-manifest.jsonl'
    $valid = [bool]$jsonl.Valid
    $latestBySourceId = @{}
    $committedCount = 0

    foreach ($entry in @($jsonl.Objects)) {
        $state = [string]$entry.state
        if ($script:ApplyStates -notcontains $state) {
            Write-ValidationError -What 'apply-manifest state is not documented' -Where "$Path -> $($entry.source_id).state" -Expected ($script:ApplyStates -join ', ') -Fix 'Use only documented apply state-machine states.'
            $valid = $false
        }

        if (-not (Test-Sha256Text -Value ([string]$entry.source_sha256) -Where "$Path -> $($entry.source_id).source_sha256")) { $valid = $false }
        $latestBySourceId[[string]$entry.source_id] = $entry

        if ($state -in @('committed', 'skipped_existing_committed')) {
            $committedCount++
            if (-not (Test-Sha256Text -Value ([string]$entry.archive_sha256) -Where "$Path -> $($entry.source_id).archive_sha256")) { $valid = $false }
            $archivePath = [string]$entry.archive_path
            if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
                Write-ValidationError -What 'Committed archive path is missing' -Where $archivePath -Expected 'Committed archive file exists' -Fix 'Restore archive file or rebuild this run from source.'
                $valid = $false
            } else {
                $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archivePath).Hash
                if (-not $actualHash.Equals([string]$entry.archive_sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
                    Write-ValidationError -What 'Committed archive hash mismatch' -Where $archivePath -Expected ([string]$entry.archive_sha256) -Fix 'Investigate archive corruption or rebuild the run.'
                    $valid = $false
                }
            }
        }
    }

    if ($committedCount -eq 0) {
        Write-ValidationError -What 'apply-manifest contains no committed item' -Where $Path -Expected 'At least one committed or skipped_existing_committed record in a completed run' -Fix 'Run apply-approved-plan.ps1 successfully before full validation.'
        $valid = $false
    }

    return [pscustomobject]@{ Valid = $valid; Latest = $latestBySourceId; Objects = @($jsonl.Objects) }
}

function Test-MineruBatch {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][hashtable]$LatestApply,
        [Parameter(Mandatory = $true)][string]$RunDir
    )

    $valid = $true
    try {
        $batch = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-ValidationError -What 'mineru-batch.json is invalid JSON' -Where $Path -Expected 'Valid JSON object' -Fix $_.Exception.Message
        return [pscustomobject]@{ Valid = $false; Batch = $null }
    }

    foreach ($field in $script:BatchRootFields) {
        if ($batch.PSObject.Properties.Name -notcontains $field) {
            Write-ValidationError -What 'mineru-batch.json is missing a required field' -Where "$Path -> $field" -Expected 'Documented MinerU batch root schema' -Fix 'Regenerate mineru-batch.json with prepare-mineru-batch.ps1.'
            $valid = $false
        }
    }

    $statePath = Resolve-RunArtifactPath -RunDir $RunDir -Path ([string](Get-ValidationPropertyValue -Object $batch -Name 'state_path')) -DefaultLeaf 'lifecycle-state.jsonl'
    if (-not $statePath.EndsWith('lifecycle-state.jsonl', [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-ValidationError -What 'mineru-batch state_path does not point to lifecycle-state.jsonl' -Where "$Path -> state_path" -Expected 'Path ending in lifecycle-state.jsonl' -Fix 'Regenerate mineru-batch.json with prepare-mineru-batch.ps1.'
        $valid = $false
    }

    if ([int](Get-ValidationPropertyValue -Object $batch -Name 'polling_budget_seconds') -le 0) {
        Write-ValidationError -What 'mineru-batch polling_budget_seconds is invalid' -Where "$Path -> polling_budget_seconds" -Expected 'Positive integer polling budget' -Fix 'Set mineruPollingBudgetSeconds to a positive integer or regenerate with defaults.'
        $valid = $false
    }

    $mapping = Get-ValidationPropertyValue -Object $batch -Name 'output_stem_mapping'
    if ([string](Get-ValidationPropertyValue -Object $mapping -Name 'markdown') -ne '<source_id>.md') {
        Write-ValidationError -What 'mineru-batch output mapping is invalid' -Where "$Path -> output_stem_mapping.markdown" -Expected '<source_id>.md' -Fix 'Use lifecycle runner source_id-based output mapping.'
        $valid = $false
    }

    $qualityPolicy = Get-ValidationPropertyValue -Object $batch -Name 'quality_gate_policy'
    $pendingPolicy = Get-ValidationPropertyValue -Object $qualityPolicy -Name 'pending_stub'
    $missingHeadingPolicy = Get-ValidationPropertyValue -Object $qualityPolicy -Name 'missing_heading_contentful'
    if ([string](Get-ValidationPropertyValue -Object $pendingPolicy -Name 'status') -ne 'pending_stub') {
        Write-ValidationError -What 'mineru-batch quality policy lacks pending_stub rule' -Where "$Path -> quality_gate_policy.pending_stub" -Expected 'pending_stub status rule' -Fix 'Regenerate mineru-batch.json with lifecycle quality policy fields.'
        $valid = $false
    }
    if ([string](Get-ValidationPropertyValue -Object $missingHeadingPolicy -Name 'status') -ne 'missing_heading_contentful') {
        Write-ValidationError -What 'mineru-batch quality policy lacks missing_heading_contentful rule' -Where "$Path -> quality_gate_policy.missing_heading_contentful" -Expected 'missing_heading_contentful status rule' -Fix 'Regenerate mineru-batch.json with lifecycle quality policy fields.'
        $valid = $false
    }

    $lifecycleStates = Read-LifecycleStatesBySourceId -Path $statePath

    foreach ($item in @($batch.items)) {
        if (-not (Test-ObjectFields -Object $item -RequiredFields $script:BatchFields -Path "$Path -> items[$([string]$item.source_id)]" -ArtifactName 'mineru-batch.json item')) {
            $valid = $false
            continue
        }

        $sourceId = [string]$item.source_id
        $processor = [string]$item.processor
        if ($script:ForbiddenProcessors -contains $processor -or $script:AllowedProcessors -notcontains $processor) {
            Write-ValidationError -What 'MinerU batch processor is forbidden or undocumented' -Where "$Path -> $sourceId.processor" -Expected ($script:AllowedProcessors -join ', ') -Fix 'Regenerate mineru-batch.json with the lifecycle runner processor.'
            $valid = $false
        }

        if ($script:PrecisionProcessors -contains $processor) {
            if ([string]$item.api_family -ne 'precision_api') {
                Write-ValidationError -What 'MinerU batch api_family is not precision_api' -Where "$Path -> $sourceId.api_family" -Expected 'precision_api' -Fix 'Regenerate mineru-batch.json with Precision API lifecycle fields.'
                $valid = $false
            }
            if ([string]$item.requires_token_env -ne 'MINERU_TOKEN') {
                Write-ValidationError -What 'MinerU batch requires_token_env is invalid' -Where "$Path -> $sourceId.requires_token_env" -Expected 'MINERU_TOKEN' -Fix 'Use MINERU_TOKEN for lifecycle runner authentication.'
                $valid = $false
            }
            $expectedModel = if ($processor -eq 'convert_with_mineru_html') { 'MinerU-HTML' } else { 'vlm' }
            if ([string]$item.model_version -ne $expectedModel -or [string]$item.model_version -eq 'pipeline') {
                Write-ValidationError -What 'MinerU batch model_version is invalid' -Where "$Path -> $sourceId.model_version" -Expected $expectedModel -Fix 'Use vlm for non-HTML and MinerU-HTML for HTML; never rely on pipeline default.'
                $valid = $false
            }
        }

        $forbiddenValues = @($item.forbidden_processors | ForEach-Object { [string]$_ })
        foreach ($requiredForbidden in $script:RequiredForbiddenProcessors) {
            if ($forbiddenValues -notcontains $requiredForbidden) {
                Write-ValidationError -What 'MinerU batch forbidden_processors is incomplete' -Where "$Path -> $sourceId.forbidden_processors" -Expected ($script:RequiredForbiddenProcessors -join ', ') -Fix 'Regenerate mineru-batch.json with MCP, lightweight API, flash, and pipeline explicitly forbidden.'
                $valid = $false
            }
        }

        if (-not $LatestApply.ContainsKey($sourceId)) {
            Write-ValidationError -What 'MinerU batch item is not present in apply-manifest' -Where "$Path -> $sourceId" -Expected 'Batch items come only from committed apply-manifest entries' -Fix 'Regenerate mineru-batch.json from apply-manifest.jsonl.'
            $valid = $false
            continue
        }

        $applyEntry = $LatestApply[$sourceId]
        if ([string]$applyEntry.state -notin @('committed', 'skipped_existing_committed')) {
            Write-ValidationError -What 'MinerU batch item is not committed' -Where "$Path -> $sourceId" -Expected 'Latest apply state committed or skipped_existing_committed' -Fix 'Regenerate batch after successful apply only.'
            $valid = $false
        }

        if (-not ([string]$item.archive_sha256).Equals([string]$applyEntry.archive_sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-ValidationError -What 'MinerU batch archive hash differs from apply-manifest' -Where "$Path -> $sourceId.archive_sha256" -Expected ([string]$applyEntry.archive_sha256) -Fix 'Regenerate mineru-batch.json from committed apply-manifest records.'
            $valid = $false
        }

        if ($script:BatchRoutes -notcontains [string]$item.mineru_route) {
            Write-ValidationError -What 'MinerU route is not documented' -Where "$Path -> $sourceId.mineru_route" -Expected ($script:BatchRoutes -join ', ') -Fix 'Use a documented MinerU bridge route.'
            $valid = $false
        }

        $outputDir = ([string]$item.output_dir).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        if (-not [System.IO.Path]::IsPathRooted($outputDir)) {
            $outputDir = [System.IO.Path]::GetFullPath((Join-Path -Path $RunDir -ChildPath $outputDir.TrimStart('.', [System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)))
        }
        $lifecycleState = if ($lifecycleStates.ContainsKey($sourceId)) { $lifecycleStates[$sourceId] } else { $null }
        $lifecycleStatus = [string](Get-ValidationPropertyValue -Object $lifecycleState -Name 'status')
        $lifecycleNextAction = [string](Get-ValidationPropertyValue -Object $lifecycleState -Name 'next_action')
        $isPendingLifecycle = Test-PendingLifecycleStatus -Status $lifecycleStatus

        if (-not (Test-Path -LiteralPath $outputDir -PathType Container)) {
            if ($isPendingLifecycle -and -not [string]::IsNullOrWhiteSpace($lifecycleNextAction)) { continue }
            Write-ValidationError -What 'MinerU output directory is missing' -Where $outputDir -Expected 'mineru-output/<source_id>/ exists for every batch item' -Fix 'Run the MinerU bridge or mock ingest before full validation.'
            $valid = $false
        } elseif (-not (Split-Path -Path $outputDir -Leaf).Equals($sourceId, [System.StringComparison]::Ordinal)) {
            Write-ValidationError -What 'MinerU output directory leaf does not match source_id' -Where $outputDir -Expected $sourceId -Fix 'Regenerate mineru-batch.json with stable output_dir values.'
            $valid = $false
        } else {
            $markdownPath = Join-Path -Path $outputDir -ChildPath "$sourceId.md"
            if (-not (Test-Path -LiteralPath $markdownPath -PathType Leaf)) {
                $otherMarkdown = @(Get-ChildItem -LiteralPath $outputDir -File -Filter '*.md' -ErrorAction SilentlyContinue)
                if ($otherMarkdown.Count -gt 0) {
                    Write-ValidationError -What 'MinerU output mapping uses a non-source_id markdown name' -Where $outputDir -Expected "$sourceId.md, not original stem .md" -Fix 'Use the lifecycle runner remapping output contract.'
                    $valid = $false
                } elseif ($isPendingLifecycle -and -not [string]::IsNullOrWhiteSpace($lifecycleNextAction)) {
                    continue
                } else {
                    if (-not (Test-RequiredFile -Path $markdownPath)) { $valid = $false }
                }
            }
        }
    }

    return [pscustomobject]@{ Valid = $valid; Batch = $batch }
}

function Test-ParseManifest {
    param([Parameter(Mandatory = $true)][string]$Path)

    $csv = Read-CsvRowsForValidation -Path $Path -RequiredFields $script:ParseFields -ArtifactName 'parse-manifest.csv'
    $valid = [bool]$csv.Valid
    foreach ($row in @($csv.Rows)) {
        $status = [string]$row.status
        $contentBytes = [int64]$row.content_bytes
        if ($status -notin $script:ParseStatuses) {
            Write-ValidationError -What 'parse-manifest status is invalid' -Where "$Path -> $($row.source_id).status" -Expected ($script:ParseStatuses -join ', ') -Fix 'Regenerate parse-manifest.csv with ingest-mineru-output.ps1.'
            $valid = $false
        }

        if ($status -eq 'parsed') {
            if (-not (Test-Sha256Text -Value ([string]$row.archive_sha256) -Where "$Path -> $($row.source_id).archive_sha256")) { $valid = $false }
            if ($contentBytes -le 0) {
                Write-ValidationError -What 'Parsed MinerU output has zero content bytes' -Where "$Path -> $($row.source_id).content_bytes" -Expected 'Positive content_bytes' -Fix 'Regenerate MinerU output before raw ingest.'
                $valid = $false
            }
            if (-not ([string]$row.has_heading).Equals('true', [System.StringComparison]::OrdinalIgnoreCase)) {
                Write-ValidationError -What 'Parsed MinerU output lacks heading flag' -Where "$Path -> $($row.source_id).has_heading" -Expected 'true for accepted parsed Markdown' -Fix 'Regenerate MinerU output with a Markdown heading.'
                $valid = $false
            }
            if ([string]::IsNullOrWhiteSpace([string]$row.output_path) -or -not (Test-Path -LiteralPath ([string]$row.output_path) -PathType Leaf)) {
                Write-ValidationError -What 'Parsed output_path is missing on disk' -Where "$Path -> $($row.source_id).output_path" -Expected "Existing MinerU <source_id>.md path" -Fix 'Run the MinerU bridge or mock mode before validation.'
                $valid = $false
            } else {
                $markdown = Get-Content -LiteralPath ([string]$row.output_path) -Raw -Encoding UTF8
                if (Test-PendingStubMarkdown -Text $markdown -SourceId ([string]$row.source_id) -ContentBytes $contentBytes) {
                    Write-ValidationError -What 'pending_stub was marked as parsed success' -Where "$Path -> $($row.source_id).status" -Expected 'pending_stub, never parsed' -Fix 'Regenerate parse-manifest.csv with pending_stub classification.'
                    $valid = $false
                }
            }
        }

        if ($status -eq 'pending') {
            if (-not [string]::IsNullOrWhiteSpace([string]$row.output_path)) {
                Write-ValidationError -What 'pending parse row has an output_path' -Where "$Path -> $($row.source_id).output_path" -Expected 'No output_path until lifecycle runner downloads markdown' -Fix 'Classify downloaded outputs as parsed, pending_stub, quality_failed, or missing_heading_contentful.'
                $valid = $false
            }
        }

        if ($status -eq 'pending_stub') {
            if ([string]::IsNullOrWhiteSpace([string]$row.output_path) -or -not (Test-Path -LiteralPath ([string]$row.output_path) -PathType Leaf)) {
                Write-ValidationError -What 'pending_stub parse row lacks the stub artifact' -Where "$Path -> $($row.source_id).output_path" -Expected 'Existing stub markdown path' -Fix 'Regenerate parse-manifest.csv from the actual lifecycle output.'
                $valid = $false
            }
        }

        if ($status -eq 'missing_heading_contentful') {
            if ($contentBytes -le 500 -or ([string]$row.has_heading).Equals('true', [System.StringComparison]::OrdinalIgnoreCase)) {
                Write-ValidationError -What 'missing_heading_contentful row is not contentful no-heading output' -Where "$Path -> $($row.source_id).status" -Expected 'content_bytes > 500 and has_heading=false' -Fix 'Use quality_failed for empty/short output or parsed for heading-bearing output.'
                $valid = $false
            }
        }

        if ($status -eq 'failed' -and [string]$row.validation_flags -match 'missing_heading' -and $contentBytes -gt 500) {
            Write-ValidationError -What 'contentful missing-heading output was mixed with failed' -Where "$Path -> $($row.source_id).status" -Expected 'missing_heading_contentful' -Fix 'Regenerate parse-manifest.csv with distinct missing_heading_contentful classification.'
            $valid = $false
        }
    }

    return [pscustomobject]@{ Valid = $valid; Rows = @($csv.Rows) }
}

function Test-RawManifest {
    param([Parameter(Mandatory = $true)][string]$Path)

    $csv = Read-CsvRowsForValidation -Path $Path -RequiredFields $script:RawFields -ArtifactName 'raw-output-manifest.csv'
    $valid = [bool]$csv.Valid
    $writtenCount = 0
    $nonTerminalCount = 0
    foreach ($row in @($csv.Rows)) {
        $status = [string]$row.status
        if ($status -notin $script:RawStatuses) {
            Write-ValidationError -What 'raw-output-manifest status is invalid' -Where "$Path -> $($row.source_id).status" -Expected ($script:RawStatuses -join ', ') -Fix 'Regenerate raw-output-manifest.csv with ingest-mineru-output.ps1.'
            $valid = $false
        }

        if ($status -eq 'written') {
            $writtenCount++
            if (-not (Test-Sha256Text -Value ([string]$row.archive_sha256) -Where "$Path -> $($row.source_id).archive_sha256")) { $valid = $false }
            if (-not (Test-Sha256Text -Value ([string]$row.raw_sha256) -Where "$Path -> $($row.source_id).raw_sha256")) { $valid = $false }
            $rawPath = [string]$row.raw_path
            if (-not (Test-Path -LiteralPath $rawPath -PathType Leaf)) {
                Write-ValidationError -What 'Written raw_path is missing on disk' -Where $rawPath -Expected 'Raw Markdown file exists' -Fix 'Rerun raw ingest or restore the raw source file.'
                $valid = $false
            } else {
                $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $rawPath).Hash
                if (-not $actualHash.Equals([string]$row.raw_sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
                    Write-ValidationError -What 'Raw output hash mismatch' -Where $rawPath -Expected ([string]$row.raw_sha256) -Fix 'Regenerate raw ingest output or inspect manual modifications.'
                    $valid = $false
                }
            }
        }

        if ($status -in @('pending', 'pending_stub', 'missing_heading_contentful')) {
            $nonTerminalCount++
        }

        if ($status -eq 'quality_failed') {
            Write-ValidationError -What 'raw-output-manifest contains terminal quality_failed row' -Where "$Path -> $($row.source_id).status" -Expected 'Fix or regenerate quality-failed output before completed-run validation' -Fix 'Inspect failures.csv next_action and rerun ingest after remediation.'
            $valid = $false
        }
    }

    if ($writtenCount -eq 0 -and $nonTerminalCount -eq 0) {
        Write-ValidationError -What 'raw-output-manifest has no written or resumable/review rows' -Where $Path -Expected 'At least one written raw Markdown row or an explicit pending/pending_stub/missing_heading_contentful row' -Fix 'Run mock or real MinerU ingest before full validation.'
        $valid = $false
    }

    return [pscustomobject]@{ Valid = $valid; Rows = @($csv.Rows) }
}

function Test-FailuresCsv {
    param([Parameter(Mandatory = $true)][string]$Path)

    $csv = Read-CsvRowsForValidation -Path $Path -RequiredFields $script:FailureFields -ArtifactName 'failures.csv' -AllowHeaderOnly
    $valid = [bool]$csv.Valid
    foreach ($row in @($csv.Rows)) {
        if ([string]::IsNullOrWhiteSpace([string]$row.error_code)) { continue }
        foreach ($field in @('stage', 'message', 'next_action')) {
            if ([string]::IsNullOrWhiteSpace([string]$row.$field)) {
                Write-ValidationError -What 'failure row lacks remediation detail' -Where "$Path -> $($row.error_code).$field" -Expected 'Failure rows include stage, message, and next_action' -Fix 'Write actionable failure metadata when producing failures.csv.'
                $valid = $false
            }
        }
    }

    return [pscustomobject]@{ Valid = $valid; Rows = @($csv.Rows) }
}

function Test-EvidenceDirectory {
    param([Parameter(Mandatory = $true)][string]$RunDir)

    $evidenceDir = Join-Path -Path $RunDir -ChildPath 'evidence'
    if (-not (Test-Path -LiteralPath $evidenceDir -PathType Container)) {
        Write-ValidationError -What 'Run evidence directory is missing' -Where $evidenceDir -Expected 'RunDir/evidence exists' -Fix 'Create run evidence during the pipeline before final validation.'
        return $false
    }

    $evidenceFiles = @(Get-ChildItem -LiteralPath $evidenceDir -File -Force)
    if ($evidenceFiles.Count -eq 0) {
        Write-ValidationError -What 'Run evidence directory is empty' -Where $evidenceDir -Expected 'At least one evidence file for this run' -Fix 'Write a run-level evidence note before final validation.'
        return $false
    }

    foreach ($file in $evidenceFiles) {
        if ($file.Length -le 0) {
            Write-ValidationError -What 'Run evidence file is empty' -Where $file.FullName -Expected 'Evidence files are non-empty' -Fix 'Write validation evidence or remove empty evidence placeholders.'
            return $false
        }
    }

    return $true
}

try {
    $resolvedRunDir = [System.IO.Path]::GetFullPath($RunDir).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $resolvedConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)
    $valid = $true

    if (-not (Test-Path -LiteralPath $resolvedRunDir -PathType Container)) {
        Write-ValidationError -What 'RunDir does not exist' -Where $resolvedRunDir -Expected 'Existing run directory' -Fix 'Run resolve-config, scan, and proposal before validation.'
        exit 1
    }

    if (-not (Test-Path -LiteralPath $resolvedConfigPath -PathType Leaf)) {
        Write-ValidationError -What 'Config file does not exist' -Where $resolvedConfigPath -Expected 'Existing config.json file' -Fix 'Pass the config used to create this run.'
        exit 1
    }

    foreach ($artifact in $script:ExpectedRunFiles) {
        $path = Join-Path -Path $resolvedRunDir -ChildPath $artifact
        if (-not (Test-RequiredFile -Path $path)) { $valid = $false }
    }

    if (-not (Test-EvidenceDirectory -RunDir $resolvedRunDir)) { $valid = $false }

    $inventoryPath = Join-Path -Path $resolvedRunDir -ChildPath 'inventory.jsonl'
    $inventory = $null
    if (Test-Path -LiteralPath $inventoryPath -PathType Leaf) {
        $inventory = Test-JsonlArtifact -Path $inventoryPath -RequiredFields $script:InventoryFields -ArtifactName 'inventory.jsonl'
        if (-not $inventory.Valid) { $valid = $false }
    }

    foreach ($snapshotName in @('source_snapshot_before.csv', 'source_snapshot_after.csv')) {
        $snapshotPath = Join-Path -Path $resolvedRunDir -ChildPath $snapshotName
        if (Test-Path -LiteralPath $snapshotPath -PathType Leaf) {
            $snapshot = Read-CsvRowsForValidation -Path $snapshotPath -RequiredFields $script:SnapshotFields -ArtifactName $snapshotName
            if (-not $snapshot.Valid) { $valid = $false }
        }
    }

    $diffPath = Join-Path -Path $resolvedRunDir -ChildPath 'source_snapshot_diff.csv'
    if (Test-Path -LiteralPath $diffPath -PathType Leaf) {
        $diff = Read-CsvRowsForValidation -Path $diffPath -RequiredFields $script:DiffFields -ArtifactName 'source_snapshot_diff.csv'
        if (-not $diff.Valid) { $valid = $false }
        foreach ($row in @($diff.Rows)) {
            if (-not ([string]$row.allowed).Equals('true', [System.StringComparison]::OrdinalIgnoreCase)) {
                Write-ValidationError -What 'Source snapshot diff contains a disallowed change' -Where "$diffPath -> $($row.source_id)" -Expected 'allowed=true for every completed-run source diff' -Fix 'Inspect source changes, then rebuild the run from a stable inbox snapshot.'
                $valid = $false
            }
        }
    }

    $planPath = Join-Path -Path $resolvedRunDir -ChildPath 'classification-plan.jsonl'
    if (Test-Path -LiteralPath $planPath -PathType Leaf) {
        $plan = Test-JsonlArtifact -Path $planPath -RequiredFields $script:PlanFields -ArtifactName 'classification-plan.jsonl'
        if (-not $plan.Valid) { $valid = $false }
    }

    $manifestPath = Join-Path -Path $resolvedRunDir -ChildPath 'proposal-manifest.json'
    $manifestResult = $null
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        $manifestResult = Test-ProposalManifest -ManifestPath $manifestPath -ConfigPath $resolvedConfigPath -RunDir $resolvedRunDir
        if (-not $manifestResult.Valid) { $valid = $false }
    }

    $approvalPath = Join-Path -Path $resolvedRunDir -ChildPath 'approval.md'
    if (Test-Path -LiteralPath $approvalPath -PathType Leaf) {
        if (-not (Test-Approval -ApprovalPath $approvalPath -ProposalManifest $manifestResult.Manifest -ConfigPath $resolvedConfigPath -RunDir $resolvedRunDir)) { $valid = $false }
    }

    $applyManifestPath = Join-Path -Path $resolvedRunDir -ChildPath 'apply-manifest.jsonl'
    $applyResult = $null
    if (Test-Path -LiteralPath $applyManifestPath -PathType Leaf) {
        $applyResult = Test-ApplyManifest -Path $applyManifestPath
        if (-not $applyResult.Valid) { $valid = $false }
    }

    $batchPath = Join-Path -Path $resolvedRunDir -ChildPath 'mineru-batch.json'
    if ((Test-Path -LiteralPath $batchPath -PathType Leaf) -and $null -ne $applyResult) {
        $batchResult = Test-MineruBatch -Path $batchPath -LatestApply $applyResult.Latest -RunDir $resolvedRunDir
        if (-not $batchResult.Valid) { $valid = $false }
    }

    $parsePath = Join-Path -Path $resolvedRunDir -ChildPath 'parse-manifest.csv'
    if (Test-Path -LiteralPath $parsePath -PathType Leaf) {
        $parseResult = Test-ParseManifest -Path $parsePath
        if (-not $parseResult.Valid) { $valid = $false }
    }

    $rawPath = Join-Path -Path $resolvedRunDir -ChildPath 'raw-output-manifest.csv'
    if (Test-Path -LiteralPath $rawPath -PathType Leaf) {
        $rawResult = Test-RawManifest -Path $rawPath
        if (-not $rawResult.Valid) { $valid = $false }
    }

    $failuresPath = Join-Path -Path $resolvedRunDir -ChildPath 'failures.csv'
    if (Test-Path -LiteralPath $failuresPath -PathType Leaf) {
        $failuresResult = Test-FailuresCsv -Path $failuresPath
        if (-not $failuresResult.Valid) { $valid = $false }
    }

    if ($valid) {
        Write-Output 'RUN VALIDATION PASSED'
        exit 0
    }

    exit 1
} catch {
    Write-ValidationError -What 'Run validation failed before all checks completed' -Where 'validate-run.ps1' -Expected 'Readable config and complete run artifacts' -Fix $_.Exception.Message
    exit 1
}
