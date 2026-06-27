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
$script:YearPattern = '(?<!\d)(20[0-2][0-9])(?!\d)'
$script:RunDirPattern = '^[0-9]{8}-[0-9]{6}-[0-9a-fA-F]{6}$'
$script:RequiredConfigFields = @('inboxRoot', 'archiveRoot', 'rawSourcesRoot', 'reviewRoot', 'themeList', 'scope')
$script:IllegalChars = @('\', '/', ':', '*', '?', '"', '<', '>', '|')
$script:ReservedNames = @(
    'CON', 'PRN', 'AUX', 'NUL',
    'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
    'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9'
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

function Convert-ToStablePath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return $Path.Replace('\', '/')
}

function Get-NormalizedRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$FullPath
    )

    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $fullFull = [System.IO.Path]::GetFullPath($FullPath)
    if (-not $fullFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path '$FullPath' is not under root '$Root'."
    }

    $relative = $fullFull.Substring($rootFull.Length).TrimStart('\', '/')
    return Convert-ToStablePath -Path $relative
}

function Test-PathIsContainedBy {
    param(
        [Parameter(Mandatory = $true)][string]$Candidate,
        [Parameter(Mandatory = $true)][string]$Root
    )

    $candidateFull = [System.IO.Path]::GetFullPath($Candidate).TrimEnd('\', '/')
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    return $candidateFull.Equals($rootFull, [System.StringComparison]::OrdinalIgnoreCase) -or
        $candidateFull.StartsWith($rootFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-IsExcludedFile {
    param(
        [Parameter(Mandatory = $true)][string]$FullPath,
        [Parameter(Mandatory = $true)][string]$RelPath,
        [Parameter(Mandatory = $true)][string]$ReviewRoot,
        [Parameter(Mandatory = $true)][string]$RawSourcesRoot,
        [Parameter(Mandatory = $true)][string]$RunDir
    )

    if ([System.IO.Path]::GetFileName($FullPath) -eq '.index.md') {
        return $true
    }

    if (Test-PathIsContainedBy -Candidate $FullPath -Root $ReviewRoot) {
        return $true
    }

    if (Test-PathIsContainedBy -Candidate $FullPath -Root $RawSourcesRoot) {
        return $true
    }

    if (Test-PathIsContainedBy -Candidate $FullPath -Root $RunDir) {
        return $true
    }

    $segments = $RelPath -split '/'
    if ($segments.Count -gt 1) {
        foreach ($segment in $segments[0..($segments.Count - 2)]) {
            if ($segment.StartsWith('.', [System.StringComparison]::Ordinal)) {
                return $true
            }

            if ($segment -match $script:RunDirPattern) {
                return $true
            }
        }
    }

    return $false
}

function Get-PackKey {
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
    param([Parameter(Mandatory = $true)][string]$RelPath)

    $segments = $RelPath -split '/'
    foreach ($segment in $segments) {
        if ($segment -match $script:YearPattern) {
            return [int]$Matches[1]
        }

        if ($segment.Length -eq 6 -and $segment -match '^[0-9]{6}$') {
            $yearPart = $segment.Substring(0, 4)
            if ($yearPart -match $script:YearPattern) {
                return [int]$Matches[1]
            }
        }
    }

    return $null
}

function Get-SourceId {
    param(
        [Parameter(Mandatory = $true)][string]$RelPath,
        [Parameter(Mandatory = $true)][string]$Sha256
    )

    $sha256 = $Sha256.ToLowerInvariant()
    $shaPrefix = $sha256.Substring(0, 8)
    $payload = [System.Text.Encoding]::UTF8.GetBytes((Convert-ToStablePath -Path $RelPath) + '|' + $shaPrefix)
    $digest = [System.Security.Cryptography.SHA256]::Create().ComputeHash($payload)
    $hex = ([System.BitConverter]::ToString($digest) -replace '-', '').ToLowerInvariant()
    return 'src_' + $hex.Substring(0, 12) + '_' + $shaPrefix
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

function Invoke-ScanInbox {
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
            throw 'scan-inbox.ps1 expects a resolved config object via pipeline or -Config.'
        }

        $config = $inputConfig
    $inboxRoot = [System.IO.Path]::GetFullPath([string]$config.InboxRoot)
    $reviewRoot = [System.IO.Path]::GetFullPath([string]$config.ReviewRoot)
    $rawSourcesRoot = [System.IO.Path]::GetFullPath([string]$config.RawSourcesRoot)
    $runDir = [System.IO.Path]::GetFullPath([string]$config.RunDir)
        $themeList = [string[]]$config.ThemeList

    $inventoryPath = Join-Path -Path $runDir -ChildPath 'inventory.jsonl'
    $snapshotBeforePath = Join-Path -Path $runDir -ChildPath 'source_snapshot_before.csv'

    $files = Get-ChildItem -LiteralPath $inboxRoot -File -Recurse -Force | Sort-Object FullName
    $inventoryRows = [System.Collections.Generic.List[object]]::new()

    foreach ($file in $files) {
        $relPath = Get-NormalizedRelativePath -Root $inboxRoot -FullPath $file.FullName

        if (Test-IsExcludedFile -FullPath $file.FullName -RelPath $relPath -ReviewRoot $reviewRoot -RawSourcesRoot $rawSourcesRoot -RunDir $runDir) {
            continue
        }

        $sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash.ToLowerInvariant()
        $size = [int64]$file.Length
        $mtime = $file.LastWriteTimeUtc.ToString('o')
        $extension = [System.IO.Path]::GetExtension($file.Name).ToLowerInvariant()
        $parentDir = [System.IO.Path]::GetDirectoryName($relPath)
        if ([string]::IsNullOrWhiteSpace($parentDir)) {
            $parentDir = '.'
        }

        $inferredTheme = Get-InferredTheme -RelPath $relPath -ThemeList $themeList
        $inferredYear = Get-InferredYear -RelPath $relPath
        $packKey = Get-PackKey -RelPath $relPath

        $reviewNeeded = [bool]($packKey -or [string]::IsNullOrWhiteSpace($inferredTheme))
        $confidence = if ($reviewNeeded) { 0.62 } elseif ($null -ne $inferredYear) { 0.91 } else { 0.78 }

        $inventoryRows.Add([ordered]@{
                source_id      = Get-SourceId -RelPath $relPath -Sha256 $sha256
                run_id         = $config.RunDirName
                abs_path       = Convert-ToStablePath -Path $file.FullName
                rel_path       = $relPath
                size           = $size
                mtime          = $mtime
                sha256         = $sha256
                parent_dir     = $parentDir
                extension      = $extension
                inferred_theme = $inferredTheme
                inferred_year  = $inferredYear
                confidence     = [double]::Parse($confidence.ToString([System.Globalization.CultureInfo]::InvariantCulture), [System.Globalization.CultureInfo]::InvariantCulture)
                review_needed  = $reviewNeeded
            })
    }

    $jsonlLines = foreach ($row in $inventoryRows) {
        $row | ConvertTo-Json -Compress -Depth 8
    }

    $snapshotRows = foreach ($row in $inventoryRows) {
        [ordered]@{
            source_id = $row.source_id
            rel_path  = $row.rel_path
            abs_path  = $row.abs_path
            sha256    = $row.sha256
            size      = $row.size
            mtime     = $row.mtime
            exists    = $true
        }
    }

    $csvLines = @()
    if ($snapshotRows.Count -gt 0) {
        $csvLines = $snapshotRows | ForEach-Object { [pscustomobject]$_ } | ConvertTo-Csv -NoTypeInformation
    } else {
        $csvLines = @('"source_id","rel_path","abs_path","sha256","size","mtime","exists"')
    }

        Write-Utf8NoBomLines -Path $inventoryPath -Lines ([string[]]$jsonlLines)
        Write-Utf8NoBomLines -Path $snapshotBeforePath -Lines ([string[]]$csvLines)

        Write-Output $config
    }
}

$resolvedConfig = Resolve-StandaloneConfig -ConfigPath $ConfigPath -RunDir $RunDir -InboxRoot $InboxRoot -ArchiveRoot $ArchiveRoot -RawSourcesRoot $RawSourcesRoot -ReviewRoot $ReviewRoot -ThemeList $ThemeList -Scope $Scope
Invoke-ScanInbox -Config $resolvedConfig | Out-Null
