Add-Type -AssemblyName System.Security

function Normalize-ZoteroTitle {
    param([string]$Title)
    return (($Title.ToLowerInvariant() -replace '[^\p{L}\p{Nd}]+', ' ') -replace '\s+', ' ').Trim()
}

function Find-ZoteroPaperMatch {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Items, [Parameter(Mandatory = $true)][object]$Record)
    $flatItems = @($Items | ForEach-Object { if ($_ -is [System.Array]) { $_ | ForEach-Object { $_ } } else { $_ } })
    $doi = [string]$Record.identifiers.doi
    $arxiv = [string]$Record.identifiers.arxiv_id
    $title = Normalize-ZoteroTitle ([string]$Record.metadata.title)
    if ($doi) {
        $match = $flatItems | Where-Object { ([string]$_.data.DOI).ToLowerInvariant() -eq $doi.ToLowerInvariant() } | Select-Object -First 1
        if ($match) { return [pscustomobject]@{ match_type='existing-doi'; item=$match } }
    }
    if ($arxiv) {
        $match = $flatItems | Where-Object { ([string]$_.data.extra) -match ('(?i)arxiv:\s*' + [regex]::Escape($arxiv)) } | Select-Object -First 1
        if ($match) { return [pscustomobject]@{ match_type='existing-arxiv'; item=$match } }
    }
    if ($title) {
        $match = $flatItems | Where-Object { (Normalize-ZoteroTitle ([string]$_.data.title)) -eq $title } | Select-Object -First 1
        if ($match) { return [pscustomobject]@{ match_type='existing-title'; item=$match } }
    }
    return $null
}

function Test-ZoteroAuthorizationForUpload {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Authorization)
    return [bool]$Authorization.key -and [bool]$Authorization.remember
}

function Test-ZoteroUploadUri {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$UploadUri, [Parameter(Mandatory = $true)][string]$BaseUri)
    $upload = [uri]$UploadUri
    $base = [uri]$BaseUri
    return $upload.Scheme -eq 'http' -and [System.Net.IPAddress]::IsLoopback(([System.Net.Dns]::GetHostAddresses($upload.Host) | Select-Object -First 1)) -and $upload.Port -eq $base.Port
}

function Get-ZoteroRollbackPlan {
    [CmdletBinding()]
    param([string]$AttachmentKey, [int]$AttachmentVersion, [string]$ParentKey, [int]$ParentVersion, [switch]$PreExistingParent)
    $plan = @()
    if ($AttachmentKey) { $plan += [pscustomobject]@{ type='attachment'; key=$AttachmentKey; version=$AttachmentVersion } }
    if ($ParentKey -and -not $PreExistingParent) { $plan += [pscustomobject]@{ type='parent'; key=$ParentKey; version=$ParentVersion } }
    return $plan
}

function Protect-ZoteroApiKey {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Key, [Parameter(Mandatory = $true)][string]$Path)
    $directory = Split-Path -Parent $Path
    if ($directory) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $plain = [System.Text.Encoding]::UTF8.GetBytes($Key)
    $protected = [System.Security.Cryptography.ProtectedData]::Protect($plain, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    [System.IO.File]::WriteAllBytes($Path, $protected)
}

function Unprotect-ZoteroApiKey {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $protected = [System.IO.File]::ReadAllBytes($Path)
    $plain = [System.Security.Cryptography.ProtectedData]::Unprotect($protected, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [System.Text.Encoding]::UTF8.GetString($plain)
}

function Get-ZoteroSecretPath {
    param([string]$ServerId)
    $root = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $HOME 'AppData\Local' }
    $safe = $ServerId -replace '[^A-Za-z0-9._-]', '_'
    return Join-Path $root "PaperZoteroFlow\secrets\zotero-$safe.bin"
}

