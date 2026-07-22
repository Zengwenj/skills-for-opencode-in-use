<#
.SYNOPSIS
验证 Office COM 与 Markdown PDF 转换工具链。

.DESCRIPTION
在临时目录中使用 OfficeCLI 创建最小 DOCX、XLSX、PPTX 夹具，并创建一个
Markdown 夹具。随后调用同目录的转换脚本生成 PDF，再使用 Poppler 验证页数
和中文锚点。默认在测试完成后删除工作目录。

.PARAMETER WorkDir
夹具、中间产物和 PDF 的工作目录。默认是 $env:TEMP\doc-toolchain-test。

.PARAMETER KeepArtifacts
保留工作目录及其全部测试产物。
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$WorkDir = (Join-Path $env:TEMP 'doc-toolchain-test'),

    [switch]$KeepArtifacts
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$markitdownPath = 'C:\Users\zengw\anaconda3\Scripts\markitdown.exe'
$pdfinfoPath = 'C:\Users\zengw\anaconda3\Library\bin\pdfinfo.exe'
$pdftotextPath = 'C:\Users\zengw\anaconda3\Library\bin\pdftotext.exe'
$exportOfficePdf = Join-Path $PSScriptRoot 'Export-OfficePdf.ps1'
$convertMarkdownToPdf = Join-Path $PSScriptRoot 'Convert-MarkdownToPdf.ps1'
$workingDirectory = [System.IO.Path]::GetFullPath($WorkDir)
$toolResults = @()
$testResults = @()
$fixtureErrors = @{}
$cleanupStatus = '未执行'
$cleanupError = ''

function Test-NativeTool {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ToolName,

        [Parameter(Mandatory)]
        [string]$Executable,

        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $commandPath = $null

    try {
        if ([System.IO.Path]::IsPathRooted($Executable)) {
            if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) {
                throw "$ToolName 可执行文件不存在: $Executable"
            }

            $commandPath = (Get-Item -LiteralPath $Executable -ErrorAction Stop).FullName
        }
        else {
            $command = Get-Command -Name $Executable -CommandType Application -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($null -eq $command) {
                throw "$ToolName 未在 PATH 中找到。"
            }

            $commandPath = $command.Path
        }

        $probeOutput = & $commandPath @Arguments 2>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            $details = (@($probeOutput) -join [System.Environment]::NewLine).Trim()
            throw "$ToolName 版本检测失败，退出代码 $exitCode。$details"
        }

        $version = @($probeOutput |
                ForEach-Object { ([string]$_).Trim() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Select-Object -First 1)

        [pscustomobject]@{
            Tool    = $ToolName
            Version = if ($version.Count -gt 0) { $version[0] } else { '版本未知' }
            Status  = '通过'
            Error   = ''
            Path    = $commandPath
        }
    }
    catch {
        [pscustomobject]@{
            Tool    = $ToolName
            Version = '-'
            Status  = '失败'
            Error   = $_.Exception.Message
            Path    = $commandPath
        }
    }
}

function Test-OfficeCom {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ToolName,

        [Parameter(Mandatory)]
        [string]$ProgId
    )

    $application = $null

    try {
        $application = New-Object -ComObject $ProgId
        [pscustomobject]@{
            Tool    = $ToolName
            Version = [string]$application.Version
            Status  = '通过'
            Error   = ''
            Path    = $ProgId
        }
    }
    catch {
        [pscustomobject]@{
            Tool    = $ToolName
            Version = '-'
            Status  = '失败'
            Error   = $_.Exception.Message
            Path    = $ProgId
        }
    }
    finally {
        if ($null -ne $application) {
            try {
                [void]$application.Quit()
            }
            catch {
            }

            try {
                [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($application)
            }
            catch {
            }

            [System.GC]::Collect()
            [System.GC]::WaitForPendingFinalizers()
        }
    }
}

function Invoke-OfficeCliCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Executable,

        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $commandOutput = & $Executable @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        $details = (@($commandOutput) -join [System.Environment]::NewLine).Trim()
        throw "officecli $($Arguments -join ' ') 失败，退出代码 $exitCode。$details"
    }
}

