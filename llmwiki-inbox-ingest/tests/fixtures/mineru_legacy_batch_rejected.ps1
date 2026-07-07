#Requires -Version 7.0
. $PSScriptRoot\common.ps1

function Write-BatchJson {
    param(
        [Parameter(Mandatory = $true)][object]$Workspace,
        [Parameter(Mandatory = $true)][object]$Batch
    )

    $batchPath = Join-Path -Path ([string]$Workspace.RunDir) -ChildPath 'mineru-batch.json'
    Write-FixtureFile -Path $batchPath -Content ($Batch | ConvertTo-Json -Compress -Depth 10)
}

Complete-Fixture {
    $missingProcessorWorkspace = New-FixtureWorkspace -Name 'mineru-legacy-missing-processor'
    $pipelineWorkspace = New-FixtureWorkspace -Name 'mineru-legacy-pipeline'
    try {
        Invoke-FullHappyPathPipeline -Workspace $missingProcessorWorkspace
        $missingBatch = Get-MineruBatch -Workspace $missingProcessorWorkspace
        $missingBatch.items[0].PSObject.Properties.Remove('processor')
        Write-BatchJson -Workspace $missingProcessorWorkspace -Batch $missingBatch
        $missingValidate = Invoke-SkillScript -ScriptName 'validate-run.ps1' -Workspace $missingProcessorWorkspace
        if ($missingValidate.ExitCode -eq 0) { throw 'validate-run accepted legacy batch without processor' }

        Invoke-FullHappyPathPipeline -Workspace $pipelineWorkspace
        $pipelineBatch = Get-MineruBatch -Workspace $pipelineWorkspace
        $pipelineBatch.items[0].processor = 'pipeline'
        $pipelineBatch.items[0].model_version = 'pipeline'
        Write-BatchJson -Workspace $pipelineWorkspace -Batch $pipelineBatch
        $pipelineValidate = Invoke-SkillScript -ScriptName 'validate-run.ps1' -Workspace $pipelineWorkspace
        if ($pipelineValidate.ExitCode -eq 0) { throw 'validate-run accepted forbidden pipeline processor' }
    } finally {
        Remove-FixtureWorkspace -Workspace $missingProcessorWorkspace
        Remove-FixtureWorkspace -Workspace $pipelineWorkspace
    }
}
