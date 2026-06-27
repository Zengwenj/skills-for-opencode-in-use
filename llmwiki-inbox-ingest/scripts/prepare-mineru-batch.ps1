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
$script:CommittedStates = @('committed', 'skipped_existing_committed')
$script:CapabilityMatrix = @{
    '.pdf'  = @{ supported_for_archive = $true; supported_for_mineru = 'true'; mineru_mode = 'mcp_flash_or_token'; reason_if_unsupported = '' }
    '.doc'  = @{ supported_for_archive = $true; supported_for_mineru = 'conditional'; mineru_mode = 'token_or_env_detected'; reason_if_unsupported = 'Flash mode may not support .doc; require environment capability check' }
    '.docx' = @{ supported_for_archive = $true; supported_for_mineru = 'true'; mineru_mode = 'mcp_flash_or_token'; reason_if_unsupported = '' }
    '.ppt'  = @{ supported_for_archive = $true; supported_for_mineru = 'conditional'; mineru_mode = 'token_or_env_detected'; reason_if_unsupported = 'Flash mode may not support .ppt; require environment capability check' }
    '.pptx' = @{ supported_for_archive = $true; supported_for_mineru = 'true'; mineru_mode = 'mcp_flash_or_token'; reason_if_unsupported = '' }
    '.xls'  = @{ supported_for_archive = $true; supported_for_mineru = 'true'; mineru_mode = 'mcp_flash_or_token'; reason_if_unsupported = '' }
    '.xlsx' = @{ supported_for_archive = $true; supported_for_mineru = 'true'; mineru_mode = 'mcp_flash_or_token'; reason_if_unsupported = '' }
    '.png'  = @{ supported_for_archive = $true; supported_for_mineru = 'true'; mineru_mode = 'mcp_flash_or_token'; reason_if_unsupported = '' }
    '.jpg'  = @{ supported_for_archive = $true; supported_for_mineru = 'true'; mineru_mode = 'mcp_flash_or_token'; reason_if_unsupported = '' }
    '.jpeg' = @{ supported_for_archive = $true; supported_for_mineru = 'true'; mineru_mode = 'mcp_flash_or_token'; reason_if_unsupported = '' }
    '.jp2'  = @{ supported_for_archive = $true; supported_for_mineru = 'true'; mineru_mode = 'mcp_flash_or_token'; reason_if_unsupported = '' }
    '.webp' = @{ supported_for_archive = $true; supported_for_mineru = 'true'; mineru_mode = 'mcp_flash_or_token'; reason_if_unsupported = '' }
    '.gif'  = @{ supported_for_archive = $true; supported_for_mineru = 'true'; mineru_mode = 'mcp_flash_or_token'; reason_if_unsupported = '' }
    '.bmp'  = @{ supported_for_archive = $true; supported_for_mineru = 'true'; mineru_mode = 'mcp_flash_or_token'; reason_if_unsupported = '' }
    '.html' = @{ supported_for_archive = $true; supported_for_mineru = 'conditional'; mineru_mode = 'html_model_or_env_detected'; reason_if_unsupported = 'Only supported when routed as HTML page/model and environment confirms' }
    '.htm'  = @{ supported_for_archive = $true; supported_for_mineru = 'conditional'; mineru_mode = 'html_model_or_env_detected'; reason_if_unsupported = 'Only supported when routed as HTML page/model and environment confirms' }
}

