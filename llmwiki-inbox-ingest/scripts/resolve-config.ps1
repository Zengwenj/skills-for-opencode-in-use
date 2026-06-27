#Requires -Version 7.0
<#
.SYNOPSIS
    Resolves and validates llmwiki-ingest configuration for downstream scripts.

.DESCRIPTION
    Config discovery walks CWD upward for `.llmwiki-ingest/config.json`.
    CLI parameters override config fields. --init generates a starter config
    and exits. Validates themeList against Windows folder-name safety rules.
    Creates timestamped run directory. Optionally creates .apply.lock.
    Outputs a resolved configuration object to the pipeline.

    When dot-sourced, exposes Resolve-LlmwikiConfig for use by other scripts.
    When run directly, executes Resolve-LlmwikiConfig with the caller's parameters.

.PARAMETER Init
    Create `.llmwiki-ingest/config.json` from the bundled example config and a
    commented approval template, then exit 0. Does not scan.

.PARAMETER InboxRoot
    Override the inboxRoot field from config.

.PARAMETER ArchiveRoot
    Override the archiveRoot field from config.

.PARAMETER RawSourcesRoot
    Override the rawSourcesRoot field from config.

.PARAMETER ReviewRoot
    Override the reviewRoot field from config.

.PARAMETER ThemeList
    Override the themeList field from config (comma-separated string).

.PARAMETER Scope
    Override the scope field from config.

.PARAMETER CreateLock
    Create `.apply.lock` inside the run directory after creation.

.PARAMETER ConfigPath
    Explicit path to config.json. Overrides discovery.

.EXAMPLE
    pwsh -File scripts/resolve-config.ps1
    Discover config from CWD upward and output resolved object.

.EXAMPLE
    pwsh -File scripts/resolve-config.ps1 -Init
    Generate starter config in CWD and exit.

.EXAMPLE
    pwsh -File scripts/resolve-config.ps1 -InboxRoot "D:\inbox"
    Override inboxRoot from CLI.

.NOTES
    All paths normalized via [System.IO.Path]::GetFullPath().
    File output is UTF-8 no BOM.
    Run directory format: reviewRoot/YYYYMMDD-HHMMSS-<6hex>
#>

[CmdletBinding(DefaultParameterSetName='Resolve')]
param(
    [Parameter(ParameterSetName='Init', Mandatory=$false)]
    [switch]$Init,

    [Parameter(ParameterSetName='Resolve')]
    [string]$InboxRoot,

    [Parameter(ParameterSetName='Resolve')]
    [string]$ArchiveRoot,

    [Parameter(ParameterSetName='Resolve')]
    [string]$RawSourcesRoot,

    [Parameter(ParameterSetName='Resolve')]
    [string]$ReviewRoot,

    [Parameter(ParameterSetName='Resolve')]
    [string]$ThemeList,

    [Parameter(ParameterSetName='Resolve')]
    [string]$Scope,

    [Parameter(ParameterSetName='Resolve')]
    [switch]$CreateLock,

    [Parameter(ParameterSetName='Resolve')]
    [string]$ConfigPath
)

# ===========================================================================
# CONSTANTS
# ===========================================================================

$script:RequiredConfigFields = @('inboxRoot', 'archiveRoot', 'rawSourcesRoot', 'reviewRoot', 'themeList', 'scope')

