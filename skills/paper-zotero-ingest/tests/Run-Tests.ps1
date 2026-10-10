$ErrorActionPreference = 'Stop'
$script:Passed = 0
$script:Failed = 0
$SkillRoot = Split-Path -Parent $PSScriptRoot

function Assert-Equal { param($Expected,$Actual,[string]$Name) if ($Expected -ne $Actual) { $script:Failed++; Write-Host "FAIL: $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red } else { $script:Passed++; Write-Host "PASS: $Name" } }
function Assert-True { param([bool]$Actual,[string]$Name) Assert-Equal $true $Actual $Name }
function Assert-False { param([bool]$Actual,[string]$Name) Assert-Equal $false $Actual $Name }

Import-Module (Join-Path $SkillRoot 'modules\ZoteroLocalApi.psm1') -Force -WarningAction SilentlyContinue
$writeToken = New-ZoteroWriteToken
Assert-True ($writeToken -match '^[0-9a-f]{32}$') 'creates a Zotero write token within the 32-character limit'
$items = @(Get-Content (Join-Path $PSScriptRoot 'fixtures\search-items.json') -Raw | ConvertFrom-Json)

$doiRecord = [pscustomobject]@{ identifiers=[pscustomobject]@{doi='10.1000/example';arxiv_id=$null}; metadata=[pscustomobject]@{title='Anything'} }
$arxivRecord = [pscustomobject]@{ identifiers=[pscustomobject]@{doi=$null;arxiv_id='2412.00174'}; metadata=[pscustomobject]@{title='Anything'} }
$titleRecord = [pscustomobject]@{ identifiers=[pscustomobject]@{doi=$null;arxiv_id=$null}; metadata=[pscustomobject]@{title='Normalized Paper Title'} }
$payloadRecord=[pscustomobject]@{identifiers=[pscustomobject]@{doi='10.1000/payload';arxiv_id=$null};metadata=[pscustomobject]@{item_type='journalArticle';title='Payload';authors=@('One Author');abstract='';year='2026';url='';venue='Journal'}}
$paperData=New-ZoteroPaperData -Record $payloadRecord -CollectionKey 'COLL0001'
Assert-True ($paperData.collections -is [System.Array]) 'keeps a single Zotero collection as an array'
Assert-Equal 1 $paperData.collections.Count 'keeps exactly one requested collection'
Assert-True ($paperData.creators -is [System.Array]) 'keeps a single Zotero creator as an array'
Assert-Equal $null (Find-ZoteroPaperMatch -Items @() -Record $doiRecord) 'treats an empty Zotero search as no match'
Assert-Equal 'existing-doi' (Find-ZoteroPaperMatch -Items $items -Record $doiRecord).match_type 'matches DOI first'
Assert-Equal 'existing-arxiv' (Find-ZoteroPaperMatch -Items $items -Record $arxivRecord).match_type 'matches arXiv ID'
Assert-Equal 'existing-title' (Find-ZoteroPaperMatch -Items $items -Record $titleRecord).match_type 'matches normalized title'

$oneShot = Get-Content (Join-Path $PSScriptRoot 'fixtures\authorize-one-shot.json') -Raw | ConvertFrom-Json
$remembered = Get-Content (Join-Path $PSScriptRoot 'fixtures\authorize-remembered.json') -Raw | ConvertFrom-Json
Assert-False (Test-ZoteroAuthorizationForUpload $oneShot) 'rejects one-shot authorization before upload'
Assert-True (Test-ZoteroAuthorizationForUpload $remembered) 'accepts remembered authorization'
Assert-True (Test-ZoteroUploadUri -UploadUri 'http://127.0.0.1:23119/api/local/uploads/key' -BaseUri 'http://127.0.0.1:23119/api/') 'accepts same loopback origin'
Assert-False (Test-ZoteroUploadUri -UploadUri 'https://example.com/upload' -BaseUri 'http://127.0.0.1:23119/api/') 'rejects a remote upload origin'

$newPlan = @(Get-ZoteroRollbackPlan -AttachmentKey 'ATTACH01' -ParentKey 'PARENT01' -PreExistingParent:$false)
$existingPlan = @(Get-ZoteroRollbackPlan -AttachmentKey 'ATTACH01' -ParentKey 'PARENT01' -PreExistingParent:$true)
Assert-Equal 'ATTACH01' $newPlan[0].key 'rolls back new attachment first'
Assert-Equal 'PARENT01' $newPlan[1].key 'rolls back new parent second'
Assert-Equal 1 $existingPlan.Count 'preserves a pre-existing parent'
$batchJson=ConvertTo-ZoteroBatchJson -Items @([ordered]@{itemType='journalArticle';title='One'})
Assert-True $batchJson.TrimStart().StartsWith('[') 'serializes Zotero create payload as an array'
$createdFixture=Get-Content (Join-Path $PSScriptRoot 'fixtures\create-item.json') -Raw|ConvertFrom-Json
$createdObject=Get-CreatedZoteroObject $createdFixture
Assert-Equal 'NEWITEM1' $createdObject.key 'parses created object key'
Assert-Equal 20 $createdObject.version 'retains created object version for rollback'
$nestedCreated=[pscustomobject]@{successful=[pscustomobject]@{'0'=[pscustomobject]@{data=[pscustomobject]@{key='NESTED01';version=21}}}}
Assert-Equal 'NESTED01' (Get-CreatedZoteroObject $nestedCreated).key 'parses a created key from nested editable data'
$failedMessage=$null
try{Get-CreatedZoteroObject ([pscustomobject]@{failed=[pscustomobject]@{'0'=[pscustomobject]@{code=400;message='invalid field'}}})|Out-Null}catch{$failedMessage=$_.Exception.Message}
Assert-True ($failedMessage -match 'invalid field') 'reports Zotero object-level create failures'
$specJson='[{"path":"C:\\papers\\one;part.pdf","role":"translated"},{"path":"C:\\papers\\two.pdf","role":"bilingual"}]'
$specs=@(ConvertFrom-ZoteroAttachmentSpecs $specJson)
Assert-Equal 2 $specs.Count 'parses an attachment list without CLI array binding'
Assert-Equal 'C:\papers\one;part.pdf' $specs[0].path 'preserves semicolons inside attachment paths'

$secretPath = Join-Path ([System.IO.Path]::GetTempPath()) ('zotero-secret-' + [guid]::NewGuid().ToString('N') + '.bin')
try {
    Protect-ZoteroApiKey -Key 'secret-value' -Path $secretPath
    Assert-Equal 'secret-value' (Unprotect-ZoteroApiKey -Path $secretPath) 'round-trips API key with DPAPI'
    Assert-False ((Get-Content -LiteralPath $secretPath -Raw) -match 'secret-value') 'does not store API key as plaintext'
}
finally { if (Test-Path $secretPath) { Remove-Item -LiteralPath $secretPath -Force } }

Write-Host "Result: $script:Passed passed, $script:Failed failed"
if ($script:Failed -gt 0) { exit 1 }
