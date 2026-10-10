function Read-FlowJson {
    param([string]$Path)
    [IO.File]::ReadAllText($Path,[Text.UTF8Encoding]::new($false,$true)) | ConvertFrom-Json
}
function Write-FlowJson {
    param([string]$Path,$Value)
    $directory=Split-Path -Parent $Path
    if(-not $directory){$directory=(Get-Location).Path}
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $temporary=Join-Path $directory ('.flow-'+[guid]::NewGuid().ToString('N')+'.tmp')
    try{
        [IO.File]::WriteAllText($temporary,($Value|ConvertTo-Json -Depth 40),[Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}}
}
function Resolve-FlowPowerShell {
    param([string]$Path)
    if($Path){return (Get-Item -LiteralPath $Path -ErrorAction Stop).FullName}
    if($PSVersionTable.PSVersion.Major -ge 7){return (Get-Process -Id $PID).Path}
    $modern=Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if($modern){return $modern.Source}
    return (Get-Command powershell.exe -ErrorAction Stop).Source
}
function ConvertTo-FlowArgument {
    param([AllowEmptyString()][string]$Value)
    if($Value -and $Value -notmatch '[\s"]'){return $Value}
    $escaped=$Value -replace '(\\*)"','$1$1\"'
    $escaped=$escaped -replace '(\\+)$','$1$1'
    return '"'+$escaped+'"'
}
function Invoke-FlowChild {
    param([string]$Runtime,[string]$Script,[string[]]$Arguments,[string]$LogDirectory)
    New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    $prefix=Join-Path $LogDirectory ([guid]::NewGuid().ToString('N'))
    $args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$Script)+$Arguments
    $commandLine=($args|ForEach-Object {ConvertTo-FlowArgument $_}) -join ' '
    $process=Start-Process -FilePath $Runtime -ArgumentList $commandLine -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput ($prefix+'.out') -RedirectStandardError ($prefix+'.err')
    [pscustomobject]@{exit_code=$process.ExitCode;stdout=$prefix+'.out';stderr=$prefix+'.err'}
}
function Test-FlowPdf {
    param([string]$Path,[string]$Sha256,[switch]$RequireReadable)
    if(-not $Path -or -not(Test-Path -LiteralPath $Path -PathType Leaf)){return $false}
    if((Get-Item -LiteralPath $Path).Length -lt 1024){return $false}
    $stream=[IO.File]::OpenRead($Path)
    try{$bytes=[byte[]]::new(5);$length=$stream.Read($bytes,0,5)}finally{$stream.Dispose()}
    if($length -ne 5 -or [Text.Encoding]::ASCII.GetString($bytes) -ne '%PDF-'){return $false}
    if($Sha256 -and (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Sha256.ToLowerInvariant()){return $false}
    if($RequireReadable){
        $pdfinfo=Get-Command pdfinfo.exe -ErrorAction SilentlyContinue
        if(-not $pdfinfo){return $false}
        $info=& $pdfinfo.Source $Path 2>$null
        if($LASTEXITCODE -ne 0 -or -not($info -match '^Pages:\s+[1-9]')){return $false}
    }
    return $true
}
function Test-FlowTranslationPair {
    param([object[]]$Artifacts,[switch]$RequireReadable)
    foreach($role in @('translated','bilingual')){
        $matching=@($Artifacts|Where-Object role -eq $role)
        if($matching.Count -ne 1 -or -not $matching[0].verified -or $matching[0].sha256 -notmatch '^[a-fA-F0-9]{64}$'){return $false}
        if(-not(Test-FlowPdf -Path $matching[0].path -Sha256 $matching[0].sha256 -RequireReadable:$RequireReadable)){return $false}
    }
    return $true
}
function Get-FlowRequirements {
    param([string]$Mode,[bool]$LocalOnly)
    switch($Mode){
        'find'{return @('find')}
        'download'{if($LocalOnly){return @('find','download','verify')}else{return @('find','download','ingest','verify')}}
        'ingest'{return @('ingest','verify')}
        'translate'{if($LocalOnly){return @('translate','verify')}else{return @('translate','attach','verify')}}
        'full'{if($LocalOnly){return @('find','download','translate','verify')}else{return @('find','download','ingest','translate','attach','verify')}}
        default{return @()}
    }
}
function Get-FlowOverallStatus {
    param($Paper,[string]$Mode,[bool]$LocalOnly)
    $requirements=@(Get-FlowRequirements $Mode $LocalOnly)
    if(-not $requirements.Count){return [string]$Paper.last_stage_status}
    $missing=@($requirements|Where-Object {-not $Paper.stage_states.$_ -or $Paper.stage_states.$_.status -ne 'succeeded'})
    if(-not $missing.Count){return 'succeeded'}
    if(@($requirements|Where-Object {$Paper.stage_states.$_.status -in @('failed','unknown')}).Count){return 'failed'}
    return 'partial'
}
function Get-FlowAttachmentRole {
    param($Data)
    $label=([string]$Data.title)+' '+([string]$Data.filename)
    if($label -match '(?i)bilingual|dual[.]pdf|\u53cc\u8bed'){return 'bilingual'}
    if($label -match '(?i)translated|mono[.]pdf|Chinese.only|\u4e2d\u6587'){return 'translated'}
    return 'original'
}
function Read-FlowLocalApi {
    param([string]$BaseUri,[string]$Path)
    $origin=[uri]$BaseUri
    if($origin.Scheme -ne 'http' -or -not $origin.IsLoopback){throw 'Only the Zotero loopback API is allowed'}
    $request=[Net.HttpWebRequest]::Create($BaseUri.TrimEnd('/')+'/'+$Path.TrimStart('/'))
    $request.Proxy=$null;$request.Timeout=30000;$request.Headers['Zotero-API-Version']='3'
    $response=$request.GetResponse()
    try{
        $reader=[IO.StreamReader]::new($response.GetResponseStream(),[Text.UTF8Encoding]::new($false,$true))
        try{$text=$reader.ReadToEnd()}finally{$reader.Dispose()}
        $value=if($text){$text|ConvertFrom-Json}else{$null}
        [pscustomobject]@{value=$value;text=$text;server_id=$response.Headers['Zotero-Server-ID']}
    }finally{$response.Dispose()}
}
function Get-FlowZoteroPdfs {
    param([string]$BaseUri,[string]$ItemKey)
    $parent=(Read-FlowLocalApi $BaseUri ('users/0/items/'+$ItemKey)).value
    if($parent.data.deleted -or $parent.data.itemType -in @('attachment','note','annotation')){throw 'A live parent paper item is required'}
    $children=@();$offset=0
    do{
        $page=@((Read-FlowLocalApi $BaseUri ('users/0/items/'+$ItemKey+'/children?limit=100&start='+$offset)).value)
        $children+=$page;$offset+=$page.Count
    }while($page.Count -eq 100)
    $files=@(foreach($child in $children){
        if($child.data.itemType -ne 'attachment' -or $child.data.contentType -ne 'application/pdf'){continue}
        $path=$null
        if($child.links.enclosure.href -and ([uri]$child.links.enclosure.href).Scheme -eq 'file'){$path=([uri]$child.links.enclosure.href).LocalPath}
        $valid=Test-FlowPdf $path -RequireReadable
        [pscustomobject]@{key=$child.key;role=(Get-FlowAttachmentRole $child.data);path=$path;verified=$valid;sha256=if($valid){(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}else{$null};size_bytes=if($valid){(Get-Item -LiteralPath $path).Length}else{0}}
    })
    [pscustomobject]@{parent=$parent;files=$files}
}
Export-ModuleMember -Function *-Flow*
