#Requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $true)]
    [string]$RunDir,

    [switch]$MockMode
)

Set-StrictMode -Version Latest

$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$script:RequiredConfigFields = @('inboxRoot', 'archiveRoot', 'rawSourcesRoot', 'reviewRoot', 'themeList', 'scope')
$script:CommittedStates = @('committed', 'skipped_existing_committed')
$script:IllegalFileNameChars = @('\', '/', ':', '*', '?', '"', '<', '>', '|')
$script:ReservedNames = @(
    'CON', 'PRN', 'AUX', 'NUL',
    'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
    'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9'
)
$script:ErrorPlaceholders = @(
    'mineru error',
    'parse failed',
    'parsing failed',
    'traceback',
    'exception:',
    'error placeholder',
    'no content extracted',
    'failed to parse',
    '解析失败'
)
$script:PendingLifecycleStatuses = @('prepared', 'submitted', 'uploaded', 'waiting-file', 'pending', 'running', 'converting', 'pending_timeout', 'stale_pending')
$script:NonTerminalStatuses = @('pending', 'pending_stub', 'missing_heading_contentful')

function Write-IngestError {
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
    param([AllowNull()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    return $Path.Replace('\', '/')
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

    # oracle O8/B5：先写临时文件再原子替换——直接 WriteAllLines 会在写入途中截断既有 manifest，
    # 崩溃即丢合并历史。替换失败时保留旧文件并抛错（绝不删除唯一旧版本换一个可能失败的新写入）。
    $tempPath = "$Path.tmp-$([guid]::NewGuid().ToString('N'))"
    try {
        [System.IO.File]::WriteAllLines($tempPath, [string[]]$normalizedLines, $script:Utf8NoBom)
        [System.IO.File]::Move($tempPath, $Path, $true)
    } finally {
        if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
    }
}

function Write-Utf8NoBomText {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )

    [System.IO.File]::WriteAllText($Path, $Text, $script:Utf8NoBom)
}

function Read-JsonlObjects {
    param([Parameter(Mandatory = $true)][string]$Path)

    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $items.Add(($line | ConvertFrom-Json))
    }

    return @($items)
}

function Read-FailureRows {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    $rows = @(Get-Content -LiteralPath $Path -Encoding UTF8 | ConvertFrom-Csv)
    return @($rows | Where-Object {
            -not ([string]::IsNullOrWhiteSpace([string]$_.run_id) -and
                [string]::IsNullOrWhiteSpace([string]$_.source_id) -and
                [string]::IsNullOrWhiteSpace([string]$_.stage) -and
                [string]::IsNullOrWhiteSpace([string]$_.error_code))
        })
}

function Get-ObjectPropertyValue {
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

    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $record = $line | ConvertFrom-Json
        $sourceId = [string](Get-ObjectPropertyValue -Object $record -Name 'source_id')
        if ([string]::IsNullOrWhiteSpace($sourceId)) { continue }
        $states[$sourceId] = $record
    }

    return $states
}

function Write-FailureRows {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Rows
    )

    if ($Rows.Count -eq 0) {
        $header = [pscustomobject]@{
            run_id        = ''
            source_id     = ''
            stage         = ''
            error_code    = ''
            message       = ''
            retryable     = ''
            next_action   = ''
            artifact_path = ''
        } | ConvertTo-Csv -NoTypeInformation
        Write-Utf8NoBomLines -Path $Path -Lines ([string[]]$header)
        return
    }

    $lines = @($Rows | ForEach-Object { [pscustomobject]$_ } | ConvertTo-Csv -NoTypeInformation)
    Write-Utf8NoBomLines -Path $Path -Lines ([string[]]$lines)
}

function Resolve-IngestConfig {
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
        ConfigPath     = $resolvedConfigPath
        RunDir         = $resolvedRunDir
        RunId          = $runDirName
        RawSourcesRoot = [System.IO.Path]::GetFullPath([string]$config['rawSourcesRoot'])
    }
}

function Get-LatestApplyEntriesBySourceId {
    param([Parameter(Mandatory = $true)][object[]]$ApplyEntries)

    $latest = @{}
    foreach ($entry in $ApplyEntries) {
        $sourceId = [string]$entry.source_id
        if ([string]::IsNullOrWhiteSpace($sourceId)) { continue }
        $latest[$sourceId] = $entry
    }

    return $latest
}

function Get-PlanItemsBySourceId {
    param([Parameter(Mandatory = $true)][object[]]$PlanItems)

    $bySourceId = @{}
    foreach ($item in $PlanItems) {
        $sourceId = [string]$item.source_id
        if ([string]::IsNullOrWhiteSpace($sourceId)) { continue }
        $bySourceId[$sourceId] = $item
    }

    return $bySourceId
}

