#Requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $true)]
    [string]$RunDir
)

Set-StrictMode -Version Latest

$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$script:RequiredConfigFields = @('inboxRoot', 'archiveRoot', 'rawSourcesRoot', 'reviewRoot', 'themeList', 'scope')
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
$script:HashFields = [ordered]@{
    config_sha256                 = $null
    inventory_sha256              = 'inventory.jsonl'
    source_snapshot_before_sha256 = 'source_snapshot_before.csv'
    classification_plan_sha256    = 'classification-plan.jsonl'
    proposal_manifest_sha256      = 'proposal-manifest.json'
}
$script:RequiredPlanFields = @(
    'source_id',
    'run_id',
    'action',
    'source_abs_path',
    'source_rel_path',
    'source_sha256',
    'target_archive_path'
)
$script:SupportedArchiveExtensions = @(
    '.pdf', '.doc', '.docx', '.ppt', '.pptx', '.xls', '.xlsx',
    '.png', '.jpg', '.jpeg', '.jp2', '.webp', '.gif', '.bmp', '.html', '.htm',
    '.zip', '.txt', '.md'
)

function Write-ApprovalError {
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

function Write-ApplyError {
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

function Convert-ToStablePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    return $Path.Replace('\\', '/')
}

function Write-Utf8NoBomLines {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Lines
    )

    $normalizedLines = @()
    if ($null -ne $Lines) {
        if ($Lines -is [string]) {
            $normalizedLines = @([string]$Lines)
        } elseif ($Lines -is [System.Collections.IEnumerable]) {
            $normalizedLines = @($Lines | ForEach-Object { [string]$_ })
        } else {
            $normalizedLines = @([string]$Lines)
        }
    }

    [System.IO.File]::WriteAllLines($Path, [string[]]$normalizedLines, $script:Utf8NoBom)
}

function Write-Utf8NoBomText {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )

    [System.IO.File]::WriteAllText($Path, $Text, $script:Utf8NoBom)
}

function Resolve-ApprovalConfig {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][string]$RunDir
    )

    $resolvedConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)
    if (-not (Test-Path -LiteralPath $resolvedConfigPath -PathType Leaf)) {
        throw "Config file not found: $resolvedConfigPath"
    }

    $config = Get-Content -LiteralPath $resolvedConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
    foreach ($field in $script:RequiredConfigFields) {
        if (-not $config.ContainsKey($field)) {
            throw "Config is missing required field '$field'."
        }
    }

    $resolvedRunDir = [System.IO.Path]::GetFullPath($RunDir).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $resolvedRunDir -PathType Container)) {
        throw "RunDir does not exist: $resolvedRunDir"
    }

    $runDirName = Split-Path -Path $resolvedRunDir -Leaf
    if ($runDirName -notmatch '^[0-9]{8}-[0-9]{6}-[0-9a-fA-F]{6}$') {
        throw "RunDir leaf '$runDirName' must match YYYYMMDD-HHMMSS-<6hex>."
    }

    return [pscustomobject]@{
        ConfigPath = $resolvedConfigPath
        Scope      = [string]$config['scope']
        RunDir     = $resolvedRunDir
        RunDirName = $runDirName
    }
}

function Ensure-PendingApprovalTemplate {
    param(
        [Parameter(Mandatory = $true)][string]$RunDir,
        [Parameter(Mandatory = $true)][string]$ApprovalPath
    )

    if (Test-Path -LiteralPath $ApprovalPath -PathType Leaf) {
        return $false
    }

    $templatePath = Join-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..\assets') -ChildPath 'approval-template.md'
    if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
        throw "Approval template asset not found: $templatePath"
    }

    $template = Get-Content -LiteralPath $templatePath -Raw -Encoding UTF8
    [System.IO.File]::WriteAllText($ApprovalPath, $template, $script:Utf8NoBom)
    return $true
}

function Convert-ApprovalValueToString {
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
            $result[[string]$key] = Convert-ApprovalValueToString -Value $YamlObject[$key]
        }
        return $result
    }

    foreach ($property in $YamlObject.PSObject.Properties) {
        $result[[string]$property.Name] = Convert-ApprovalValueToString -Value $property.Value
    }
    return $result
}

function Parse-ApprovalFrontmatter {
    param([Parameter(Mandatory = $true)][string]$ApprovalPath)

    $raw = Get-Content -LiteralPath $ApprovalPath -Raw -Encoding UTF8
    $normalized = $raw -replace "`r`n", "`n" -replace "`r", "`n"
    $match = [regex]::Match($normalized, '^---\n(.*?)\n---', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $match.Success) {
        throw 'approval.md is missing YAML frontmatter delimited by ---.'
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

        $fields[$lineMatch.Groups[1].Value] = Convert-ApprovalValueToString -Value $lineMatch.Groups[2].Value
    }

    return $fields
}

function Test-PlaceholderValue {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $true }
    $trimmed = $Value.Trim()
    return $trimmed -match '^(TODO|TBD|PLACEHOLDER|pending|false|<.*>)$'
}

function Test-ApprovalSchema {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Fields,
        [Parameter(Mandatory = $true)][string]$ApprovalPath
    )

    $valid = $true
    foreach ($field in $script:RequiredApprovalFields) {
        if (-not $Fields.ContainsKey($field)) {
            Write-ApprovalError -What 'Approval schema field is missing' -Where "$ApprovalPath -> $field" -Expected 'All 11 approval fields must be present' -Fix 'Regenerate approval.md from the template, then have a human fill the approval values.'
            $valid = $false
        }
    }

    foreach ($field in $Fields.Keys) {
        if ($script:RequiredApprovalFields -notcontains $field) {
            Write-ApprovalError -What 'Approval schema contains an extra field' -Where "$ApprovalPath -> $field" -Expected 'Exactly the 11 approved schema fields and no alternatives' -Fix 'Remove the extra field and use only the documented approval schema.'
            $valid = $false
        }
    }

    return $valid
}

