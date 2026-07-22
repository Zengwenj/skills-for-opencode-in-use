<#
用途：使用 Microsoft Word COM 将文本型 PDF 快速重建为可编辑 DOCX。
限制：此过程不保证视觉保真；复杂排版、表格和图片位置可能偏移。
适用场景：简单文本型 PDF。扫描件或复杂布局应使用 MinerU 路径。
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$InputPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

if ([System.IO.Path]::GetExtension($InputPath) -ine '.pdf') {
    throw "输入文件必须是 .pdf：$InputPath"
}

if (-not (Test-Path -LiteralPath $InputPath -PathType Leaf)) {
    throw "输入 PDF 不存在：$InputPath"
}

if ([System.IO.Path]::GetExtension($OutputPath) -ine '.docx') {
    throw "输出文件必须是 .docx：$OutputPath"
}

$inputPath = (Resolve-Path -LiteralPath $InputPath).Path
$outputPath = [System.IO.Path]::GetFullPath($OutputPath)
$outputDirectory = [System.IO.Path]::GetDirectoryName($outputPath)

if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    throw "输出目录不存在：$outputDirectory"
}

Write-Warning '输出为可编辑重建件，不保证与原 PDF 视觉一致。复杂或扫描 PDF 应使用 MinerU 提取后由 OfficeCLI 重新排版。'
Write-Information -InformationAction Continue -MessageData '开始 Word COM 可编辑重建：不保证视觉保真。'

$word = $null
$doc = $null

try {
    $word = New-Object -ComObject Word.Application
    $word.Visible = $false
    $word.DisplayAlerts = 0

    $doc = $word.Documents.Open($inputPath)
    $doc.SaveAs2($outputPath, 16)

    Write-Information -InformationAction Continue -MessageData '转换完成：可编辑重建，不保证视觉保真。'
    [pscustomobject]@{
        InputPath        = $inputPath
        OutputPath       = $outputPath
        ConversionResult = '可编辑重建，不保证视觉保真'
    }
}
finally {
    if ($null -ne $doc) {
        try {
            $doc.Close()
        }
        catch {
            Write-Verbose "关闭 Word 文档失败：$($_.Exception.Message)"
        }
        finally {
            [System.Runtime.InteropServices.Marshal]::ReleaseComObject($doc) | Out-Null
        }
    }

    if ($null -ne $word) {
        try {
            $word.Quit()
        }
        catch {
            Write-Verbose "退出 Word 失败：$($_.Exception.Message)"
        }
        finally {
            [System.Runtime.InteropServices.Marshal]::ReleaseComObject($word) | Out-Null
        }
    }
}
