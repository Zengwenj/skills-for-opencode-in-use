#Requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $true)]
    [string]$RunDir,

    [string]$InboxRoot,
    [string]$ArchiveRoot,
    [string]$RawSourcesRoot,
    [string]$ReviewRoot,
    [string]$ThemeList,
    [string]$Scope
)

Set-StrictMode -Version Latest

$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$script:RequiredConfigFields = @('inboxRoot', 'archiveRoot', 'rawSourcesRoot', 'reviewRoot', 'themeList', 'scope')
$script:IllegalChars = @('\', '/', ':', '*', '?', '"', '<', '>', '|')
$script:ReservedNames = @(
    'CON', 'PRN', 'AUX', 'NUL',
    'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
    'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9'
)
$script:CodeCacheExtensions = @(
    '.ps1', '.psm1', '.psd1', '.js', '.jsx', '.ts', '.tsx', '.mts', '.cts',
    '.py', '.pyi', '.cs', '.java', '.go', '.rs', '.c', '.cc', '.cpp', '.h', '.hpp',
    '.json', '.yaml', '.yml', '.csv', '.log', '.tmp', '.bak', '.cache', '.db', '.sqlite'
)

function Test-ThemeName {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    foreach ($character in $script:IllegalChars) {
        if ($Name.Contains($character)) { return $false }
    }

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($Name)
    if ($script:ReservedNames -contains $baseName.ToUpperInvariant()) { return $false }
    if ($Name[-1] -eq '.' -or $Name[-1] -eq ' ') { return $false }
    foreach ($character in $Name.ToCharArray()) {
        if ([char]::IsControl($character)) { return $false }
    }

    return $true
}

function Resolve-ThemeList {
    param([object]$Value)

    if ($null -eq $Value) { return @() }
    if ($Value -is [string]) {
        return @($Value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    }

    return @($Value | ForEach-Object { [string]$_ })
}

function Assert-ThemeList {
    param([string[]]$Themes)

    if ($null -eq $Themes -or $Themes.Count -eq 0) {
        throw 'themeList must contain at least one valid theme name.'
    }

    $seen = @{}
    foreach ($theme in $Themes) {
        if ($seen.ContainsKey($theme)) {
            throw "Duplicate theme name '$theme'."
        }

        $seen[$theme] = $true
        if (-not (Test-ThemeName -Name $theme)) {
            throw "Theme name '$theme' is not a valid Windows folder name."
        }
    }
}

function Resolve-StandaloneConfig {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][string]$RunDir,
        [string]$InboxRoot,
        [string]$ArchiveRoot,
        [string]$RawSourcesRoot,
        [string]$ReviewRoot,
        [string]$ThemeList,
        [string]$Scope
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

    $themes = if ($PSBoundParameters.ContainsKey('ThemeList') -and -not [string]::IsNullOrWhiteSpace($ThemeList)) {
        Resolve-ThemeList -Value $ThemeList
    } else {
        Resolve-ThemeList -Value $config['themeList']
    }
    Assert-ThemeList -Themes ([string[]]$themes)

    $resolvedRunDir = [System.IO.Path]::GetFullPath($RunDir)
    if (-not (Test-Path -LiteralPath $resolvedRunDir -PathType Container)) {
        throw "RunDir does not exist: $resolvedRunDir"
    }

    $runDirName = Split-Path -Path $resolvedRunDir -Leaf
    if ($runDirName -notmatch '^(?<timestamp>[0-9]{8}-[0-9]{6})-(?<hex>[0-9a-fA-F]{6})$') {
        throw "RunDir leaf '$runDirName' must match YYYYMMDD-HHMMSS-<6hex>."
    }

    return [pscustomobject]@{
        ConfigPath     = $resolvedConfigPath
        ConfigSha256   = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedConfigPath).Hash.ToLowerInvariant()
        InboxRoot      = [System.IO.Path]::GetFullPath($(if ($PSBoundParameters.ContainsKey('InboxRoot') -and $InboxRoot) { $InboxRoot } else { [string]$config['inboxRoot'] }))
        ArchiveRoot    = [System.IO.Path]::GetFullPath($(if ($PSBoundParameters.ContainsKey('ArchiveRoot') -and $ArchiveRoot) { $ArchiveRoot } else { [string]$config['archiveRoot'] }))
        RawSourcesRoot = [System.IO.Path]::GetFullPath($(if ($PSBoundParameters.ContainsKey('RawSourcesRoot') -and $RawSourcesRoot) { $RawSourcesRoot } else { [string]$config['rawSourcesRoot'] }))
        ReviewRoot     = [System.IO.Path]::GetFullPath($(if ($PSBoundParameters.ContainsKey('ReviewRoot') -and $ReviewRoot) { $ReviewRoot } else { [string]$config['reviewRoot'] }))
        ThemeList      = [string[]]$themes
        Scope          = $(if ($PSBoundParameters.ContainsKey('Scope') -and $Scope) { $Scope } else { [string]$config['scope'] })
        RunDir         = $resolvedRunDir
        RunDirName     = $runDirName
        RunTimestamp   = $Matches['timestamp']
        RunRandomHex   = $Matches['hex']
        LockCreated    = $false
    }
}
$script:ZipExtensions = @('.zip')
$script:TextExtensions = @('.txt', '.md')
$script:SupportedMineruExtensions = @(
    '.pdf', '.doc', '.docx', '.ppt', '.pptx', '.xls', '.xlsx',
    '.png', '.jpg', '.jpeg', '.jp2', '.webp', '.gif', '.bmp', '.html', '.htm'
)