function Remove-TestWorkDir {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $lastError = ''
    for ($attempt = 1; $attempt -le 20; $attempt++) {
        try {
            if (Test-Path -LiteralPath $Path -PathType Container) {
                Remove-Item -LiteralPath $Path -Recurse -Force
            }

            return
        }
        catch {
            $lastError = $_.Exception.Message
            if ($attempt -eq 20) {
                throw "删除 WorkDir 失败: $lastError"
            }

            Start-Sleep -Milliseconds 500
        }
    }
}

function New-DocxFixture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$OfficeCli,

        [Parameter(Mandatory)]
        [string]$Path
    )

    Invoke-OfficeCliCommand -Executable $OfficeCli -Arguments @('create', $Path)
    Invoke-OfficeCliCommand -Executable $OfficeCli -Arguments @(
        'add', $Path, '/body', '--type', 'paragraph', '--prop', 'text=测试标题', '--prop', 'style=Heading1'
    )
    Invoke-OfficeCliCommand -Executable $OfficeCli -Arguments @(
        'add', $Path, '/body', '--type', 'paragraph', '--prop', 'text=收入增长百分之二十五'
    )
    Invoke-OfficeCliCommand -Executable $OfficeCli -Arguments @(
        'add', $Path, '/body', '--type', 'table', '--prop', 'data=项目,数值;收入,25'
    )
    Invoke-OfficeCliCommand -Executable $OfficeCli -Arguments @('save', $Path)
    Invoke-OfficeCliCommand -Executable $OfficeCli -Arguments @('close', $Path)
}

function New-XlsxFixture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$OfficeCli,

        [Parameter(Mandatory)]
        [string]$Path
    )

    Invoke-OfficeCliCommand -Executable $OfficeCli -Arguments @('create', $Path)
    Invoke-OfficeCliCommand -Executable $OfficeCli -Arguments @('set', $Path, '/Sheet1/A1', '--prop', 'value=月份', '--prop', 'bold=true')
    Invoke-OfficeCliCommand -Executable $OfficeCli -Arguments @('set', $Path, '/Sheet1/B1', '--prop', 'value=收入', '--prop', 'bold=true')
    Invoke-OfficeCliCommand -Executable $OfficeCli -Arguments @('set', $Path, '/Sheet1/C1', '--prop', 'value=备注', '--prop', 'bold=true')
    Invoke-OfficeCliCommand -Executable $OfficeCli -Arguments @('set', $Path, '/Sheet1/A2', '--prop', 'value=一月')
    Invoke-OfficeCliCommand -Executable $OfficeCli -Arguments @('set', $Path, '/Sheet1/B2', '--prop', 'value=250000')
    Invoke-OfficeCliCommand -Executable $OfficeCli -Arguments @('set', $Path, '/Sheet1/C2', '--prop', 'value=同比增长')
    Invoke-OfficeCliCommand -Executable $OfficeCli -Arguments @('set', $Path, '/Sheet1/col[A]', '--prop', 'width=14')
    Invoke-OfficeCliCommand -Executable $OfficeCli -Arguments @('set', $Path, '/Sheet1/col[B]', '--prop', 'width=16')
    Invoke-OfficeCliCommand -Executable $OfficeCli -Arguments @('set', $Path, '/Sheet1/col[C]', '--prop', 'width=20')
    Invoke-OfficeCliCommand -Executable $OfficeCli -Arguments @('save', $Path)
    Invoke-OfficeCliCommand -Executable $OfficeCli -Arguments @('close', $Path)
}

