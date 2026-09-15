#Requires -Version 7.0
. $PSScriptRoot\common.ps1

Complete-Fixture {
    $workspace = New-FixtureWorkspace -Name 'mineru-near-empty-image-missing'
    try {
        Initialize-PreparedMineruRun -Workspace $workspace
        $item = Get-SingleMineruBatchItem -Workspace $workspace
        $sourceId = [string]$item.source_id

        # 反例：Markdown 有标题但引用的图片在盘上不存在（或只是装饰性小图）——不得借此绕过近空拦截。
        $body = "# 358号附件2-9`n`n附件2-9`n`n![scan]($sourceId.images/missing.jpg)`n"
        Write-FixtureMineruOutput -Workspace $workspace -SourceId $sourceId -Markdown $body

        $imagesDir = Join-Path -Path ([string]$workspace.RunDir) -ChildPath (Join-Path -Path 'mineru-output' -ChildPath (Join-Path -Path $sourceId -ChildPath "$sourceId.images"))
        New-Item -ItemType Directory -Path $imagesDir -Force | Out-Null
        $tiny = New-Object byte[] 512
        [System.IO.File]::WriteAllBytes((Join-Path -Path $imagesDir -ChildPath 'missing.jpg'), $tiny)

        Write-FixtureLifecycleState -Workspace $workspace -SourceId $sourceId -Status 'mapped'

        $ingest = Invoke-SkillScript -ScriptName 'ingest-mineru-output.ps1' -Workspace $workspace
        Assert-ExitCode -Result $ingest -Expected 1 -Step 'ingest near-empty with bogus image ref'

        $parsePath = Join-Path -Path ([string]$workspace.RunDir) -ChildPath 'parse-manifest.csv'
        Assert-FileContains -Path $parsePath -Pattern 'near_empty_content' -Label 'parse-manifest.csv validation_flags'
        if ((Get-Content -LiteralPath $parsePath -Raw -Encoding UTF8).Contains('image_only_content')) {
            throw 'near-empty output with a missing/tiny image was wrongly admitted as image_only_content'
        }
        if (@(Get-ChildItem -LiteralPath ([string]$workspace.Raw) -File -Recurse).Count -ne 0) {
            throw 'near-empty output with a missing/tiny image must not be written to raw'
        }
    } finally {
        Remove-FixtureWorkspace -Workspace $workspace
    }
}