$script:IllegalChars       = @('\', '/', ':', '*', '?', '"', '<', '>', '|')
$script:ReservedNames      = @(
    'CON', 'PRN', 'AUX', 'NUL',
    'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
    'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9'
)

# ===========================================================================
# HELPER: write an error in the standard 4-part format
# ===========================================================================
function Write-ConfigError {
    param(
        [string]$What,
        [string]$Where,
        [string]$Expected,
        [string]$Fix
    )
    $msg = @(
        "[ERROR] $What",
        "  File/Field: $Where",
        "  Expected: $Expected",
        "  Action: $Fix"
    ) -join "`n"
    Write-Error $msg
}

# ===========================================================================
# HELPER: validate a single theme name against Windows folder-name rules
# ===========================================================================
function Test-ThemeName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }

    # Check for illegal characters
    foreach ($ch in $script:IllegalChars) {
        if ($Name.Contains($ch)) { return $false }
    }

    # Check for Windows reserved names (case-insensitive, with or without extension)
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($Name)
    if ($script:ReservedNames -contains $baseName.ToUpperInvariant()) { return $false }

    # Check trailing dot or space
    if ($Name[-1] -eq '.' -or $Name[-1] -eq ' ') { return $false }

    # Check for control characters
    foreach ($c in $Name.ToCharArray()) {
        if ([char]::IsControl($c)) { return $false }
    }

    return $true
}

# ===========================================================================
# HELPER: validate the entire themeList
# ===========================================================================
function Validate-ThemeList {
    param([string[]]$Themes, [string]$ConfigSource)

    if ($null -eq $Themes -or $Themes.Count -eq 0) {
        Write-ConfigError -What "themeList is empty or missing" `
                          -Where "config file: $ConfigSource -> themeList" `
                          -Expected "Non-empty array of theme names" `
                          -Fix "Add at least one valid theme name to themeList in config.json"
        return $false
    }

    $allValid = $true
    $seen = @{}
    for ($i = 0; $i -lt $Themes.Count; $i++) {
        $theme = $Themes[$i]
        if ($seen.ContainsKey($theme)) {
            Write-ConfigError -What "Duplicate theme name '$theme'" `
                              -Where "config file: $ConfigSource -> themeList[$i]" `
                              -Expected "Unique theme names" `
                              -Fix "Remove duplicate entry for '$theme' from themeList"
            $allValid = $false
            continue
        }
        $seen[$theme] = $true

        if (-not (Test-ThemeName -Name $theme)) {
            Write-ConfigError -What "Theme name '$theme' is not a valid Windows folder name" `
                              -Where "config file: $ConfigSource -> themeList[$i]" `
                              -Expected "Name must not contain \ / : * ? `" < > |, must not be a reserved name (CON, PRN, etc.), must not end with . or space" `
                              -Fix "Rename theme '$theme' to a valid folder name in config.json"
            $allValid = $false
        }
    }

    return $allValid
}

# ===========================================================================
# HELPER: resolve path to the script's own assets directory
# ===========================================================================
function Get-AssetsDir {
    # Script is at <skill>/scripts/resolve-config.ps1
    # Assets are at <skill>/assets/
    return Join-Path -Path $PSScriptRoot -ChildPath '..\assets'
}