function New-PptxFixture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$OfficeCli,

        [Parameter(Mandatory)]
        [string]$Path
    )

    Invoke-OfficeCliCommand -Executable $OfficeCli -Arguments @('create', $Path)
    Invoke-OfficeCliCommand -Executable $OfficeCli -Arguments @(
        'add', $Path, '/', '--type', 'slide', '--prop', 'title=季度报告'
    )
    Invoke-OfficeCliCommand -Executable $OfficeCli -Arguments @(
        'add', $Path, '/slide[1]', '--type', 'shape', '--prop', 'text=营收增长25%',
        '--prop', 'x=2cm', '--prop', 'y=5cm', '--prop', 'width=20cm', '--prop', 'height=3cm',
        '--prop', 'size=24pt'
    )
    Invoke-OfficeCliCommand -Executable $OfficeCli -Arguments @('save', $Path)
    Invoke-OfficeCliCommand -Executable $OfficeCli -Arguments @('close', $Path)
}

function Invoke-MarkdownConversion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$InputPath,

        [Parameter(Mandatory)]
        [string]$OutputPath,

        [Parameter(Mandatory)]
        [string]$TestWorkDir,

        [Parameter(Mandatory)]
        [string]$PandocPath
    )

    $pandocDirectory = Split-Path -Path $PandocPath -Parent
    if (-not (Test-Path -LiteralPath $PandocPath -PathType Leaf)) {
        throw "Pandoc 可执行文件不存在: $PandocPath"
    }

    $originalPath = $env:PATH
    $separator = [System.IO.Path]::PathSeparator

    try {
        $pathEntries = @($originalPath.Split($separator) |
                ForEach-Object { $_.Trim().Trim('"') } |
                Where-Object {
                    -not [string]::IsNullOrWhiteSpace($_) -and
                    -not (Test-Path -LiteralPath (Join-Path $_ 'pandoc.exe') -PathType Leaf)
                })
        $env:PATH = (@($pandocDirectory) + $pathEntries) -join $separator
        & $convertMarkdownToPdf -InputPath $InputPath -OutputPath $OutputPath -WorkDir $TestWorkDir
    }
    finally {
        $env:PATH = $originalPath
    }
}

function Get-PdfPageCount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PdfInfo,

        [Parameter(Mandatory)]
        [string]$PdfPath
    )

    if ([string]::IsNullOrWhiteSpace($PdfInfo)) {
        throw 'pdfinfo 不可用。'
    }

    $infoOutput = & $PdfInfo $PdfPath 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "pdfinfo 验证失败，退出代码 $exitCode。$(@($infoOutput) -join ' ')"
    }

    foreach ($line in @($infoOutput)) {
        if ([string]$line -match '^\s*Pages:\s*(?<Pages>\d+)\s*$') {
            return [int]$Matches.Pages
        }
    }

    throw 'pdfinfo 输出中缺少 Pages 字段。'
}

function Test-PdfChineseAnchor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PdfToText,

        [Parameter(Mandatory)]
        [string]$PdfPath,

        [Parameter(Mandatory)]
        [string]$Anchor
    )

    if ([string]::IsNullOrWhiteSpace($PdfToText)) {
        throw 'pdftotext 不可用。'
    }

    $textPath = [System.IO.Path]::ChangeExtension($PdfPath, '.txt')
    $textOutput = & $PdfToText '-enc' 'UTF-8' $PdfPath $textPath 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "pdftotext 验证失败，退出代码 $exitCode。$(@($textOutput) -join ' ')"
    }

    if (-not (Test-Path -LiteralPath $textPath -PathType Leaf)) {
        throw "pdftotext 未生成文本文件: $textPath"
    }

    $text = [System.IO.File]::ReadAllText($textPath, [System.Text.Encoding]::UTF8)
    $normalizedText = [System.Text.RegularExpressions.Regex]::Replace($text, '\s+', '')
    $normalizedAnchor = [System.Text.RegularExpressions.Regex]::Replace($Anchor, '\s+', '')
    return $normalizedText.Contains($normalizedAnchor)
}