function Resolve-OutputDirPath {
    param(
        [Parameter(Mandatory = $true)][string]$RunDir,
        [Parameter(Mandatory = $true)][string]$OutputDir
    )

    $candidate = $OutputDir.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
    if ([System.IO.Path]::IsPathRooted($candidate)) {
        return [System.IO.Path]::GetFullPath($candidate)
    }

    $trimmed = $candidate.TrimStart('.', [System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    if ($trimmed.StartsWith('run' + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
        $trimmed = $trimmed.Substring(4)
    }

    return [System.IO.Path]::GetFullPath((Join-Path -Path $RunDir -ChildPath $trimmed))
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

function ConvertTo-SafeFileStem {
    param([Parameter(Mandatory = $true)][string]$Name)

    $safe = $Name.Normalize([System.Text.NormalizationForm]::FormC)
    foreach ($character in $script:IllegalFileNameChars) {
        $safe = $safe.Replace($character, '_')
    }

    $builder = [System.Text.StringBuilder]::new()
    foreach ($character in $safe.ToCharArray()) {
        if ([char]::IsControl($character)) {
            [void]$builder.Append('_')
        } else {
            [void]$builder.Append($character)
        }
    }

    $safe = $builder.ToString().Trim().TrimEnd('.', ' ')
    if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'source' }
    if ($script:ReservedNames -contains $safe.ToUpperInvariant()) { $safe = '_' + $safe }

    return $safe
}

function Get-RawTargetPath {
    param(
        [Parameter(Mandatory = $true)][string]$RawSourcesRoot,
        [Parameter(Mandatory = $true)][string]$Theme,
        [Parameter(Mandatory = $true)][int]$Year,
        [Parameter(Mandatory = $true)][string]$ArchivePath
    )

    $safeStem = ConvertTo-SafeFileStem -Name ([System.IO.Path]::GetFileNameWithoutExtension($ArchivePath))
    $targetDir = [System.IO.Path]::Combine($RawSourcesRoot, $Theme, $Year.ToString())
    if (-not (Test-Path -LiteralPath $targetDir -PathType Container)) {
        New-Item -ItemType Directory -Path $targetDir -Force -ErrorAction Stop | Out-Null
    }

    $suffix = ''
    $index = 1
    do {
        $fileName = $safeStem + $suffix + '.md'
        $candidate = [System.IO.Path]::Combine($targetDir, $fileName)
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return [pscustomobject]@{ Path = $candidate; Suffix = $suffix }
        }

        $index++
        $suffix = "__$index"
    } while ($true)
}

function Test-MarkdownHeading {
    param([Parameter(Mandatory = $true)][string]$Text)
    # LOCAL-PATCH 2026-09-09: 接受 ATX H1-H6（原版仅 H1 误拦 MinerU 对 pptx/pdf 合法 ## 输出）
    # 验证: Z:/91_临时生成物/质量门测试/test-heading.ps1 (10/10); 试点 20/20 闭环
    # 证据: Z:/llmwikivault/.omo/evidence/llmwiki-inbox-ingest-runs/20260909-*/evidence/
    return [regex]::IsMatch(($Text -replace "`r`n", "`n"), '(?m)^#{1,6}\s')
}

function Test-ErrorPlaceholder {
    param([Parameter(Mandatory = $true)][string]$Text)

    $lower = $Text.ToLowerInvariant()
    foreach ($placeholder in $script:ErrorPlaceholders) {
        if ($lower.Contains($placeholder)) { return $true }
    }

    return $false
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

function Test-PendingLifecycleStatus {
    param([AllowNull()][string]$Status)
    return -not [string]::IsNullOrWhiteSpace($Status) -and $script:PendingLifecycleStatuses -contains $Status
}

function Get-NextActionForStatus {
    param(
        [Parameter(Mandatory = $true)][string]$Status,
        [AllowNull()][string]$LifecycleNextAction
    )

    if (-not [string]::IsNullOrWhiteSpace($LifecycleNextAction)) { return $LifecycleNextAction }

    switch ($Status) {
        'pending' { return 'resume the lifecycle runner or extend polling_budget_seconds before raw ingest' }
        'pending_stub' { return 'resubmit this source with the lifecycle runner or extend the poll timeout; do not ingest the stub' }
        'missing_heading_contentful' { return 'review or normalize the Markdown heading before writing to raw sources' }
        'quality_failed' { return 'regenerate MinerU output or inspect the quality flags before raw ingest' }
        default { return 'regenerate MinerU output for this committed archive or remove it from the batch after review' }
    }
}

function Get-ParseStatusForError {
    param([AllowNull()][string]$ErrorCode)

    if ([string]::IsNullOrWhiteSpace($ErrorCode)) { return 'parsed' }
    if ($ErrorCode -in @('pending', 'pending_stub', 'missing_heading_contentful', 'quality_failed')) { return $ErrorCode }
    return 'failed'
}

function Get-RawStatusForError {
    param([AllowNull()][string]$ErrorCode)

    if ([string]::IsNullOrWhiteSpace($ErrorCode)) { return 'written' }
    if ($ErrorCode -in @('pending', 'pending_stub', 'missing_heading_contentful', 'quality_failed')) { return $ErrorCode }
    return 'failed'
}

function Get-FailureStage {
    param([Parameter(Mandatory = $true)][string]$ErrorCode)

    if ($ErrorCode -in @('quality_failed', 'missing_heading_contentful', 'raw_path_escape', 'raw_write_failed', 'raw_target_divergent', 'raw_origin_divergent', 'raw_content_divergent', 'raw_plan_disk_mismatch', 'raw_plan_origin_divergent', 'raw_plan_content_divergent', 'image_name_conflict')) { return 'raw' }
    return 'mineru'
}

function Test-RetryableError {
    param([Parameter(Mandatory = $true)][string]$ErrorCode)
    return $ErrorCode -in @('pending', 'pending_stub', 'mineru_output_missing', 'quality_failed')
}

function New-MockMarkdown {
    param(
        [Parameter(Mandatory = $true)][object]$BatchItem,
        [Parameter(Mandatory = $true)][object]$PlanItem
    )

    $paragraph = 'This mock MinerU extraction is intentionally long enough to pass the raw quality gate. It represents extracted document content for fixture verification and does not call any external MinerU service. The text preserves provenance through the batch item and committed archive path. '
    $body = ($paragraph * 8)
    return @(
        "# Mock MinerU extraction for $([string]$BatchItem.source_id)",
        '',
        "Source ID: $([string]$BatchItem.source_id)",
        "Theme: $([string]$PlanItem.target_theme)",
        "Year: $([string]$PlanItem.target_year)",
        '',
        $body
    ) -join "`n"
}

function New-FrontmatterMarkdown {
    param(
        [Parameter(Mandatory = $true)][object]$BatchItem,
        [Parameter(Mandatory = $true)][object]$ApplyEntry,
        [Parameter(Mandatory = $true)][object]$PlanItem,
        [Parameter(Mandatory = $true)][string]$Markdown,
        [AllowEmptyString()][string]$ParsedDate = ''
    )

    $archivePath = Convert-ToStablePath -Path ([System.IO.Path]::GetFullPath([string]$ApplyEntry.archive_path))
    $sourceType = ([System.IO.Path]::GetExtension($archivePath)).TrimStart('.').ToLowerInvariant()
    # 幂等重算：当已有 raw 落盘记录时复用原 parsed_date，保证同输入产出字节级一致的内容哈希
    $parsedDate = if (-not [string]::IsNullOrWhiteSpace($ParsedDate)) { $ParsedDate } else { [DateTime]::UtcNow.ToString('o') }
    $frontmatter = @(
        '---',
        "source_id: `"$([string]$BatchItem.source_id)`"",
        "run_id: `"$([string]$ApplyEntry.run_id)`"",
        "source_file: `"$archivePath`"",
        "archive_path: `"$archivePath`"",
        "source_type: `"$sourceType`"",
        "theme: `"$([string]$PlanItem.target_theme)`"",
        "year: $([int]$PlanItem.target_year)",
        "parsed_date: `"$parsedDate`"",
        'status: "raw-parsed"',
        "source_sha256: `"$(([string]$ApplyEntry.archive_sha256).ToLowerInvariant())`"",
        "ingest_run: `"$([string]$ApplyEntry.run_id)`"",
        'review_status: "pending_review"',
        '---',
        ''
    ) -join "`n"

    return $frontmatter + $Markdown
}

function Get-TextSha256Hex {
    param([Parameter(Mandatory = $true)][string]$Text)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha256.ComputeHash($script:Utf8NoBom.GetBytes($Text))
        return -join ($hashBytes | ForEach-Object { $_.ToString('x2') })
    } finally {
        $sha256.Dispose()
    }
}

function Read-RawJournalLatestBySourceId {
    param([Parameter(Mandatory = $true)][string]$Path)

    $latest = @{}
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $latest }
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $event = $line | ConvertFrom-Json
        $sourceId = [string](Get-ObjectPropertyValue -Object $event -Name 'source_id')
        if ([string]::IsNullOrWhiteSpace($sourceId)) { continue }
        $latest[$sourceId] = $event
    }
    return $latest
}

function Add-RawJournalEvent {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$SourceId,
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [Parameter(Mandatory = $true)][string]$ContentSha256,
        [Parameter(Mandatory = $true)][ValidateSet('planned', 'written')][string]$State
    )

    $event = [ordered]@{
        source_id      = $SourceId
        target_path    = $TargetPath
        content_sha256 = $ContentSha256
        state          = $State
        ts             = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($event | ConvertTo-Json -Compress) + "`n")
    $stream = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } finally {
        $stream.Dispose()
    }
}

