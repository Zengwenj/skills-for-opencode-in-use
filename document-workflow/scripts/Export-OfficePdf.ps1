<#
.SYNOPSIS
使用 Microsoft Office COM 将 DOCX、XLSX 或 PPTX 文件导出为 PDF。

.DESCRIPTION
根据输入文件扩展名选择 Word、Excel 或 PowerPoint COM 后端。所有 Office 实例
均以不可见、无交互提示方式运行，并在 finally 块中关闭文档、退出应用及释放 COM 引用。

.PARAMETER InputPath
要导出的 .docx、.xlsx 或 .pptx 文件路径。

.PARAMETER OutputPath
目标 .pdf 文件路径；其父目录必须已存在。
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

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $InputPath -PathType Leaf)) {
    throw "输入文件不存在: $InputPath"
}

$inputFile = Get-Item -LiteralPath $InputPath -ErrorAction Stop
$inputExtension = $inputFile.Extension.ToLowerInvariant()

if ($inputExtension -notin @('.docx', '.xlsx', '.pptx')) {
    throw "不支持的 Office 文件扩展名: $inputExtension。仅支持 .docx、.xlsx、.pptx。"
}

$outputFullPath = [System.IO.Path]::GetFullPath($OutputPath)
if ([System.IO.Path]::GetExtension($outputFullPath) -ine '.pdf') {
    throw "输出文件必须使用 .pdf 扩展名: $OutputPath"
}

$outputDirectory = Split-Path -Path $outputFullPath -Parent
if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    throw "输出目录不存在: $outputDirectory"
}

$application = $null
$documentCollection = $null
$officeDocument = $null

try {
    switch ($inputExtension) {
        '.docx' {
            $application = New-Object -ComObject Word.Application
            $application.Visible = $false
            $application.DisplayAlerts = 0
            $application.ScreenUpdating = $false

            $documentCollection = $application.Documents
            $officeDocument = $documentCollection.Open($inputFile.FullName, $false, $true)

            # wdExportFormatPDF = 17; wdExportOptimizeForPrint = 0.
            [void]$officeDocument.ExportAsFixedFormat($outputFullPath, 17, $false, 0)
        }

        '.xlsx' {
            $application = New-Object -ComObject Excel.Application
            $application.Visible = $false
            $application.DisplayAlerts = $false

            $documentCollection = $application.Workbooks
            $officeDocument = $documentCollection.Open($inputFile.FullName, 0, $true)

            # xlTypePDF = 0.
            [void]$officeDocument.ExportAsFixedFormat(0, $outputFullPath)
        }

        '.pptx' {
            $application = New-Object -ComObject PowerPoint.Application
            # PowerPoint COM 不支持 Visible=$false；WithWindow=false 已防止窗口弹出
            $application.DisplayAlerts = $false

            $documentCollection = $application.Presentations
            $officeDocument = $documentCollection.Open($inputFile.FullName, $true, $false, $false)

            # ppSaveAsPDF = 32.
            [void]$officeDocument.SaveAs($outputFullPath, 32)
        }
    }
}
finally {
    if ($null -ne $officeDocument) {
        try {
            [void]$officeDocument.Close()
        }
        catch {
        }
    }

    if ($null -ne $application) {
        try {
            [void]$application.Quit()
        }
        catch {
        }
    }

    foreach ($comObject in @($officeDocument, $documentCollection, $application)) {
        if ($null -ne $comObject) {
            try {
                [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($comObject)
            }
            catch {
            }
        }
    }

    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
}