function Invoke-PdfTest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [ValidateSet('Office', 'Markdown')]
        [string]$Mode,

        [Parameter(Mandatory)]
        [string]$InputPath,

        [Parameter(Mandatory)]
        [string]$OutputPath,

        [Parameter(Mandatory)]
        [string]$Anchor,

        [Parameter(Mandatory)]
        [string]$PdfInfo,

        [Parameter(Mandatory)]
        [string]$PdfToText,

        [Parameter(Mandatory)]
        [string]$TestWorkDir,
        [Parameter(Mandatory)]
        [string]$PandocPath
    )

    $errors = @()
    $pages = $null
    $anchorFound = $false

    try {
        if (-not (Test-Path -LiteralPath $InputPath -PathType Leaf)) {
            throw "测试夹具不存在: $InputPath"
        }

        if ($Mode -eq 'Office') {
            & $exportOfficePdf -InputPath $InputPath -OutputPath $OutputPath
        }
        else {
            Invoke-MarkdownConversion -InputPath $InputPath -OutputPath $OutputPath -TestWorkDir $TestWorkDir -PandocPath $PandocPath
        }
    }
    catch {
        $errors += "转换失败: $($_.Exception.Message)"
    }

    if (Test-Path -LiteralPath $OutputPath -PathType Leaf) {
        try {
            $pages = Get-PdfPageCount -PdfInfo $PdfInfo -PdfPath $OutputPath
            if ($pages -le 0) {
                $errors += "pdfinfo 返回无效页数: $pages"
            }
        }
        catch {
            $errors += "pdfinfo: $($_.Exception.Message)"
        }

        try {
            $anchorFound = Test-PdfChineseAnchor -PdfToText $PdfToText -PdfPath $OutputPath -Anchor $Anchor
            if (-not $anchorFound) {
                $errors += "pdftotext 未找到中文锚点: $Anchor"
            }
        }
        catch {
            $errors += "pdftotext: $($_.Exception.Message)"
        }
    }
    else {
        $errors += "未生成预期的 PDF: $OutputPath"
    }

    [pscustomobject]@{
        Name        = $Name
        InputPath   = $InputPath
        PdfPath     = $OutputPath
        Pages       = $pages
        Anchor      = $Anchor
        AnchorFound = $anchorFound
        Status      = if ($errors.Count -eq 0 -and $pages -gt 0 -and $anchorFound) { '通过' } else { '失败' }
        Error       = $errors -join ' | '
    }
}

Write-Host "测试工作目录: $workingDirectory"
Write-Host '开始检测工具与 Office COM 后端...'

$officeCliResult = Test-NativeTool -ToolName 'officecli' -Executable 'officecli' -Arguments @('--version')
$toolResults += $officeCliResult
$pandocResult = Test-NativeTool -ToolName 'pandoc' -Executable 'pandoc' -Arguments @('--version')
$toolResults += $pandocResult
$markitdownResult = Test-NativeTool -ToolName 'markitdown' -Executable $markitdownPath -Arguments @('--version')
$toolResults += $markitdownResult
$pdfinfoResult = Test-NativeTool -ToolName 'pdfinfo' -Executable $pdfinfoPath -Arguments @('-v')
$toolResults += $pdfinfoResult
$pdftotextResult = Test-NativeTool -ToolName 'pdftotext' -Executable $pdftotextPath -Arguments @('-v')
$toolResults += $pdftotextResult
$wordComResult = Test-OfficeCom -ToolName 'Word COM' -ProgId 'Word.Application'
$toolResults += $wordComResult
$excelComResult = Test-OfficeCom -ToolName 'Excel COM' -ProgId 'Excel.Application'
$toolResults += $excelComResult
$powerPointComResult = Test-OfficeCom -ToolName 'PowerPoint COM' -ProgId 'PowerPoint.Application'
$toolResults += $powerPointComResult

$workDirReady = $false
$workDirError = ''

try {
    if (Test-Path -LiteralPath $workingDirectory -PathType Leaf) {
        throw "WorkDir 指向文件而不是目录: $workingDirectory"
    }

    if (Test-Path -LiteralPath $workingDirectory -PathType Container) {
        Remove-TestWorkDir -Path $workingDirectory
    }

    New-Item -ItemType Directory -Path $workingDirectory -Force | Out-Null
    $workDirReady = $true
}
catch {
    $workDirError = $_.Exception.Message
    Write-Host "[失败] 准备 WorkDir: $workDirError" -ForegroundColor Red
}