function Test-ApprovalPreflight {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][psobject]$Config)

    $approvalPath = Join-Path -Path ([string]$Config.RunDir) -ChildPath 'approval.md'
    $createdThisRun = Ensure-PendingApprovalTemplate -RunDir ([string]$Config.RunDir) -ApprovalPath $approvalPath
    if ($createdThisRun) {
        Write-ApprovalError -What 'approval.md was missing and a pending template was created' -Where $approvalPath -Expected 'Human-edited approval.md created before apply starts' -Fix 'Review the proposal, fill approval.md manually, and rerun apply-approved-plan.ps1.'
        return $false
    }

    $valid = $true
    try {
        $fields = Parse-ApprovalFrontmatter -ApprovalPath $approvalPath
    } catch {
        Write-ApprovalError -What 'Approval file could not be parsed' -Where $approvalPath -Expected 'YAML frontmatter with 11 flat key-value fields' -Fix $_.Exception.Message
        return $false
    }

    if (-not (Test-ApprovalSchema -Fields $fields -ApprovalPath $approvalPath)) {
        $valid = $false
    }

    if (-not $valid) { return $false }

    if ([string]$fields['status'] -cne 'approved') {
        Write-ApprovalError -What 'Approval status is not valid for apply' -Where "$approvalPath -> status" -Expected 'Human approval value must equal approved' -Fix 'Have the human approver set the status field after reviewing the proposal.'
        $valid = $false
    }

    if (-not ([string]$fields['allow_apply']).Equals('true', [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-ApprovalError -What 'Apply permission is not enabled' -Where "$approvalPath -> allow_apply" -Expected 'allow_apply must equal true' -Fix 'Have the human approver set allow_apply after reviewing the proposal.'
        $valid = $false
    }

    foreach ($field in @('approved_by', 'approved_at')) {
        if (Test-PlaceholderValue -Value ([string]$fields[$field])) {
            Write-ApprovalError -What 'Approval field is empty or placeholder' -Where "$approvalPath -> $field" -Expected 'Non-empty human approval metadata' -Fix "Fill $field with the human approver metadata."
            $valid = $false
        }
    }

    if (-not ([string]$fields['run_id']).Equals([string]$Config.RunDirName, [System.StringComparison]::Ordinal)) {
        Write-ApprovalError -What 'Approval run_id does not match RunDir' -Where "$approvalPath -> run_id" -Expected ([string]$Config.RunDirName) -Fix 'Use the approval.md that belongs to this run directory.'
        $valid = $false
    }

    if (-not ([string]$fields['scope']).Equals([string]$Config.Scope, [System.StringComparison]::Ordinal)) {
        Write-ApprovalError -What 'Approval scope does not match config scope' -Where "$approvalPath -> scope" -Expected ([string]$Config.Scope) -Fix 'Regenerate proposal artifacts for the current config, then approve that run.'
        $valid = $false
    }

    foreach ($entry in $script:HashFields.GetEnumerator()) {
        $field = [string]$entry.Key
        $expectedHash = [string]$fields[$field]
        if ($expectedHash -notmatch '^[0-9a-fA-F]{64}$') {
            Write-ApprovalError -What 'Approval hash is empty, placeholder, or malformed' -Where "$approvalPath -> $field" -Expected '64-character SHA256 hex string' -Fix 'Copy the current artifact SHA256 into approval.md before applying.'
            $valid = $false
            continue
        }

        $artifactPath = if ($null -eq $entry.Value) { [string]$Config.ConfigPath } else { Join-Path -Path ([string]$Config.RunDir) -ChildPath ([string]$entry.Value) }
        if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
            Write-ApprovalError -What 'Artifact referenced by approval hash is missing' -Where $artifactPath -Expected "Existing file for $field" -Fix 'Rerun the scan/proposal pipeline before applying.'
            $valid = $false
            continue
        }

        $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $artifactPath).Hash
        if (-not $actualHash.Equals($expectedHash, [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-ApprovalError -What 'Approval hash does not match current artifact bytes' -Where "$approvalPath -> $field" -Expected "$actualHash for $artifactPath" -Fix 'Do not apply this run. Regenerate/review artifacts or update approval.md after human review.'
            $valid = $false
        }
    }

    return $valid
}

function Resolve-ApplyRuntimeConfig {
    param([Parameter(Mandatory = $true)][string]$ConfigPath)

    $resolvedConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)
    $config = Get-Content -LiteralPath $resolvedConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable

    return [pscustomobject]@{
        ConfigPath     = $resolvedConfigPath
        InboxRoot      = [System.IO.Path]::GetFullPath([string]$config['inboxRoot'])
        ArchiveRoot    = [System.IO.Path]::GetFullPath([string]$config['archiveRoot'])
        RawSourcesRoot = [System.IO.Path]::GetFullPath([string]$config['rawSourcesRoot'])
        ReviewRoot     = [System.IO.Path]::GetFullPath([string]$config['reviewRoot'])
        Scope          = [string]$config['scope']
    }
}

function Test-PathWithinRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Candidate,
        [Parameter(Mandatory = $true)][string]$Root
    )

    $candidateFull = [System.IO.Path]::GetFullPath($Candidate).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    return $candidateFull.Equals($rootFull, [System.StringComparison]::OrdinalIgnoreCase) -or
        $candidateFull.StartsWith($rootFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-PlanSourceId {
    param(
        [Parameter(Mandatory = $true)][string]$SourceRelPath,
        [Parameter(Mandatory = $true)][string]$SourceSha256
    )

    $sha256 = $SourceSha256.ToLowerInvariant()
    $shaPrefix = $sha256.Substring(0, 8)
    $payload = [System.Text.Encoding]::UTF8.GetBytes((Convert-ToStablePath -Path $SourceRelPath) + '|' + $shaPrefix)
    $digest = [System.Security.Cryptography.SHA256]::Create().ComputeHash($payload)
    $hex = ([System.BitConverter]::ToString($digest) -replace '-', '').ToLowerInvariant()
    return 'src_' + $hex.Substring(0, 12) + '_' + $shaPrefix
}

function Read-JsonlObjects {
    param([Parameter(Mandatory = $true)][string]$Path)

    $items = @()
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @()
    }

    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $items += ($line | ConvertFrom-Json)
    }

    return @($items)
}

