#Requires -Version 7.0
. $PSScriptRoot\common.ps1

Complete-Fixture {
    $workspace = New-FixtureWorkspace -Name 'mineru_image_only_missing_heading'
    try {
        Initialize-PreparedMineruRun -Workspace $workspace
        $item = Get-SingleMineruBatchItem -Workspace $workspace
        $sourceId = [string]$item.source_id

        # 图片型但无标题：不得因为"图片型放行"就写出无标题 raw（validate 会拒），
        # 应走既有归一化非终态路由 missing_heading_contentful。
        $body = "附件2-1`n`n![scan]($sourceId.images/scan.jpg)`n"
        Write-FixtureMineruOutput -Workspace $workspace -SourceId $sourceId -Markdown $body

        $imagesDir = Join-Path -Path ([string]$workspace.RunDir) -ChildPath (Join-Path -Path 'mineru-output' -ChildPath (Join-Path -Path $sourceId -ChildPath "$sourceId.images"))
        New-Item -ItemType Directory -Path $imagesDir -Force | Out-Null
        $imageBytes = New-Object byte[] 20480
        (New-Object System.Random 11).NextBytes($imageBytes)
        [System.IO.File]::WriteAllBytes((Join-Path -Path $imagesDir -ChildPath 'scan.jpg'), $imageBytes)

        Write-FixtureLifecycleState -Workspace $workspace -SourceId $sourceId -Status 'mapped'

        $ingest = Invoke-SkillScript -ScriptName 'ingest-mineru-output.ps1' -Workspace $workspace
        Assert-ExitCode -Result $ingest -Expected 0 -Step 'ingest image-only without heading'

        $parsePath = Join-Path -Path ([string]$workspace.RunDir) -ChildPath 'parse-manifest.csv'
        $rawPath = Join-Path -Path ([string]$workspace.RunDir) -ChildPath 'raw-output-manifest.csv'
        Assert-FileContains -Path $parsePath -Pattern 'missing_heading_contentful' -Label 'parse-manifest.csv'
        Assert-FileContains -Path $parsePath -Pattern 'image_only_content' -Label 'parse-manifest.csv validation_flags'
        if ((Get-Content -LiteralPath $parsePath -Raw -Encoding UTF8).Contains('quality_failed')) {
            throw 'image-only output without a heading was wrongly treated as a parse defect'
        }
        if (@(Get-ChildItem -LiteralPath ([string]$workspace.Raw) -File -Recurse).Count -ne 0) {
            throw 'heading-less image-only output must not be written to raw before normalization'
        }

        $validate = Invoke-SkillScript -ScriptName 'validate-run.ps1' -Workspace $workspace
        Assert-ExitCode -Result $validate -Expected 0 -Step 'validate heading-less image-only run'
    } finally {
        Remove-FixtureWorkspace -Workspace $workspace
    }
}
