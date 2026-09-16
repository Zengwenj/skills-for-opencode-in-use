#Requires -Version 7.0
. $PSScriptRoot\common.ps1

# 反例：目标已存在、字节不同、且**文本层也不同** → 必须维持 fail-closed，不得借用等价规则放行。
Complete-Fixture {
    $workspace = New-FixtureWorkspace -Name 'apply-collision-different-content'
    try {
        $docxSource = Join-Path -Path ([string]$workspace.Inbox) -ChildPath (Join-Path -Path 'ThemeA' -ChildPath (Join-Path -Path '2026' -ChildPath 'policy-note.docx'))
        New-FixtureDocxFile -Path $docxSource -Text 'INBOX-VERSION-BODY'

        Invoke-ScanAndProposal -Workspace $workspace
        $plan = @(Get-Content -LiteralPath (Join-Path -Path ([string]$workspace.RunDir) -ChildPath 'classification-plan.jsonl') -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
        if ($plan.Count -ne 1) { throw "expected exactly 1 plan item, found $($plan.Count)" }

        # 库内既有件文本不同（真修订）
        New-FixtureDocxFile -Path ([string]$plan[0].target_archive_path) -Text 'LIBRARY-VERSION-BODY'

        Approve-FixtureRun -Workspace $workspace | Out-Null
        $apply = Invoke-SkillScript -ScriptName 'apply-approved-plan.ps1' -Workspace $workspace
        Assert-ExitCode -Result $apply -Expected 1 -Step 'apply with genuinely different content at target'

        $applyManifestPath = Join-Path -Path ([string]$workspace.RunDir) -ChildPath 'apply-manifest.jsonl'
        Assert-FileContains -Path $applyManifestPath -Pattern 'preflight_failed' -Label 'apply-manifest.jsonl'
        if ((Get-Content -LiteralPath $applyManifestPath -Raw -Encoding UTF8).Contains('skipped_equivalent_content')) {
            throw 'content-differing collision was wrongly skipped as text-equivalent'
        }
        Assert-FileContains -Path (Join-Path -Path ([string]$workspace.RunDir) -ChildPath 'failures.csv') -Pattern 'target_exists' -Label 'failures.csv'
    } finally {
        Remove-FixtureWorkspace -Workspace $workspace
    }
}
