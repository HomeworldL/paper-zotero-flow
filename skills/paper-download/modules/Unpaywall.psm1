function ConvertFrom-UnpaywallWork {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Work)
    if ($Work -is [string]) { $Work = $Work | ConvertFrom-Json }
    $locations = @()
    $all = @()
    if ($Work.best_oa_location) { $all += $Work.best_oa_location }
    $all += @($Work.oa_locations)
    $seen = @{}
    foreach ($location in $all) {
        $url = [string]$location.url_for_pdf
        if (-not $url -or $seen.ContainsKey($url)) { continue }
        $uri = $null
        if (-not [uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https') { continue }
        $seen[$url] = $true
        $locations += [pscustomobject]@{
            url = $url; source_type = 'unpaywall'; version_type = [string]$location.version
            landing_url = [string]$location.url; host_type = [string]$location.host_type
        }
    }
    return $locations
}

function Get-UnpaywallLocations {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Doi, [Parameter(Mandatory = $true)][string]$Email)
    $uri = "https://api.unpaywall.org/v2/$([uri]::EscapeDataString($Doi))?email=$([uri]::EscapeDataString($Email))"
    return ConvertFrom-UnpaywallWork (Invoke-RestMethod -Uri $uri -Headers @{ 'User-Agent' = 'PaperZoteroFlow/1.0' } -TimeoutSec 45)
}

Export-ModuleMember -Function ConvertFrom-UnpaywallWork, Get-UnpaywallLocations