function Write-PrepareError {
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

function Resolve-PrepareConfig {
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

    $language = $null
    if ($config.ContainsKey('mineruLanguage') -and -not [string]::IsNullOrWhiteSpace([string]$config['mineruLanguage'])) {
        $language = [string]$config['mineruLanguage']
    } else {
        $language = 'ch'
    }

    return [pscustomobject]@{
        ConfigPath = $resolvedConfigPath
        RunDir     = $resolvedRunDir
        RunId      = $runDirName
        Language   = $language
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

function New-RawTargetHint {
    param(
        [Parameter(Mandatory = $true)][object]$PlanItem,
        [Parameter(Mandatory = $true)][string]$ArchivePath
    )

    $theme = [string]$PlanItem.target_theme
    $year = [string]$PlanItem.target_year
    $leaf = [System.IO.Path]::GetFileNameWithoutExtension($ArchivePath) + '.md'
    if ([string]::IsNullOrWhiteSpace($theme) -or [string]::IsNullOrWhiteSpace($year)) {
        return $leaf
    }

    return Convert-ToStablePath -Path ([System.IO.Path]::Combine($theme, $year, $leaf))
}

try {
    $config = Resolve-PrepareConfig -ConfigPath $ConfigPath -RunDir $RunDir
    $applyManifestPath = Join-Path -Path ([string]$config.RunDir) -ChildPath 'apply-manifest.jsonl'
    $classificationPlanPath = Join-Path -Path ([string]$config.RunDir) -ChildPath 'classification-plan.jsonl'
    $batchPath = Join-Path -Path ([string]$config.RunDir) -ChildPath 'mineru-batch.json'
    $failuresPath = Join-Path -Path ([string]$config.RunDir) -ChildPath 'failures.csv'

    foreach ($artifactPath in @($applyManifestPath, $classificationPlanPath)) {
        if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
            Write-PrepareError -What 'Required run artifact is missing' -Where $artifactPath -Expected 'Existing apply and classification artifacts in RunDir' -Fix 'Run proposal and apply before preparing the MinerU batch.'
            exit 1
        }
    }

    $applyEntries = @(Read-JsonlObjects -Path $applyManifestPath)
    $planItems = @(Read-JsonlObjects -Path $classificationPlanPath)
    $latestApply = Get-LatestApplyEntriesBySourceId -ApplyEntries $applyEntries
    $planBySourceId = Get-PlanItemsBySourceId -PlanItems $planItems

    $batchItems = [System.Collections.Generic.List[object]]::new()
    $failureRows = [System.Collections.Generic.List[object]]::new()
    foreach ($row in @(Read-FailureRows -Path $failuresPath)) { $failureRows.Add($row) }

    foreach ($sourceId in @($latestApply.Keys | Sort-Object)) {
        $applyEntry = $latestApply[$sourceId]
        $state = [string]$applyEntry.state
        if ($script:CommittedStates -notcontains $state) { continue }

        if (-not $planBySourceId.ContainsKey($sourceId)) {
            $failureRows.Add([ordered]@{
                    run_id        = [string]$config.RunId
                    source_id     = $sourceId
                    stage         = 'mineru'
                    error_code    = 'classification_plan_missing'
                    message       = 'committed item has no matching classification-plan row'
                    retryable     = $false
                    next_action   = 'rebuild the run so apply-manifest and classification-plan share source_id values'
                    artifact_path = 'classification-plan.jsonl'
                })
            continue
        }

        $planItem = $planBySourceId[$sourceId]
        if (-not [bool]$planItem.enter_raw_sources -or -not [bool]$planItem.mineru_candidate) {
            continue
        }

        $archivePath = [System.IO.Path]::GetFullPath([string]$applyEntry.archive_path)
        $archiveSha256 = ([string]$applyEntry.archive_sha256).ToLowerInvariant()
        $extension = [System.IO.Path]::GetExtension($archivePath).ToLowerInvariant()

        $capability = $null
        if ($script:CapabilityMatrix.ContainsKey($extension)) {
            $capability = $script:CapabilityMatrix[$extension]
        }

        if ($null -eq $capability -or -not [bool]$capability.supported_for_archive) {
            $failureRows.Add([ordered]@{
                    run_id        = [string]$config.RunId
                    source_id     = $sourceId
                    stage         = 'mineru'
                    error_code    = 'unsupported_mineru_extension'
                    message       = "extension '$extension' is not supported by the MinerU capability matrix"
                    retryable     = $false
                    next_action   = 'exclude this source from MinerU/raw or update the documented capability matrix before rerunning'
                    artifact_path = $archivePath
                })
            continue
        }

        $mineruRoute = $null
        $reason = $null
        switch ([string]$capability.supported_for_mineru) {
            'true' {
                $mineruRoute = 'mcp_flash_or_token'
                $reason = $null
            }
            'conditional' {
                $mineruRoute = 'conditional'
                $reason = [string]$capability.reason_if_unsupported
            }
            default {
                $failureRows.Add([ordered]@{
                        run_id        = [string]$config.RunId
                        source_id     = $sourceId
                        stage         = 'mineru'
                        error_code    = 'unsupported_mineru_extension'
                        message       = "extension '$extension' is not supported for MinerU parsing"
                        retryable     = $false
                        next_action   = 'exclude this source from MinerU/raw or convert it to a supported format'
                        artifact_path = $archivePath
                    })
                continue
            }
        }

        $outputDir = Join-Path -Path ([string]$config.RunDir) -ChildPath (Join-Path -Path 'mineru-output' -ChildPath $sourceId)
        $batchItems.Add([ordered]@{
                source_id         = $sourceId
                archive_path      = Convert-ToStablePath -Path $archivePath
                archive_sha256    = $archiveSha256
                extension         = $extension
                mineru_route      = $mineruRoute
                output_dir        = Convert-ToStablePath -Path $outputDir
                language          = [string]$config.Language
                raw_target_hint   = New-RawTargetHint -PlanItem $planItem -ArchivePath $archivePath
                reason_if_skipped = $reason
            })
    }

    $batch = [ordered]@{
        schema_version = '1.0'
        run_id         = [string]$config.RunId
        created_at     = [DateTime]::UtcNow.ToString('o')
        items          = @($batchItems)
    }

    Write-Utf8NoBomText -Path $batchPath -Text ($batch | ConvertTo-Json -Compress -Depth 8)
    Write-FailureRows -Path $failuresPath -Rows @($failureRows)

    Write-Output "MINERU BATCH READY: $batchPath"
    exit 0
} catch {
    $exceptionDetails = @(
        "ExceptionType: $($_.Exception.GetType().FullName)",
        "Message: $($_.Exception.Message)",
        "Position: $($_.InvocationInfo.PositionMessage)",
        "Stack: $($_.ScriptStackTrace)"
    ) -join ' | '
    Write-PrepareError -What 'MinerU batch preparation failed before completion' -Where 'prepare-mineru-batch.ps1' -Expected 'Readable config, run directory, apply manifest, and classification plan' -Fix $exceptionDetails
    exit 1
}