function Convert-ToStablePath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return $Path.Replace('\', '/')
}

function Write-Utf8NoBomText {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )

    [System.IO.File]::WriteAllText($Path, $Text, $script:Utf8NoBom)
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

function Get-PathLeafPackKey {
    param([Parameter(Mandatory = $true)][string]$RelPath)

    $segments = $RelPath -split '/'
    if ($segments.Count -lt 2) {
        return $null
    }

    for ($index = $segments.Count - 2; $index -ge 0; $index--) {
        if ($segments[$index].EndsWith('-pack', [System.StringComparison]::OrdinalIgnoreCase)) {
            return ($segments[0..$index] -join '/')
        }
    }

    return $null
}

function Get-InferredTheme {
    param(
        [Parameter(Mandatory = $true)][string]$RelPath,
        [Parameter(Mandatory = $true)][string[]]$ThemeList
    )

    $stablePath = '/' + (Convert-ToStablePath -Path $RelPath).Trim('/') + '/'
    $segments = $RelPath -split '/'
    foreach ($segment in $segments) {
        foreach ($theme in $ThemeList) {
            $normalizedTheme = [string]$theme
            if ($segment.Trim() -ieq $normalizedTheme.Trim()) {
                return $normalizedTheme.Trim()
            }

            $themeToken = '/' + $normalizedTheme.Trim() + '/'
            if ($stablePath.Contains($themeToken)) {
                return $normalizedTheme.Trim()
            }
        }
    }

    return ''
}

function Get-InferredYear {
    param([Parameter(Mandatory = $true)][object]$InventoryItem)

    if ($null -ne $InventoryItem.inferred_year) {
        return [int]$InventoryItem.inferred_year
    }

    return $null
}

function New-ArchivePath {
    param(
        [Parameter(Mandatory = $true)][string]$ArchiveRoot,
        [Parameter(Mandatory = $true)][string]$Theme,
        [Parameter(Mandatory = $true)][int]$Year,
        [Parameter(Mandatory = $true)][string]$FileName
    )

    return Convert-ToStablePath -Path ([System.IO.Path]::Combine($ArchiveRoot, $Theme, $Year.ToString(), $FileName))
}