function Invoke-ZoteroHttp {
    param(
        [object]$Context, [string]$Method, [string]$Path, [byte[]]$Body,
        [string]$ContentType = 'application/json', [switch]$Auth, [hashtable]$ExtraHeaders
    )
    $base = ([string]$Context.base_uri).TrimEnd('/')
    $url = if ($Path -match '^https?://') { $Path } else { $base + '/' + $Path.TrimStart('/') }
    $request = [System.Net.HttpWebRequest]::Create($url)
    $request.Method = $Method
    $request.Timeout = 180000
    $request.ReadWriteTimeout = 180000
    $request.Accept = 'application/json'
    $request.Headers['Zotero-API-Version'] = '3'
    if ($Context.server_id) { $request.Headers['Zotero-Server-ID'] = [string]$Context.server_id }
    if ($Auth) {
        if (-not $Context.api_key) { throw 'Zotero write authorization is required' }
        $request.Headers['Zotero-API-Key'] = [string]$Context.api_key
    }
    if ($ExtraHeaders) { foreach ($key in $ExtraHeaders.Keys) { $request.Headers[$key] = [string]$ExtraHeaders[$key] } }
    if ($Body) {
        $request.ContentType = $ContentType
        $request.ContentLength = $Body.Length
        $stream = $request.GetRequestStream()
        try { $stream.Write($Body,0,$Body.Length) } finally { $stream.Dispose() }
    }
    try { $response = $request.GetResponse() }
    catch [System.Net.WebException] {
        $response = $_.Exception.Response
        $detail = ''
        if ($response) { $reader = New-Object IO.StreamReader($response.GetResponseStream()); try { $detail=$reader.ReadToEnd() } finally { $reader.Dispose(); $response.Dispose() } }
        throw "Zotero $Method $Path failed: $detail"
    }
    try {
        $reader = New-Object IO.StreamReader($response.GetResponseStream())
        try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
        $headers = @{}
        foreach ($name in $response.Headers.AllKeys) { $headers[$name] = $response.Headers[$name] }
        return [pscustomobject]@{ text=$text; headers=$headers; status_code=[int]$response.StatusCode }
    }
    finally { $response.Dispose() }
}

function Connect-ZoteroLocalApi {
    [CmdletBinding()]
    param([string]$BaseUri = 'http://127.0.0.1:23119/api/')
    $context = [pscustomobject]@{ base_uri=$BaseUri.TrimEnd('/') + '/'; server_id=$null; api_key=$null; remembered=$false }
    $response = Invoke-ZoteroHttp -Context $context -Method GET -Path ''
    $serverId = $response.headers['Zotero-Server-ID']
    if (-not $serverId) { $serverId = $response.headers['zotero-server-id'] }
    if (-not $serverId) { throw 'Zotero 10 Local API did not return Zotero-Server-ID' }
    $context.server_id = $serverId
    $secret = Get-ZoteroSecretPath $serverId
    try { $context.api_key = Unprotect-ZoteroApiKey $secret } catch { $context.api_key = $null }
    if ($context.api_key) { $context.remembered = $true }
    return $context
}

function Request-ZoteroLocalAuthorization {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Context, [switch]$RequireRemembered)
    $body = [System.Text.Encoding]::UTF8.GetBytes('{"appName":"Paper Zotero Flow"}')
    $response = Invoke-ZoteroHttp -Context $Context -Method POST -Path 'local/authorize' -Body $body -ContentType 'application/json'
    $authorization = $response.text | ConvertFrom-Json
    if ($RequireRemembered -and -not (Test-ZoteroAuthorizationForUpload $authorization)) { throw 'File upload requires Zotero Always Allow authorization' }
    $Context.api_key = [string]$authorization.key
    $Context.remembered = [bool]$authorization.remember
    if ($Context.remembered) { Protect-ZoteroApiKey -Key $Context.api_key -Path (Get-ZoteroSecretPath $Context.server_id) }
    return $authorization
}

function ConvertFrom-ZoteroResponseJson {
    param([object]$Response)
    if (-not $Response.text) { return $null }
    return $Response.text | ConvertFrom-Json
}

function Find-ZoteroPaper {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Context, [Parameter(Mandatory = $true)][object]$Record)
    $terms = @($Record.identifiers.doi, $Record.identifiers.arxiv_id, $Record.metadata.title) | Where-Object { $_ }
    $items = @()
    $seen = @{}
    foreach ($term in $terms) {
        $path = 'users/0/items/top?q=' + [uri]::EscapeDataString([string]$term) + '&itemType=-attachment&limit=25'
        foreach ($item in @(ConvertFrom-ZoteroResponseJson (Invoke-ZoteroHttp -Context $Context -Method GET -Path $path))) {
            $key = [string]$item.data.key
            if (-not $seen.ContainsKey($key)) { $seen[$key]=$true; $items += $item }
        }
    }
    return Find-ZoteroPaperMatch -Items $items -Record $Record
}

function ConvertTo-ZoteroCreator {
    param([string]$Name)
    $parts = @($Name.Trim() -split '\s+')
    if ($parts.Count -le 1) { return [pscustomobject]@{ creatorType='author'; name=$Name } }
    return [pscustomobject]@{ creatorType='author'; firstName=($parts[0..($parts.Count-2)] -join ' '); lastName=$parts[-1] }
}

function ConvertTo-ZoteroBatchJson {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object[]]$Items)
    return ConvertTo-Json -InputObject @($Items) -Depth 15
}

