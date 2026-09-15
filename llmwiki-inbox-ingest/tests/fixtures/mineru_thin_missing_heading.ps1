#Requires -Version 7.0
. $PSScriptRoot\common.ps1

Complete-Fixture {
    $workspace = New-FixtureWorkspace -Name 'mineru-thin-missing-heading'
    try {
        Initialize-PreparedMineruRun -Workspace $workspace
        $item = Get-SingleMineruBatchItem -Workspace $workspace
        $sourceId = [string]$item.source_id

        # 薄内容且无标题：标题要求不因内容量分档而放宽 → 仍走归一化路径（非终态），不写 raw
        $body = "为不影响支行业务发展，科技支行申请装修延后至明年 4 月动工。特此申请。" * 3
        $byteCount = [System.Text.Encoding]::UTF8.GetByteCount($body)
        if ($byteCount -le 150 -or $byteCount -gt 500) {
            throw "fixture markdown byte count $byteCount is outside the thin-content band (150, 500]"
        }
        Write-FixtureMineruOutput -Workspace $workspace -SourceId $sourceId -Markdown $body
        Write-FixtureLifecycleState -Workspace $workspace -SourceId $sourceId -Status 'mapped'

        $ingest = Invoke-SkillScript -ScriptName 'ingest-mineru-output.ps1' -Workspace $workspace
        Assert-ExitCode -Result $ingest -Expected 0 -Step 'ingest thin no-heading content'

        $parsePath = Join-Path -Path ([string]$workspace.RunDir) -ChildPath 'parse-manifest.csv'
        $rawPath = Join-Path -Path ([string]$workspace.RunDir) -ChildPath 'raw-output-manifest.csv'
        Assert-FileContains -Path $parsePath -Pattern 'missing_heading_contentful' -Label 'parse-manifest.csv'
        Assert-FileContains -Path $rawPath -Pattern 'missing_heading_contentful' -Label 'raw-output-manifest.csv'

        if (@(Get-ChildItem -LiteralPath ([string]$workspace.Raw) -File -Recurse).Count -ne 0) {
            throw 'heading-less thin output should not be written to raw before normalization'
        }

        $validate = Invoke-SkillScript -ScriptName 'validate-run.ps1' -Workspace $workspace
        Assert-ExitCode -Result $validate -Expected 0 -Step 'validate thin no-heading run'
    } finally {
        Remove-FixtureWorkspace -Workspace $workspace
    }
}
