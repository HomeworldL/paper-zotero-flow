function Get-ArxivPdfCandidate {
    [CmdletBinding()]
    param([string]$ArxivId)
    if (-not $ArxivId) { return $null }
    $value = $ArxivId.Trim()
    $match = [regex]::Match($value, '^(?i)([a-z-]+(?:\.[A-Z]{2})?/\d{7}|\d{4}\.\d{4,5})(v\d+)?$')
    if (-not $match.Success) { return $null }
    $id = $match.Groups[1].Value + $match.Groups[2].Value
    return [pscustomobject]@{ url="https://arxiv.org/pdf/$id.pdf"; source_type='arxiv'; version_type='submittedVersion'; landing_url="https://arxiv.org/abs/$id"; arxiv_id=$id }
}

function Test-PdfContentType {
    [CmdletBinding()]
    param([string]$ContentType)
    if (-not $ContentType) { return $true }
    $mediaType = ($ContentType -split ';', 2)[0].Trim().ToLowerInvariant()
    return $mediaType -in @('application/pdf', 'application/octet-stream')
}

Export-ModuleMember -Function Get-ArxivPdfCandidate, Test-PdfContentType
