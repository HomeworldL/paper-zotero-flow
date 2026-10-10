[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Query,
    [string]$OutputPath,
    [string]$PaperId = ([guid]::NewGuid().ToString())
)

$ErrorActionPreference = 'Stop'
$SkillRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $SkillRoot 'modules\Crossref.psm1') -Force -WarningAction SilentlyContinue
Import-Module (Join-Path $SkillRoot 'modules\Arxiv.psm1') -Force -WarningAction SilentlyContinue
Import-Module (Join-Path $SkillRoot 'modules\OpenAlex.psm1') -Force

function Write-Result {
    param([object]$Value)
    if ($OutputPath) {
        $directory = Split-Path -Parent $OutputPath
        if (-not $directory) { $directory = (Get-Location).Path }
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $temp = Join-Path $directory ('.result-' + [guid]::NewGuid().ToString('N') + '.tmp')
        [System.IO.File]::WriteAllText($temp, ($Value | ConvertTo-Json -Depth 30), (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temp -Destination $OutputPath -Force
    }
    $Value
}

$records = @()
$errors = @()
$status = 'failed'
try {
    $arxivId = Normalize-ArxivId $Query
    $doi = if ($Query -match '(?i)(?:doi\.org/|doi:\s*)?(10\.\d{4,9}/\S+)') { Normalize-Doi $Matches[1].TrimEnd('.', ',', ';', ')') } else { $null }
    if ($doi) {
        try { $records += ConvertFrom-CrossrefWork (Get-CrossrefWork -Doi $doi) } catch { $errors += [pscustomobject]@{ source = 'crossref'; message = $_.Exception.Message } }
        try { $records += Get-OpenAlexWork -Doi $doi } catch { $errors += [pscustomobject]@{ source = 'openalex'; message = $_.Exception.Message } }
    }
    elseif ($arxivId) {
        try { $records += Get-ArxivEntry $arxivId } catch { $errors += [pscustomobject]@{ source = 'arxiv'; message = $_.Exception.Message } }
        if ($records.Count -and $records[0].identifiers.doi) {
            try { $records += ConvertFrom-CrossrefWork (Get-CrossrefWork -Doi $records[0].identifiers.doi) } catch { $errors += [pscustomobject]@{ source = 'crossref'; message = $_.Exception.Message } }
        }
    }
    else {
        $selection = Get-CrossrefWork -Title $Query
        if ($selection.status -eq 'ambiguous') {
            $status = 'ambiguous'
            $result = [pscustomobject][ordered]@{ schema='paper-record.v1'; schema_version=1; paper_id=$PaperId; status=$status; inputs=[pscustomobject]@{query=$Query}; outputs=[pscustomobject]@{candidates=@($selection.candidates)}; provenance=@('crossref'); errors=@() }
            Write-Result $result
            exit 2
        }
        if ($selection.status -eq 'succeeded') { $records += ConvertFrom-CrossrefWork $selection.candidate }
    }
    if ($records.Count -eq 0) { throw 'Paper could not be resolved uniquely' }
    $merged = Merge-PaperRecord -Records $records
    $status = 'succeeded'
    $outputs = $merged
}
catch {
    $errors += [pscustomobject]@{ source = 'resolver'; message = $_.Exception.Message }
    $outputs = [pscustomobject]@{}
}
$result = [pscustomobject][ordered]@{ schema='paper-record.v1'; schema_version=1; paper_id=$PaperId; status=$status; inputs=[pscustomobject]@{query=$Query}; outputs=$outputs; provenance=@($records | ForEach-Object { $_.provenance }); errors=$errors }
Write-Result $result
if ($status -ne 'succeeded') { exit 1 }
