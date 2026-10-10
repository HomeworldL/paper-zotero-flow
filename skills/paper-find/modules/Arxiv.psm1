function Normalize-ArxivId {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Value)
    $match = [regex]::Match($Value, '(?i)(?:arxiv:\s*|arxiv\.org/(?:abs|pdf)/)?([a-z-]+(?:\.[A-Z]{2})?/\d{7}|\d{4}\.\d{4,5})(v\d+)?(?:\.pdf)?')
    if (-not $match.Success) { return $null }
    return ($match.Groups[1].Value + $match.Groups[2].Value)
}

function ConvertFrom-ArxivEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Entry)
    $id = Normalize-ArxivId ([string]$Entry.id)
    $workId = $id -replace 'v\d+$', ''
    $authors = @($Entry.author | ForEach-Object { [string]$_.name })
    $doiNode = $Entry.SelectSingleNode("*[local-name()='doi']")
    $doi = if ($doiNode) { ([string]$doiNode.InnerText).ToLowerInvariant() } else { $null }
    $pdfUrl = "https://arxiv.org/pdf/$id.pdf"
    [pscustomobject][ordered]@{
        identifiers = [pscustomobject]@{ doi = $doi; arxiv_id = $id; arxiv_work_id = $workId; pmid = $null }
        metadata = [pscustomobject][ordered]@{
            title = (([string]$Entry.title) -replace '\s+', ' ').Trim()
            authors = $authors
            year = ([datetime]$Entry.published).Year
            venue = 'arXiv'
            url = "https://arxiv.org/abs/$id"
            abstract = (([string]$Entry.summary) -replace '\s+', ' ').Trim()
            item_type = 'preprint'
            metadata_source = 'arxiv'
        }
        pdf_candidates = @([pscustomobject]@{ url = $pdfUrl; source_type = 'arxiv'; version_type = 'submittedVersion'; landing_url = "https://arxiv.org/abs/$id" })
        provenance = @([pscustomobject]@{ source = 'arxiv'; record_id = $id })
    }
}

function ConvertTo-ArxivFeed {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Response)
    if ($Response -is [System.Xml.XmlDocument]) { return $Response }
    if ($Response -is [System.Xml.XmlElement]) {
        $document = New-Object System.Xml.XmlDocument
        $document.LoadXml($Response.OuterXml)
        return $document
    }
    $document = New-Object System.Xml.XmlDocument
    $document.LoadXml([string]$Response)
    return $document
}

function ConvertFrom-ArxivResponse {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Response)
    $xml = ConvertTo-ArxivFeed $Response
    $entry = if ($xml.DocumentElement.LocalName -eq 'entry') { $xml.DocumentElement } else { $xml.feed.entry }
    if (-not $entry) { return $null }
    return ConvertFrom-ArxivEntry $entry
}

function Get-ArxivEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ArxivId)
    $id = Normalize-ArxivId $ArxivId
    if (-not $id) { throw 'Invalid arXiv identifier' }
    $response = Invoke-RestMethod -Uri "https://export.arxiv.org/api/query?id_list=$([uri]::EscapeDataString($id))" -TimeoutSec 45
    return ConvertFrom-ArxivResponse $response
}

Export-ModuleMember -Function Normalize-ArxivId, ConvertFrom-ArxivEntry, ConvertTo-ArxivFeed, ConvertFrom-ArxivResponse, Get-ArxivEntry