if ($workDirReady) {
    $docxPath = Join-Path $workingDirectory 'fixture.docx'
    $xlsxPath = Join-Path $workingDirectory 'fixture.xlsx'
    $pptxPath = Join-Path $workingDirectory 'fixture.pptx'
    $markdownPath = Join-Path $workingDirectory 'fixture.md'

    if ($officeCliResult.Status -eq '通过') {
        try {
            New-DocxFixture -OfficeCli $officeCliResult.Path -Path $docxPath
            Write-Host '[通过] DOCX 夹具已创建。' -ForegroundColor Green
        }
        catch {
            $fixtureErrors['DOCX'] = $_.Exception.Message
            Write-Host "[失败] DOCX 夹具: $($_.Exception.Message)" -ForegroundColor Red
        }

        try {
            New-XlsxFixture -OfficeCli $officeCliResult.Path -Path $xlsxPath
            Write-Host '[通过] XLSX 夹具已创建。' -ForegroundColor Green
        }
        catch {
            $fixtureErrors['XLSX'] = $_.Exception.Message
            Write-Host "[失败] XLSX 夹具: $($_.Exception.Message)" -ForegroundColor Red
        }

        try {
            New-PptxFixture -OfficeCli $officeCliResult.Path -Path $pptxPath
            Write-Host '[通过] PPTX 夹具已创建。' -ForegroundColor Green
        }
        catch {
            $fixtureErrors['PPTX'] = $_.Exception.Message
            Write-Host "[失败] PPTX 夹具: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    else {
        foreach ($fixtureName in @('DOCX', 'XLSX', 'PPTX')) {
            $fixtureErrors[$fixtureName] = "officecli 检测失败: $($officeCliResult.Error)"
        }
    }

    try {
        $markdownContent = "# Markdown 测试`r`n`r`n这是一个测试段落`r`n"
        [System.IO.File]::WriteAllText($markdownPath, $markdownContent, [System.Text.UTF8Encoding]::new($true))
        Write-Host '[通过] Markdown 夹具已创建。' -ForegroundColor Green
    }
    catch {
        $fixtureErrors['Markdown'] = $_.Exception.Message
        Write-Host "[失败] Markdown 夹具: $($_.Exception.Message)" -ForegroundColor Red
    }

    $testDefinitions = @(
        [pscustomobject]@{
            Name = 'Word DOCX → PDF'; Mode = 'Office'; Fixture = 'DOCX'; Input = $docxPath
            Output = (Join-Path $workingDirectory 'fixture-docx.pdf'); Anchor = '收入增长百分之二十五'
        },
        [pscustomobject]@{
            Name = 'Excel XLSX → PDF'; Mode = 'Office'; Fixture = 'XLSX'; Input = $xlsxPath
            Output = (Join-Path $workingDirectory 'fixture-xlsx.pdf'); Anchor = '收入'
        },
        [pscustomobject]@{
            Name = 'PowerPoint PPTX → PDF'; Mode = 'Office'; Fixture = 'PPTX'; Input = $pptxPath
            Output = (Join-Path $workingDirectory 'fixture-pptx.pdf'); Anchor = '季度报告'
        },
        [pscustomobject]@{
            Name = 'Markdown → DOCX → PDF'; Mode = 'Markdown'; Fixture = 'Markdown'; Input = $markdownPath
            Output = (Join-Path $workingDirectory 'fixture-markdown.pdf'); Anchor = '这是一个测试段落'
        }
    )

    foreach ($definition in $testDefinitions) {
        if ($fixtureErrors.ContainsKey($definition.Fixture)) {
            $testResults += [pscustomobject]@{
                Name        = $definition.Name
                InputPath   = $definition.Input
                PdfPath     = $definition.Output
                Pages       = $null
                Anchor      = $definition.Anchor
                AnchorFound = $false
                Status      = '失败'
                Error       = "夹具生成失败: $($fixtureErrors[$definition.Fixture])"
            }
            continue
        }

        $testResults += Invoke-PdfTest `
            -Name $definition.Name `
            -Mode $definition.Mode `
            -InputPath $definition.Input `
            -OutputPath $definition.Output `
            -Anchor $definition.Anchor `
            -PdfInfo $pdfinfoResult.Path `
            -PdfToText $pdftotextResult.Path `
            -TestWorkDir $workingDirectory `
            -PandocPath $pandocResult.Path
    }
}
else {
    foreach ($name in @('Word DOCX → PDF', 'Excel XLSX → PDF', 'PowerPoint PPTX → PDF', 'Markdown → DOCX → PDF')) {
        $testResults += [pscustomobject]@{
            Name        = $name
            InputPath   = '-'
            PdfPath     = '-'
            Pages       = $null
            Anchor      = '-'
            AnchorFound = $false
            Status      = '失败'
            Error       = "WorkDir 准备失败: $workDirError"
        }
    }
}

if ($KeepArtifacts) {
    $cleanupStatus = '已保留'
}
else {
    try {
        if (Test-Path -LiteralPath $workingDirectory -PathType Container) {
            Remove-TestWorkDir -Path $workingDirectory
        }

        $cleanupStatus = '已清理'
    }
    catch {
        $cleanupStatus = '失败'
        $cleanupError = $_.Exception.Message
        Write-Host "[失败] 清理 WorkDir: $cleanupError" -ForegroundColor Red
    }
}

Write-Host ''
Write-Host '工具检测结果'
Write-Host (($toolResults |
        Select-Object @{ Name = '工具名'; Expression = { $_.Tool } },
        @{ Name = '版本'; Expression = { $_.Version } },
        @{ Name = '状态'; Expression = { $_.Status } },
        @{ Name = '错误'; Expression = { $_.Error } } |
        Format-Table -AutoSize |
        Out-String).TrimEnd())

Write-Host ''
Write-Host 'PDF 验证结果'
Write-Host (($testResults |
        Select-Object @{ Name = '测试项'; Expression = { $_.Name } },
        @{ Name = '页数'; Expression = { if ($null -eq $_.Pages) { '-' } else { $_.Pages } } },
        @{ Name = '中文锚点'; Expression = { $_.Anchor } },
        @{ Name = '锚点结果'; Expression = { if ($_.AnchorFound) { '通过' } else { '失败' } } },
        @{ Name = '状态'; Expression = { $_.Status } },
        @{ Name = '错误'; Expression = { $_.Error } } |
        Format-Table -AutoSize -Wrap |
        Out-String).TrimEnd())

Write-Host ''
Write-Host "清理状态: $cleanupStatus"
if (-not [string]::IsNullOrWhiteSpace($cleanupError)) {
    Write-Host "清理错误: $cleanupError" -ForegroundColor Red
}

$allTestsPassed = $testResults.Count -eq 4 -and @($testResults | Where-Object { $_.Status -ne '通过' }).Count -eq 0
$allToolsPassed = $toolResults.Count -eq 8 -and @($toolResults | Where-Object { $_.Status -ne '通过' }).Count -eq 0
$officeTestsPassed = @($testResults | Where-Object { $_.Name -like '*DOCX*' -or $_.Name -like '*XLSX*' -or $_.Name -like '*PPTX*' })
$officeSuccess = $officeTestsPassed.Count -eq 3 -and @($officeTestsPassed | Where-Object { $_.Status -ne '通过' }).Count -eq 0

[pscustomobject]@{
    WorkDir          = $workingDirectory
    KeepArtifacts    = [bool]$KeepArtifacts
    CleanupStatus    = $cleanupStatus
    CleanupError     = $cleanupError
    ToolResults      = $toolResults
    PdfResults       = $testResults
    OfficePdfSuccess = $officeSuccess
    Success          = $allToolsPassed -and $allTestsPassed -and ($cleanupStatus -ne '失败')
}
