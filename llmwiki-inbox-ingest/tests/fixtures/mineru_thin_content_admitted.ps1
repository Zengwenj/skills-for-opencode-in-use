#Requires -Version 7.0
. $PSScriptRoot\common.ps1

Complete-Fixture {
    $workspace = New-FixtureWorkspace -Name 'mineru-thin-content-admitted'
    try {
        Initialize-PreparedMineruRun -Workspace $workspace
        $item = Get-SingleMineruBatchItem -Workspace $workspace
        $sourceId = [string]$item.source_id

        # 薄内容：有标题、字节数落在 (150, 500] 区间——应放行写入并标记 thin_content
        $body = "# 延后装修申请`n`n为不影响支行业务发展，科技支行申请装修延后至明年 4 月动工。特此申请。`n" +
                "因正值年末冲刺阶段和开门红黄金揽存时段，支行申请延后开工。`n"
        $byteCount = [System.Text.Encoding]::UTF8.GetByteCount($body)
        if ($byteCount -le 150 -or $byteCount -gt 500) {
            throw "fixture markdown byte count $byteCount is outside the thin-content band (150, 500]"
        }
        Write-FixtureMineruOutput -Workspace $workspace -SourceId $sourceId -Markdown $body
        Write-FixtureLifecycleState -Workspace $workspace -SourceId $sourceId -Status 'mapped'

        $ingest = Invoke-SkillScript -ScriptName 'ingest-mineru-output.ps1' -Workspace $workspace
        Assert-ExitCode -Result $ingest -Expected 0 -Step 'ingest thin content'

        $parsePath = Join-Path -Path ([string]$workspace.RunDir) -ChildPath 'parse-manifest.csv'
        $rawPath = Join-Path -Path ([string]$workspace.RunDir) -ChildPath 'raw-output-manifest.csv'
        Assert-FileContains -Path $parsePath -Pattern 'thin_content' -Label 'parse-manifest.csv'
        Assert-FileContains -Path $rawPath -Pattern 'written' -Label 'raw-output-manifest.csv'

        $rawFiles = @(Get-ChildItem -LiteralPath ([string]$workspace.Raw) -File -Recurse)
        if ($rawFiles.Count -ne 1) {
            throw "thin but complete output should be written to raw exactly once; found $($rawFiles.Count)"
        }

        $failuresPath = Join-Path -Path ([string]$workspace.RunDir) -ChildPath 'failures.csv'
        if ((Test-Path -LiteralPath $failuresPath -PathType Leaf) -and
            (Get-Content -LiteralPath $failuresPath -Raw -Encoding UTF8).Contains('quality_failed')) {
            throw 'thin content was misclassified as a quality failure'
        }

        $validate = Invoke-SkillScript -ScriptName 'validate-run.ps1' -Workspace $workspace
        Assert-ExitCode -Result $validate -Expected 0 -Step 'validate thin content run'
    } finally {
        Remove-FixtureWorkspace -Workspace $workspace
    }
}
