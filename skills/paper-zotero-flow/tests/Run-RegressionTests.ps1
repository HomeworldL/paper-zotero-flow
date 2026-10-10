$ErrorActionPreference='Stop'
$taskSkill=Split-Path -Parent $PSScriptRoot
$taskRoot=Join-Path ([IO.Path]::GetTempPath()) ('pzf-regression-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $taskRoot | Out-Null
$script:Passed=0;$script:Failed=0
function Check($Expected,$Actual,[string]$Name){
    if($Expected -eq $Actual){$script:Passed++;Write-Output ('PASS: '+$Name)}else{$script:Failed++;Write-Output ("FAIL: $Name (expected $Expected, got $Actual)")}
}
function Save($Path,$Value){[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 40),[Text.UTF8Encoding]::new($false))}
function Run($File,[string[]]$Arguments){
    $taskOut=Join-Path $taskRoot ([guid]::NewGuid().ToString('N')+'.out')
    $taskErr=$taskOut+'.err'
    $taskProcess=Start-Process -FilePath (Get-Command pwsh.exe).Source -ArgumentList (@('-NoProfile','-File',('"'+$File+'"'))+$Arguments) -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $taskOut -RedirectStandardError $taskErr
    return $taskProcess.ExitCode
}
$taskId='11111111-1111-1111-1111-111111111111'
try{
    $taskManifest=Join-Path $taskRoot 'manifest.json'
    $taskStage=Join-Path $taskRoot 'stage.json'
    $taskSeed=@{schema_version=1;run_id='regression';requested_mode='full';local_only=$false;papers=@()}
    Save $taskManifest $taskSeed
    $taskFind=@{schema='paper-record.v1';schema_version=1;paper_id=$taskId;status='succeeded';inputs=@{};outputs=@{metadata=@{title='Example'}};provenance=@();errors=@()}
    Save $taskStage $taskFind
    $taskExit=Run (Join-Path $taskSkill 'scripts\Update-RunManifest.ps1') @('-ManifestPath',('"'+$taskManifest+'"'),'-StageResultPath',('"'+$taskStage+'"'),'-PaperId',$taskId)
    $taskResult=Get-Content $taskManifest -Raw | ConvertFrom-Json
    Check 0 $taskExit 'valid discovery merges'
    Check 'partial' $taskResult.papers[0].status 'discovery alone cannot complete a full workflow'

    $taskArtifacts=@(@{role='translated';path='mono.pdf';sha256=('a'*64);size_bytes=2048;verified=$true},@{role='bilingual';path='dual.pdf';sha256=('b'*64);size_bytes=2048;verified=$true})
    $taskTranslation=@{schema='translation-result.v1';schema_version=1;paper_id=$taskId;status='succeeded';inputs=@{service='qwenmt'};outputs=@{artifacts=$taskArtifacts;attempts=@();service_used='qwenmt'};provenance=@();errors=@()}
    Save $taskStage $taskTranslation
    $taskExit=Run (Join-Path $taskSkill 'scripts\Update-RunManifest.ps1') @('-ManifestPath',('"'+$taskManifest+'"'),'-StageResultPath',('"'+$taskStage+'"'),'-PaperId',$taskId)
    $taskResult=Get-Content $taskManifest -Raw | ConvertFrom-Json
    Check 'partial' $taskResult.papers[0].status 'generated translations are not verified Zotero attachments'

    $taskTranslation.status='failed';$taskTranslation.outputs.artifacts=@();$taskTranslation.errors=@(@{code='translation_failed';message='retry failed'})
    Save $taskStage $taskTranslation
    $taskExit=Run (Join-Path $taskSkill 'scripts\Update-RunManifest.ps1') @('-ManifestPath',('"'+$taskManifest+'"'),'-StageResultPath',('"'+$taskStage+'"'),'-PaperId',$taskId)
    $taskResult=Get-Content $taskManifest -Raw | ConvertFrom-Json
    Check 2 @($taskResult.papers[0].translations).Count 'failed retry preserves previous successful artifacts'
    Check 'failed' $taskResult.papers[0].stage_states.translate.status 'failure is attributed to its actual stage'
    Check 'qwenmt' $taskResult.papers[0].artifact_translation_run.service_used 'failed retry does not erase the provider provenance of retained artifacts'

    $taskPlan=Join-Path $taskRoot 'plan.json'
    $taskExit=Run (Join-Path $taskSkill 'scripts\Invoke-PaperZoteroFlow.ps1') @('-Mode','translate','-InputPdf',('"'+(Join-Path $taskRoot 'existing.pdf')+'"'),'-ItemKey','C6IML9UX','-PlanOnly','-ResultPath',('"'+$taskPlan+'"'))
    Check 0 $taskExit 'plans translation of an existing PDF and parent item without discovery'
    if(Test-Path $taskPlan){$taskPlanData=Get-Content $taskPlan -Raw|ConvertFrom-Json;Check 'translate,ingest.attach,verify' ($taskPlanData.route -join ',') 'translation route ends in read-back verification'}

    $taskTranslation.status='succeeded';$taskTranslation.outputs.artifacts=@($taskArtifacts[0]);$taskTranslation.errors=@()
    Save $taskStage $taskTranslation
    $taskExit=Run (Join-Path $taskSkill 'scripts\Test-PaperZoteroFlowResult.ps1') @('-Path',('"'+$taskStage+'"'),'-ExpectedSchema','translation-result.v1')
    Check 1 $taskExit 'successful translation must declare both output roles'

    # A real one-page PDF fixture, with correct xref offsets (no network or library writes).
    $taskPdf=Join-Path $taskRoot 'real.pdf'
    $taskObjects=@('<< /Type /Catalog /Pages 2 0 R >>','<< /Type /Pages /Kids [3 0 R] /Count 1 >>','<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >>',"<< /Length 0 >>`nstream`n`nendstream")
    $taskPdfText="%PDF-1.4`n%"+('padding'*300)+"`n";$taskOffsets=@(0)
    for($taskIndex=0;$taskIndex -lt $taskObjects.Count;$taskIndex++){$taskOffsets+=[Text.Encoding]::ASCII.GetByteCount($taskPdfText);$taskPdfText+=([string]($taskIndex+1))+" 0 obj`n"+$taskObjects[$taskIndex]+"`nendobj`n"}
    $taskXref=[Text.Encoding]::ASCII.GetByteCount($taskPdfText)
    $taskPdfText+="xref`n0 5`n0000000000 65535 f `n"
    foreach($taskOffset in $taskOffsets[1..4]){$taskPdfText+=('{0:D10} 00000 n ' -f $taskOffset)+"`n"}
    $taskPdfText+="trailer`n<< /Size 5 /Root 1 0 R >>`nstartxref`n$taskXref`n%%EOF`n"
    [IO.File]::WriteAllText($taskPdf,$taskPdfText,[Text.Encoding]::ASCII)
    $taskSha=(Get-FileHash $taskPdf -Algorithm SHA256).Hash.ToLowerInvariant()
    $taskPair=@(@{role='translated';path=$taskPdf;sha256=$taskSha;verified=$true},@{role='bilingual';path=$taskPdf;sha256=$taskSha;verified=$true})
    $taskLocalManifest=Join-Path $taskRoot 'local-manifest.json'
    Save $taskLocalManifest @{schema_version=1;requested_mode='translate';local_only=$true;papers=@(@{paper_id=$taskId;translations=$taskPair;zotero=@{};pdf=@{}})}
    $taskVerify=Join-Path $taskRoot 'verify.json'
    $taskExit=Run (Join-Path $taskSkill 'scripts\Test-FlowCompletion.ps1') @('-ManifestPath',('"'+$taskLocalManifest+'"'),'-PaperId',$taskId,'-ResultPath',('"'+$taskVerify+'"'))
    Check 0 $taskExit 'verifies both readable local PDF artifacts without Zotero access'
    if(Test-Path $taskVerify){$taskEvidence=Get-Content $taskVerify -Raw|ConvertFrom-Json;Check $true $taskEvidence.outputs.verified 'verification returns explicit completion evidence'}
    $taskPair[1].sha256=('f'*64)
    Save $taskLocalManifest @{schema_version=1;requested_mode='translate';local_only=$true;papers=@(@{paper_id=$taskId;translations=$taskPair;zotero=@{};pdf=@{}})}
    $taskExit=Run (Join-Path $taskSkill 'scripts\Test-FlowCompletion.ps1') @('-ManifestPath',('"'+$taskLocalManifest+'"'),'-PaperId',$taskId,'-ResultPath',('"'+$taskVerify+'"'))
    Check 1 $taskExit 'rejects a changed output despite a stored verified flag'

    $taskExit=Run (Join-Path $taskSkill 'scripts\Invoke-PaperZoteroFlow.ps1') @('-Input','Example','-Mode','full','-ResumeState','attachment-failed','-PlanOnly','-ResultPath',('"'+$taskPlan+'"'))
    $taskPlanData=Get-Content $taskPlan -Raw|ConvertFrom-Json
    Check 'ingest.attach,verify' ($taskPlanData.route -join ',') 'attachment-only retry cannot schedule a new translation'

    $taskBoundManifest=Join-Path $taskRoot 'uncertain.json'
    Save $taskBoundManifest @{schema_version=1;requested_mode='translate';local_only=$false;papers=@(@{paper_id=$taskId;translations=@();pdf=@{};zotero=@{};stage_states=@{translate=@{status='succeeded'};attach=@{status='unknown'}};stage_history=@()})}
    $taskProof=@{schema='verification-result.v1';schema_version=1;paper_id=$taskId;status='succeeded';inputs=@{mode='verify'};outputs=@{verified=$true;certified_stages=@('translate','attach');checks=@();checked_at='2026-10-10T00:00:00Z'};provenance=@();errors=@()}
    Save $taskStage $taskProof
    $taskExit=Run (Join-Path $taskSkill 'scripts\Update-RunManifest.ps1') @('-ManifestPath',('"'+$taskBoundManifest+'"'),'-StageResultPath',('"'+$taskStage+'"'),'-PaperId',$taskId)
    $taskResult=Get-Content $taskBoundManifest -Raw|ConvertFrom-Json
    Check 'succeeded' $taskResult.papers[0].status 'successful read-back reconciles an unknown attachment outcome without replaying writes'

    $taskPair[1].sha256=$taskSha
    $taskFixture=Join-Path $taskRoot 'external-fixtures';New-Item -ItemType Directory $taskFixture | Out-Null
    $taskTranslation.status='succeeded';$taskTranslation.outputs.artifacts=$taskPair;$taskTranslation.errors=@()
    Save (Join-Path $taskFixture 'translation-success.json') $taskTranslation
    $taskEndResult=Join-Path $taskRoot 'end-result.json'
    $taskExit=Run (Join-Path $taskSkill 'scripts\Invoke-PaperZoteroFlow.ps1') @('-Mode','translate','-InputPdf',('"'+$taskPdf+'"'),'-LocalOnly','-RunRoot',('"'+$taskRoot+'"'),'-RunId','local-end-to-end','-StageFixtureRoot',('"'+$taskFixture+'"'),'-ResultPath',('"'+$taskEndResult+'"'))
    Check 0 $taskExit 'existing-PDF workflow performs real local completion verification after a simulated provider stage'
    if(Test-Path $taskEndResult){
        $taskEnd=Get-Content $taskEndResult -Raw|ConvertFrom-Json
        Check 1 $taskEnd.completed 'end-to-end completion counts the requested paper once'
        Check $true $taskEnd.papers[0].completion_verified 'end-to-end completion includes fresh verification evidence'
        $taskRetainedPath=Join-Path $taskRoot ('local-end-to-end\stage-results\'+$taskEnd.papers[0].paper_id+'\translate.json')
        $taskRetainedHash=(Get-FileHash $taskRetainedPath).Hash
        # If resume wrongly invokes translation, this deliberately unusable provider result fails it.
        $taskTranslation.status='failed';$taskTranslation.outputs.artifacts=@();$taskTranslation.errors=@(@{code='must_not_run';message='provider must not be invoked'})
        Save (Join-Path $taskFixture 'translation-success.json') $taskTranslation
        $taskExit=Run (Join-Path $taskSkill 'scripts\Invoke-PaperZoteroFlow.ps1') @('-Mode','translate','-InputPdf',('"'+$taskPdf+'"'),'-LocalOnly','-Resume','-RunRoot',('"'+$taskRoot+'"'),'-RunId','local-end-to-end','-StageFixtureRoot',('"'+$taskFixture+'"'),'-ResultPath',('"'+$taskEndResult+'"'))
        Check 0 $taskExit 'resume succeeds without invoking a failing provider when valid outputs already exist'
        Check $taskRetainedHash (Get-FileHash $taskRetainedPath).Hash 'resume does not replace the successful translation result'
    }
    $taskEmptyDirectory=Join-Path $taskRoot 'empty-run';New-Item -ItemType Directory $taskEmptyDirectory | Out-Null
    Save (Join-Path $taskEmptyDirectory 'manifest.json') @{schema_version=1;requested_mode='translate';local_only=$true;papers=@()}
    $taskExit=Run (Join-Path $taskSkill 'scripts\Invoke-PaperZoteroFlow.ps1') @('-Mode','verify','-RunRoot',('"'+$taskRoot+'"'),'-RunId','empty-run')
    Check 1 $taskExit 'verification of an empty manifest cannot claim all papers completed'
}finally{
    # This is a freshly created, exact test directory; no user data lives here.
    if((Split-Path -Leaf $taskRoot) -notlike 'pzf-regression-*'){throw 'Unexpected test cleanup target'}
    Remove-Item -LiteralPath $taskRoot -Recurse -Force
}
Write-Output ("Result: $script:Passed passed, $script:Failed failed")
if($script:Failed){exit 1}
