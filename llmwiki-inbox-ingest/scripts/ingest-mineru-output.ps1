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

    [System.IO.File]::WriteAllLines($Path, [string[]]$normalizedLines, $script:Utf8NoBom)
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
    return [regex]::IsMatch(($Text -replace "`r`n", "`n"), '(?m)^#\s+')
}

function Test-ErrorPlaceholder {
    param([Parameter(Mandatory = $true)][string]$Text)

    $lower = $Text.ToLowerInvariant()
    foreach ($placeholder in $script:ErrorPlaceholders) {
        if ($lower.Contains($placeholder)) { return $true }
    }

    return $false
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
        [Parameter(Mandatory = $true)][string]$Markdown
    )

    $archivePath = Convert-ToStablePath -Path ([System.IO.Path]::GetFullPath([string]$ApplyEntry.archive_path))
    $sourceType = ([System.IO.Path]::GetExtension($archivePath)).TrimStart('.').ToLowerInvariant()
    $parsedDate = [DateTime]::UtcNow.ToString('o')
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

    $batch = Get-Content -LiteralPath $batchPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $applyEntries = @(Read-JsonlObjects -Path $applyManifestPath)
    $planItems = @(Read-JsonlObjects -Path $classificationPlanPath)
    $latestApply = Get-LatestApplyEntriesBySourceId -ApplyEntries $applyEntries
    $planBySourceId = Get-PlanItemsBySourceId -PlanItems $planItems

    $parseRows = [System.Collections.Generic.List[object]]::new()
    $rawRows = [System.Collections.Generic.List[object]]::new()
    $failureRows = [System.Collections.Generic.List[object]]::new()
    foreach ($row in @(Read-FailureRows -Path $failuresPath)) { $failureRows.Add($row) }

    foreach ($item in @($batch.items)) {
        $sourceId = [string]$item.source_id
        $outputDir = Resolve-OutputDirPath -RunDir ([string]$config.RunDir) -OutputDir ([string]$item.output_dir)
        $outputPath = Join-Path -Path $outputDir -ChildPath 'full.md'
        $route = if ($MockMode) { 'mock' } else { [string]$item.mineru_route }
        $validationFlags = [System.Collections.Generic.List[string]]::new()
        $errorCode = $null
        $message = ''

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
                $errorCode = 'mineru_output_missing'
                $message = 'MinerU output full.md is missing'
            } else {
                $markdown = Get-Content -LiteralPath $outputPath -Raw -Encoding UTF8
                $contentBytes = [System.Text.Encoding]::UTF8.GetByteCount($markdown)
                $hasHeading = Test-MarkdownHeading -Text $markdown
                if ($contentBytes -le 500) { $validationFlags.Add('content_bytes_le_500') }
                if (-not $hasHeading) { $validationFlags.Add('missing_heading') }
                if (Test-ErrorPlaceholder -Text $markdown) { $validationFlags.Add('error_placeholder') }

                if ($validationFlags.Count -gt 0) {
                    $errorCode = 'raw_quality_failed'
                    $message = 'MinerU markdown failed raw quality gate: ' + ($validationFlags -join ';')
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
            $target = Get-RawTargetPath -RawSourcesRoot ([string]$config.RawSourcesRoot) -Theme $theme -Year $year -ArchivePath ([string]$applyEntry.archive_path)
            if (-not (Test-PathWithinRoot -Candidate ([string]$target.Path) -Root ([string]$config.RawSourcesRoot)) ) {
                $errorCode = 'raw_path_escape'
                $message = 'computed raw target path escapes rawSourcesRoot'
            } else {
                $rawMarkdown = New-FrontmatterMarkdown -BatchItem $item -ApplyEntry $applyEntry -PlanItem $planItem -Markdown $markdown
                Write-Utf8NoBomText -Path ([string]$target.Path) -Text $rawMarkdown
                $rawHash = (Get-FileHash -Algorithm SHA256 -LiteralPath ([string]$target.Path)).Hash.ToLowerInvariant()
                $rawRows.Add([ordered]@{
                        source_id        = $sourceId
                        run_id           = [string]$applyEntry.run_id
                        archive_path     = Convert-ToStablePath -Path ([System.IO.Path]::GetFullPath([string]$applyEntry.archive_path))
                        archive_sha256   = ([string]$applyEntry.archive_sha256).ToLowerInvariant()
                        raw_path         = Convert-ToStablePath -Path ([string]$target.Path)
                        raw_sha256       = $rawHash
                        collision_suffix = if ([string]::IsNullOrWhiteSpace([string]$target.Suffix)) { $null } else { [string]$target.Suffix }
                        status           = 'written'
                        message          = 'raw created'
                    })
            }
        }

        $parseRows.Add([ordered]@{
                source_id        = $sourceId
                run_id           = [string]$config.RunId
                archive_path     = Convert-ToStablePath -Path ([string]$item.archive_path)
                archive_sha256   = ([string]$item.archive_sha256).ToLowerInvariant()
                route            = $route
                status           = if ($null -eq $errorCode) { 'parsed' } else { 'failed' }
                output_path      = if (Test-Path -LiteralPath $outputPath -PathType Leaf) { Convert-ToStablePath -Path $outputPath } else { $null }
                content_bytes    = $contentBytes
                has_heading      = $hasHeading
                validation_flags = if ($validationFlags.Count -eq 0) { '' } else { $validationFlags -join ';' }
                error_type       = $errorCode
                retry_count      = 0
            })

        if ($null -ne $errorCode) {
            $failureRows.Add([ordered]@{
                    run_id        = [string]$config.RunId
                    source_id     = $sourceId
                    stage         = if ($errorCode -in @('raw_quality_failed', 'raw_path_escape')) { 'raw' } else { 'mineru' }
                    error_code    = $errorCode
                    message       = $message
                    retryable     = ($errorCode -in @('mineru_output_missing', 'raw_quality_failed'))
                    next_action   = 'regenerate MinerU output for this committed archive or remove it from the batch after review'
                    artifact_path = if (Test-Path -LiteralPath $outputPath -PathType Leaf) { Convert-ToStablePath -Path $outputPath } else { Convert-ToStablePath -Path $outputDir }
                })
            $rawRows.Add([ordered]@{
                    source_id        = $sourceId
                    run_id           = [string]$config.RunId
                    archive_path     = Convert-ToStablePath -Path ([string]$item.archive_path)
                    archive_sha256   = ([string]$item.archive_sha256).ToLowerInvariant()
                    raw_path         = ''
                    raw_sha256       = ''
                    collision_suffix = $null
                    status           = 'failed'
                    message          = $message
                })
        }
    }

    $parseLines = @($parseRows | ForEach-Object { [pscustomobject]$_ } | ConvertTo-Csv -NoTypeInformation)
    $rawLines = @($rawRows | ForEach-Object { [pscustomobject]$_ } | ConvertTo-Csv -NoTypeInformation)
    Write-Utf8NoBomLines -Path $parseManifestPath -Lines ([string[]]$parseLines)
    Write-Utf8NoBomLines -Path $rawManifestPath -Lines ([string[]]$rawLines)
    Write-FailureRows -Path $failuresPath -Rows @($failureRows)

    $failedRows = @($rawRows | Where-Object { [string]$_['status'] -eq 'failed' })
    if ($failedRows.Count -gt 0) {
        Write-Output 'RAW INGEST COMPLETED WITH FAILURES'
        exit 1
    }

    Write-Output 'RAW INGEST COMPLETE'
    exit 0
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
