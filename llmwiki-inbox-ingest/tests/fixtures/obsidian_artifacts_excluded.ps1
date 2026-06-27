#Requires -Version 7.0
. $PSScriptRoot\common.ps1

Complete-Fixture {
    $workspace = New-FixtureWorkspace -Name 'obsidian-excluded'
    try {
        Initialize-HappyPathSource -Workspace $workspace | Out-Null
        Write-FixtureFile -Path (Join-Path -Path ([string]$workspace.Inbox) -ChildPath '.index.md') -Content '# index should be excluded'
        Write-FixtureFile -Path (Join-Path -Path ([string]$workspace.Inbox) -ChildPath (Join-Path -Path '.obsidian' -ChildPath 'workspace.json')) -Content '{"excluded":true}'
        Invoke-ScanAndProposal -Workspace $workspace
        $rows = @(Get-InventoryRows -Workspace $workspace)
        if ($rows.Count -ne 1) { throw "expected only one normal source in inventory, found $($rows.Count)" }
        if (@($rows | Where-Object { [string]$_.rel_path -like '*.obsidian*' -or [string]$_.rel_path -eq '.index.md' }).Count -ne 0) {
            throw '.obsidian or .index.md appeared in inventory'
        }
    } finally {
        Remove-FixtureWorkspace -Workspace $workspace
    }
}
