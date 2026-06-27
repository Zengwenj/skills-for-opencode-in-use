#Requires -Version 7.0
. $PSScriptRoot\common.ps1

Complete-Fixture {
    $workspace = New-FixtureWorkspace -Name 'e2e-happy-path'
    try {
        Invoke-FullHappyPathPipeline -Workspace $workspace

        foreach ($artifact in @('inventory.jsonl', 'classification-plan.jsonl', 'apply-manifest.jsonl', 'mineru-batch.json', 'parse-manifest.csv', 'raw-output-manifest.csv')) {
            Assert-FileExists -Path (Join-Path -Path ([string]$workspace.RunDir) -ChildPath $artifact) -Label $artifact
        }
        $rawFiles = @(Get-ChildItem -LiteralPath ([string]$workspace.Raw) -File -Recurse)
        if ($rawFiles.Count -ne 1) { throw "expected exactly one raw file, found $($rawFiles.Count)" }
        Assert-FileContains -Path $rawFiles[0].FullName -Pattern 'status: "raw-parsed"' -Label 'raw frontmatter'
    } finally {
        Remove-FixtureWorkspace -Workspace $workspace
    }
}