function New-ApplyManifestEntry {
    param(
        [Parameter(Mandatory = $true)][string]$SourceId,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$State,
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$SourceSha256,
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [AllowNull()][string]$ArchiveSha256,
        [AllowNull()][string]$TempPath,
        [Parameter(Mandatory = $true)][int]$Attempt,
        [AllowNull()][string]$ErrorCode,
        [AllowNull()][string]$Message
    )

    return [ordered]@{
        source_id     = $SourceId
        run_id        = $RunId
        state         = $State
        source_path   = $SourcePath
        source_sha256 = $SourceSha256.ToLowerInvariant()
        archive_path   = $ArchivePath
        archive_sha256 = if ([string]::IsNullOrWhiteSpace($ArchiveSha256)) { $null } else { $ArchiveSha256.ToLowerInvariant() }
        temp_path     = if ([string]::IsNullOrWhiteSpace($TempPath)) { $null } else { $TempPath }
        attempt       = $Attempt
        timestamp     = [DateTime]::UtcNow.ToString('o')
        error_code    = if ([string]::IsNullOrWhiteSpace($ErrorCode)) { $null } else { $ErrorCode }
        message       = if ([string]::IsNullOrWhiteSpace($Message)) { $null } else { $Message }
    }
}

function Get-CurrentSnapshotRow {
    param(
        [Parameter(Mandatory = $true)][object]$InventoryItem,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $exists = Test-Path -LiteralPath $Path -PathType Leaf
    if (-not $exists) {
        return [ordered]@{
            source_id = [string]$InventoryItem.source_id
            rel_path  = [string]$InventoryItem.rel_path
            abs_path  = [string]$InventoryItem.abs_path
            sha256    = ''
            size      = ''
            mtime     = ''
            exists    = $false
        }
    }

    $fileItem = Get-Item -LiteralPath $Path
    return [ordered]@{
        source_id = [string]$InventoryItem.source_id
        rel_path  = [string]$InventoryItem.rel_path
        abs_path  = [string]$InventoryItem.abs_path
        sha256    = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
        size      = [int64]$fileItem.Length
        mtime     = $fileItem.LastWriteTimeUtc.ToString('o')
        exists    = $true
    }
}

function Write-ApplyArtifacts {
    param(
        [Parameter(Mandatory = $true)][string]$RunDir,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$ApplyEntries,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$FailureRows,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$InventoryItems,
        [Parameter(Mandatory = $true)][string]$SnapshotBeforePath
    )

    $applyManifestPath = Join-Path -Path $RunDir -ChildPath 'apply-manifest.jsonl'
    $applyLogPath = Join-Path -Path $RunDir -ChildPath 'apply-log.md'
    $snapshotAfterPath = Join-Path -Path $RunDir -ChildPath 'source_snapshot_after.csv'
    $snapshotDiffPath = Join-Path -Path $RunDir -ChildPath 'source_snapshot_diff.csv'
    $failuresPath = Join-Path -Path $RunDir -ChildPath 'failures.csv'

    $applyManifestLines = @($ApplyEntries | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 8 })
    Write-Utf8NoBomLines -Path $applyManifestPath -Lines ([string[]]$applyManifestLines)

    $applyLogLines = @('# Apply log', '')
    foreach ($entry in $ApplyEntries) {
        $applyLogLines += "- $($entry.timestamp) $($entry.source_id) $($entry.state) $($entry.archive_path)"
        if ($entry.message) {
            $applyLogLines += "  - $($entry.message)"
        }
    }
    Write-Utf8NoBomLines -Path $applyLogPath -Lines ([string[]]$applyLogLines)

    $afterRows = [System.Collections.Generic.List[object]]::new()
    foreach ($inventoryItem in $InventoryItems) {
        $afterRows.Add((Get-CurrentSnapshotRow -InventoryItem $inventoryItem -Path ([string]$inventoryItem.abs_path)))
    }

    $afterLines = @($afterRows | ForEach-Object { [pscustomobject]$_ } | ConvertTo-Csv -NoTypeInformation)
    Write-Utf8NoBomLines -Path $snapshotAfterPath -Lines ([string[]]$afterLines)

    $beforeRows = @()
    if (Test-Path -LiteralPath $SnapshotBeforePath -PathType Leaf) {
        $beforeRows = @(Get-Content -LiteralPath $SnapshotBeforePath -Encoding UTF8 | ConvertFrom-Csv)
    }

    $beforeBySourceId = @{}
    foreach ($row in $beforeRows) {
        $beforeBySourceId[[string]$row.source_id] = $row
    }

    $diffRows = [System.Collections.Generic.List[object]]::new()
    foreach ($row in $afterRows) {
        $beforeRow = $beforeBySourceId[[string]$row.source_id]
        if ($null -eq $beforeRow) {
            $diffRows.Add([ordered]@{
                    source_id      = [string]$row.source_id
                    rel_path       = [string]$row.rel_path
                    before_sha256  = $null
                    after_sha256   = [string]$row.sha256
                    change_type    = 'new'
                    allowed        = $false
                    message        = 'new source appeared after scan'
                })
            continue
        }

        if (-not [bool]$row.exists) {
            $diffRows.Add([ordered]@{
                    source_id      = [string]$row.source_id
                    rel_path       = [string]$row.rel_path
                    before_sha256  = [string]$beforeRow.sha256
                    after_sha256   = $null
                    change_type    = 'missing'
                    allowed        = $false
                    message        = 'source missing after apply'
                })
            continue
        }

        $isUnchanged = ([string]$beforeRow.sha256).Equals([string]$row.sha256, [System.StringComparison]::OrdinalIgnoreCase) -and
            ([string]$beforeRow.size).Equals([string]$row.size, [System.StringComparison]::OrdinalIgnoreCase) -and
            ([string]$beforeRow.mtime).Equals([string]$row.mtime, [System.StringComparison]::OrdinalIgnoreCase)

        $diffRows.Add([ordered]@{
                source_id      = [string]$row.source_id
                rel_path       = [string]$row.rel_path
                before_sha256  = [string]$beforeRow.sha256
                after_sha256   = [string]$row.sha256
                change_type    = if ($isUnchanged) { 'unchanged' } else { 'modified' }
                allowed        = $isUnchanged
                message        = if ($isUnchanged) { 'source retained' } else { 'source changed during apply' }
            })
    }

    $diffLines = @($diffRows | ForEach-Object { [pscustomobject]$_ } | ConvertTo-Csv -NoTypeInformation)
    Write-Utf8NoBomLines -Path $snapshotDiffPath -Lines ([string[]]$diffLines)

    $failureLines = @()
    if ($FailureRows.Count -eq 0) {
        $failureHeader = [pscustomobject]@{
            run_id        = ''
            source_id     = ''
            stage         = ''
            error_code    = ''
            message       = ''
            retryable     = ''
            next_action   = ''
            artifact_path = ''
        } | ConvertTo-Csv -NoTypeInformation
        Write-Utf8NoBomLines -Path $failuresPath -Lines ([string[]]$failureHeader)
    } else {
        $failureLines = @($FailureRows | ForEach-Object { [pscustomobject]$_ } | ConvertTo-Csv -NoTypeInformation)
        Write-Utf8NoBomLines -Path $failuresPath -Lines ([string[]]$failureLines)
    }
}