function Get-RawFrontmatterValue {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    if ($text -notmatch '(?s)\A---\r?\n(.*?)\r?\n---') { return $null }
    $frontmatter = $Matches[1]
    $pattern = '(?m)^\s*' + [regex]::Escape($Name) + ':\s*"?([^"\r\n]*)"?\s*$'
    if ($frontmatter -match $pattern) { return $Matches[1].Trim() }
    return $null
}

function Remove-StaleRawTempFiles {
    param([Parameter(Mandatory = $true)][string]$FinalPath)

    $parent = Split-Path -Path $FinalPath -Parent
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { return }
    $leaf = Split-Path -Path $FinalPath -Leaf
    foreach ($tempFile in @(Get-ChildItem -LiteralPath $parent -File -Filter ($leaf + '.tmp-*') -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $tempFile.FullName -Force -ErrorAction SilentlyContinue
    }
}

function Write-RawTextAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256
    )

    Remove-StaleRawTempFiles -FinalPath $TargetPath
    $bytes = $script:Utf8NoBom.GetBytes($Text)
    $tempPath = $TargetPath + '.tmp-' + [guid]::NewGuid().ToString('N')
    $stream = [System.IO.FileStream]::new($tempPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } finally {
        $stream.Dispose()
    }

    try {
        $tempHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $tempPath).Hash.ToLowerInvariant()
        if (-not $tempHash.Equals($ExpectedSha256, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "atomic temp verification failed for $TargetPath (expected $ExpectedSha256, temp has $tempHash)"
        }
        [System.IO.File]::Move($tempPath, $TargetPath)
    } catch {
        if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
        throw
    }

    return $ExpectedSha256
}

function Find-MarkdownLocalImageRefs {
    param([Parameter(Mandatory = $true)][string]$Text)

    $refs = [System.Collections.Generic.List[string]]::new()
    foreach ($match in [regex]::Matches($Text, '!\[[^\]]*\]\(\s*([^)\s]+)(?:\s+"[^"]*")?\s*\)')) {
        $refs.Add([string]$match.Groups[1].Value)
    }
    foreach ($match in [regex]::Matches($Text, '(?i)<img\s[^>]*?src\s*=\s*(?:"([^"]+)"|''([^'']+)'')')) {
        if (-not [string]::IsNullOrWhiteSpace([string]$match.Groups[1].Value)) {
            $refs.Add([string]$match.Groups[1].Value)
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$match.Groups[2].Value)) {
            $refs.Add([string]$match.Groups[2].Value)
        }
    }

    return @($refs | Where-Object {
            $value = [string]$_
            -not [string]::IsNullOrWhiteSpace($value) -and
            -not ($value -cmatch '^[A-Za-z][A-Za-z0-9+.-]*:') -and
            -not $value.StartsWith('//') -and
            -not $value.StartsWith('\') -and
            -not $value.StartsWith('#')
        } | Select-Object -Unique)
}

