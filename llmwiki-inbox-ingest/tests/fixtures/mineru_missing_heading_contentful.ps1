#Requires -Version 7.0
. $PSScriptRoot\common.ps1

Complete-Fixture {
    $workspace = New-FixtureWorkspace -Name 'mineru-missing-heading-contentful'
    try {
        Initialize-PreparedMineruRun -Workspace $workspace
        $item = Get-SingleMineruBatchItem -Workspace $workspace
        $sourceId = [string]$item.source_id

        $body = ('Contentful MinerU extraction without a Markdown heading. It should be routed for normalization instead of treated as empty output. ' * 10)
        Write-FixtureMineruOutput -Workspace $workspace -SourceId $sourceId -Markdown $body
        Write-FixtureLifecycleState -Workspace $workspace -SourceId $sourceId -Status 'mapped'

        $ingest = Invoke-SkillScript -ScriptName 'ingest-mineru-output.ps1' -Workspace $workspace
        Assert-ExitCode -Result $ingest -Expected 0 -Step 'ingest missing_heading_contentful'

        $parsePath = Join-Path -Path ([string]$workspace.RunDir) -ChildPath 'parse-manifest.csv'
        $rawPath = Join-Path -Path ([string]$workspace.RunDir) -ChildPath 'raw-output-manifest.csv'
        Assert-FileContains -Path $parsePath -Pattern 'missing_heading_contentful' -Label 'parse-manifest.csv'
        Assert-FileContains -Path $rawPath -Pattern 'missing_heading_contentful' -Label 'raw-output-manifest.csv'
        if ((Get-Content -LiteralPath $parsePath -Raw -Encoding UTF8).Contains('raw_quality_failed')) {
            throw 'contentful no-heading output was mixed with raw_quality_failed'
        }
        if (@(Get-ChildItem -LiteralPath ([string]$workspace.Raw) -File -Recurse).Count -ne 0) {
            throw 'missing_heading_contentful output should not be written to raw without normalization'
        }

        $validate = Invoke-SkillScript -ScriptName 'validate-run.ps1' -Workspace $workspace
        Assert-ExitCode -Result $validate -Expected 0 -Step 'validate missing_heading_contentful run'
    } finally {
        Remove-FixtureWorkspace -Workspace $workspace
    }
}
