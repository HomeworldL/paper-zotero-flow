[CmdletBinding()]
param(
 [Alias('Input')][string[]]$PaperInput,[string]$InputListPath,
 [Parameter(Mandatory=$true)][ValidateSet('find','download','ingest','translate','full','verify')][string]$Mode,
 [string]$InputPdf,[string]$ItemKey,[string]$PaperRecordPath,[string]$DownloadResultPath,
 [string]$CollectionKey,[switch]$LocalOnly,[string]$RunId,[switch]$Resume,[switch]$PlanOnly,
 [ValidateSet('none','attachment-failed')][string]$ResumeState='none',
 [ValidateSet('qwenmt','bing')][string]$TranslationService='qwenmt',
 [ValidateSet('none','bing')][string]$TranslationFallback='bing',
 [string]$QwenModel='qwen-mt-flash',[ValidateSet('direct','system')][string]$QwenNetwork='direct',
 [ValidateRange(1,100)][int]$QwenQps=1,[ValidateRange(1,100)][int]$QwenWorkers=1,
 [switch]$AutoEnableOcrWorkaround,[string]$PowerShellPath,
 [string]$BaseUri='http://127.0.0.1:23119/api/',
 [string]$SkillsRoot,[string]$StageFixtureRoot,[string]$RunRoot,[string]$ResultPath
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'FlowSupport.psm1') -Force
$FlowRoot=Split-Path -Parent $PSScriptRoot
if(-not $SkillsRoot){$SkillsRoot=Split-Path -Parent $FlowRoot}
$runtime=Resolve-FlowPowerShell $PowerShellPath
if(-not $RunRoot){$RunRoot=Join-Path $env:LOCALAPPDATA 'PaperZoteroFlow\runs'}
if(-not $RunId){
 if(-not $PlanOnly -and ($Resume -or $Mode -eq 'verify' -or $ResumeState -ne 'none')){throw 'Resume and verification require the original RunId'}
 $RunId=[guid]::NewGuid().ToString()
}
if($RunId -notmatch '^[a-zA-Z0-9._-]+$' -or $RunId -in @('.','..')){throw 'RunId must be a single directory name'}
$CurrentRun=Join-Path $RunRoot $RunId
$ManifestPath=Join-Path $CurrentRun 'manifest.json'
$StageRoot=Join-Path $CurrentRun 'stage-results'
$allInputs=@($PaperInput|Where-Object {$_})
if($InputListPath){
 $raw=[IO.File]::ReadAllText($InputListPath,[Text.Encoding]::UTF8)
 if($raw.TrimStart().StartsWith('[')){$allInputs+=@($raw|ConvertFrom-Json)}else{$allInputs+=@($raw -split '\r?\n'|Where-Object {$_.Trim()})}
}
if(-not $allInputs.Count -and $ItemKey){$allInputs=@('zotero:'+$ItemKey)}
if(-not $allInputs.Count -and $InputPdf){$allInputs=@($InputPdf)}
if(-not $allInputs.Count -and $Mode -ne 'verify'){throw 'Provide paper inputs, an InputPdf, or an existing ItemKey'}
if(($InputPdf -or $ItemKey -or $PaperRecordPath -or $DownloadResultPath) -and $allInputs.Count -gt 1){throw 'Existing-item and PDF inputs are one-paper operations'}
if($Mode -eq 'translate' -and -not $LocalOnly -and -not $ItemKey -and -not $Resume -and $ResumeState -eq 'none'){throw 'Translation attachment requires an existing ItemKey, or a resumed run with its parent item'}
function Get-StablePaperId([string]$Value){
 $md5=[Security.Cryptography.MD5]::Create()
 try{$hash=$md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value.ToLowerInvariant().Trim()))}finally{$md5.Dispose()}
 return ([guid]::new([byte[]]$hash)).ToString()
}
function Get-StageRoute{
 if($ResumeState -eq 'attachment-failed'){return @('ingest.attach','verify')}
 switch($Mode){
  'find'{return @('find')}
  'download'{if($LocalOnly){return @('find','download','verify')}else{return @('find','download','ingest','verify')}}
  'ingest'{return @('ingest','verify')}
  'translate'{if($LocalOnly){return @('translate','verify')}else{return @('translate','ingest.attach','verify')}}
  'full'{if($LocalOnly){return @('find','download','translate','verify')}else{return @('find','download','ingest','translate','ingest.attach','verify')}}
  'verify'{return @('verify')}
 }
}
$route=@(Get-StageRoute)
if($PlanOnly){
 $plan=[pscustomobject]@{mode=$Mode;local_only=[bool]$LocalOnly;resume_state=$ResumeState;translation_service=$TranslationService;translation_fallback=$TranslationFallback;qwen_model=$QwenModel;qwen_network=$QwenNetwork;qwen_qps=$QwenQps;qwen_workers=$QwenWorkers;runtime=$runtime;route=$route}
 if($ResultPath){Write-FlowJson $ResultPath $plan};$plan;exit 0
}
if(-not(Get-Command Get-FileHash -ErrorAction SilentlyContinue)){throw 'Get-FileHash is unavailable in this host'}
if($Mode -ne 'find' -and -not(Get-Command pdfinfo.exe -ErrorAction SilentlyContinue)){throw 'PDF read-back verification requires pdfinfo.exe; use the configured bundled runtime'}
if(($Resume -or $Mode -eq 'verify' -or $ResumeState -ne 'none') -and -not(Test-Path -LiteralPath $ManifestPath)){throw 'The original manifest is required; do not guess attachment targets'}
if(Test-Path -LiteralPath $ManifestPath){
 if(-not $Resume -and $Mode -ne 'verify' -and $ResumeState -eq 'none'){throw 'Run exists; use Resume instead of overwriting it'}
 $manifest=Read-FlowJson $ManifestPath
 if($manifest.schema_version -ne 1){throw 'Unsupported manifest version'}
 if($Mode -eq 'verify' -and -not @($manifest.papers).Count){throw 'There are no requested papers to verify'}
 $requestedMode=if($manifest.requested_mode){[string]$manifest.requested_mode}else{if($Mode -eq 'verify'){throw 'Legacy manifest has no requested mode; specify its original workflow to resume'}else{$Mode}}
 $LocalOnly=[bool]$manifest.local_only
}else{
 $requestedMode=$Mode
 $manifest=[pscustomobject]@{schema_version=1;run_id=$RunId;created_at=[DateTime]::UtcNow.ToString('o');requested_mode=$Mode;local_only=[bool]$LocalOnly;requested_collection=$CollectionKey;papers=@()}
}
New-Item -ItemType Directory -Path $StageRoot -Force|Out-Null
$mutex=[Threading.Mutex]::new($false,('Local\PaperZoteroFlow-'+(Get-StablePaperId ([IO.Path]::GetFullPath($CurrentRun)))))
if(-not $mutex.WaitOne(0)){throw 'This run is already active; do not start a second batch'}
function Invoke-ChildScript([string]$Script,[string[]]$Arguments){Invoke-FlowChild -Runtime $runtime -Script $Script -Arguments $Arguments -LogDirectory (Join-Path $CurrentRun 'stage-logs')}
function Merge-Stage([string]$Path,[string]$Id){
 $result=Read-FlowJson $Path
 $arguments=@('-ManifestPath',$ManifestPath,'-StageResultPath',$Path,'-PaperId',$Id,'-RequestedMode',$requestedMode)
 if($LocalOnly){$arguments+='-LocalOnly'}
 $merge=Invoke-ChildScript (Join-Path $PSScriptRoot 'Update-RunManifest.ps1') $arguments
 if($merge.exit_code -ne 0){throw ('Stage contract/merge failed; see '+$merge.stderr)}
 return $result
}
function Get-Paper([string]$Id){@((Read-FlowJson $ManifestPath).papers|Where-Object paper_id -eq $Id)[0]}
function Save-InvocationResult([string]$Script,[string[]]$Arguments,[string]$Destination){
 if(Test-Path -LiteralPath $Destination){Move-Item -LiteralPath $Destination -Destination ($Destination+'.previous-'+[guid]::NewGuid().ToString('N'))}
 $child=Invoke-ChildScript $Script $Arguments
 if(-not(Test-Path -LiteralPath $Destination)){throw ('Stage produced no result; see '+$child.stderr)}
 $value=Read-FlowJson $Destination
 if($child.exit_code -ne 0 -and $value.status -eq 'succeeded'){throw 'Child failed despite a success result; reconciliation is required'}
}
function Copy-Fixture([string]$Name,[string]$Id,[string]$Destination){$fixture=Read-FlowJson (Join-Path $StageFixtureRoot $Name);$fixture.paper_id=$Id;Write-FlowJson $Destination $fixture}
function New-StageRecord([string]$Schema,[string]$Id,$Inputs,$Outputs,$Provenance){
 [pscustomobject]@{schema=$Schema;schema_version=1;paper_id=$Id;status='succeeded';inputs=$Inputs;outputs=$Outputs;provenance=@($Provenance);errors=@()}
}
try{
 $manifest|Add-Member -NotePropertyName run_state -NotePropertyValue 'running' -Force
 $manifest|Add-Member -NotePropertyName process_id -NotePropertyValue $PID -Force
 Write-FlowJson $ManifestPath $manifest
 $tasks=if($Mode -eq 'verify'){@($manifest.papers|ForEach-Object {[pscustomobject]@{id=$_.paper_id;query=$_.query}})}else{@($allInputs|ForEach-Object {[pscustomobject]@{id=(Get-StablePaperId $_);query=$_}})}
 foreach($task in $tasks){
  $id=$task.id;$query=$task.query
  $directory=Join-Path $StageRoot $id;New-Item -ItemType Directory -Path $directory -Force|Out-Null
  $findPath=Join-Path $directory 'find.json';$downloadPath=Join-Path $directory 'download.json';$ingestPath=Join-Path $directory 'ingest.json'
  $translationPath=Join-Path $directory 'translate.json';$attachPath=Join-Path $directory 'attach.json';$verifyPath=Join-Path $directory 'verify.json'
  $activeStage='prepare';$uncertain=$false
  try{
   if($Mode -ne 'verify' -and ($InputPdf -or $ItemKey)){
    $source=$InputPdf;$previous=Get-Paper $id;$library=$null
    if($ItemKey){
     $library=Get-FlowZoteroPdfs $BaseUri $ItemKey
     $root=Read-FlowLocalApi $BaseUri ''
     if($previous.zotero.item_key -and $previous.zotero.item_key -ne $ItemKey){throw 'Existing run is bound to a different parent'}
     if($previous.zotero.server_id -and $previous.zotero.server_id -ne $root.server_id){throw 'Existing run is bound to a different Zotero server'}
     if(-not $source){$source=@($library.files|Where-Object {$_.verified -and $_.role -eq 'original'})[0].path}
     $binding=New-StageRecord 'zotero-result.v1' $id @{mode='binding'} @{server_id=$root.server_id;item_key=$ItemKey;item_action='reused';attachments=@()} @{source='zotero-local-api-read'}
     # An existing binding is not evidence that an earlier mutation succeeded.
     if(-not ($Resume -and $previous)){
      Write-FlowJson $ingestPath $binding;Merge-Stage $ingestPath $id|Out-Null
     }
    }
    if($source){
     if(-not(Test-FlowPdf $source -RequireReadable)){throw 'Existing PDF is unreadable'}
     $sha=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
     if($previous.pdf.sha256 -and $previous.pdf.sha256 -ne $sha){throw 'Original PDF changed; use a new run instead of reusing old translations'}
     $record=New-StageRecord 'download-result.v1' $id @{existing_pdf=$source} @{path=$source;sha256=$sha;size_bytes=(Get-Item -LiteralPath $source).Length;verified=$true;source_type='existing-local'} @{source='local-file'}
     Write-FlowJson $downloadPath $record;Merge-Stage $downloadPath $id|Out-Null
     # Only a fresh run may adopt a stored pair. A resumed run's expected
     # outputs and their producer provenance must remain authoritative.
     if(-not $Resume -and -not @($previous.translations).Count -and $library -and @($library.files|Where-Object {$_.role -eq 'original' -and $_.sha256 -eq $sha}).Count){
      $pair=@($library.files|Where-Object {$_.verified -and $_.role -in @('translated','bilingual')})
      if(Test-FlowTranslationPair $pair -RequireReadable){
       $cached=New-StageRecord 'translation-result.v1' $id @{input_pdf=$source} @{artifacts=$pair;attempts=@();service_used=$null} @{source='existing-zotero-attachments';note='Provider not inferred from filename'}
       Write-FlowJson $translationPath $cached;Merge-Stage $translationPath $id|Out-Null
      }
     }
    }
   }
   foreach($inputRecord in @(@{path=$PaperRecordPath;destination=$findPath},@{path=$DownloadResultPath;destination=$downloadPath})){
    if($inputRecord.path){$copy=Read-FlowJson $inputRecord.path;$copy.paper_id=$id;Write-FlowJson $inputRecord.destination $copy;Merge-Stage $inputRecord.destination $id|Out-Null}
   }
   $paper=Get-Paper $id;$itemRoute=$route
   if($paper -and ($paper.stage_states.attach.status -eq 'unknown' -or $paper.stage_states.ingest.status -eq 'unknown')){$itemRoute=@('verify')}
   elseif($Resume -and $paper -and @($paper.translations).Count -and -not(Test-FlowTranslationPair @($paper.translations) -RequireReadable)){$itemRoute=@('verify')}
   elseif($Resume -and $paper -and (Test-FlowTranslationPair @($paper.translations) -RequireReadable)){
    if($LocalOnly){$itemRoute=@('verify')}elseif($paper.zotero.item_key){$itemRoute=@('ingest.attach','verify')}
   }
   foreach($stage in $itemRoute){
    $activeStage=if($stage -eq 'ingest.attach'){'attach'}else{$stage};$uncertain=$false
    $paper=Get-Paper $id
    if($stage -eq 'find' -and $Resume -and (Test-Path -LiteralPath $findPath)){$cached=Read-FlowJson $findPath;if($cached.status -eq 'succeeded'){Merge-Stage $findPath $id|Out-Null;continue}}
    if($stage -eq 'download' -and $Resume -and $paper.pdf.verified -and (Test-FlowPdf $paper.pdf.path $paper.pdf.sha256 -RequireReadable)){Merge-Stage $downloadPath $id|Out-Null;continue}
    if($stage -eq 'translate' -and (Test-FlowTranslationPair @($paper.translations) -RequireReadable)){continue}
    switch($stage){
     'find'{
      if($StageFixtureRoot){Copy-Fixture 'find-success.json' $id $findPath}else{Save-InvocationResult (Join-Path $SkillsRoot 'paper-find\scripts\Resolve-Paper.ps1') @('-Query',$query,'-PaperId',$id,'-OutputPath',$findPath) $findPath}
      $result=Merge-Stage $findPath $id
     }
     'download'{
      if($StageFixtureRoot){Copy-Fixture $(if($query -eq 'no-pdf'){'download-no-pdf.json'}else{'download-success.json'}) $id $downloadPath}else{
       $args=@('-PaperRecordPath',$findPath,'-OutputDirectory',(Join-Path $directory 'original'),'-PaperId',$id,'-ResultPath',$downloadPath)
       $config=Join-Path (Split-Path -Parent $RunRoot) 'config.json'
       if(Test-Path -LiteralPath $config){$email=[string](Read-FlowJson $config).unpaywall_email;if($email){$args+=@('-UnpaywallEmail',$email)}}
       Save-InvocationResult (Join-Path $SkillsRoot 'paper-download\scripts\Download-Paper.ps1') $args $downloadPath
      }
      $result=Merge-Stage $downloadPath $id
     }
     'ingest'{
      if($Resume -and $paper.zotero.item_key){
       $actual=Get-FlowZoteroPdfs $BaseUri $paper.zotero.item_key
       if(@($actual.files|Where-Object {$_.verified -and $_.role -eq 'original' -and $_.sha256 -eq $paper.pdf.sha256}).Count){continue}
       throw 'Existing parent lacks its expected original; reconcile before replaying ingest'
      }
      if($StageFixtureRoot){Copy-Fixture 'ingest-success.json' $id $ingestPath}else{
       $uncertain=$true
       $args=@('-Mode','create-with-pdf','-PaperRecordPath',$findPath,'-DownloadResultPath',$downloadPath,'-PaperId',$id,'-ResultPath',$ingestPath,'-BaseUri',$BaseUri)
       if($CollectionKey){$args+=@('-CollectionKey',$CollectionKey)}
       Save-InvocationResult (Join-Path $SkillsRoot 'paper-zotero-ingest\scripts\Invoke-ZoteroIngest.ps1') $args $ingestPath
       $uncertain=$false
      }
      $result=Merge-Stage $ingestPath $id
     }
     'translate'{
      if(-not $paper.pdf.verified -or -not(Test-FlowPdf $paper.pdf.path $paper.pdf.sha256 -RequireReadable)){throw 'Verified original PDF is required before translation'}
      if($StageFixtureRoot){Copy-Fixture 'translation-success.json' $id $translationPath}else{
       $args=@('-InputPdf',$paper.pdf.path,'-OutputDirectory',(Join-Path $directory 'translated'),'-Service',$TranslationService,'-FallbackService',$TranslationFallback,'-QwenModel',$QwenModel,'-QwenNetwork',$QwenNetwork,'-QwenQps',[string]$QwenQps,'-QwenWorkers',[string]$QwenWorkers,'-PaperId',$id,'-ResultPath',$translationPath)
       if($AutoEnableOcrWorkaround){$args+='-AutoEnableOcrWorkaround'}
       Save-InvocationResult (Join-Path $SkillsRoot 'paper-translate\scripts\Invoke-PaperTranslation.ps1') $args $translationPath
      }
      $result=Merge-Stage $translationPath $id
     }
     'ingest.attach'{
      if(-not(Test-FlowTranslationPair @($paper.translations) -RequireReadable)){throw 'Attachment retry requires both unchanged readable local outputs; no retranslation was started'}
      if(-not $paper.zotero.item_key){throw 'An existing parent item is required'}
      if($StageFixtureRoot){Copy-Fixture 'attach-success.json' $id $attachPath}else{
       $actual=Get-FlowZoteroPdfs $BaseUri $paper.zotero.item_key
       if(@($actual.files|Where-Object {$_.role -in @('translated','bilingual') -and -not $_.verified}).Count){throw 'Unreadable existing translated attachment requires reconciliation'}
       $matching=@($paper.translations|ForEach-Object {$expected=$_;$actual.files|Where-Object {$_.verified -and $_.role -eq $expected.role -and $_.sha256 -eq $expected.sha256}|Select-Object -First 1})
       if($matching.Count -eq 2){
        $already=New-StageRecord 'zotero-result.v1' $id @{mode='attach-to-item'} @{server_id=$paper.zotero.server_id;item_key=$paper.zotero.item_key;attachments=@($matching|ForEach-Object {@{key=$_.key;role=$_.role;sha256=$_.sha256;action='reused'}})} @{source='zotero-local-api-read'}
        Write-FlowJson $attachPath $already
       }else{
        $specs=@($paper.translations|ForEach-Object {[pscustomobject]@{path=$_.path;role=if($_.role -eq 'bilingual'){([string][char]0x53cc)+([char]0x8bed)+' PDF'}else{([string][char]0x4e2d)+([char]0x6587)+' PDF'}}})
        $specPath=Join-Path $directory 'attachments.json';Write-FlowJson $specPath $specs
        $uncertain=$true
        Save-InvocationResult (Join-Path $SkillsRoot 'paper-zotero-ingest\scripts\Invoke-ZoteroIngest.ps1') @('-Mode','attach-to-item','-ItemKey',$paper.zotero.item_key,'-PaperId',$id,'-AttachmentListPath',$specPath,'-ResultPath',$attachPath,'-BaseUri',$BaseUri) $attachPath
        $uncertain=$false
       }
      }
      $result=Merge-Stage $attachPath $id
     }
     'verify'{
      if($StageFixtureRoot -and -not $LocalOnly){Copy-Fixture 'verification-success.json' $id $verifyPath}else{Save-InvocationResult (Join-Path $PSScriptRoot 'Test-FlowCompletion.ps1') @('-ManifestPath',$ManifestPath,'-PaperId',$id,'-BaseUri',$BaseUri,'-ResultPath',$verifyPath) $verifyPath}
      $result=Merge-Stage $verifyPath $id
     }
    }
    if($result.status -ne 'succeeded'){break}
   }
  }catch{
   $failure=[pscustomobject]@{schema='paper-record.v1';schema_version=1;paper_id=$id;status='failed';inputs=@{query=$query;failed_stage=$activeStage;mutation_uncertain=$uncertain};outputs=@{};provenance=@();errors=@(@{code='orchestration_failed';message=$_.Exception.Message})}
   $failurePath=Join-Path $directory ('failure-'+[guid]::NewGuid().ToString('N')+'.json');Write-FlowJson $failurePath $failure
   Merge-Stage $failurePath $id|Out-Null
  }
 }
 $manifest=Read-FlowJson $ManifestPath
 $incomplete=@($manifest.papers|Where-Object status -ne 'succeeded')
 $manifest|Add-Member -NotePropertyName run_state -NotePropertyValue $(if($incomplete.Count){'finished_with_errors'}else{'finished'}) -Force
 $manifest|Add-Member -NotePropertyName finished_at -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
 Write-FlowJson $ManifestPath $manifest
 $summary=[pscustomobject]@{run_id=$RunId;manifest_path=$ManifestPath;run_state=$manifest.run_state;total=@($manifest.papers).Count;completed=@($manifest.papers|Where-Object status -eq 'succeeded').Count;incomplete=$incomplete.Count;fixture_run=[bool]$StageFixtureRoot;papers=@($manifest.papers)}
 if($ResultPath){Write-FlowJson $ResultPath $summary};$summary
 if($incomplete.Count){exit 1}else{exit 0}
}finally{$mutex.ReleaseMutex();$mutex.Dispose()}