function Copy-RawImageAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestPath
    )

    $sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $SourcePath).Hash.ToLowerInvariant()
    if (Test-Path -LiteralPath $DestPath -PathType Leaf) {
        $destHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $DestPath).Hash.ToLowerInvariant()
        if ($destHash.Equals($sourceHash, [System.StringComparison]::OrdinalIgnoreCase)) { return 'skipped_existing' }
        return 'conflict'
    }

    $parent = Split-Path -Path $DestPath -Parent
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
    }
    Remove-StaleRawTempFiles -FinalPath $DestPath
    $bytes = [System.IO.File]::ReadAllBytes($SourcePath)
    $tempPath = $DestPath + '.tmp-' + [guid]::NewGuid().ToString('N')
    $stream = [System.IO.FileStream]::new($tempPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } finally {
        $stream.Dispose()
    }

    try {
        $tempHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $tempPath).Hash.ToLowerInvariant()
        if (-not $tempHash.Equals($sourceHash, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "image temp verification failed for $DestPath"
        }
        [System.IO.File]::Move($tempPath, $DestPath)
        return 'copied'
    } catch {
        if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
        if ((Test-Path -LiteralPath $DestPath -PathType Leaf) -and
            ((Get-FileHash -Algorithm SHA256 -LiteralPath $DestPath).Hash.ToLowerInvariant()).Equals($sourceHash, [System.StringComparison]::OrdinalIgnoreCase)) {
            return 'skipped_existing'
        }
        throw
    }
}

function Copy-RawImageDependencies {
    param(
        [Parameter(Mandatory = $true)][string]$Markdown,
        [Parameter(Mandatory = $true)][string]$OutputDir,
        [Parameter(Mandatory = $true)][string]$TargetDir,
        [Parameter(Mandatory = $true)][string]$RawSourcesRoot,
        [Parameter(Mandatory = $true)][string]$RunDir
    )

    $copied = 0
    $skipped = 0
    foreach ($ref in @(Find-MarkdownLocalImageRefs -Text $Markdown)) {
        $relative = $ref.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        $sourcePath = $null
        foreach ($baseDir in @($OutputDir, (Split-Path -Path $OutputDir -Parent))) {
            $candidate = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($baseDir, $relative))
            if ((Test-PathWithinRoot -Candidate $candidate -Root $RunDir) -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                $sourcePath = $candidate
                break
            }
        }
        if ($null -eq $sourcePath) { continue }

        $destPath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($TargetDir, $relative))
        if (-not (Test-PathWithinRoot -Candidate $destPath -Root $RawSourcesRoot)) {
            return [pscustomobject]@{
                Ok = $false; ErrorCode = 'raw_path_escape'; Copied = $copied; Skipped = $skipped
                Message = "image reference '$ref' escapes rawSourcesRoot"
            }
        }

        $result = Copy-RawImageAtomic -SourcePath $sourcePath -DestPath $destPath
        switch ($result) {
            'copied' { $copied++ }
            'skipped_existing' { $skipped++ }
            'conflict' {
                return [pscustomobject]@{
                    Ok = $false; ErrorCode = 'image_name_conflict'; Copied = $copied; Skipped = $skipped
                    Message = "image target exists with a different content hash (manual adjudication required): $destPath"
                }
            }
        }
    }

    return [pscustomobject]@{
        Ok = $true; ErrorCode = $null; Copied = $copied; Skipped = $skipped
        Message = "images copied=$copied skipped_hash_dedupe=$skipped"
    }
}