function New-ZoteroWriteToken {
    return [guid]::NewGuid().ToString('N')
}

function Get-CreatedZoteroObject {
    [CmdletBinding()]
    param([object]$Response)
    $successful = $Response.successful.'0'
    if ($successful.key) { return [pscustomobject]@{key=[string]$successful.key;version=[int]$successful.version} }
    if ($successful.data.key) { return [pscustomobject]@{key=[string]$successful.data.key;version=[int]$successful.data.version} }
    if ($Response.success.'0') { return [pscustomobject]@{key=[string]$Response.success.'0';version=0} }
    $failed = $Response.failed.'0'
    if ($failed) { throw "Zotero object create failed ($($failed.code)): $($failed.message)" }
    throw 'Zotero create response did not contain an item key'
}

function ConvertFrom-ZoteroAttachmentSpecs {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Json)
    $parsed = $Json | ConvertFrom-Json
    $items = @($parsed | ForEach-Object { if ($_ -is [System.Array]) { $_ | ForEach-Object { $_ } } else { $_ } })
    foreach ($item in $items) {
        if (-not $item.path -or -not $item.role) { throw 'Each attachment requires path and role' }
        [pscustomobject]@{ path=[string]$item.path; role=[string]$item.role }
    }
}

function New-ZoteroPaperData {
    [CmdletBinding()]
    param([object]$Record,[string]$CollectionKey)
    $metadata = $Record.metadata
    [object[]]$creators = @($metadata.authors | ForEach-Object { ConvertTo-ZoteroCreator ([string]$_) })
    [string[]]$collections = @()
    if ($CollectionKey) { $collections = @($CollectionKey) }
    $item = [ordered]@{
        itemType = if ($metadata.item_type -in @('journalArticle','conferencePaper','preprint')) { $metadata.item_type } else { 'journalArticle' }
        title = [string]$metadata.title
        creators = $creators
        abstractNote = [string]$metadata.abstract
        date = [string]$metadata.year
        DOI = [string]$Record.identifiers.doi
        url = [string]$metadata.url
        language = 'en'
        libraryCatalog = 'Paper Zotero Flow'
        extra = if ($Record.identifiers.arxiv_id) { 'arXiv: ' + [string]$Record.identifiers.arxiv_id } else { '' }
        tags = @()
        collections = $collections
        relations = @{}
    }
    if ($item.itemType -eq 'conferencePaper') { $item['conferenceName']=[string]$metadata.venue; $item['proceedingsTitle']=[string]$metadata.venue }
    elseif ($item.itemType -eq 'journalArticle') { $item['publicationTitle']=[string]$metadata.venue }
    elseif ($item.itemType -eq 'preprint') { $item['repository']=[string]$metadata.venue; $item['archiveID']=[string]$Record.identifiers.arxiv_id }
    return [pscustomobject]$item
}

function New-ZoteroPaper {
    [CmdletBinding()]
    param([object]$Context,[object]$Record,[string]$CollectionKey)
    $item = New-ZoteroPaperData -Record $Record -CollectionKey $CollectionKey
    $body = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-ZoteroBatchJson -Items @($item)))
    $response = ConvertFrom-ZoteroResponseJson (Invoke-ZoteroHttp -Context $Context -Method POST -Path 'users/0/items' -Body $body -Auth -ExtraHeaders @{'Zotero-Write-Token'=(New-ZoteroWriteToken)})
    return Get-CreatedZoteroObject $response
}

