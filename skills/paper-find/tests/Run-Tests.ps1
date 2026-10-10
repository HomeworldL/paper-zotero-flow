$ErrorActionPreference = 'Stop'
$script:Passed = 0
$script:Failed = 0
$SkillRoot = Split-Path -Parent $PSScriptRoot

function Assert-Equal {
    param($Expected, $Actual, [string]$Name)
    if ($Expected -ne $Actual) { $script:Failed++; Write-Host "FAIL: $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red }
    else { $script:Passed++; Write-Host "PASS: $Name" }
}
function Assert-True {
    param([bool]$Actual, [string]$Name)
    Assert-Equal $true $Actual $Name
}

Import-Module (Join-Path $SkillRoot 'modules\Crossref.psm1') -Force -WarningAction SilentlyContinue
Import-Module (Join-Path $SkillRoot 'modules\Arxiv.psm1') -Force -WarningAction SilentlyContinue
Import-Module (Join-Path $SkillRoot 'modules\OpenAlex.psm1') -Force

$crossref = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures\crossref-doi.json') -Raw | ConvertFrom-Json
$arxivXml = [xml](Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures\arxiv-entry.xml') -Raw)
$openAlex = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures\openalex-work.json') -Raw | ConvertFrom-Json
$search = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures\crossref-search.json') -Raw | ConvertFrom-Json

Assert-Equal '10.1145/123.456' (Normalize-Doi 'https://doi.org/10.1145/123.456') 'normalizes DOI URLs'
Assert-Equal '2412.00174v2' (Normalize-ArxivId 'https://arxiv.org/pdf/2412.00174v2.pdf') 'preserves arXiv versions'

$crossrefRecord = ConvertFrom-CrossrefWork $crossref
Assert-Equal 'Example Interactive Character' $crossrefRecord.metadata.title 'parses Crossref title'
Assert-Equal 'conferencePaper' $crossrefRecord.metadata.item_type 'maps proceedings articles'

$arxivRecord = ConvertFrom-ArxivEntry $arxivXml.feed.entry
Assert-Equal '2412.00174v2' $arxivRecord.identifiers.arxiv_id 'parses arXiv identifier'
Assert-Equal '2412.00174' $arxivRecord.identifiers.arxiv_work_id 'emits unversioned arXiv work id'
$feedFromElement = ConvertTo-ArxivFeed $arxivXml.feed
Assert-Equal '2412.00174v2' (Normalize-ArxivId ([string]$feedFromElement.feed.entry.id)) 'accepts an XmlElement response from Windows PowerShell'
$recordFromEntryResponse = ConvertFrom-ArxivResponse $arxivXml.feed.entry
Assert-Equal '2412.00174v2' $recordFromEntryResponse.identifiers.arxiv_id 'accepts a direct Atom entry response'

$openAlexRecord = ConvertFrom-OpenAlexWork $openAlex
Assert-Equal 'openalex' $openAlexRecord.pdf_candidates[0].source_type 'parses OpenAlex OA location'
$openAlexStringRecord = ConvertFrom-OpenAlexWork (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures\openalex-work.json') -Raw)
Assert-Equal 'openalex' $openAlexStringRecord.pdf_candidates[0].source_type 'parses an OpenAlex JSON string response'
$duplicateCaseJson = '{"id":"W1","doi":"https://doi.org/10.1000/example","title":"Case Test","publication_year":2026,"primary_location":{"landing_page_url":"https://example.org","pdf_url":null,"source":{"display_name":"Venue"}},"best_oa_location":{"pdf_url":"https://example.org/paper.pdf","landing_page_url":"https://example.org","version":"publishedVersion"},"authorships":[],"abstract_inverted_index":{"The":[0],"the":[1]}}'
Assert-Equal 'openalex' (ConvertFrom-OpenAlexWork $duplicateCaseJson).pdf_candidates[0].source_type 'accepts OpenAlex JSON with case-duplicate abstract keys'

$merged = Merge-PaperRecord -Records @($arxivRecord, $openAlexRecord, $crossrefRecord)
Assert-Equal '10.1000/published' $merged.identifiers.doi 'keeps published DOI'
Assert-Equal '2412.00174v2' $merged.identifiers.arxiv_id 'keeps arXiv version'
Assert-Equal 'crossref' $merged.metadata.metadata_source 'prefers Crossref metadata'
Assert-True (@($merged.pdf_candidates).Count -ge 2) 'combines PDF candidates'

$ambiguity = Select-CrossrefTitleCandidate -Query 'Interactive Character System' -Items @($search.message.items)
Assert-Equal 'ambiguous' $ambiguity.status 'rejects two close title candidates'

Write-Host "Result: $script:Passed passed, $script:Failed failed"
if ($script:Failed -gt 0) { exit 1 }