try {
    $config = Resolve-IngestConfig -ConfigPath $ConfigPath -RunDir $RunDir
    $batchPath = Join-Path -Path ([string]$config.RunDir) -ChildPath 'mineru-batch.json'
    $applyManifestPath = Join-Path -Path ([string]$config.RunDir) -ChildPath 'apply-manifest.jsonl'
    $classificationPlanPath = Join-Path -Path ([string]$config.RunDir) -ChildPath 'classification-plan.jsonl'
    $parseManifestPath = Join-Path -Path ([string]$config.RunDir) -ChildPath 'parse-manifest.csv'
    $rawManifestPath = Join-Path -Path ([string]$config.RunDir) -ChildPath 'raw-output-manifest.csv'
    $failuresPath = Join-Path -Path ([string]$config.RunDir) -ChildPath 'failures.csv'

    foreach ($artifactPath in @($batchPath, $applyManifestPath, $classificationPlanPath)) {
        if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
            Write-IngestError -What 'Required run artifact is missing' -Where $artifactPath -Expected 'Existing MinerU batch, apply manifest, and classification plan in RunDir' -Fix 'Run apply-approved-plan.ps1 and prepare-mineru-batch.ps1 before raw ingest.'
            exit 1
        }
    }

    # raw 侧加锁（沿用 .apply.lock 语义）：已存在即拒绝并发执行，结束时（含异常与 exit 路径）释放并删除
    $rawLockPath = Join-Path -Path ([string]$config.RunDir) -ChildPath '.raw-ingest.lock'
    if (Test-Path -LiteralPath $rawLockPath -PathType Leaf) {
        Write-IngestError -What '.raw-ingest.lock already exists' -Where $rawLockPath -Expected 'No concurrent raw ingest attempt for this RunDir' -Fix 'Wait for the active raw ingest to finish, or remove the stale lock only after verifying the prior run ended.'
        exit 1
    }
    $rawLockHandle = [System.IO.File]::Open($rawLockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)

    try {
        $batch = Get-Content -LiteralPath $batchPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $statePathValue = [string](Get-ObjectPropertyValue -Object $batch -Name 'state_path')
        $lifecycleStatePath = Resolve-RunArtifactPath -RunDir ([string]$config.RunDir) -Path $statePathValue -DefaultLeaf 'lifecycle-state.jsonl'
        $lifecycleStates = Read-LifecycleStatesBySourceId -Path $lifecycleStatePath
        $applyEntries = @(Read-JsonlObjects -Path $applyManifestPath)
        $planItems = @(Read-JsonlObjects -Path $classificationPlanPath)
        $latestApply = Get-LatestApplyEntriesBySourceId -ApplyEntries $applyEntries
        $planBySourceId = Get-PlanItemsBySourceId -PlanItems $planItems

        # 契约 §4：raw-journal.jsonl 逐项 write-ahead 日志（latest 生效），持久化 source_id → raw 路径与内容哈希
        $rawJournalPath = Join-Path -Path ([string]$config.RunDir) -ChildPath 'raw-journal.jsonl'
        $rawJournalLatest = Read-RawJournalLatestBySourceId -Path $rawJournalPath

        # 旧 parse/raw manifest 合并追加（禁止清空或覆盖历史行）
        $parseRows = [System.Collections.Generic.List[object]]::new()
        $rawRows = [System.Collections.Generic.List[object]]::new()
        $failureRows = [System.Collections.Generic.List[object]]::new()
        $currentRawRows = [System.Collections.Generic.List[object]]::new()
        if (Test-Path -LiteralPath $parseManifestPath -PathType Leaf) {
            foreach ($existingRow in @(Get-Content -LiteralPath $parseManifestPath -Encoding UTF8 | ConvertFrom-Csv)) {
                $parseRows.Add($existingRow)
            }
        }
        if (Test-Path -LiteralPath $rawManifestPath -PathType Leaf) {
            foreach ($existingRow in @(Get-Content -LiteralPath $rawManifestPath -Encoding UTF8 | ConvertFrom-Csv)) {
                $rawRows.Add($existingRow)
            }
        }
        $batchSourceIds = @($batch.items | ForEach-Object { [string]$_.source_id })
        foreach ($row in @(Read-FailureRows -Path $failuresPath)) {
            if ($batchSourceIds -contains [string]$row.source_id -and [string]$row.stage -in @('mineru', 'raw')) { continue }
            $failureRows.Add($row)
        }

        foreach ($item in @($batch.items)) {
            $sourceId = [string]$item.source_id
            $outputDir = Resolve-OutputDirPath -RunDir ([string]$config.RunDir) -OutputDir ([string]$item.output_dir)
            $outputPath = Join-Path -Path $outputDir -ChildPath "$sourceId.md"
            $route = if ($MockMode) { 'mock' } else { [string]$item.mineru_route }
            $validationFlags = [System.Collections.Generic.List[string]]::new()
            $errorCode = $null
            $message = ''
            $nextAction = ''

            if (-not $latestApply.ContainsKey($sourceId)) {
                $errorCode = 'source_id_mismatch'
                $message = 'batch source_id has no matching apply-manifest entry'
            } elseif (-not ($script:CommittedStates -contains [string]$latestApply[$sourceId].state)) {
                $errorCode = 'source_not_committed'
                $message = 'batch item does not point at a committed apply-manifest state'
            } elseif (-not $planBySourceId.ContainsKey($sourceId)) {
                $errorCode = 'source_id_mismatch'
                $message = 'batch source_id has no matching classification-plan row'
            } elseif (-not ([string]$latestApply[$sourceId].archive_sha256).Equals([string]$item.archive_sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
                $errorCode = 'archive_sha_mismatch'
                $message = 'batch archive_sha256 differs from committed apply-manifest archive_sha256'
            } elseif (-not (Split-Path -Path $outputDir -Leaf).Equals($sourceId, [System.StringComparison]::Ordinal)) {
                $errorCode = 'source_id_mismatch'
                $message = 'batch output_dir leaf does not match source_id'
            }

            $applyEntry = if ($latestApply.ContainsKey($sourceId)) { $latestApply[$sourceId] } else { $null }
            $planItem = if ($planBySourceId.ContainsKey($sourceId)) { $planBySourceId[$sourceId] } else { $null }
            $lifecycleState = if ($lifecycleStates.ContainsKey($sourceId)) { $lifecycleStates[$sourceId] } else { $null }
            $lifecycleStatus = [string](Get-ObjectPropertyValue -Object $lifecycleState -Name 'status')
            $lifecycleNextAction = [string](Get-ObjectPropertyValue -Object $lifecycleState -Name 'next_action')

            if ($null -eq $errorCode -and $MockMode) {
                if (-not (Test-Path -LiteralPath $outputDir -PathType Container)) {
                    New-Item -ItemType Directory -Path $outputDir -Force -ErrorAction Stop | Out-Null
                }
                Write-Utf8NoBomText -Path $outputPath -Text (New-MockMarkdown -BatchItem $item -PlanItem $planItem)
            }

            $markdown = ''
            $contentBytes = 0
            $hasHeading = $false
            if ($null -eq $errorCode) {
                if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
                    if (Test-PendingLifecycleStatus -Status $lifecycleStatus) {
                        $errorCode = 'pending'
                        $message = "MinerU lifecycle state is $lifecycleStatus; output has not been downloaded yet"
                        $nextAction = Get-NextActionForStatus -Status 'pending' -LifecycleNextAction $lifecycleNextAction
                    } else {
                        $errorCode = 'mineru_output_missing'
                        $message = "MinerU output $sourceId.md is missing"
                        $nextAction = Get-NextActionForStatus -Status $errorCode -LifecycleNextAction $null
                    }
                } else {
                    $markdown = Get-Content -LiteralPath $outputPath -Raw -Encoding UTF8
                    $contentBytes = [System.Text.Encoding]::UTF8.GetByteCount($markdown)
                    $hasHeading = Test-MarkdownHeading -Text $markdown
                    if (Test-PendingStubMarkdown -Text $markdown -SourceId $sourceId -ContentBytes $contentBytes) {
                        $validationFlags.Add('pending_stub')
                        $errorCode = 'pending_stub'
                        $message = 'MinerU markdown is the pending placeholder stub, not a parsed output'
                        $nextAction = Get-NextActionForStatus -Status $errorCode -LifecycleNextAction $lifecycleNextAction
                    } else {
                        if ($contentBytes -le 500) { $validationFlags.Add('content_bytes_le_500') }
                        if (-not $hasHeading) { $validationFlags.Add('missing_heading') }
                        if (Test-ErrorPlaceholder -Text $markdown) { $validationFlags.Add('error_placeholder') }

                        if ($contentBytes -gt 500 -and -not $hasHeading -and -not (Test-ErrorPlaceholder -Text $markdown)) {
                            $errorCode = 'missing_heading_contentful'
                            $message = 'MinerU markdown has content but no Markdown heading; route to normalization review'
                            $nextAction = Get-NextActionForStatus -Status $errorCode -LifecycleNextAction $null
                        } elseif ($validationFlags.Count -gt 0) {
                            $errorCode = 'quality_failed'
                            $message = 'MinerU markdown failed raw quality gate: ' + ($validationFlags -join ';')
                            $nextAction = Get-NextActionForStatus -Status $errorCode -LifecycleNextAction $null
                        }
                    }
                }
            }

            if ($null -eq $errorCode -and $applyEntry) {
                $archivePath = [System.IO.Path]::GetFullPath([string]$applyEntry.archive_path)
                if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
                    $errorCode = 'archive_missing'
                    $message = 'committed archive file is missing during raw ingest'
                } else {
                    $archiveHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archivePath).Hash.ToLowerInvariant()
                    if (-not $archiveHash.Equals([string]$applyEntry.archive_sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $errorCode = 'archive_sha_mismatch'
                        $message = 'committed archive file hash differs from apply-manifest archive_sha256'
                    }
                }
            }

            if ($null -eq $errorCode) {
                $theme = [string]$planItem.target_theme
                $year = [int]$planItem.target_year
                $journalEvent = if ($rawJournalLatest.ContainsKey($sourceId)) { $rawJournalLatest[$sourceId] } else { $null }
                $journalState = [string](Get-ObjectPropertyValue -Object $journalEvent -Name 'state')
                $journalTargetStable = [string](Get-ObjectPropertyValue -Object $journalEvent -Name 'target_path')
                $journalHash = [string](Get-ObjectPropertyValue -Object $journalEvent -Name 'content_sha256')

                if ($journalState -eq 'written') {
                    # 幂等重跑：来源 + 哈希双验通过 → skip（不重写、不产生 __N 副本）
                    $journalTarget = [System.IO.Path]::GetFullPath($journalTargetStable.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
                    if (-not (Test-PathWithinRoot -Candidate $journalTarget -Root ([string]$config.RawSourcesRoot))) {
                        $errorCode = 'raw_path_escape'
                        $message = 'journal target_path escapes rawSourcesRoot'
                    } elseif (-not (Test-Path -LiteralPath $journalTarget -PathType Leaf)) {
                        $errorCode = 'raw_target_divergent'
                        $message = "journal says written but raw target is missing (manual adjudication required): $journalTargetStable"
                    } else {
                        $diskHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $journalTarget).Hash.ToLowerInvariant()
                        $frontmatterSourceSha = [string](Get-RawFrontmatterValue -Path $journalTarget -Name 'source_sha256')
                        if (-not $diskHash.Equals($journalHash, [System.StringComparison]::OrdinalIgnoreCase)) {
                            $errorCode = 'raw_target_divergent'
                            $message = "raw target on disk no longer matches the journal content hash (manual adjudication required): $journalTargetStable"
                        } elseif (-not $frontmatterSourceSha.Equals(([string]$applyEntry.archive_sha256).ToLowerInvariant(), [System.StringComparison]::OrdinalIgnoreCase)) {
                            $errorCode = 'raw_origin_divergent'
                            $message = 'existing raw target was written from a different archive lineage; manual adjudication required (no overwrite, no renamed copy)'
                        } else {
                            $preservedParsedDate = [string](Get-RawFrontmatterValue -Path $journalTarget -Name 'parsed_date')
                            $regeneratedMarkdown = New-FrontmatterMarkdown -BatchItem $item -ApplyEntry $applyEntry -PlanItem $planItem -Markdown $markdown -ParsedDate $preservedParsedDate
                            $regeneratedHash = Get-TextSha256Hex -Text $regeneratedMarkdown
                            if (-not $regeneratedHash.Equals($journalHash, [System.StringComparison]::OrdinalIgnoreCase)) {
                                $errorCode = 'raw_content_divergent'
                                $message = 'same source_id produced different raw content than the journal record; manual adjudication required (no overwrite, no renamed copy)'
                            } else {
                                $imageResult = Copy-RawImageDependencies -Markdown $markdown -OutputDir $outputDir -TargetDir (Split-Path -Path $journalTarget -Parent) -RawSourcesRoot ([string]$config.RawSourcesRoot) -RunDir ([string]$config.RunDir)
                                if (-not $imageResult.Ok) {
                                    $errorCode = [string]$imageResult.ErrorCode
                                    $message = [string]$imageResult.Message
                                } else {
                                    $currentRawRows.Add([ordered]@{
                                            source_id        = $sourceId
                                            run_id           = [string]$applyEntry.run_id
                                            archive_path     = Convert-ToStablePath -Path ([System.IO.Path]::GetFullPath([string]$applyEntry.archive_path))
                                            archive_sha256   = ([string]$applyEntry.archive_sha256).ToLowerInvariant()
                                            raw_path         = Convert-ToStablePath -Path $journalTarget
                                            raw_sha256       = $journalHash.ToLowerInvariant()
                                            collision_suffix = $null
                                            status           = 'skipped'
                                            message          = 'skipped_idempotent_written; ' + [string]$imageResult.Message
                                        })
                                }
                            }
                        }
                    }
                } else {
                    $recoveryHandled = $false
                    if ($journalState -eq 'planned') {
                        # 崩溃于“已落盘未记 written”：按 target 实际哈希反向核验后补记 written，不重复写
                        $journalTarget = [System.IO.Path]::GetFullPath($journalTargetStable.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
                        if (-not (Test-PathWithinRoot -Candidate $journalTarget -Root ([string]$config.RawSourcesRoot))) {
                            $errorCode = 'raw_path_escape'
                            $message = 'journal target_path escapes rawSourcesRoot'
                            $recoveryHandled = $true
                        } elseif (Test-Path -LiteralPath $journalTarget -PathType Leaf) {
                            $diskHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $journalTarget).Hash.ToLowerInvariant()
                            if (-not $diskHash.Equals($journalHash, [System.StringComparison]::OrdinalIgnoreCase)) {
                                # oracle O8：盘上内容与 journal 计划哈希不符 → 人工裁决
                                $errorCode = 'raw_plan_disk_mismatch'
                                $message = "planned raw target exists with a different content hash (manual adjudication required): $journalTargetStable"
                            } else {
                                # oracle O8：补记 written 前复用 written 分支的双重核验——
                                # 盘上文件必须确实来自当前档案世系（frontmatter source_sha256），
                                # 且当前输入重建内容须与 journal 哈希一致（防"旧正文记作新来源成功"）
                                $frontmatterSourceSha = [string](Get-RawFrontmatterValue -Path $journalTarget -Name 'source_sha256')
                                if (-not $frontmatterSourceSha.Equals(([string]$applyEntry.archive_sha256).ToLowerInvariant(), [System.StringComparison]::OrdinalIgnoreCase)) {
                                    $errorCode = 'raw_plan_origin_divergent'
                                    $message = "planned raw target was written from a different archive lineage (manual adjudication required): $journalTargetStable"
                                } else {
                                    $preservedParsedDate = [string](Get-RawFrontmatterValue -Path $journalTarget -Name 'parsed_date')
                                    $recoveredMarkdown = New-FrontmatterMarkdown -BatchItem $item -ApplyEntry $applyEntry -PlanItem $planItem -Markdown $markdown -ParsedDate $preservedParsedDate
                                    $recoveredHash = Get-TextSha256Hex -Text $recoveredMarkdown
                                    if (-not $recoveredHash.Equals($journalHash, [System.StringComparison]::OrdinalIgnoreCase)) {
                                        $errorCode = 'raw_plan_content_divergent'
                                        $message = "current source regenerates different content than the journal plan (manual adjudication required): $journalTargetStable"
                                    } else {
                                        Add-RawJournalEvent -Path $rawJournalPath -SourceId $sourceId -TargetPath $journalTargetStable -ContentSha256 $journalHash -State 'written'
                                        $imageResult = Copy-RawImageDependencies -Markdown $markdown -OutputDir $outputDir -TargetDir (Split-Path -Path $journalTarget -Parent) -RawSourcesRoot ([string]$config.RawSourcesRoot) -RunDir ([string]$config.RunDir)
                                        if (-not $imageResult.Ok) {
                                            $errorCode = [string]$imageResult.ErrorCode
                                            $message = [string]$imageResult.Message
                                        } else {
                                            $currentRawRows.Add([ordered]@{
                                                    source_id        = $sourceId
                                                    run_id           = [string]$applyEntry.run_id
                                                    archive_path     = Convert-ToStablePath -Path ([System.IO.Path]::GetFullPath([string]$applyEntry.archive_path))
                                                    archive_sha256   = ([string]$applyEntry.archive_sha256).ToLowerInvariant()
                                                    raw_path         = Convert-ToStablePath -Path $journalTarget
                                                    raw_sha256       = $diskHash
                                                    collision_suffix = $null
                                                    status           = 'written'
                                                    message          = 'raw written recovered from journal plan verification (origin+content double-checked); ' + [string]$imageResult.Message
                                                })
                                        }
                                    }
                                }
                            }
                            $recoveryHandled = $true
                        }
                        # planned 但尚未落盘：按全新写入重跑（重新 planned → 原子落盘 → written）
                    }

                    if (-not $recoveryHandled -and $null -eq $errorCode) {
                        $target = Get-RawTargetPath -RawSourcesRoot ([string]$config.RawSourcesRoot) -Theme $theme -Year $year -ArchivePath ([string]$applyEntry.archive_path)
                        if (-not (Test-PathWithinRoot -Candidate ([string]$target.Path) -Root ([string]$config.RawSourcesRoot)) ) {
                            $errorCode = 'raw_path_escape'
                            $message = 'computed raw target path escapes rawSourcesRoot'
                        } else {
                            $rawMarkdown = New-FrontmatterMarkdown -BatchItem $item -ApplyEntry $applyEntry -PlanItem $planItem -Markdown $markdown
                            $rawHash = Get-TextSha256Hex -Text $rawMarkdown
                            # write-ahead：先记 planned（含 target 与内容哈希）并 fsync，再原子落盘，最后记 written
                            Add-RawJournalEvent -Path $rawJournalPath -SourceId $sourceId -TargetPath (Convert-ToStablePath -Path ([string]$target.Path)) -ContentSha256 $rawHash -State 'planned'
                            $imageResult = Copy-RawImageDependencies -Markdown $markdown -OutputDir $outputDir -TargetDir (Split-Path -Path ([string]$target.Path) -Parent) -RawSourcesRoot ([string]$config.RawSourcesRoot) -RunDir ([string]$config.RunDir)
                            if (-not $imageResult.Ok) {
                                $errorCode = [string]$imageResult.ErrorCode
                                $message = [string]$imageResult.Message
                            } else {
                                try {
                                    $null = Write-RawTextAtomic -TargetPath ([string]$target.Path) -Text $rawMarkdown -ExpectedSha256 $rawHash
                                    Add-RawJournalEvent -Path $rawJournalPath -SourceId $sourceId -TargetPath (Convert-ToStablePath -Path ([string]$target.Path)) -ContentSha256 $rawHash -State 'written'
                                    $currentRawRows.Add([ordered]@{
                                            source_id        = $sourceId
                                            run_id           = [string]$applyEntry.run_id
                                            archive_path     = Convert-ToStablePath -Path ([System.IO.Path]::GetFullPath([string]$applyEntry.archive_path))
                                            archive_sha256   = ([string]$applyEntry.archive_sha256).ToLowerInvariant()
                                            raw_path         = Convert-ToStablePath -Path ([string]$target.Path)
                                            raw_sha256       = $rawHash
                                            collision_suffix = if ([string]::IsNullOrWhiteSpace([string]$target.Suffix)) { $null } else { [string]$target.Suffix }
                                            status           = 'written'
                                            message          = 'raw created; ' + [string]$imageResult.Message
                                        })
                                } catch {
                                    $errorCode = 'raw_write_failed'
                                    $message = "atomic raw write failed: $($_.Exception.Message)"
                                }
                            }
                        }
                    }
                }
            }

            $parseStatus = Get-ParseStatusForError -ErrorCode $errorCode
            $parseRows.Add([ordered]@{
                    source_id        = $sourceId
                    run_id           = [string]$config.RunId
                    archive_path     = Convert-ToStablePath -Path ([string]$item.archive_path)
                    archive_sha256   = ([string]$item.archive_sha256).ToLowerInvariant()
                    route            = $route
                    status           = $parseStatus
                    output_path      = if (Test-Path -LiteralPath $outputPath -PathType Leaf) { Convert-ToStablePath -Path $outputPath } else { $null }
                    content_bytes    = $contentBytes
                    has_heading      = $hasHeading
                    validation_flags = if ($validationFlags.Count -eq 0) { '' } else { $validationFlags -join ';' }
                    error_type       = $errorCode
                    retry_count      = 0
                })

            if ($null -ne $errorCode) {
                if ([string]::IsNullOrWhiteSpace($nextAction)) {
                    $nextAction = Get-NextActionForStatus -Status $errorCode -LifecycleNextAction $null
                }
                $failureRows.Add([ordered]@{
                        run_id        = [string]$config.RunId
                        source_id     = $sourceId
                        stage         = Get-FailureStage -ErrorCode $errorCode
                        error_code    = $errorCode
                        message       = $message
                        retryable     = (Test-RetryableError -ErrorCode $errorCode)
                        next_action   = $nextAction
                        artifact_path = if (Test-Path -LiteralPath $outputPath -PathType Leaf) { Convert-ToStablePath -Path $outputPath } else { Convert-ToStablePath -Path $outputDir }
                    })
                $currentRawRows.Add([ordered]@{
                        source_id        = $sourceId
                        run_id           = [string]$config.RunId
                        archive_path     = Convert-ToStablePath -Path ([string]$item.archive_path)
                        archive_sha256   = ([string]$item.archive_sha256).ToLowerInvariant()
                        raw_path         = ''
                        raw_sha256       = ''
                        collision_suffix = $null
                        status           = Get-RawStatusForError -ErrorCode $errorCode
                        message          = $message
                    })
            }
        }

        foreach ($currentRow in @($currentRawRows)) {
            $rawRows.Add($currentRow)
        }

        $parseLines = @($parseRows | ForEach-Object { [pscustomobject]$_ } | ConvertTo-Csv -NoTypeInformation)
        $rawLines = @($rawRows | ForEach-Object { [pscustomobject]$_ } | ConvertTo-Csv -NoTypeInformation)
        Write-Utf8NoBomLines -Path $parseManifestPath -Lines ([string[]]$parseLines)
        Write-Utf8NoBomLines -Path $rawManifestPath -Lines ([string[]]$rawLines)
        Write-FailureRows -Path $failuresPath -Rows @($failureRows)

        # 终态判定只看本次运行的行，历史合并行不参与（避免旧失败行永久阻塞续跑）
        $failedRows = @($currentRawRows | Where-Object { [string]$_['status'] -in @('failed', 'quality_failed') })
        if ($failedRows.Count -gt 0) {
            Write-Output 'RAW INGEST COMPLETED WITH FAILURES'
            exit 1
        }

        Write-Output 'RAW INGEST COMPLETE'
        exit 0
    } finally {
        if ($null -ne $rawLockHandle) {
            $rawLockHandle.Dispose()
        }
        if (Test-Path -LiteralPath $rawLockPath -PathType Leaf) {
            Remove-Item -LiteralPath $rawLockPath -Force -ErrorAction SilentlyContinue
        }
    }
} catch {
    $exceptionDetails = @(
        "ExceptionType: $($_.Exception.GetType().FullName)",
        "Message: $($_.Exception.Message)",
        "Position: $($_.InvocationInfo.PositionMessage)",
        "Stack: $($_.ScriptStackTrace)"
    ) -join ' | '
    Write-IngestError -What 'Raw ingest failed before completion' -Where 'ingest-mineru-output.ps1' -Expected 'Readable config, run directory, MinerU batch, apply manifest, classification plan, and markdown outputs' -Fix $exceptionDetails
    exit 1
}
