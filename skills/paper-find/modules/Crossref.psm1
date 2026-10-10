function Normalize-Doi {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Value)
    $normalized = $Value.Trim()
    $normalized = $normalized -replace '^(?i)doi:\s*', ''
    $normalized = $normalized -replace '^(?i)https?://(?:dx\.)?doi\.org/', ''
    return $normalized.Trim().ToLowerInvariant()
}

function ConvertFrom-CrossrefWork {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Work)
    $title = if (@($Work.title).Count) { [string]@($Work.title)[0] } else { '' }
    $authors = @($Work.author | ForEach-Object { (([string]$_.given + ' ' + [string]$_.family).Trim()) })
    $year = $null
    if ($Work.published.'date-parts') { $year = [int]@(@($Work.published.'date-parts')[0])[0] }
    $venue = if (@($Work.'container-title').Count) { [string]@($Work.'container-title')[0] } else { '' }
    $itemType = if ([string]$Work.type -eq 'journal-article') { 'journalArticle' } elseif ([string]$Work.type -eq 'proceedings-article') { 'conferencePaper' } else { 'document' }
    $abstract = ([string]$Work.abstract) -replace '<[^>]+>', ' '
    $abstract = ($abstract -replace '\s+', ' ').Trim()
    [pscustomobject][ordered]@{
        identifiers = [pscustomobject]@{ doi = Normalize-Doi ([string]$Work.DOI); arxiv_id = $null; arxiv_work_id = $null; pmid = $null }
        metadata = [pscustomobject][ordered]@{
            title = $title; authors = $authors; year = $year; venue = $venue
            url = [string]$Work.URL; abstract = $abstract; item_type = $itemType; metadata_source = 'crossref'
        }
        pdf_candidates = @()
        provenance = @([pscustomobject]@{ source = 'crossref'; record_id = [string]$Work.DOI })
    }
}

function Get-NormalizedTitleTokens {
    param([string]$Title)
    return @(($Title.ToLowerInvariant() -replace '[^\p{L}\p{Nd}]+', ' ').Trim() -split '\s+' | Where-Object { $_ })
}

function Get-TitleSimilarity {
    param([string]$Left, [string]$Right)
    $a = @(Get-NormalizedTitleTokens $Left | Select-Object -Unique)
    $b = @(Get-NormalizedTitleTokens $Right | Select-Object -Unique)
    if ($a.Count -eq 0 -or $b.Count -eq 0) { return 0.0 }
    $intersection = @($a | Where-Object { $b -contains $_ }).Count
    return (2.0 * $intersection) / ($a.Count + $b.Count)
}

function Select-CrossrefTitleCandidate {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Query, [Parameter(Mandatory = $true)][object[]]$Items)
    $ranked = @($Items | ForEach-Object {
        $candidateTitle = if (@($_.title).Count) { [string]@($_.title)[0] } else { '' }
        [pscustomobject]@{ item = $_; similarity = Get-TitleSimilarity $Query $candidateTitle }
    } | Sort-Object similarity -Descending)
    if ($ranked.Count -eq 0) { return [pscustomobject]@{ status = 'failed'; candidate = $null; candidates = @() } }
    $best = [double]$ranked[0].similarity
    $second = if ($ranked.Count -gt 1) { [double]$ranked[1].similarity } else { 0.0 }
    if ($best -lt 0.90 -or ($ranked.Count -gt 1 -and ($best - $second) -lt 0.08)) {
        return [pscustomobject]@{ status = 'ambiguous'; candidate = $null; candidates = $ranked }
    }
    return [pscustomobject]@{ status = 'succeeded'; candidate = $ranked[0].item; candidates = $ranked }
}

function Get-CrossrefWork {
    [CmdletBinding()]
    param([string]$Doi, [string]$Title)
    $headers = @{ 'User-Agent' = 'PaperZoteroFlow/1.0 (mailto:local-user@example.invalid)' }
    if ($Doi) {
        $encoded = [uri]::EscapeDataString((Normalize-Doi $Doi))
        return (Invoke-RestMethod -Uri "https://api.crossref.org/works/$encoded" -Headers $headers -TimeoutSec 45).message
    }
    $query = [uri]::EscapeDataString($Title)
    $items = @((Invoke-RestMethod -Uri "https://api.crossref.org/works?query.title=$query&rows=5" -Headers $headers -TimeoutSec 45).message.items)
    return Select-CrossrefTitleCandidate -Query $Title -Items $items
}

Export-ModuleMember -Function Normalize-Doi, ConvertFrom-CrossrefWork, Select-CrossrefTitleCandidate, Get-CrossrefWork
