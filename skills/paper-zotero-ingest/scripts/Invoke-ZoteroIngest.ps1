[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('create-with-pdf','attach-to-item')][string]$Mode,
    [string]$PaperRecordPath,
    [string]$DownloadResultPath,
    [string]$CollectionKey,
    [string]$ItemKey,
    [string[]]$Attachment,
    [string]$AttachmentListPath,
    [string]$ResultPath,
    [string]$BaseUri = 'http://127.0.0.1:23119/api/',
    [string]$PaperId = ([guid]::NewGuid().ToString())
)

$ErrorActionPreference = 'Stop'
$SkillRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $SkillRoot 'modules\ZoteroLocalApi.psm1') -Force -WarningAction SilentlyContinue

function Read-JsonFile { param([string]$Path) [IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8) | ConvertFrom-Json }
function Write-Result { param([object]$Value) if ($ResultPath) { $dir=Split-Path -Parent $ResultPath; if(-not $dir){$dir=(Get-Location).Path};New-Item -ItemType Directory -Path $dir -Force|Out-Null;$tmp=Join-Path $dir ('.zotero-'+[guid]::NewGuid().ToString('N')+'.tmp');[IO.File]::WriteAllText($tmp,($Value|ConvertTo-Json -Depth 30),(New-Object Text.UTF8Encoding($false)));Move-Item $tmp $ResultPath -Force };$Value }
function Get-SelectedCollectionKey {
    param([string]$ApiBase)
    try {
        $origin = ([uri]$ApiBase).GetLeftPart([UriPartial]::Authority)
        $response = Invoke-RestMethod -Method Post -Uri ($origin + '/connector/getSelectedCollection') -ContentType 'application/json' -Body '{}' -TimeoutSec 10
        $id = [string]$response.id
        if ($id -match '^C(.+)$') { return $Matches[1] }
    } catch {}
    return $null
}

$errors=@();$attachments=@();$rollbacks=@();$createdParent=$false;$parentKey=$ItemKey;$parentVersion=0;$context=$null
try {
    $context = Connect-ZoteroLocalApi -BaseUri $BaseUri
    if (-not $context.api_key -or -not $context.remembered) { Request-ZoteroLocalAuthorization -Context $context -RequireRemembered | Out-Null }
    if ($Mode -eq 'create-with-pdf') {
        if (-not $PaperRecordPath -or -not $DownloadResultPath) { throw 'create-with-pdf requires paper and download result paths' }
        $paperResult=Read-JsonFile $PaperRecordPath;$download=Read-JsonFile $DownloadResultPath
        $PaperId=[string]$paperResult.paper_id
        if($paperResult.schema -ne 'paper-record.v1' -or $paperResult.status -ne 'succeeded'){throw 'Paper record is not successful'}
        if($download.schema -ne 'download-result.v1' -or $download.status -ne 'succeeded' -or -not $download.outputs.verified){throw 'A verified download-result.v1 is required before creating a Zotero item'}
        if(-not $CollectionKey){$configPath=Join-Path $env:LOCALAPPDATA 'PaperZoteroFlow\config.json';if(Test-Path $configPath){$CollectionKey=[string](Read-JsonFile $configPath).default_zotero_collection_key}}
        if(-not $CollectionKey){$CollectionKey=Get-SelectedCollectionKey $BaseUri}
        if(-not $CollectionKey){throw 'collection_required'}
        $match=Find-ZoteroPaper -Context $context -Record $paperResult.outputs
        if($match){$parentKey=[string]$match.item.data.key;$parentVersion=[int]$match.item.version;$itemAction='reused'}else{$created=New-ZoteroPaper -Context $context -Record $paperResult.outputs -CollectionKey $CollectionKey;$parentKey=$created.key;$parentVersion=$created.version;$createdParent=$true;$itemAction='created'}
        $attachments += Add-ZoteroStoredAttachment -Context $context -ParentKey $parentKey -FilePath ([string]$download.outputs.path) -Role 'Full Text PDF'
    } else {
        if(-not $parentKey){throw 'attach-to-item requires ItemKey'}
        $itemAction='reused'
        $attachmentSpecs=@()
        if($AttachmentListPath){$attachmentSpecs=@(ConvertFrom-ZoteroAttachmentSpecs ([IO.File]::ReadAllText($AttachmentListPath,[Text.Encoding]::UTF8)))}
        else{foreach($spec in @($Attachment)){$parts=@{};foreach($part in ($spec -split ';')){$pair=$part -split '=',2;if($pair.Count -eq 2){$parts[$pair[0]]=$pair[1]}};if(-not $parts.path -or -not $parts.role){throw 'Attachment must use path=<file>;role=<semantic role>'};$attachmentSpecs += [pscustomobject]@{path=$parts.path;role=$parts.role}}}
        foreach($spec in $attachmentSpecs){
            $attachments += Add-ZoteroStoredAttachment -Context $context -ParentKey $parentKey -FilePath $spec.path -Role $spec.role
        }
    }
    $status='succeeded'
}
catch {
    $status='failed';$errors += [pscustomobject]@{code='zotero_ingest_failed';message=$_.Exception.Message}
    if($context -and $parentKey){
        foreach($step in @(Get-ZoteroRollbackPlan -AttachmentKey $null -ParentKey $parentKey -ParentVersion $parentVersion -PreExistingParent:(-not $createdParent))){
            try{Remove-ZoteroCreatedObject -Context $context -Key $step.key -Version $step.version;$rollbacks += [pscustomobject]@{key=$step.key;status='deleted'}}catch{$rollbacks += [pscustomobject]@{key=$step.key;status='failed';message=$_.Exception.Message}}
        }
    }
}
$outputs=[pscustomobject]@{server_id=if($context){$context.server_id}else{$null};collection_key=$CollectionKey;item_key=$parentKey;item_action=$itemAction;attachments=$attachments;rollback=$rollbacks}
$result=[pscustomobject][ordered]@{schema='zotero-result.v1';schema_version=1;paper_id=$PaperId;status=$status;inputs=[pscustomobject]@{mode=$Mode};outputs=$outputs;provenance=@([pscustomobject]@{source='zotero-local-api';base_uri=$BaseUri});errors=$errors}
Write-Result $result
if($status -eq 'succeeded'){exit 0}else{exit 1}
