[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ManifestPath,

    [Parameter(Mandatory = $true)]
    [string]$StageResultPath,

    [Parameter(Mandatory = $true)]
    [string]$PaperId,
    [string]$RequestedMode,
    [switch]$LocalOnly
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'FlowSupport.psm1') -Force

function Set-ObjectProperty {
    param([object]$Object, [string]$Name, [object]$Value)
    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

function Write-AtomicJson {
    param([string]$Destination, [object]$Value)
    $directory = Split-Path -Parent $Destination
    if (-not $directory) { $directory = (Get-Location).Path }
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $temporary = Join-Path $directory ('.' + [System.IO.Path]::GetFileName($Destination) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $json = $Value | ConvertTo-Json -Depth 30
        [System.IO.File]::WriteAllText($temporary, $json, (New-Object System.Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $Destination) {
            $backup = $temporary + '.bak'
            [System.IO.File]::Replace($temporary, $Destination, $backup, $true)
            if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force }
        }
        else {
            [System.IO.File]::Move($temporary, $Destination)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

try {
    $validator = Join-Path $PSScriptRoot 'Test-PaperZoteroFlowResult.ps1'
    $stageJson = [System.IO.File]::ReadAllText($StageResultPath, [System.Text.Encoding]::UTF8)
    $stage = $stageJson | ConvertFrom-Json
    $validation=Invoke-FlowChild -Runtime (Resolve-FlowPowerShell) -Script $validator -Arguments @('-Path',$StageResultPath,'-ExpectedSchema',$stage.schema) -LogDirectory (Split-Path -Parent $ManifestPath)
    if ($validation.exit_code -ne 0) { throw 'Stage result failed contract validation' }
    if ([string]$stage.paper_id -ne $PaperId) { throw 'Stage result paper_id does not match -PaperId' }

    if (Test-Path -LiteralPath $ManifestPath) {
        $manifestJson = [System.IO.File]::ReadAllText($ManifestPath, [System.Text.Encoding]::UTF8)
        $manifest = $manifestJson | ConvertFrom-Json
        if ([int]$manifest.schema_version -ne 1) { throw 'Unsupported manifest schema version' }
    }
    else {
        $manifest = [pscustomobject][ordered]@{
            schema_version = 1
            run_id = [guid]::NewGuid().ToString()
            created_at = [DateTime]::UtcNow.ToString('o')
            requested_collection = $null
            papers = @()
        }
    }
    if($RequestedMode){Set-ObjectProperty $manifest 'requested_mode' $RequestedMode;Set-ObjectProperty $manifest 'local_only' ([bool]$LocalOnly)}

    $papers = @($manifest.papers)
    $paper = $papers | Where-Object { [string]$_.paper_id -eq $PaperId } | Select-Object -First 1
    if ($null -eq $paper) {
        $paper = [pscustomobject][ordered]@{
            paper_id = $PaperId
            identifiers = [pscustomobject]@{ doi = $null; arxiv_id = $null; pmid = $null }
            metadata = [pscustomobject]@{ title = ''; authors = @(); year = $null; venue = ''; url = ''; metadata_source = '' }
            pdf = [pscustomobject]@{ path = $null; source_url = $null; source_type = $null; version_type = $null; sha256 = $null; size_bytes = $null; verified = $false }
            zotero = [pscustomobject]@{ server_id = $null; collection_key = $null; item_key = $null; attachments = @() }
            translations = @()
            translation_run = $null
            stage_states = [pscustomobject]@{}
            stage_history = @()
            status = 'requested'
            error = $null
        }
        $papers += $paper
        Set-ObjectProperty $manifest 'papers' $papers
    }

    switch ([string]$stage.schema) {
        'paper-record.v1' {
            if ($stage.outputs.identifiers) { Set-ObjectProperty $paper 'identifiers' $stage.outputs.identifiers }
            if ($stage.outputs.metadata) { Set-ObjectProperty $paper 'metadata' $stage.outputs.metadata }
            if ($stage.outputs.pdf_candidates) { Set-ObjectProperty $paper 'pdf_candidates' @($stage.outputs.pdf_candidates) }
        }
        'download-result.v1' { Set-ObjectProperty $paper 'pdf' $stage.outputs }
        'zotero-result.v1' {
            $current = $paper.zotero
            $incoming = $stage.outputs
            $mergedAttachments = @()
            $seenAttachment = @{}
            foreach ($attachment in @($current.attachments) + @($incoming.attachments)) {
                $identity = if ($attachment.sha256 -and $attachment.role) { [string]$attachment.role + ':' + [string]$attachment.sha256 } elseif ($attachment.key) { [string]$attachment.key } else { [guid]::NewGuid().ToString() }
                if (-not $seenAttachment.ContainsKey($identity)) { $seenAttachment[$identity]=$true; $mergedAttachments += $attachment }
            }
            $merged = [pscustomobject]@{
                server_id = if ($incoming.server_id) { $incoming.server_id } else { $current.server_id }
                collection_key = if ($incoming.collection_key) { $incoming.collection_key } else { $current.collection_key }
                item_key = if ($incoming.item_key) { $incoming.item_key } else { $current.item_key }
                item_action = if ($incoming.item_action) { $incoming.item_action } else { $current.item_action }
                attachments = $mergedAttachments
                rollback = @($incoming.rollback)
            }
            Set-ObjectProperty $paper 'zotero' $merged
        }
        'translation-result.v1' {
            $artifacts = if ($stage.outputs.artifacts) { @($stage.outputs.artifacts) } else { @() }
            if($stage.status -eq 'succeeded'){Set-ObjectProperty $paper 'translations' $artifacts}
            $attempts = if ($stage.outputs.attempts) { @($stage.outputs.attempts) } else { @() }
            $totalDuration = 0.0
            foreach ($attempt in $attempts) { $totalDuration += [double]$attempt.duration_seconds }
            $translationRun = [pscustomobject][ordered]@{
                requested_service = [string]$stage.inputs.service
                fallback_service = [string]$stage.inputs.fallback_service
                qwen_model = [string]$stage.inputs.qwen_model
                qwen_network = [string]$stage.inputs.qwen_network
                qwen_qps = if ($null -ne $stage.inputs.qwen_qps) { [int]$stage.inputs.qwen_qps } else { $null }
                qwen_workers = if ($null -ne $stage.inputs.qwen_workers) { [int]$stage.inputs.qwen_workers } else { $null }
                service_used = [string]$stage.outputs.service_used
                fallback_used = [bool]$stage.outputs.fallback_used
                fallback_reason = [string]$stage.outputs.fallback_reason
                total_duration_seconds = [math]::Round($totalDuration, 3)
                attempts = $attempts
                diagnostic_logs = @($stage.outputs.diagnostic_logs | Where-Object {$_})
            }
            Set-ObjectProperty $paper 'translation_run' $translationRun
            if($stage.status -eq 'succeeded'){Set-ObjectProperty $paper 'artifact_translation_run' $translationRun}
        }
        'verification-result.v1' {Set-ObjectProperty $paper 'verification' $stage.outputs}
    }
    $stageName=switch([string]$stage.schema){
        'paper-record.v1' {'find'}
        'download-result.v1' {'download'}
        'translation-result.v1' {'translate'}
        'verification-result.v1' {'verify'}
        'zotero-result.v1' {if($stage.inputs.mode -eq 'attach-to-item'){'attach'}else{'ingest'}}
    }
    if($stage.inputs.failed_stage){$stageName=[string]$stage.inputs.failed_stage}
    if(-not $paper.stage_states){Set-ObjectProperty $paper 'stage_states' ([pscustomobject]@{})}
    if($stageName -ne 'verify' -and $manifest.requested_mode -and $manifest.requested_mode -ne 'find'){
        Set-ObjectProperty $paper.stage_states 'verify' ([pscustomobject]@{status='pending';updated_at=[DateTime]::UtcNow.ToString('o');errors=@()})
    }
    $stageState=[pscustomobject]@{status=[string]$stage.status;updated_at=[DateTime]::UtcNow.ToString('o');errors=@($stage.errors)}
    if($stage.inputs.mutation_uncertain){$stageState.status='unknown'}
    Set-ObjectProperty $paper.stage_states $stageName $stageState
    if($stageName -eq 'verify' -and $stage.status -eq 'succeeded'){
        $allowed=@(Get-FlowRequirements ([string]$manifest.requested_mode) ([bool]$manifest.local_only))
        foreach($certified in @($stage.outputs.certified_stages)){
            if($certified -notin $allowed){continue}
            Set-ObjectProperty $paper.stage_states $certified ([pscustomobject]@{status='succeeded';updated_at=$stageState.updated_at;errors=@();reconciled_by='verify'})
        }
    }
    Set-ObjectProperty $paper 'stage_history' (@($paper.stage_history)+@([pscustomobject]@{stage=$stageName;status=$stageState.status;updated_at=$stageState.updated_at;errors=@($stage.errors)}))
    Set-ObjectProperty $paper 'last_stage_status' ([string]$stage.status)
    Set-ObjectProperty $paper 'last_stage_name' $stageName
    Set-ObjectProperty $paper 'status' (Get-FlowOverallStatus $paper ([string]$manifest.requested_mode) ([bool]$manifest.local_only))
    Set-ObjectProperty $paper 'completion_verified' ([bool]($paper.status -eq 'succeeded' -and $paper.stage_states.verify.status -eq 'succeeded'))
    $errorValue = if (@($stage.errors).Count -gt 0) { @($stage.errors) } else { $null }
    Set-ObjectProperty $paper 'error' $errorValue

    Write-AtomicJson -Destination $ManifestPath -Value $manifest
    [System.IO.File]::ReadAllText($ManifestPath, [System.Text.Encoding]::UTF8)
    exit 0
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
