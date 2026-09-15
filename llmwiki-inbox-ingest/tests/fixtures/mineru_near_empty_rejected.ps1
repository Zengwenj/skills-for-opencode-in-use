#Requires -Version 7.0
. $PSScriptRoot\common.ps1

Complete-Fixture {
    $workspace = New-FixtureWorkspace -Name 'mineru-near-empty-rejected'
    try {
        Initialize-PreparedMineruRun -Workspace $workspace
        $item = Get-SingleMineruBatchItem -Workspace $workspace
        $sourceId = [string]$item.source_id

        # 近空：有标题但内容 <= 150 字节——解析几乎没抽出东西，应判 quality_failed 且不写 raw
        $body = "# 附件11`n`n附件11`n"
        $byteCount = [System.Text.Encoding]::UTF8.GetByteCount($body)
        if ($byteCount -gt 150) {
            throw "fixture markdown byte count $byteCount is not in the near-empty band (<= 150)"
        }
        Write-FixtureMineruOutput -Workspace $workspace -SourceId $sourceId -Markdown $body
        Write-FixtureLifecycleState -Workspace $workspace -SourceId $sourceId -Status 'mapped'

        $ingest = Invoke-SkillScript -ScriptName 'ingest-mineru-output.ps1' -Workspace $workspace
        Assert-ExitCode -Result $ingest -Expected 1 -Step 'ingest near-empty content'

        $parsePath = Join-Path -Path ([string]$workspace.RunDir) -ChildPath 'parse-manifest.csv'
        $rawPath = Join-Path -Path ([string]$workspace.RunDir) -ChildPath 'raw-output-manifest.csv'
        $failuresPath = Join-Path -Path ([string]$workspace.RunDir) -ChildPath 'failures.csv'
        Assert-FileContains -Path $parsePath -Pattern 'quality_failed' -Label 'parse-manifest.csv'
        Assert-FileContains -Path $rawPath -Pattern 'quality_failed' -Label 'raw-output-manifest.csv'
        Assert-FileContains -Path $parsePath -Pattern 'near_empty_content' -Label 'parse-manifest.csv validation_flags'
        Assert-FileExists -Path $failuresPath -Label 'failures.csv'

        if (@(Get-ChildItem -LiteralPath ([string]$workspace.Raw) -File -Recurse).Count -ne 0) {
            throw 'near-empty output must not be written to raw'
        }

        $validate = Invoke-SkillScript -ScriptName 'validate-run.ps1' -Workspace $workspace
        Assert-ExitCode -Result $validate -Expected 1 -Step 'validate near-empty run is refused'
    } finally {
        Remove-FixtureWorkspace -Workspace $workspace
    }
}