function Invoke-ApprovedPlanApply {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][psobject]$Config)

    $runDir = [System.IO.Path]::GetFullPath([string]$Config.RunDir)
    $lockPath = Join-Path -Path $runDir -ChildPath '.apply.lock'
    $lockHandle = $null
    $applySucceeded = $true
    $applyEntries = [System.Collections.Generic.List[object]]::new()
    $failureRows = [System.Collections.Generic.List[object]]::new()
    $planItems = @()
    $inventoryItems = @()

    if (Test-Path -LiteralPath $lockPath -PathType Leaf) {
        Write-ApplyError -What '.apply.lock already exists' -Where $lockPath -Expected 'No concurrent apply attempt for this RunDir' -Fix 'Wait for the active apply to finish or remove the stale lock only after verifying the prior run ended.'
        return $false
    }

    try {
        $lockHandle = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)

        $runtimeConfig = Resolve-ApplyRuntimeConfig -ConfigPath ([string]$Config.ConfigPath)
        $inventoryPath = Join-Path -Path $runDir -ChildPath 'inventory.jsonl'
        $snapshotBeforePath = Join-Path -Path $runDir -ChildPath 'source_snapshot_before.csv'
        $planPath = Join-Path -Path $runDir -ChildPath 'classification-plan.jsonl'
        $applyManifestPath = Join-Path -Path $runDir -ChildPath 'apply-manifest.jsonl'

        foreach ($path in @($inventoryPath, $snapshotBeforePath, $planPath)) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                Write-ApplyError -What 'Required run artifact is missing' -Where $path -Expected 'Existing proposal-stage artifact in RunDir' -Fix 'Run scan-inbox.ps1 and build-proposal.ps1 again before applying.'
                return $false
            }
        }

        $inventoryItems = @(Read-JsonlObjects -Path $inventoryPath)
        $planItems = @(Read-JsonlObjects -Path $planPath)

        $existingCommittedBySourceId = @{}
        $existingCommittedExact = @{}
        $existingApplyItems = @(Read-JsonlObjects -Path $applyManifestPath)
        foreach ($entry in $existingApplyItems) {
            $applyEntries.Add($entry)
        }

        foreach ($entry in $existingApplyItems) {
            $entrySourceId = [string]$entry.source_id
            $entryArchivePath = [string]$entry.archive_path
            $entrySourceSha256 = ([string]$entry.source_sha256).ToLowerInvariant()
            $entryState = [string]$entry.state
            if ($entryState -eq 'committed') {
                $existingCommittedBySourceId[$entrySourceId] = $entry
                $existingCommittedExact[("$entrySourceId|$entryArchivePath|$entrySourceSha256")] = $entry
            }
        }

        $attemptBySourceId = @{}
        foreach ($entry in $existingApplyItems) {
            $entrySourceId = [string]$entry.source_id
            $existingAttempt = 0
            if ($attemptBySourceId.ContainsKey($entrySourceId)) {
                $existingAttempt = [int]$attemptBySourceId[$entrySourceId]
            }

            $candidateAttempt = [int]$entry.attempt
            if ($candidateAttempt -gt $existingAttempt) {
                $attemptBySourceId[$entrySourceId] = $candidateAttempt
            }
        }

        $plannedStates = @('archive_only', 'archive_and_raw')
        foreach ($planItem in $planItems) {
            $sourceId = [string]$planItem.source_id
            $runId = [string]$planItem.run_id
            $action = [string]$planItem.action
            $sourcePath = [System.IO.Path]::GetFullPath([string]$planItem.source_abs_path)
            $sourceRelPath = [string]$planItem.source_rel_path
            $sourceSha256 = ([string]$planItem.source_sha256).ToLowerInvariant()
            $targetArchivePath = if ($null -eq $planItem.target_archive_path -or [string]::IsNullOrWhiteSpace([string]$planItem.target_archive_path)) { '' } else { [System.IO.Path]::GetFullPath([string]$planItem.target_archive_path) }
            $tempPath = ''

            $nextAttempt = 1
            if ($attemptBySourceId.ContainsKey($sourceId)) {
                $nextAttempt = [int]$attemptBySourceId[$sourceId] + 1
            }
            $attemptBySourceId[$sourceId] = $nextAttempt

            $applyEntries.Add((New-ApplyManifestEntry -SourceId $sourceId -RunId $runId -State 'planned' -SourcePath $sourcePath -SourceSha256 $sourceSha256 -ArchivePath $targetArchivePath -ArchiveSha256 $null -TempPath $null -Attempt $nextAttempt -ErrorCode $null -Message 'apply candidate queued'))

            if ($action -notin $plannedStates) {
                $applyEntries.Add((New-ApplyManifestEntry -SourceId $sourceId -RunId $runId -State 'skipped' -SourcePath $sourcePath -SourceSha256 $sourceSha256 -ArchivePath $targetArchivePath -ArchiveSha256 $null -TempPath $null -Attempt $nextAttempt -ErrorCode $null -Message "action=$action"))
                continue
            }

            if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
                $applySucceeded = $false
                $errorCode = 'source_missing'
                Write-ApplyError -What 'Source file is missing during apply' -Where $sourcePath -Expected 'Source file still exists at apply time' -Fix 'Restore or re-scan the inbox item, then rebuild the proposal.'
                $applyEntries.Add((New-ApplyManifestEntry -SourceId $sourceId -RunId $runId -State 'preflight_failed' -SourcePath $sourcePath -SourceSha256 $sourceSha256 -ArchivePath $targetArchivePath -ArchiveSha256 $null -TempPath $null -Attempt $nextAttempt -ErrorCode $errorCode -Message 'source file missing'))
                $failureRows.Add([ordered]@{
                        run_id        = $runId
                        source_id     = $sourceId
                        stage         = 'apply'
                        error_code    = $errorCode
                        message       = 'source file missing'
                        retryable     = $true
                        next_action   = 're-scan inbox, rebuild proposal, and re-apply'
                        artifact_path = 'classification-plan.jsonl'
                    })
                break
            }

            if (-not (Test-PathWithinRoot -Candidate $targetArchivePath -Root $runtimeConfig.ArchiveRoot)) {
                $applySucceeded = $false
                $errorCode = 'target_path_escape'
                Write-ApplyError -What 'Target archive path escapes archiveRoot' -Where $targetArchivePath -Expected $runtimeConfig.ArchiveRoot -Fix 'Regenerate the proposal so the target stays inside archiveRoot.'
                $applyEntries.Add((New-ApplyManifestEntry -SourceId $sourceId -RunId $runId -State 'preflight_failed' -SourcePath $sourcePath -SourceSha256 $sourceSha256 -ArchivePath $targetArchivePath -ArchiveSha256 $null -TempPath $null -Attempt $nextAttempt -ErrorCode $errorCode -Message 'target path is outside archiveRoot'))
                $failureRows.Add([ordered]@{
                        run_id        = $runId
                        source_id     = $sourceId
                        stage         = 'apply'
                        error_code    = $errorCode
                        message       = 'target path is outside archiveRoot'
                        retryable     = $false
                        next_action   = 'regenerate proposal with a valid archive path'
                        artifact_path = 'classification-plan.jsonl'
                    })
                break
            }

            $targetExtension = [System.IO.Path]::GetExtension($targetArchivePath).ToLowerInvariant()
            if ($script:SupportedArchiveExtensions -notcontains $targetExtension) {
                $applySucceeded = $false
                $errorCode = 'unsupported_archive_extension'
                Write-ApplyError -What 'Target archive extension is not supported' -Where $targetArchivePath -Expected ($script:SupportedArchiveExtensions -join ', ') -Fix 'Regenerate the proposal with a supported archive target extension.'
                $applyEntries.Add((New-ApplyManifestEntry -SourceId $sourceId -RunId $runId -State 'preflight_failed' -SourcePath $sourcePath -SourceSha256 $sourceSha256 -ArchivePath $targetArchivePath -ArchiveSha256 $null -TempPath $null -Attempt $nextAttempt -ErrorCode $errorCode -Message 'target archive extension is unsupported'))
                $failureRows.Add([ordered]@{
                        run_id        = $runId
                        source_id     = $sourceId
                        stage         = 'apply'
                        error_code    = $errorCode
                        message       = 'target archive extension is unsupported'
                        retryable     = $false
                        next_action   = 'regenerate proposal with a supported archive target extension'
                        artifact_path = 'classification-plan.jsonl'
                    })
                break
            }

            if ((Test-PathWithinRoot -Candidate $sourcePath -Root $runtimeConfig.ArchiveRoot) -or (Test-PathWithinRoot -Candidate $sourcePath -Root $runtimeConfig.RawSourcesRoot) -or (Test-PathWithinRoot -Candidate $sourcePath -Root $runtimeConfig.ReviewRoot)) {
                $applySucceeded = $false
                $errorCode = 'source_path_forbidden_root'
                Write-ApplyError -What 'Source path is inside a forbidden root' -Where $sourcePath -Expected 'Source path outside archiveRoot/rawSourcesRoot/reviewRoot' -Fix 'Move the source back under the inbox root and rebuild the proposal.'
                $applyEntries.Add((New-ApplyManifestEntry -SourceId $sourceId -RunId $runId -State 'preflight_failed' -SourcePath $sourcePath -SourceSha256 $sourceSha256 -ArchivePath $targetArchivePath -ArchiveSha256 $null -TempPath $null -Attempt $nextAttempt -ErrorCode $errorCode -Message 'source path is inside a forbidden root'))
                $failureRows.Add([ordered]@{
                        run_id        = $runId
                        source_id     = $sourceId
                        stage         = 'apply'
                        error_code    = $errorCode
                        message       = 'source path is inside a forbidden root'
                        retryable     = $false
                        next_action   = 'move source back under inboxRoot and re-scan'
                        artifact_path = 'classification-plan.jsonl'
                    })
                break
            }

            $currentSourceSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $sourcePath).Hash.ToLowerInvariant()
            if (-not $currentSourceSha256.Equals($sourceSha256, [System.StringComparison]::OrdinalIgnoreCase)) {
                $applySucceeded = $false
                $errorCode = 'source_hash_changed'
                Write-ApplyError -What 'Source hash changed after proposal freeze' -Where $sourcePath -Expected $sourceSha256 -Fix 'Re-scan and rebuild the proposal after the source stops changing.'
                $applyEntries.Add((New-ApplyManifestEntry -SourceId $sourceId -RunId $runId -State 'preflight_failed' -SourcePath $sourcePath -SourceSha256 $sourceSha256 -ArchivePath $targetArchivePath -ArchiveSha256 $null -TempPath $null -Attempt $nextAttempt -ErrorCode $errorCode -Message 'source hash changed since proposal'))
                $failureRows.Add([ordered]@{
                        run_id        = $runId
                        source_id     = $sourceId
                        stage         = 'apply'
                        error_code    = $errorCode
                        message       = 'source hash changed since proposal'
                        retryable     = $true
                        next_action   = 're-scan inbox and rebuild proposal'
                        artifact_path = 'classification-plan.jsonl'
                    })
                break
            }

            $currentSourceId = Get-PlanSourceId -SourceRelPath $sourceRelPath -SourceSha256 $currentSourceSha256
            if (-not $currentSourceId.Equals($sourceId, [System.StringComparison]::Ordinal)) {
                $applySucceeded = $false
                $errorCode = 'source_id_mismatch'
                Write-ApplyError -What 'Recomputed source_id does not match frozen plan' -Where $sourcePath -Expected $sourceId -Fix 'Re-scan and rebuild the proposal with the current source file bytes.'
                $applyEntries.Add((New-ApplyManifestEntry -SourceId $sourceId -RunId $runId -State 'preflight_failed' -SourcePath $sourcePath -SourceSha256 $sourceSha256 -ArchivePath $targetArchivePath -ArchiveSha256 $null -TempPath $null -Attempt $nextAttempt -ErrorCode $errorCode -Message 'source_id no longer matches source path and hash'))
                $failureRows.Add([ordered]@{
                        run_id        = $runId
                        source_id     = $sourceId
                        stage         = 'apply'
                        error_code    = $errorCode
                        message       = 'source_id no longer matches source path and hash'
                        retryable     = $true
                        next_action   = 're-scan inbox and rebuild proposal'
                        artifact_path = 'classification-plan.jsonl'
                    })
                break
            }

            $exactCommittedKey = "$sourceId|$targetArchivePath|$sourceSha256"
            $exactCommittedMatch = $null
            if ($existingCommittedExact.ContainsKey($exactCommittedKey)) {
                $exactCommittedMatch = $existingCommittedExact[$exactCommittedKey]
            }

            $targetExists = Test-Path -LiteralPath $targetArchivePath -PathType Leaf
            if ($exactCommittedMatch) {
                if (-not $targetExists) {
                    $applySucceeded = $false
                    $errorCode = 'failed_divergent'
                    Write-ApplyError -What 'Committed target is missing on rerun' -Where $targetArchivePath -Expected 'Exact committed archive file must still exist' -Fix 'Restore the committed archive file or rebuild the run from a clean state.'
                    $applyEntries.Add((New-ApplyManifestEntry -SourceId $sourceId -RunId $runId -State 'failed_divergent' -SourcePath $sourcePath -SourceSha256 $sourceSha256 -ArchivePath $targetArchivePath -ArchiveSha256 $null -TempPath $null -Attempt $nextAttempt -ErrorCode $errorCode -Message 'exact committed match exists, but final target is missing'))
                    $failureRows.Add([ordered]@{
                            run_id        = $runId
                            source_id     = $sourceId
                            stage         = 'apply'
                            error_code    = $errorCode
                            message       = 'exact committed match exists, but final target is missing'
                            retryable     = $false
                            next_action   = 'restore archive target and re-validate'
                            artifact_path = 'apply-manifest.jsonl'
                        })
                    break
                }

                $targetHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $targetArchivePath).Hash.ToLowerInvariant()
                if (-not $targetHash.Equals($sourceSha256, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $applySucceeded = $false
                    $errorCode = 'failed_divergent'
                    Write-ApplyError -What 'Committed target diverged from frozen source hash' -Where $targetArchivePath -Expected $sourceSha256 -Fix 'Do not reuse this run. Investigate the archive target and rebuild from a clean state.'
                    $applyEntries.Add((New-ApplyManifestEntry -SourceId $sourceId -RunId $runId -State 'failed_divergent' -SourcePath $sourcePath -SourceSha256 $sourceSha256 -ArchivePath $targetArchivePath -ArchiveSha256 $targetHash -TempPath $null -Attempt $nextAttempt -ErrorCode $errorCode -Message 'exact committed match exists, but target hash diverged'))
                    $failureRows.Add([ordered]@{
                            run_id        = $runId
                            source_id     = $sourceId
                            stage         = 'apply'
                            error_code    = $errorCode
                            message       = 'exact committed match exists, but target hash diverged'
                            retryable     = $false
                            next_action   = 'inspect archive target and resolve divergence'
                            artifact_path = $targetArchivePath
                        })
                    break
                }

                $applyEntries.Add((New-ApplyManifestEntry -SourceId $sourceId -RunId $runId -State 'skipped_existing_committed' -SourcePath $sourcePath -SourceSha256 $sourceSha256 -ArchivePath $targetArchivePath -ArchiveSha256 $targetHash -TempPath $null -Attempt $nextAttempt -ErrorCode $null -Message 'exact committed match already exists'))
                continue
            }

            if ($existingCommittedBySourceId.ContainsKey($sourceId)) {
                $applySucceeded = $false
                $errorCode = 'failed_divergent'
                Write-ApplyError -What 'Rerun divergence detected for committed source_id' -Where $targetArchivePath -Expected 'Same source_id + archive_path + source_sha256 as the prior committed item' -Fix 'Do not continue. Rebuild the run from a clean state or inspect the archive target.'
                $priorCommitted = $existingCommittedBySourceId[$sourceId]
                $applyEntries.Add((New-ApplyManifestEntry -SourceId $sourceId -RunId $runId -State 'failed_divergent' -SourcePath $sourcePath -SourceSha256 $sourceSha256 -ArchivePath $targetArchivePath -ArchiveSha256 ([string]$priorCommitted.archive_sha256) -TempPath $null -Attempt $nextAttempt -ErrorCode $errorCode -Message 'same source_id already committed with a different archive target or hash'))
                $failureRows.Add([ordered]@{
                        run_id        = $runId
                        source_id     = $sourceId
                        stage         = 'apply'
                        error_code    = $errorCode
                        message       = 'same source_id already committed with a different archive target or hash'
                        retryable     = $false
                        next_action   = 'inspect prior committed target and rebuild the run'
                        artifact_path = 'apply-manifest.jsonl'
                    })
                break
            }

            if ($targetExists) {
                $applySucceeded = $false
                $errorCode = 'target_exists'
                Write-ApplyError -What 'Archive target already exists' -Where $targetArchivePath -Expected 'No file at final archive target unless it is an exact committed match' -Fix 'Pick a different proposal or resolve the collision manually before re-applying.'
                $applyEntries.Add((New-ApplyManifestEntry -SourceId $sourceId -RunId $runId -State 'preflight_failed' -SourcePath $sourcePath -SourceSha256 $sourceSha256 -ArchivePath $targetArchivePath -ArchiveSha256 (Get-FileHash -Algorithm SHA256 -LiteralPath $targetArchivePath).Hash.ToLowerInvariant() -TempPath $null -Attempt $nextAttempt -ErrorCode $errorCode -Message 'target archive file already exists'))
                $failureRows.Add([ordered]@{
                        run_id        = $runId
                        source_id     = $sourceId
                        stage         = 'apply'
                        error_code    = $errorCode
                        message       = 'target archive file already exists'
                        retryable     = $false
                        next_action   = 'resolve the archive collision and rebuild the proposal'
                        artifact_path = $targetArchivePath
                    })
                break
            }

            $targetDir = Split-Path -Path $targetArchivePath -Parent
            $targetLeaf = Split-Path -Path $targetArchivePath -Leaf
            if (-not (Test-Path -LiteralPath $targetDir -PathType Container)) {
                New-Item -ItemType Directory -Path $targetDir -Force -ErrorAction Stop | Out-Null
            }
            $tempPath = Join-Path -Path $targetDir -ChildPath ($targetLeaf + '.tmp')

            if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
                Remove-Item -LiteralPath $tempPath -Force -ErrorAction Stop
            }

            try {
                Copy-Item -LiteralPath $sourcePath -Destination $tempPath -ErrorAction Stop
                $applyEntries.Add((New-ApplyManifestEntry -SourceId $sourceId -RunId $runId -State 'copied_temp' -SourcePath $sourcePath -SourceSha256 $sourceSha256 -ArchivePath $targetArchivePath -ArchiveSha256 $null -TempPath $tempPath -Attempt $nextAttempt -ErrorCode $null -Message 'source copied to temp'))

                $tempHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $tempPath).Hash.ToLowerInvariant()
                if (-not $tempHash.Equals($sourceSha256, [System.StringComparison]::OrdinalIgnoreCase)) {
                    Remove-Item -LiteralPath $tempPath -Force -ErrorAction Stop
                    $applySucceeded = $false
                    $errorCode = 'copy_verify_failed'
                    Write-ApplyError -What 'Temp copy hash does not match source hash' -Where $tempPath -Expected $sourceSha256 -Fix 'Inspect the storage volume and rerun the apply after fixing the copy path.'
                    $applyEntries.Add((New-ApplyManifestEntry -SourceId $sourceId -RunId $runId -State 'failed_partial_deleted' -SourcePath $sourcePath -SourceSha256 $sourceSha256 -ArchivePath $targetArchivePath -ArchiveSha256 $null -TempPath $tempPath -Attempt $nextAttempt -ErrorCode $errorCode -Message 'temp copy hash mismatch; temp deleted'))
                    $failureRows.Add([ordered]@{
                            run_id        = $runId
                            source_id     = $sourceId
                            stage         = 'apply'
                            error_code    = $errorCode
                            message       = 'temp copy hash mismatch; temp deleted'
                            retryable     = $true
                            next_action   = 'rerun apply after investigating the copy failure'
                            artifact_path = $tempPath
                        })
                    break
                }

                Rename-Item -LiteralPath $tempPath -NewName $targetLeaf -ErrorAction Stop
                $applyEntries.Add((New-ApplyManifestEntry -SourceId $sourceId -RunId $runId -State 'committed' -SourcePath $sourcePath -SourceSha256 $sourceSha256 -ArchivePath $targetArchivePath -ArchiveSha256 $tempHash -TempPath $null -Attempt $nextAttempt -ErrorCode $null -Message 'atomic rename complete'))

                if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
                    $applySucceeded = $false
                    $errorCode = 'source_missing_post_commit'
                    Write-ApplyError -What 'Source file disappeared after commit' -Where $sourcePath -Expected 'Source file still exists after commit' -Fix 'Restore the source and inspect the apply log. The archive copy is already committed.'
                    $applyEntries.Add((New-ApplyManifestEntry -SourceId $sourceId -RunId $runId -State 'failed' -SourcePath $sourcePath -SourceSha256 $sourceSha256 -ArchivePath $targetArchivePath -ArchiveSha256 $tempHash -TempPath $null -Attempt $nextAttempt -ErrorCode $errorCode -Message 'source missing after commit'))
                    $failureRows.Add([ordered]@{
                            run_id        = $runId
                            source_id     = $sourceId
                            stage         = 'apply'
                            error_code    = $errorCode
                            message       = 'source missing after commit'
                            retryable     = $false
                            next_action   = 'inspect source retention and re-scan the inbox'
                            artifact_path = $targetArchivePath
                        })
                    break
                }

                $postCommitSourceSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $sourcePath).Hash.ToLowerInvariant()
                if (-not $postCommitSourceSha256.Equals($sourceSha256, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $applySucceeded = $false
                    $errorCode = 'source_hash_changed_post_commit'
                    Write-ApplyError -What 'Source hash changed after commit' -Where $sourcePath -Expected $sourceSha256 -Fix 'The archive copy is committed, but the source changed. Re-scan the inbox and review the divergence.'
                    $applyEntries.Add((New-ApplyManifestEntry -SourceId $sourceId -RunId $runId -State 'failed' -SourcePath $sourcePath -SourceSha256 $sourceSha256 -ArchivePath $targetArchivePath -ArchiveSha256 $tempHash -TempPath $null -Attempt $nextAttempt -ErrorCode $errorCode -Message 'source hash changed after commit'))
                    $failureRows.Add([ordered]@{
                            run_id        = $runId
                            source_id     = $sourceId
                            stage         = 'apply'
                            error_code    = $errorCode
                            message       = 'source hash changed after commit'
                            retryable     = $false
                            next_action   = 're-scan the source and inspect the committed archive'
                            artifact_path = $targetArchivePath
                        })
                    break
                }

                $finalArchiveHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $targetArchivePath).Hash.ToLowerInvariant()
                if (-not $finalArchiveHash.Equals($sourceSha256, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $applySucceeded = $false
                    $errorCode = 'target_hash_mismatch'
                    Write-ApplyError -What 'Committed archive hash does not match source hash' -Where $targetArchivePath -Expected $sourceSha256 -Fix 'Investigate the archive target and rerun from a clean state.'
                    $applyEntries.Add((New-ApplyManifestEntry -SourceId $sourceId -RunId $runId -State 'failed' -SourcePath $sourcePath -SourceSha256 $sourceSha256 -ArchivePath $targetArchivePath -ArchiveSha256 $finalArchiveHash -TempPath $null -Attempt $nextAttempt -ErrorCode $errorCode -Message 'committed target hash mismatch'))
                    $failureRows.Add([ordered]@{
                            run_id        = $runId
                            source_id     = $sourceId
                            stage         = 'apply'
                            error_code    = $errorCode
                            message       = 'committed target hash mismatch'
                            retryable     = $false
                            next_action   = 'inspect the archive target for corruption'
                            artifact_path = $targetArchivePath
                        })
                    break
                }
            } catch {
                $tempStillExists = Test-Path -LiteralPath $tempPath -PathType Leaf
                if ($tempStillExists) {
                    Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
                }

                $applySucceeded = $false
                $errorCode = 'failed'
                $exceptionDetails = @(
                    "ExceptionType: $($_.Exception.GetType().FullName)",
                    "Message: $($_.Exception.Message)",
                    "Position: $($_.InvocationInfo.PositionMessage)",
                    "Stack: $($_.ScriptStackTrace)"
                ) -join ' | '
                Write-ApplyError -What 'Apply operation failed during copy or rename' -Where $sourcePath -Expected 'Successful copy, verify, and atomic rename' -Fix $exceptionDetails
                $applyEntries.Add((New-ApplyManifestEntry -SourceId $sourceId -RunId $runId -State 'failed' -SourcePath $sourcePath -SourceSha256 $sourceSha256 -ArchivePath $targetArchivePath -ArchiveSha256 $null -TempPath $tempPath -Attempt $nextAttempt -ErrorCode $errorCode -Message $_.Exception.Message))
                $failureRows.Add([ordered]@{
                        run_id        = $runId
                        source_id     = $sourceId
                        stage         = 'apply'
                        error_code    = $errorCode
                        message       = $_.Exception.Message
                        retryable     = $false
                        next_action   = 'inspect the exception and rerun the apply'
                        artifact_path = $tempPath
                    })
                break
            }
        }

        Write-ApplyArtifacts -RunDir $runDir -ApplyEntries @($applyEntries) -FailureRows @($failureRows) -InventoryItems $inventoryItems -SnapshotBeforePath $snapshotBeforePath

        return $applySucceeded
    } catch {
        $exceptionDetails = @(
            "ExceptionType: $($_.Exception.GetType().FullName)",
            "Message: $($_.Exception.Message)",
            "Position: $($_.InvocationInfo.PositionMessage)",
            "Stack: $($_.ScriptStackTrace)"
        ) -join ' | '
        Write-ApplyError -What 'Apply phase failed before completion' -Where 'apply-approved-plan.ps1' -Expected 'Readable run artifacts and writable RunDir' -Fix $exceptionDetails
        return $false
    } finally {
        if ($null -ne $lockHandle) {
            $lockHandle.Dispose()
        }

        if (Test-Path -LiteralPath $lockPath -PathType Leaf) {
            Remove-Item -LiteralPath $lockPath -Force
        }
    }
}

try {
    $resolvedConfig = Resolve-ApprovalConfig -ConfigPath $ConfigPath -RunDir $RunDir
    if (Test-ApprovalPreflight -Config $resolvedConfig) {
        Write-Output 'APPROVAL VALID — proceeding to apply'
        if (Invoke-ApprovedPlanApply -Config $resolvedConfig) {
            Write-Output 'APPLY COMPLETE'
            exit 0
        }

        Write-Output 'APPLY FAILED'
        exit 1
    }

    exit 1
} catch {
    $exceptionDetails = @(
        "ExceptionType: $($_.Exception.GetType().FullName)",
        "Message: $($_.Exception.Message)",
        "Position: $($_.InvocationInfo.PositionMessage)",
        "Stack: $($_.ScriptStackTrace)"
    ) -join ' | '
    Write-ApprovalError -What 'Approval preflight failed before validation completed' -Where 'apply-approved-plan.ps1' -Expected 'Readable config, run directory, approval.md, and proposal artifacts' -Fix $exceptionDetails
    exit 1
}
