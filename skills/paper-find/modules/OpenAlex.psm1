function ConvertFrom-OpenAlexJsonText {
    param([string]$Text)
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        return $Text | ConvertFrom-Json -AsHashtable
    }
    Add-Type -AssemblyName System.Web.Extensions
    $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $serializer.MaxJsonLength = [int]::MaxValue
    $serializer.RecursionLimit = 512
    return $serializer.DeserializeObject($Text)
}

function ConvertFrom-OpenAlexWork {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Work)
    if ($Work -is [string]) { $Work = ConvertFrom-OpenAlexJsonText $Work }
    $doi = if ($Work.doi) { ([string]$Work.doi -replace '^(?i)https?://doi\.org/', '').ToLowerInvariant() } else { $null }
    $location = if ($Work.best_oa_location) { $Work.best_oa_location } else { $Work.primary_location }
    $candidates = @()
    if ($location -and $location.pdf_url) {
        $candidates += [pscustomobject]@{
            url = [string]$location.pdf_url; source_type = 'openalex'; version_type = [string]$location.version
            landing_url = [string]$location.landing_page_url
        }
    }
    $venue = if ($Work.primary_location.source) { [string]$Work.primary_location.source.display_name } else { '' }
    [pscustomobject][ordered]@{
        identifiers = [pscustomobject]@{ doi = $doi; arxiv_id = $null; arxiv_work_id = $null; pmid = $null; openalex_id = [string]$Work.id }
        metadata = [pscustomobject][ordered]@{
            title = [string]$Work.title
            authors = @($Work.authorships | ForEach-Object { [string]$_.author.display_name })
            year = if ($Work.publication_year) { [int]$Work.publication_year } else { $null }
            venue = $venue
            url = [string]$Work.primary_location.landing_page_url
            abstract = ''
            item_type = 'document'
            metadata_source = 'openalex'
        }
        pdf_candidates = $candidates
        provenance = @([pscustomobject]@{ source = 'openalex'; record_id = [string]$Work.id })
    }
}

function Merge-PaperRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object[]]$Records)
    $records = @($Records | Where-Object { $_ })
    if ($records.Count -eq 0) { throw 'At least one record is required' }
    $authoritative = $records | Where-Object { $_.metadata.metadata_source -eq 'crossref' } | Select-Object -First 1
    if (-not $authoritative) { $authoritative = $records | Where-Object { $_.metadata.metadata_source -eq 'arxiv' } | Select-Object -First 1 }
    if (-not $authoritative) { $authoritative = $records[0] }

    $identifiers = [ordered]@{ doi = $null; arxiv_id = $null; arxiv_work_id = $null; pmid = $null; openalex_id = $null }
    foreach ($record in $records) {
        foreach ($name in @($identifiers.Keys)) {
            if (-not $identifiers[$name] -and $record.identifiers.PSObject.Properties[$name]) { $identifiers[$name] = $record.identifiers.$name }
        }
    }
    $metadata = [ordered]@{}
    foreach ($name in @('title','authors','year','venue','url','abstract','item_type','metadata_source')) {
        $value = $authoritative.metadata.$name
        if (($null -eq $value -or $value -eq '' -or (@($value).Count -eq 0)) -and $name -ne 'metadata_source') {
            foreach ($record in $records) {
                $candidate = $record.metadata.$name
                if ($null -ne $candidate -and $candidate -ne '' -and @($candidate).Count -gt 0) { $value = $candidate; break }
            }
        }
        $metadata[$name] = $value
    }
    $seen = @{}
    $pdfCandidates = @()
    foreach ($candidate in @($records | ForEach-Object { $_.pdf_candidates })) {
        if ($candidate.url -and -not $seen.ContainsKey([string]$candidate.url)) { $seen[[string]$candidate.url] = $true; $pdfCandidates += $candidate }
    }
    [pscustomobject][ordered]@{
        identifiers = [pscustomobject]$identifiers
        metadata = [pscustomobject]$metadata
        pdf_candidates = $pdfCandidates
        provenance = @($records | ForEach-Object { $_.provenance })
    }
}

function Get-OpenAlexWork {
    [CmdletBinding()]
    param([string]$Doi, [string]$Title)
    if ($Doi) { $uri = "https://api.openalex.org/works/https://doi.org/$([uri]::EscapeDataString($Doi))" }
    else { $uri = "https://api.openalex.org/works?search=$([uri]::EscapeDataString($Title))&per-page=5" }
    $response = Invoke-RestMethod -Uri $uri -Headers @{ 'User-Agent' = 'PaperZoteroFlow/1.0' } -TimeoutSec 45
    if ($response.results) { return @($response.results | ForEach-Object { ConvertFrom-OpenAlexWork $_ }) }
    return ConvertFrom-OpenAlexWork $response
}

Export-ModuleMember -Function ConvertFrom-OpenAlexWork, Merge-PaperRecord, Get-OpenAlexWork