function Get-ZoteroAttachmentFingerprint {
    [CmdletBinding()]
    param([object]$Context,[object]$Attachment)
    $key = [string]$Attachment.data.key
    try {
        $url = (Invoke-ZoteroHttp -Context $Context -Method GET -Path "users/0/items/$key/file/view/url").text.Trim()
        if (-not $url.StartsWith('file://')) { return $null }
        $path = ([uri]$url).LocalPath
        if (-not (Test-Path -LiteralPath $path)) { return $null }
        return [pscustomobject]@{ key=$key; role=[string]$Attachment.data.title; sha256=(Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant() }
    }
    catch { return $null }
}

function Add-ZoteroStoredAttachment {
    [CmdletBinding()]
    param([object]$Context,[string]$ParentKey,[string]$FilePath,[string]$Role)
    if (-not $Context.remembered) { throw 'File upload requires Zotero Always Allow authorization' }
    $info = Get-Item -LiteralPath $FilePath
    $sha256 = (Get-FileHash $FilePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $children = @(ConvertFrom-ZoteroResponseJson (Invoke-ZoteroHttp -Context $Context -Method GET -Path "users/0/items/$ParentKey/children"))
    foreach ($child in $children) {
        if ([string]$child.data.title -ne $Role) { continue }
        $fingerprint = Get-ZoteroAttachmentFingerprint -Context $Context -Attachment $child
        if ($fingerprint -and $fingerprint.sha256 -eq $sha256) { return [pscustomobject]@{ key=$fingerprint.key; action='reused'; role=$Role; sha256=$sha256 } }
    }
    $attachment = [ordered]@{itemType='attachment';linkMode='imported_file';title=$Role;parentItem=$ParentKey;contentType='application/pdf';charset='';filename=$info.Name;note='';tags=@();relations=@{}}
    $createBody = [Text.Encoding]::UTF8.GetBytes((ConvertTo-ZoteroBatchJson -Items @($attachment)))
    $created = ConvertFrom-ZoteroResponseJson (Invoke-ZoteroHttp -Context $Context -Method POST -Path 'users/0/items' -Body $createBody -Auth -ExtraHeaders @{'Zotero-Write-Token'=(New-ZoteroWriteToken)})
    $createdAttachment = Get-CreatedZoteroObject $created
    $attachmentKey = $createdAttachment.key
    try {
        $bytes = [IO.File]::ReadAllBytes($FilePath)
        $md5Provider = [Security.Cryptography.MD5]::Create()
        try { $md5 = [BitConverter]::ToString($md5Provider.ComputeHash($bytes)).Replace('-','').ToLowerInvariant() } finally { $md5Provider.Dispose() }
        $mtime = (New-Object DateTimeOffset $info.LastWriteTimeUtc).ToUnixTimeMilliseconds()
        $form = "md5=$md5&filename=$([uri]::EscapeDataString($info.Name))&filesize=$($info.Length)&mtime=$mtime&contentType=application%2Fpdf"
        $authorization = ConvertFrom-ZoteroResponseJson (Invoke-ZoteroHttp -Context $Context -Method POST -Path "users/0/items/$attachmentKey/file" -Body ([Text.Encoding]::UTF8.GetBytes($form)) -ContentType 'application/x-www-form-urlencoded' -Auth -ExtraHeaders @{'If-None-Match'='*'})
        if (-not $authorization.exists) {
            if (-not (Test-ZoteroUploadUri -UploadUri ([string]$authorization.url) -BaseUri ([string]$Context.base_uri))) { throw 'Zotero upload URL is not on the configured loopback origin' }
            $uploadContext = [pscustomobject]@{base_uri=$Context.base_uri;server_id=$null;api_key=$null}
            Invoke-ZoteroHttp -Context $uploadContext -Method POST -Path ([string]$authorization.url) -Body $bytes -ContentType ([string]$authorization.contentType) | Out-Null
            $confirm = 'upload=' + [uri]::EscapeDataString([string]$authorization.uploadKey)
            Invoke-ZoteroHttp -Context $Context -Method POST -Path "users/0/items/$attachmentKey/file" -Body ([Text.Encoding]::UTF8.GetBytes($confirm)) -ContentType 'application/x-www-form-urlencoded' -Auth -ExtraHeaders @{'If-None-Match'='*'} | Out-Null
        }
    }
    catch {
        try { Remove-ZoteroCreatedObject -Context $Context -Key $attachmentKey -Version $createdAttachment.version } catch { }
        throw
    }
    return [pscustomobject]@{ key=$attachmentKey; version=$createdAttachment.version; action='created'; role=$Role; sha256=$sha256 }
}

function Remove-ZoteroCreatedObject {
    [CmdletBinding()]
    param([object]$Context,[string]$Key,[int]$Version)
    if ($Version -le 0) { throw 'A known positive Zotero object version is required for rollback' }
    Invoke-ZoteroHttp -Context $Context -Method DELETE -Path "users/0/items/$Key" -Auth -ExtraHeaders @{'If-Unmodified-Since-Version'=$Version} | Out-Null
}

Export-ModuleMember -Function Normalize-ZoteroTitle,Find-ZoteroPaperMatch,Test-ZoteroAuthorizationForUpload,Test-ZoteroUploadUri,Get-ZoteroRollbackPlan,Protect-ZoteroApiKey,Unprotect-ZoteroApiKey,ConvertTo-ZoteroBatchJson,New-ZoteroWriteToken,Get-CreatedZoteroObject,ConvertFrom-ZoteroAttachmentSpecs,Connect-ZoteroLocalApi,Request-ZoteroLocalAuthorization,Find-ZoteroPaper,New-ZoteroPaperData,New-ZoteroPaper,Add-ZoteroStoredAttachment,Get-ZoteroAttachmentFingerprint,Remove-ZoteroCreatedObject
