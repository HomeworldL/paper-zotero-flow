$ErrorActionPreference = 'Stop'
$script:Passed = 0
$script:Failed = 0
$SkillRoot = Split-Path -Parent $PSScriptRoot
$DownloadScript = Join-Path $SkillRoot 'scripts\Download-Paper.ps1'
$TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('paper-download-tests-' + [guid]::NewGuid().ToString('N'))

function Assert-Equal { param($Expected,$Actual,[string]$Name) if ($Expected -ne $Actual) { $script:Failed++; Write-Host "FAIL: $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red } else { $script:Passed++; Write-Host "PASS: $Name" } }
function Assert-True { param([bool]$Actual,[string]$Name) Assert-Equal $true $Actual $Name }
function Invoke-Download {
    param([string[]]$Arguments)
    $stdout = Join-Path $TempRoot ([guid]::NewGuid().ToString('N') + '.out')
    $stderr = Join-Path $TempRoot ([guid]::NewGuid().ToString('N') + '.err')
    $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $DownloadScript + '"')) + $Arguments
    $process = Start-Process powershell.exe -ArgumentList $args -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    return $process.ExitCode
}

try {
    New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null
    Import-Module (Join-Path $SkillRoot 'modules\Unpaywall.psm1') -Force
    Import-Module (Join-Path $SkillRoot 'modules\OpenAlexOa.psm1') -Force
    Import-Module (Join-Path $SkillRoot 'modules\DownloadPolicy.psm1') -Force
    $unpaywall = Get-Content (Join-Path $PSScriptRoot 'fixtures\unpaywall-work.json') -Raw | ConvertFrom-Json
    $openAlex = Get-Content (Join-Path $PSScriptRoot 'fixtures\openalex-oa.json') -Raw | ConvertFrom-Json
    Assert-Equal 'unpaywall' (ConvertFrom-UnpaywallWork $unpaywall)[0].source_type 'parses Unpaywall locations'
    Assert-Equal 'unpaywall' (ConvertFrom-UnpaywallWork (Get-Content (Join-Path $PSScriptRoot 'fixtures\unpaywall-work.json') -Raw))[0].source_type 'parses an Unpaywall JSON string response'
    Assert-Equal 'openalex' (ConvertFrom-OpenAlexOaWork $openAlex)[0].source_type 'parses OpenAlex OA locations'
    Assert-Equal 'openalex' (ConvertFrom-OpenAlexOaWork (Get-Content (Join-Path $PSScriptRoot 'fixtures\openalex-oa.json') -Raw))[0].source_type 'parses an OpenAlex OA JSON string response'
    $duplicateCaseJson='{"best_oa_location":{"pdf_url":"https://example.org/paper.pdf","landing_page_url":"https://example.org","version":"publishedVersion"},"locations":[],"abstract_inverted_index":{"The":[0],"the":[1]}}'
    Assert-Equal 'openalex' (ConvertFrom-OpenAlexOaWork $duplicateCaseJson)[0].source_type 'accepts OpenAlex OA JSON with case-duplicate keys'
    Assert-Equal $null (Get-ArxivPdfCandidate -ArxivId '10.1145/3586183.3606763') 'does not interpret a DOI tail as an arXiv ID'
    Assert-Equal 'https://arxiv.org/pdf/1706.03762v7.pdf' (Get-ArxivPdfCandidate -ArxivId '1706.03762v7').url 'builds an arXiv PDF candidate from an arXiv ID'
    Assert-True (Test-PdfContentType 'application/pdf') 'accepts PDF content type'
    Assert-True (Test-PdfContentType 'application/octet-stream') 'accepts generic binary content type'
    Assert-True (Test-PdfContentType '') 'allows a missing content type when signature validation follows'
    Assert-Equal $false (Test-PdfContentType 'text/html') 'rejects a declared HTML response'

    $utf8RecordPath = Join-Path $TempRoot 'utf8-paper-record.json'
    $utf8ResultPath = Join-Path $TempRoot 'utf8-download-result.json'
    $utf8Record = '{"schema":"paper-record.v1","schema_version":1,"paper_id":"11111111-1111-1111-1111-111111111111","status":"succeeded","inputs":{},"outputs":{"identifiers":{"doi":null,"arxiv_id":null},"metadata":{"url":"https://example.org/paper/' + [char]0x2026 + '"},"pdf_candidates":[]},"provenance":[],"errors":[]}'
    [System.IO.File]::WriteAllText($utf8RecordPath, $utf8Record, [System.Text.UTF8Encoding]::new($false))
    $exit = Invoke-Download @('-PaperRecordPath',('"'+$utf8RecordPath+'"'),'-OutputDirectory',('"'+$TempRoot+'"'),'-ResultPath',('"'+$utf8ResultPath+'"'))
    Assert-Equal 2 $exit 'accepts a UTF-8 paper record without a BOM'
    $utf8Result = [System.IO.File]::ReadAllText($utf8ResultPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    Assert-Equal ('https://example.org/paper/' + [char]0x2026) $utf8Result.outputs.landing_url 'preserves Unicode metadata from a paper record'

    $htmlPath = Join-Path $TempRoot 'html.pdf'
    Copy-Item (Join-Path $PSScriptRoot 'fixtures\html-as-pdf.bin') $htmlPath
    $htmlResult = Join-Path $TempRoot 'html-result.json'
    $exit = Invoke-Download @('-CandidateFile',('"'+$htmlPath+'"'),'-IdentityConfirmed','-OutputDirectory',('"'+$TempRoot+'"'),'-ResultPath',('"'+$htmlResult+'"'))
    Assert-Equal 1 $exit 'rejects HTML masquerading as PDF'
    Assert-Equal 'failed' (Get-Content $htmlResult -Raw | ConvertFrom-Json).status 'reports invalid candidate failure'

    $smallPath = Join-Path $TempRoot 'small.pdf'
    Copy-Item (Join-Path $PSScriptRoot 'fixtures\valid-minimal.pdf') $smallPath
    $smallResult = Join-Path $TempRoot 'small-result.json'
    $exit = Invoke-Download @('-CandidateFile',('"'+$smallPath+'"'),'-IdentityConfirmed','-OutputDirectory',('"'+$TempRoot+'"'),'-ResultPath',('"'+$smallResult+'"'))
    Assert-Equal 1 $exit 'rejects a PDF below 10 KiB'

    $validPath = Join-Path $TempRoot 'valid.pdf'
    $prefix = [System.IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'fixtures\valid-minimal.pdf'))
    $bytes = New-Object byte[] 12000
    [Array]::Copy($prefix, $bytes, $prefix.Length)
    [System.IO.File]::WriteAllBytes($validPath, $bytes)
    $unconfirmedResult = Join-Path $TempRoot 'unconfirmed-result.json'
    $exit = Invoke-Download @('-CandidateFile',('"'+$validPath+'"'),'-OutputDirectory',('"'+$TempRoot+'"'),'-ResultPath',('"'+$unconfirmedResult+'"'))
    Assert-Equal 2 $exit 'requires identity confirmation for browser files'
    Assert-Equal 'needs_identity_review' (Get-Content $unconfirmedResult -Raw | ConvertFrom-Json).status 'reports identity review state'

    $validResult = Join-Path $TempRoot 'valid-result.json'
    $exit = Invoke-Download @('-CandidateFile',('"'+$validPath+'"'),'-IdentityConfirmed','-OutputDirectory',('"'+$TempRoot+'"'),'-ResultPath',('"'+$validResult+'"'))
    $result = Get-Content $validResult -Raw | ConvertFrom-Json
    Assert-Equal 0 $exit 'accepts a confirmed valid PDF'
    Assert-True ([bool]$result.outputs.verified) 'marks a valid PDF verified'
    Assert-True ([bool]([string]$result.outputs.sha256 -match '^[0-9a-f]{64}$')) 'returns SHA-256'
}
finally {
    if (Test-Path $TempRoot) { Remove-Item -LiteralPath $TempRoot -Recurse -Force }
}
Write-Host "Result: $script:Passed passed, $script:Failed failed"
if ($script:Failed -gt 0) { exit 1 }