function Get-Classification {
    param(
        [Parameter(Mandatory = $true)][object]$Item,
        [Parameter(Mandatory = $true)][string[]]$ThemeList,
        [Parameter(Mandatory = $true)][string]$ArchiveRoot,
        [Parameter(Mandatory = $true)][string]$RawSourcesRoot
    )

    $relPath = [string]$Item.rel_path
    $extension = [string]$Item.extension
    $theme = Get-InferredTheme -RelPath $relPath -ThemeList $ThemeList
    $year = Get-InferredYear -InventoryItem $Item
    $packKey = Get-PathLeafPackKey -RelPath $relPath
    $itemReviewNeeded = [bool]$Item.review_needed
    $unknownTheme = [string]::IsNullOrWhiteSpace($theme)
    $reviewNeeded = $itemReviewNeeded -or $unknownTheme
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($relPath)
    $fileName = [System.IO.Path]::GetFileName($relPath)

    $reasonCodes = [System.Collections.Generic.List[string]]::new()
    if ($packKey) { $reasonCodes.Add('pack_review_needed') }
    if ($unknownTheme) { $reasonCodes.Add('unknown_theme') }
    if ($null -ne $year) { $reasonCodes.Add('year_regex') }

    $isCodeCache = $script:CodeCacheExtensions -contains $extension
    $isZip = $script:ZipExtensions -contains $extension
    $isText = $script:TextExtensions -contains $extension
    $isSupportedMineru = $script:SupportedMineruExtensions -contains $extension

    $targetArchivePath = $null
    if (-not $unknownTheme -and $null -ne $year) {
        $targetArchivePath = New-ArchivePath -ArchiveRoot $ArchiveRoot -Theme $theme -Year $year -FileName $fileName
    }

    $enterRawSources = $false
    $mineruCandidate = $false
    $action = 'review_only'

    if ($isCodeCache) {
        $action = 'skip'
        $reasonCodes.Add('code_or_cache')
    } elseif (-not $isZip -and -not $isText -and -not $isSupportedMineru) {
        $action = 'review_only'
        $reasonCodes.Add('unsupported_extension')
    } elseif (-not $reviewNeeded) {
        if ($isZip) {
            $action = 'archive_only'
            $reasonCodes.Add('archive_only_zip')
        } else {
            $action = 'archive_and_raw'
            $enterRawSources = $true
            if ($isSupportedMineru) {
                $mineruCandidate = $true
                $reasonCodes.Add('mineru_candidate')
            } elseif ($isText) {
                $reasonCodes.Add('text_source')
            }
        }
    } else {
        $action = 'review_only'
        if ($isSupportedMineru) {
            $reasonCodes.Add('mineru_candidate')
        } elseif ($isText) {
            $reasonCodes.Add('text_source')
        }
    }

    $confidence = if ($action -eq 'skip') {
        0.18
    } elseif ($reviewNeeded) {
        0.42
    } elseif ($isSupportedMineru) {
        0.93
    } elseif ($isText) {
        0.89
    } elseif ($isZip) {
        0.84
    } else {
        0.66
    }

    if ($action -eq 'review_only' -and -not $targetArchivePath) {
        $targetArchivePath = $null
    }

    return [ordered]@{
        source_id           = [string]$Item.source_id
        run_id              = [string]$Item.run_id
        action              = $action
        source_abs_path     = Convert-ToStablePath -Path ([string]$Item.abs_path)
        source_rel_path     = $relPath
        source_sha256       = ([string]$Item.sha256).ToLowerInvariant()
        target_archive_path = $targetArchivePath
        target_theme        = if ($unknownTheme) { '' } else { $theme }
        target_year         = $year
        pack_key            = $packKey
        enter_raw_sources   = $enterRawSources
        mineru_candidate    = $mineruCandidate
        confidence          = [double]::Parse($confidence.ToString([System.Globalization.CultureInfo]::InvariantCulture), [System.Globalization.CultureInfo]::InvariantCulture)
        review_needed       = $reviewNeeded
        reason_codes        = @($reasonCodes | Select-Object -Unique)
    }
}

