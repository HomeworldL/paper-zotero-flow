[CmdletBinding()]
param(
    [string]$PaperRecordPath,
    [string]$Identifier,
    [string]$DirectUrl,
    [string]$CandidateFile,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [string]$ResultPath,
    [string]$UnpaywallEmail,
    [int64]$MinimumBytes = 10240,
    [switch]$IdentityConfirmed,
    [string]$PaperId = ([guid]::NewGuid().ToString())
)

$ErrorActionPreference = 'Stop'
$SkillRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $SkillRoot 'modules\Unpaywall.psm1') -Force
Import-Module (Join-Path $SkillRoot 'modules\OpenAlexOa.psm1') -Force
Import-Module (Join-Path $SkillRoot 'modules\DownloadPolicy.psm1') -Force

function Write-StageResult {
    param([object]$Value)
    if ($ResultPath) {
        $directory = Split-Path -Parent $ResultPath
        if (-not $directory) { $directory = (Get-Location).Path }
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $temp = Join-Path $directory ('.download-result-' + [guid]::NewGuid().ToString('N') + '.tmp')
        [System.IO.File]::WriteAllText($temp, ($Value | ConvertTo-Json -Depth 30), (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temp -Destination $ResultPath -Force
    }
    $Value
}

function Test-PdfFile {
    param([string]$Path, [int64]$Minimum)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [pscustomobject]@{ verified=$false; reason='missing_file' } }
    $info = Get-Item -LiteralPath $Path
    if ($info.Length -lt $Minimum) { return [pscustomobject]@{ verified=$false; reason='below_minimum_size'; size_bytes=$info.Length } }
    $stream = [System.IO.File]::OpenRead($Path)
    try { $header = New-Object byte[] 5; $read = $stream.Read($header,0,5) } finally { $stream.Dispose() }
    if ($read -ne 5 -or [System.Text.Encoding]::ASCII.GetString($header) -ne '%PDF-') { return [pscustomobject]@{ verified=$false; reason='invalid_signature'; size_bytes=$info.Length } }
    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    return [pscustomobject]@{ verified=$true; reason=$null; size_bytes=$info.Length; sha256=$hash }
}

function Receive-PdfCandidate {
    param([string]$Url, [string]$Destination)
    $partial = $Destination + '.partial'
    if (Test-Path $partial) { Remove-Item -LiteralPath $partial -Force }
    try {
        $request = [System.Net.HttpWebRequest]::Create($Url)
        $request.UserAgent = 'PaperZoteroFlow/1.0'
        $request.Timeout = 120000
        $request.ReadWriteTimeout = 120000
        $request.AllowAutoRedirect = $true
        $request.MaximumAutomaticRedirections = 5
        $response = $request.GetResponse()
        try {
            $input = $response.GetResponseStream()
            $output = [System.IO.File]::Create($partial)
            try { $input.CopyTo($output) } finally { $output.Dispose(); $input.Dispose() }
            $contentType = [string]$response.ContentType
        }
        finally { $response.Dispose() }
        Move-Item -LiteralPath $partial -Destination $Destination -Force
        return $contentType
    }
    catch {
        if (Test-Path $partial) { Remove-Item -LiteralPath $partial -Force }
        throw
    }
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$errors = @()
$attempted = @()
$record = $null
if ($PaperRecordPath) {
    $record = [System.IO.File]::ReadAllText($PaperRecordPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($record.schema -ne 'paper-record.v1' -or $record.status -ne 'succeeded') { throw 'PaperRecordPath must contain a successful paper-record.v1 result' }
    $PaperId = [string]$record.paper_id
}

if ($CandidateFile) {
    $validation = Test-PdfFile -Path $CandidateFile -Minimum $MinimumBytes
    $status = if (-not $validation.verified) { 'failed' } elseif (-not $IdentityConfirmed) { 'needs_identity_review' } else { 'succeeded' }
    $outputs = [pscustomobject]@{ path=(Resolve-Path -LiteralPath $CandidateFile).Path; source_url=$null; source_type='browser'; version_type=$null; sha256=$validation.sha256; size_bytes=$validation.size_bytes; verified=([bool]$validation.verified -and [bool]$IdentityConfirmed) }
    if (-not $validation.verified) { $errors += [pscustomobject]@{ code=$validation.reason; message='Candidate is not a valid PDF' } }
    $result = [pscustomobject][ordered]@{ schema='download-result.v1'; schema_version=1; paper_id=$PaperId; status=$status; inputs=[pscustomobject]@{candidate_file=$CandidateFile}; outputs=$outputs; provenance=@([pscustomobject]@{source='browser'}); errors=$errors }
    Write-StageResult $result
    if ($status -eq 'succeeded') { exit 0 } elseif ($status -eq 'needs_identity_review') { exit 2 } else { exit 1 }
}

$candidates = @()
if ($record -and $record.outputs.pdf_candidates) { $candidates += @($record.outputs.pdf_candidates) }
$rawIdentifier = if ($Identifier) { $Identifier } elseif ($record) { [string]$record.outputs.identifiers.doi } else { '' }
$arxivValue = if ($record -and $record.outputs.identifiers.arxiv_id) { [string]$record.outputs.identifiers.arxiv_id } else { $Identifier }
$arxivCandidate = Get-ArxivPdfCandidate -ArxivId $arxivValue
if ($arxivCandidate) { $candidates = @($arxivCandidate) + $candidates }
$doi = if ($record) { [string]$record.outputs.identifiers.doi } elseif ($rawIdentifier -match '(10\.\d{4,9}/\S+)') { $Matches[1].TrimEnd('.',',',';',')') } else { $null }
if ($doi -and $UnpaywallEmail) { try { $candidates += @(Get-UnpaywallLocations -Doi $doi -Email $UnpaywallEmail) } catch { $errors += [pscustomobject]@{source='unpaywall';message=$_.Exception.Message} } }
if ($doi) { try { $candidates += @(Get-OpenAlexOaLocations -Doi $doi) } catch { $errors += [pscustomobject]@{source='openalex';message=$_.Exception.Message} } }
if ($DirectUrl) { $candidates += [pscustomobject]@{url=$DirectUrl;source_type='explicit';version_type=$null;landing_url=$DirectUrl} }

$priority = @{ arxiv=1; unpaywall=2; openalex=3; explicit=4 }
$seen = @{}
$candidates = @($candidates | Where-Object { $_.url -and -not $seen.ContainsKey([string]$_.url) -and ($seen[[string]$_.url]=$true) } | Sort-Object @{Expression={if($priority.ContainsKey([string]$_.source_type)){$priority[[string]$_.source_type]}else{99}}})
foreach ($candidate in $candidates) {
    $attempted += $candidate
    try {
        $safeName = if ($doi) { ($doi -replace '[<>:"/\\|?*]', '_') + '.pdf' } elseif ($arxivCandidate) { [string]$arxivCandidate.arxiv_id + '.pdf' } else { [guid]::NewGuid().ToString('N') + '.pdf' }
        $destination = Join-Path $OutputDirectory $safeName
        $contentType = Receive-PdfCandidate -Url ([string]$candidate.url) -Destination $destination
        if (-not (Test-PdfContentType $contentType)) { Remove-Item -LiteralPath $destination -Force; throw "declared_non_pdf_content_type:$contentType" }
        $validation = Test-PdfFile -Path $destination -Minimum $MinimumBytes
        if (-not $validation.verified) { Remove-Item -LiteralPath $destination -Force; throw $validation.reason }
        $trusted = @('arxiv','unpaywall','openalex') -contains [string]$candidate.source_type
        if (-not $trusted -and -not $IdentityConfirmed) {
            $result = [pscustomobject][ordered]@{schema='download-result.v1';schema_version=1;paper_id=$PaperId;status='needs_identity_review';inputs=[pscustomobject]@{identifier=$Identifier};outputs=[pscustomobject]@{path=$destination;source_url=$candidate.url;source_type=$candidate.source_type;version_type=$candidate.version_type;sha256=$validation.sha256;size_bytes=$validation.size_bytes;verified=$false};provenance=$attempted;errors=$errors}
            Write-StageResult $result; exit 2
        }
        $result = [pscustomobject][ordered]@{schema='download-result.v1';schema_version=1;paper_id=$PaperId;status='succeeded';inputs=[pscustomobject]@{identifier=$Identifier};outputs=[pscustomobject]@{path=$destination;source_url=$candidate.url;source_type=$candidate.source_type;version_type=$candidate.version_type;sha256=$validation.sha256;size_bytes=$validation.size_bytes;verified=$true;content_type=$contentType};provenance=$attempted;errors=$errors}
        Write-StageResult $result; exit 0
    }
    catch { $errors += [pscustomobject]@{source=[string]$candidate.source_type;url=[string]$candidate.url;message=$_.Exception.Message} }
}
$landingUrl = if ($record) { [string]$record.outputs.metadata.url } else { $DirectUrl }
$status = if ($landingUrl) { 'needs_browser' } else { 'failed' }
$result = [pscustomobject][ordered]@{schema='download-result.v1';schema_version=1;paper_id=$PaperId;status=$status;inputs=[pscustomobject]@{identifier=$Identifier};outputs=[pscustomobject]@{path=$null;landing_url=$landingUrl;verified=$false};provenance=$attempted;errors=$errors}
Write-StageResult $result
if ($status -eq 'needs_browser') { exit 2 } else { exit 1 }
