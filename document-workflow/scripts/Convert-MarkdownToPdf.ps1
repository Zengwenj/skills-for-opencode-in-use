<#
.SYNOPSIS
通过 Pandoc 和 Office COM 将 Markdown 文件两阶段转换为 PDF。

.DESCRIPTION
本脚本明确执行两阶段转换（Markdown→DOCX→PDF）：先使用 Pandoc 生成 DOCX 中间产物，
再调用同目录的 Export-OfficePdf.ps1 将 DOCX 导出为 PDF。

.PARAMETER InputPath
要转换的 .md 文件路径。

.PARAMETER OutputPath
目标 .pdf 文件路径；其父目录必须已存在。

.PARAMETER WorkDir
DOCX 中间产物的存放目录。默认使用 $env:TEMP。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$InputPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath,

    [ValidateNotNullOrEmpty()]
    [string]$WorkDir = $env:TEMP
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $InputPath -PathType Leaf)) {
    throw "输入 Markdown 文件不存在: $InputPath"
}

$inputFile = Get-Item -LiteralPath $InputPath -ErrorAction Stop
if ($inputFile.Extension -ine '.md') {
    throw "输入文件必须使用 .md 扩展名: $InputPath"
}

$outputFullPath = [System.IO.Path]::GetFullPath($OutputPath)
if ([System.IO.Path]::GetExtension($outputFullPath) -ine '.pdf') {
    throw "输出文件必须使用 .pdf 扩展名: $OutputPath"
}

$outputDirectory = Split-Path -Path $outputFullPath -Parent
if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    throw "输出目录不存在: $outputDirectory"
}

if ([string]::IsNullOrWhiteSpace($WorkDir)) {
    throw 'WorkDir 不能为空。'
}

New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
$workDirectory = (Get-Item -LiteralPath $WorkDir -ErrorAction Stop).FullName
$intermediateDocx = Join-Path $workDirectory ("{0}_intermediate.docx" -f $inputFile.BaseName)

$pandoc = Get-Command -Name pandoc -CommandType Application -ErrorAction SilentlyContinue
if ($null -eq $pandoc) {
    throw '未找到 Pandoc。请先确保 pandoc.exe 已加入 PATH。'
}

Write-Host '两阶段转换（Markdown→DOCX→PDF）'
Write-Host "阶段 1/2：Pandoc 生成 DOCX 中间产物: $intermediateDocx"

& $pandoc.Path $inputFile.FullName -o $intermediateDocx
if ($LASTEXITCODE -ne 0) {
    throw "Pandoc 生成 DOCX 失败，退出代码: $LASTEXITCODE"
}

if (-not (Test-Path -LiteralPath $intermediateDocx -PathType Leaf)) {
    throw "Pandoc 未生成预期的 DOCX 中间产物: $intermediateDocx"
}

Write-Host "阶段 2/2：Office COM 导出 PDF: $outputFullPath"
& (Join-Path $PSScriptRoot 'Export-OfficePdf.ps1') -InputPath $intermediateDocx -OutputPath $outputFullPath

if (-not (Test-Path -LiteralPath $outputFullPath -PathType Leaf)) {
    throw "Office COM 未生成预期的 PDF 文件: $outputFullPath"
}
