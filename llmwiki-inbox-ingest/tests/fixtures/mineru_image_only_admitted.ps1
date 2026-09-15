#Requires -Version 7.0
. $PSScriptRoot\common.ps1

Complete-Fixture {
    $workspace = New-FixtureWorkspace -Name 'mineru-image-only-admitted'
    try {
        Initialize-PreparedMineruRun -Workspace $workspace
        $item = Get-SingleMineruBatchItem -Workspace $workspace
        $sourceId = [string]$item.source_id

        # 图片型文档：正文是整页扫描图，Markdown 只有标题 + 图片引用，文本必然近空。
        # 解析是完整的（源就是 1 个标签格 + 1 张整页图），应放行写入并标 image_only_content。
        # 标题仍必须有（由既有归一化路径补），本用例镜像"归一化后的端态"。
        $body = "# 358号附件2-1`n`n附件2-1`n`n![scan]($sourceId.images/scan.jpg)`n"
        $byteCount = [System.Text.Encoding]::UTF8.GetByteCount($body)
        if ($byteCount -gt 150) {
            throw "fixture markdown byte count $byteCount is not in the near-empty band (<= 150)"
        }
        Write-FixtureMineruOutput -Workspace $workspace -SourceId $sourceId -Markdown $body

        $imagesDir = Join-Path -Path ([string]$workspace.RunDir) -ChildPath (Join-Path -Path 'mineru-output' -ChildPath (Join-Path -Path $sourceId -ChildPath "$sourceId.images"))
        New-Item -ItemType Directory -Path $imagesDir -Force | Out-Null
        $imageBytes = New-Object byte[] 20480
        (New-Object System.Random 7).NextBytes($imageBytes)
        [System.IO.File]::WriteAllBytes((Join-Path -Path $imagesDir -ChildPath 'scan.jpg'), $imageBytes)

        Write-FixtureLifecycleState -Workspace $workspace -SourceId $sourceId -Status 'mapped'

        $ingest = Invoke-SkillScript -ScriptName 'ingest-mineru-output.ps1' -Workspace $workspace
        Assert-ExitCode -Result $ingest -Expected 0 -Step 'ingest image-only content'

        $parsePath = Join-Path -Path ([string]$workspace.RunDir) -ChildPath 'parse-manifest.csv'
        $rawPath = Join-Path -Path ([string]$workspace.RunDir) -ChildPath 'raw-output-manifest.csv'
        Assert-FileContains -Path $parsePath -Pattern 'image_only_content' -Label 'parse-manifest.csv validation_flags'
        if ((Get-Content -LiteralPath $parsePath -Raw -Encoding UTF8).Contains('near_empty_content')) {
            throw 'image-only content was mixed with near_empty_content'
        }
        if ((Get-Content -LiteralPath $rawPath -Raw -Encoding UTF8).Contains('quality_failed')) {
            throw 'image-only content was rejected by the quality gate'
        }

        $rawFiles = @(Get-ChildItem -LiteralPath ([string]$workspace.Raw) -File -Recurse -Filter '*.md')
        if ($rawFiles.Count -ne 1) {
            throw "expected 1 raw markdown after image-only ingest, found $($rawFiles.Count)"
        }
        $rawImages = @(Get-ChildItem -LiteralPath ([string]$workspace.Raw) -File -Recurse -Filter 'scan.jpg')
        if ($rawImages.Count -ne 1) {
            throw "expected image-only payload to be copied into raw, found $($rawImages.Count) scan.jpg"
        }

        $validate = Invoke-SkillScript -ScriptName 'validate-run.ps1' -Workspace $workspace
        Assert-ExitCode -Result $validate -Expected 0 -Step 'validate image-only run'
    } finally {
        Remove-FixtureWorkspace -Workspace $workspace
    }
}