function Invoke-BuildProposal {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline = $true, Mandatory = $true)]
        [psobject]$Config
    )

    begin {
        $inputConfig = $null
    }

    process {
        $inputConfig = $Config
    }

    end {
        if (-not $inputConfig) {
            throw 'build-proposal.ps1 expects a resolved config object via pipeline or -Config.'
        }

        $config = $inputConfig
    $runDir = [System.IO.Path]::GetFullPath([string]$config.RunDir)
    $inventoryPath = Join-Path -Path $runDir -ChildPath 'inventory.jsonl'
    $snapshotBeforePath = Join-Path -Path $runDir -ChildPath 'source_snapshot_before.csv'
    $planPath = Join-Path -Path $runDir -ChildPath 'classification-plan.jsonl'
    $proposalPath = Join-Path -Path $runDir -ChildPath 'classification-proposal.md'
    $manifestPath = Join-Path -Path $runDir -ChildPath 'proposal-manifest.json'

    if (-not (Test-Path -LiteralPath $inventoryPath -PathType Leaf)) {
        throw "Missing inventory.jsonl at '$inventoryPath'. Run scan-inbox.ps1 first."
    }

    $inventoryItems = foreach ($line in Get-Content -LiteralPath $inventoryPath -Encoding UTF8) {
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            $line | ConvertFrom-Json
        }
    }

    $sortedItems = $inventoryItems | Sort-Object rel_path, source_id
    $planRows = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $sortedItems) {
        $planRows.Add((Get-Classification -Item $item -ThemeList ([string[]]$config.ThemeList) -ArchiveRoot ([string]$config.ArchiveRoot) -RawSourcesRoot ([string]$config.RawSourcesRoot)))
    }

    $planLines = foreach ($row in $planRows) {
        $row | ConvertTo-Json -Compress -Depth 8
    }
    Write-Utf8NoBomLines -Path $planPath -Lines ([string[]]$planLines)

    $inventoryHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $inventoryPath).Hash.ToLowerInvariant()
    $snapshotBeforeHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $snapshotBeforePath).Hash.ToLowerInvariant()
    $planHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $planPath).Hash.ToLowerInvariant()

    $reviewNeededItems = $planRows | Where-Object { $_.review_needed }
    $applyCandidates = $planRows | Where-Object { $_.action -in @('archive_only', 'archive_and_raw') }
    $rawCandidates = $planRows | Where-Object { $_.action -eq 'archive_and_raw' }
    $blockedItems = $planRows | Where-Object { $_.action -in @('review_only', 'skip') }

    $actions = [ordered]@{
        archive_only      = @($planRows | Where-Object { $_.action -eq 'archive_only' }).Count
        archive_and_raw   = @($planRows | Where-Object { $_.action -eq 'archive_and_raw' }).Count
        review_only       = @($planRows | Where-Object { $_.action -eq 'review_only' }).Count
        skip              = @($planRows | Where-Object { $_.action -eq 'skip' }).Count
    }

    $artifactPaths = [ordered]@{
        inventory                    = 'inventory.jsonl'
        source_snapshot_before       = 'source_snapshot_before.csv'
        classification_plan          = 'classification-plan.jsonl'
        classification_proposal      = 'classification-proposal.md'
        proposal_manifest            = 'proposal-manifest.json'
    }

    $createdAt = [DateTime]::ParseExact(
        [string]$config.RunTimestamp,
        'yyyyMMdd-HHmmss',
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::AssumeLocal
    ).ToUniversalTime().ToString('o')

    $manifest = [ordered]@{
        schema_version                = '1.0'
        run_id                        = [string]$config.RunDirName
        scope                         = [string]$config.Scope
        created_at                    = $createdAt
        config_sha256                 = ([string]$config.ConfigSha256).ToLowerInvariant()
        inventory_sha256              = $inventoryHash
        source_snapshot_before_sha256  = $snapshotBeforeHash
        classification_plan_sha256    = $planHash
        item_count                    = @($planRows).Count
        review_needed_count           = @($reviewNeededItems).Count
        actions                       = $actions
        artifact_paths                = $artifactPaths
    }

    $manifestJson = $manifest | ConvertTo-Json -Compress -Depth 8

    $runMetadataSection = @(
        '## Run metadata',
        '',
        '| Field | Value |',
        '| --- | --- |',
        "| run_id | $([string]$config.RunDirName) |",
        "| scope | $([string]$config.Scope) |",
        "| item_count | $(@($planRows).Count) |",
        "| review_needed_count | $(@($reviewNeededItems).Count) |",
        "| inventory_sha256 | $inventoryHash |",
        "| source_snapshot_before_sha256 | $snapshotBeforeHash |",
        "| classification_plan_sha256 | $planHash |",
        "| config_sha256 | $(([string]$config.ConfigSha256).ToLowerInvariant()) |"
    )

    $statisticsSection = @(
        '## Statistics',
        '',
        "- archive_only: $($actions.archive_only)",
        "- archive_and_raw: $($actions.archive_and_raw)",
        "- review_only: $($actions.review_only)",
        "- skip: $($actions.skip)",
        "- apply candidates: $(@($applyCandidates).Count)",
        "- raw candidates: $(@($rawCandidates).Count)"
    )

    function New-ItemLines {
        param([object[]]$Items)
        if (-not $Items -or $Items.Count -eq 0) {
            return @('- None')
        }

        return $Items | ForEach-Object {
            '- ' + $_.source_id + ' | action=' + $_.action + ' | theme=' + $_.target_theme + ' | year=' + ($_.target_year -as [string]) + ' | reason=' + (($_.reason_codes -join ',') -as [string])
        }
    }

    $reviewNeededSection = @('## Review-needed items', '') + (New-ItemLines -Items @($reviewNeededItems))
    $applySection = @('## Apply candidates', '') + (New-ItemLines -Items @($applyCandidates))
    $rawSection = @('## Raw candidates', '') + (New-ItemLines -Items @($rawCandidates))
    $blockedSection = @('## Failures/blocked', '') + (New-ItemLines -Items @($blockedItems))

    $proposalLines = @()
    $proposalLines += '# Classification proposal'
    $proposalLines += ''
    $proposalLines += $runMetadataSection
    $proposalLines += ''
    $proposalLines += $statisticsSection
    $proposalLines += ''
    $proposalLines += $reviewNeededSection
    $proposalLines += ''
    $proposalLines += $applySection
    $proposalLines += ''
    $proposalLines += $rawSection
    $proposalLines += ''
    $proposalLines += $blockedSection

    Write-Utf8NoBomLines -Path $proposalPath -Lines ([string[]]$proposalLines)

        Write-Utf8NoBomText -Path $manifestPath -Text $manifestJson

        Write-Output $config
    }
}

$resolvedConfig = Resolve-StandaloneConfig -ConfigPath $ConfigPath -RunDir $RunDir -InboxRoot $InboxRoot -ArchiveRoot $ArchiveRoot -RawSourcesRoot $RawSourcesRoot -ReviewRoot $ReviewRoot -ThemeList $ThemeList -Scope $Scope
Invoke-BuildProposal -Config $resolvedConfig | Out-Null
