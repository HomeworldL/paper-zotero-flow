function ConvertFrom-OpenAlexOaJsonText {
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

function ConvertFrom-OpenAlexOaWork {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Work)
    if ($Work -is [string]) { $Work = ConvertFrom-OpenAlexOaJsonText $Work }
    $all = @()
    if ($Work.best_oa_location) { $all += $Work.best_oa_location }
    $all += @($Work.locations)
    $locations = @()
    $seen = @{}
    foreach ($location in $all) {
        $url = [string]$location.pdf_url
        if (-not $url -or $seen.ContainsKey($url)) { continue }
        $uri = $null
        if (-not [uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https') { continue }
        $seen[$url] = $true
        $locations += [pscustomobject]@{
            url = $url; source_type = 'openalex'; version_type = [string]$location.version
            landing_url = [string]$location.landing_page_url
        }
    }
    return $locations
}

function Get-OpenAlexOaLocations {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Doi)
    $uri = "https://api.openalex.org/works/https://doi.org/$([uri]::EscapeDataString($Doi))"
    return ConvertFrom-OpenAlexOaWork (Invoke-RestMethod -Uri $uri -Headers @{ 'User-Agent' = 'PaperZoteroFlow/1.0' } -TimeoutSec 45)
}

Export-ModuleMember -Function ConvertFrom-OpenAlexOaWork, Get-OpenAlexOaLocations