# ===========================================================================
# INIT MODE: generate example config and exit
# ===========================================================================
function Invoke-InitMode {
    $cwd = Get-Location
    $configDir = Join-Path -Path $cwd -ChildPath '.llmwiki-ingest'

    if (Test-Path -LiteralPath $configDir -PathType Container) {
        Write-Host "[INFO] Directory already exists: $configDir" -ForegroundColor Yellow
    } else {
        try {
            New-Item -ItemType Directory -Path $configDir -ErrorAction Stop | Out-Null
            Write-Host "[OK] Created directory: $configDir" -ForegroundColor Green
        } catch {
            Write-ConfigError -What "Failed to create .llmwiki-ingest directory" `
                              -Where "CWD: $cwd" `
                              -Expected "Writable directory at $configDir" `
                              -Fix "Check permissions and try again, or create $configDir manually"
            throw
        }
    }

    $assetsDir = Get-AssetsDir
    $exampleConfig = Join-Path -Path $assetsDir -ChildPath 'example-config.json'
    $approvalTemplate = Join-Path -Path $assetsDir -ChildPath 'approval-template.md'

    $targetConfig = Join-Path -Path $configDir -ChildPath 'config.json'
    $targetApproval = Join-Path -Path $configDir -ChildPath 'approval-template.md'

    # Copy example config
    if (-not (Test-Path -LiteralPath $exampleConfig)) {
        Write-ConfigError -What "Example config asset not found" `
                          -Where "$exampleConfig" `
                          -Expected "File to exist" `
                          -Fix "Ensure the skill package has assets/example-config.json"
        throw "Missing asset: $exampleConfig"
    }

    $configContent = Get-Content -LiteralPath $exampleConfig -Raw -Encoding UTF8
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($targetConfig, $configContent, $utf8NoBom)
    Write-Host "[OK] Created: $targetConfig" -ForegroundColor Green

    # Copy approval template
    if (Test-Path -LiteralPath $approvalTemplate) {
        $approvalContent = Get-Content -LiteralPath $approvalTemplate -Raw -Encoding UTF8
        [System.IO.File]::WriteAllText($targetApproval, $approvalContent, $utf8NoBom)
        Write-Host "[OK] Created: $targetApproval" -ForegroundColor Green
    } else {
        Write-Host "[WARN] Approval template asset not found at $approvalTemplate — skipping" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "=== Next steps ===" -ForegroundColor Cyan
    Write-Host "1. Edit '$targetConfig' to set your paths:" -ForegroundColor White
    Write-Host "   - inboxRoot:      where raw inbox files live" -ForegroundColor White
    Write-Host "   - archiveRoot:    where committed archives go" -ForegroundColor White
    Write-Host "   - rawSourcesRoot: where raw/sources Markdown output goes" -ForegroundColor White
    Write-Host "   - reviewRoot:     where review runs and artifacts live" -ForegroundColor White
    Write-Host "   - themeList:      your classification themes (folder-safe names)" -ForegroundColor White
    Write-Host "   - scope:          scan scope (default: root_inbox_recursive)" -ForegroundColor White
    Write-Host "2. Review '$targetApproval' for the approval workflow template" -ForegroundColor White
    Write-Host "3. Run 'pwsh -File scripts/resolve-config.ps1' to verify config" -ForegroundColor White

    exit 0
}

# ===========================================================================
# CONFIG DISCOVERY: walk CWD upward for .llmwiki-ingest/config.json
# ===========================================================================
function Find-ConfigFile {
    param([string]$ExplicitPath)

    if ($ExplicitPath) {
        $resolved = [System.IO.Path]::GetFullPath($ExplicitPath)
        if (Test-Path -LiteralPath $resolved -PathType Leaf) {
            return $resolved
        }
        Write-ConfigError -What "Config file not found at explicit path" `
                          -Where "$resolved (from -ConfigPath)" `
                          -Expected "Existing file at $resolved" `
                          -Fix "Check the path, or run with -Init to create a new config"
        return $null
    }

    $current = Get-Location
    $searchPath = $current.Path

    while ($true) {
        $candidate = Join-Path -Path $searchPath -ChildPath '.llmwiki-ingest\config.json'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [System.IO.Path]::GetFullPath($candidate)
        }

        $parent = Split-Path -Path $searchPath -Parent
        if (-not $parent -or $parent -eq $searchPath) {
            # Reached root
            break
        }
        $searchPath = $parent
    }

    Write-ConfigError -What "No config file found" `
                      -Where "Searched CWD and parent directories for .llmwiki-ingest\config.json" `
                      -Expected "A config file at .llmwiki-ingest\config.json in CWD or a parent directory" `
                      -Fix "Run 'pwsh -File scripts/resolve-config.ps1 -Init' to create a starter config"
    return $null
}

# ===========================================================================
# CONFIG LOADING AND VALIDATION
# ===========================================================================
function Load-Config {
    param([string]$ConfigFile)

    # Read and parse JSON
    try {
        $raw = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8
        $config = $raw | ConvertFrom-Json -AsHashtable
    } catch {
        Write-ConfigError -What "Failed to parse config JSON" `
                          -Where "$ConfigFile" `
                          -Expected "Valid JSON" `
                          -Fix "Check JSON syntax in $ConfigFile. Error: $($_.Exception.Message)"
        return $null
    }

    # Validate required fields exist
    $missing = @()
    foreach ($field in $script:RequiredConfigFields) {
        if (-not $config.ContainsKey($field)) {
            $missing += $field
        }
    }
    if ($missing.Count -gt 0) {
        Write-ConfigError -What "Config is missing required fields" `
                          -Where "$ConfigFile" `
                          -Expected "All fields present: $($script:RequiredConfigFields -join ', ')" `
                          -Fix "Add missing fields to config.json: $($missing -join ', ')"
        return $null
    }

    # Validate types
    $stringFields = @('inboxRoot', 'archiveRoot', 'rawSourcesRoot', 'reviewRoot', 'scope')
    foreach ($field in $stringFields) {
        if ($null -ne $config[$field] -and $config[$field] -isnot [string]) {
            Write-ConfigError -What "Config field '$field' must be a string" `
                              -Where "$ConfigFile -> $field" `
                              -Expected "String value" `
                              -Fix "Set '$field' to a string in config.json"
            return $null
        }
    }

    if ($null -ne $config['themeList'] -and $config['themeList'] -isnot [array]) {
        Write-ConfigError -What "Config field 'themeList' must be an array" `
                          -Where "$ConfigFile -> themeList" `
                          -Expected "Array of strings" `
                          -Fix "Set themeList to an array of strings in config.json"
        return $null
    }

    return $config
}

# ===========================================================================
# THEME LIST VALIDATION
# ===========================================================================
function Test-ConfigThemeList {
    param([hashtable]$Config, [string]$ConfigFile)

    $themes = $Config['themeList']
    if ($themes -is [array]) {
        $themeArray = [string[]]$themes
    } elseif ($themes -is [string]) {
        # Gracefully handle single string: wrap in array with warning
        Write-Warning "themeList is a single string; wrapping in array. Consider using an array format in config.json."
        $themeArray = @([string]$themes)
    } else {
        Write-ConfigError -What "themeList is not a valid array" `
                          -Where "$ConfigFile -> themeList" `
                          -Expected "Array of theme name strings" `
                          -Fix "Set themeList to an array like: `"themeList`": [`"ThemeA`", `"ThemeB`"]"
        return $null
    }

    if (-not (Validate-ThemeList -Themes $themeArray -ConfigSource $ConfigFile)) {
        return $null
    }

    return $themeArray
}

# ===========================================================================
# RUN DIRECTORY CREATION
# ===========================================================================
function New-RunDirectory {
    param(
        [string]$ReviewRoot,
        [switch]$DoCreateLock
    )

    # Normalize reviewRoot
    $reviewRootNorm = [System.IO.Path]::GetFullPath($ReviewRoot)

    # Generate timestamp: YYYYMMDD-HHMMSS
    $now = [DateTime]::Now
    $ts = $now.ToString('yyyyMMdd-HHmmss')

    # Generate 6 random hex chars using cryptographic RNG
    $bytes = [byte[]]::new(3)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $hex = ($bytes | ForEach-Object { $_.ToString('x2') }) -join ''

    $runDirName = "$ts-$hex"
    $runDir = Join-Path -Path $reviewRootNorm -ChildPath $runDirName

    # Fail closed if run directory already exists
    if (Test-Path -LiteralPath $runDir) {
        Write-ConfigError -What "Run directory already exists — refusing to overwrite or reuse" `
                          -Where "$runDir" `
                          -Expected "A new, unique run directory" `
                          -Fix "Wait a moment and retry (timestamp + random hex will differ), or clean up the existing directory manually if it is stale"
        return $null
    }

    # Ensure reviewRoot exists
    if (-not (Test-Path -LiteralPath $reviewRootNorm -PathType Container)) {
        try {
            New-Item -ItemType Directory -Path $reviewRootNorm -Force -ErrorAction Stop | Out-Null
        } catch {
            Write-ConfigError -What "Failed to create reviewRoot directory" `
                              -Where "$reviewRootNorm" `
                              -Expected "Writable directory" `
                              -Fix "Check permissions for $reviewRootNorm. Error: $($_.Exception.Message)"
            return $null
        }
    }

    # Create run directory
    try {
        New-Item -ItemType Directory -Path $runDir -ErrorAction Stop | Out-Null
        Write-Host "[OK] Created run directory: $runDir" -ForegroundColor Green
    } catch {
        Write-ConfigError -What "Failed to create run directory" `
                          -Where "$runDir" `
                          -Expected "Writable directory at $runDir" `
                          -Fix "Check permissions and disk space. Error: $($_.Exception.Message)"
        return $null
    }

    # Create apply lock if requested
    if ($DoCreateLock) {
        $lockPath = Join-Path -Path $runDir -ChildPath '.apply.lock'
        try {
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            $lockContent = @{
                created_at = $now.ToString('o')
                run_id     = $runDirName
                pid        = $PID
            } | ConvertTo-Json -Compress
            [System.IO.File]::WriteAllText($lockPath, $lockContent, $utf8NoBom)
            Write-Host "[OK] Created apply lock: $lockPath" -ForegroundColor Green
        } catch {
            Write-ConfigError -What "Failed to create .apply.lock" `
                              -Where "$lockPath" `
                              -Expected "Writable file at $lockPath" `
                              -Fix "Check permissions. Error: $($_.Exception.Message)"
            return $null
        }
    }

    return @{
        RunDir     = $runDir
        RunDirName = $runDirName
        Timestamp  = $ts
        RandomHex  = $hex
    }
}

# ===========================================================================
# MAIN: resolve config and return structured object
# ===========================================================================
function Resolve-LlmwikiConfig {
    [CmdletBinding(DefaultParameterSetName='Resolve')]
    param(
        [Parameter(ParameterSetName='Init', Mandatory=$false)]
        [switch]$Init,

        [Parameter(ParameterSetName='Resolve')]
        [string]$InboxRoot,

        [Parameter(ParameterSetName='Resolve')]
        [string]$ArchiveRoot,

        [Parameter(ParameterSetName='Resolve')]
        [string]$RawSourcesRoot,

        [Parameter(ParameterSetName='Resolve')]
        [string]$ReviewRoot,

        [Parameter(ParameterSetName='Resolve')]
        [string]$ThemeList,

        [Parameter(ParameterSetName='Resolve')]
        [string]$Scope,

        [Parameter(ParameterSetName='Resolve')]
        [switch]$CreateLock,

        [Parameter(ParameterSetName='Resolve')]
        [string]$ConfigPath
    )

    # --init mode: generate starter config and exit
    if ($Init) {
        Invoke-InitMode
        # unreachable (exit 0 called above)
        return
    }

    # --- Config discovery ---
    $configFile = Find-ConfigFile -ExplicitPath $ConfigPath
    if (-not $configFile) {
        exit 1
    }

    # --- Load and validate config ---
    $config = Load-Config -ConfigFile $configFile
    if (-not $config) {
        exit 1
    }

    # Compute config SHA256
    $configHashBytes = Get-FileHash -Algorithm SHA256 -LiteralPath $configFile
    $configSha256 = $configHashBytes.Hash

    # --- ThemeList validation ---
    $validatedThemes = Test-ConfigThemeList -Config $config -ConfigFile $configFile
    if (-not $validatedThemes) {
        exit 1
    }

    # --- Apply CLI overrides ---
    $finalConfig = @{}
    foreach ($key in $config.Keys) {
        $finalConfig[$key] = $config[$key]
    }

    # Override individual string fields
    if ($PSBoundParameters.ContainsKey('InboxRoot')) {
        $finalConfig['inboxRoot'] = [System.IO.Path]::GetFullPath($InboxRoot)
    } else {
        $finalConfig['inboxRoot'] = [System.IO.Path]::GetFullPath($config['inboxRoot'])
    }

    if ($PSBoundParameters.ContainsKey('ArchiveRoot')) {
        $finalConfig['archiveRoot'] = [System.IO.Path]::GetFullPath($ArchiveRoot)
    } else {
        $finalConfig['archiveRoot'] = [System.IO.Path]::GetFullPath($config['archiveRoot'])
    }

    if ($PSBoundParameters.ContainsKey('RawSourcesRoot')) {
        $finalConfig['rawSourcesRoot'] = [System.IO.Path]::GetFullPath($RawSourcesRoot)
    } else {
        $finalConfig['rawSourcesRoot'] = [System.IO.Path]::GetFullPath($config['rawSourcesRoot'])
    }

    if ($PSBoundParameters.ContainsKey('ReviewRoot')) {
        $finalConfig['reviewRoot'] = [System.IO.Path]::GetFullPath($ReviewRoot)
    } else {
        $finalConfig['reviewRoot'] = [System.IO.Path]::GetFullPath($config['reviewRoot'])
    }

    if ($PSBoundParameters.ContainsKey('Scope')) {
        $finalConfig['scope'] = $Scope
    }

    # Override themeList
    if ($PSBoundParameters.ContainsKey('ThemeList')) {
        $overrideThemes = $ThemeList -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
        if (Validate-ThemeList -Themes $overrideThemes -ConfigSource 'CLI argument -ThemeList') {
            $validatedThemes = $overrideThemes
        } else {
            exit 1
        }
    }
    $finalConfig['themeList'] = $validatedThemes

    # --- Create run directory ---
    $runInfo = New-RunDirectory -ReviewRoot $finalConfig['reviewRoot'] -DoCreateLock:$CreateLock
    if (-not $runInfo) {
        exit 1
    }

    # --- Build output object ---
    $result = [PSCustomObject]@{
        ConfigPath       = $configFile
        ConfigSha256     = $configSha256
        InboxRoot        = $finalConfig['inboxRoot']
        ArchiveRoot      = $finalConfig['archiveRoot']
        RawSourcesRoot   = $finalConfig['rawSourcesRoot']
        ReviewRoot       = $finalConfig['reviewRoot']
        ThemeList        = $validatedThemes
        Scope            = $finalConfig['scope']
        RunDir           = $runInfo.RunDir
        RunDirName       = $runInfo.RunDirName
        RunTimestamp     = $runInfo.Timestamp
        RunRandomHex     = $runInfo.RandomHex
        LockCreated      = $CreateLock.IsPresent
    }

    return $result
}

# ===========================================================================
# SCRIPT ENTRY POINT
# ===========================================================================
# When run as a script (not dot-sourced), execute with the caller's parameters.
# When dot-sourced, the caller gets the function definitions without execution.
if ($MyInvocation.InvocationName -ne '.') {
    $splat = @{}
    if ($Init)              { $splat['Init'] = $true }
    if ($PSBoundParameters.ContainsKey('InboxRoot'))      { $splat['InboxRoot'] = $InboxRoot }
    if ($PSBoundParameters.ContainsKey('ArchiveRoot'))    { $splat['ArchiveRoot'] = $ArchiveRoot }
    if ($PSBoundParameters.ContainsKey('RawSourcesRoot')) { $splat['RawSourcesRoot'] = $RawSourcesRoot }
    if ($PSBoundParameters.ContainsKey('ReviewRoot'))     { $splat['ReviewRoot'] = $ReviewRoot }
    if ($PSBoundParameters.ContainsKey('ThemeList'))      { $splat['ThemeList'] = $ThemeList }
    if ($PSBoundParameters.ContainsKey('Scope'))          { $splat['Scope'] = $Scope }
    if ($CreateLock)        { $splat['CreateLock'] = $true }
    if ($PSBoundParameters.ContainsKey('ConfigPath'))     { $splat['ConfigPath'] = $ConfigPath }

    $output = Resolve-LlmwikiConfig @splat
    if ($output) {
        # Output to pipeline so callers can capture it
        $output
        exit 0
    }
    exit 1
}
