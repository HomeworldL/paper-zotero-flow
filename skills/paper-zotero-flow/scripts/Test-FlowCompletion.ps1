[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ManifestPath,
    [Parameter(Mandatory=$true)][string]$PaperId,
    [string]$BaseUri='http://127.0.0.1:23119/api/',
    [Parameter(Mandatory=$true)][string]$ResultPath
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'FlowSupport.psm1') -Force
$errors=@();$checks=@();$serverId=$null;$status='failed';$certifiedStages=@()
try{
    $manifest=Read-FlowJson $ManifestPath
    $paper=@($manifest.papers | Where-Object paper_id -eq $PaperId)[0]
    if(-not $paper){throw 'Paper is absent from the manifest'}
    $mode=[string]$manifest.requested_mode
    if($mode -notin @('download','ingest','translate','full')){throw 'Verification requires the original requested mode'}
    $needsTranslations=$mode -in @('translate','full')
    $needsOriginal=$mode -in @('download','ingest','full')
    if($needsOriginal){
        if(-not(Test-FlowPdf $paper.pdf.path $paper.pdf.sha256 -RequireReadable)){throw 'Original PDF is missing, changed, or unreadable'}
        $checks+=@([pscustomobject]@{role='original';path=$paper.pdf.path;sha256=$paper.pdf.sha256;verified=$true})
    }
    if($needsTranslations){
        if(-not(Test-FlowTranslationPair @($paper.translations) -RequireReadable)){throw 'Both unchanged readable translation PDFs are required'}
        $checks+=@($paper.translations)
    }
    if(-not $manifest.local_only){
        if(-not $paper.zotero.item_key){throw 'Zotero parent item is missing'}
        $root=Read-FlowLocalApi $BaseUri ''
        $serverId=$root.server_id
        if(-not $serverId){throw 'Zotero server identity is unavailable'}
        if($paper.zotero.server_id -and $paper.zotero.server_id -ne $serverId){throw 'Zotero server identity changed; do not replay writes'}
        $library=Get-FlowZoteroPdfs $BaseUri $paper.zotero.item_key
        if($manifest.requested_collection -and $manifest.requested_collection -notin @($library.parent.data.collections)){throw 'Parent item is not in the requested collection'}
        foreach($expected in $checks){
            $actual=@($library.files | Where-Object {$_.verified -and $_.role -eq $expected.role -and $_.sha256 -eq $expected.sha256})
            if(-not $actual.Count){throw ('Verified Zotero attachment is missing for role '+$expected.role)}
            $expected | Add-Member -NotePropertyName attachment_key -NotePropertyValue $actual[0].key -Force
            $expected | Add-Member -NotePropertyName stored_path -NotePropertyValue $actual[0].path -Force
        }
    }
    if($needsOriginal){$certifiedStages+='download';if(-not $manifest.local_only){$certifiedStages+='ingest'}}
    if($needsTranslations){$certifiedStages+='translate';if(-not $manifest.local_only){$certifiedStages+='attach'}}
    if($paper.metadata.title -and $mode -in @('download','full')){$certifiedStages+='find'}
    $status='succeeded'
}catch{$errors+=@([pscustomobject]@{code='completion_verification_failed';message=$_.Exception.Message})}
$result=[pscustomobject]@{
    schema='verification-result.v1';schema_version=1;paper_id=$PaperId;status=$status
    inputs=[pscustomobject]@{mode='verify';manifest_path=$ManifestPath}
    outputs=[pscustomobject]@{verified=($status -eq 'succeeded');checked_at=[DateTime]::UtcNow.ToString('o');local_only=[bool]$manifest.local_only;server_id=$serverId;item_key=$paper.zotero.item_key;checks=$checks;certified_stages=$certifiedStages}
    provenance=@([pscustomobject]@{source=if($manifest.local_only){'local-files'}else{'zotero-local-api-readback'};base_uri=if($manifest.local_only){$null}else{$BaseUri}})
    errors=$errors
}
Write-FlowJson $ResultPath $result
$result
if($status -eq 'succeeded'){exit 0}else{exit 1}
