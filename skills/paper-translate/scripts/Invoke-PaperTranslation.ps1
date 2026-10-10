[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$InputPdf,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [string]$ExecutablePath,
    [ValidateSet('qwenmt', 'bing')][string]$Service = 'qwenmt',
    [ValidateSet('none', 'bing')][string]$FallbackService = 'bing',
    [string]$QwenApiKey,
    [string]$QwenModel = 'qwen-mt-flash',
    [string]$QwenBaseUrl = 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    [ValidateSet('direct', 'system')][string]$QwenNetwork = 'direct',
    [ValidateRange(1, 100)][int]$QwenQps = 1,
    [ValidateRange(1, 100)][int]$QwenWorkers = 1,
    [string]$SourceLanguage = 'en',
    [string]$TargetLanguage = 'zh-CN',
    [string]$Pages,
    [string]$ResultPath,
    [string]$PaperId = ([guid]::NewGuid().ToString()),
    [switch]$SkipFallbackProbe,
    [switch]$AutoEnableOcrWorkaround
)

$ErrorActionPreference = 'Stop'

function Write-Result {
    param([object]$Value)
    if ($ResultPath) {
        $directory = Split-Path -Parent $ResultPath
        if (-not $directory) { $directory = (Get-Location).Path }
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $temporary = Join-Path $directory ('.translation-' + [guid]::NewGuid().ToString('N') + '.tmp')
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 30), (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temporary -Destination $ResultPath -Force
    }
    $Value
}

function Test-OutputPdf {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $item = Get-Item -LiteralPath $Path
    if ($item.Length -lt 1024) { return $false }
    $stream = [IO.File]::OpenRead($Path)
    try {
        $bytes = New-Object byte[] 5
        $read = $stream.Read($bytes, 0, 5)
    }
    finally { $stream.Dispose() }
    return $read -eq 5 -and [Text.Encoding]::ASCII.GetString($bytes) -eq '%PDF-'
}

function Resolve-QwenApiKey {
    if ($QwenApiKey) { return $QwenApiKey.Trim() }
    foreach ($scope in @('Process', 'User', 'Machine')) {
        $value = [Environment]::GetEnvironmentVariable('DASHSCOPE_API_KEY', $scope)
        if ($value) { return $value.Trim() }
    }
    return $null
}

function Protect-LogLines {
    param([object[]]$Lines, [string]$Secret)
    return @($Lines | ForEach-Object {
        $line = [string]$_
        if ($Secret) { $line = $line.Replace($Secret, '<redacted>') }
        $line = $line -replace '(?i)(--qwenmt-api-key\s+)(\S+)', '$1<redacted>'
        $line -replace '(?i)(Bearer\s+)[A-Za-z0-9._-]+','$1<redacted>'
    })
}

function Get-TranslationFailureKind {
    param([object[]]$Lines,[string]$Message)
    $text=(@($Lines)+@($Message)) -join "`n"
    if($text -match '(?i)scanned PDF detected'){return 'scanned_pdf'}
    if($text -match '(?i)code 401|Unauthorized|invalid.api.key'){return 'authorization'}
    if($text -match '(?i)quota|insufficient.balance|free.allocation|code 429'){return 'quota_or_rate_limit'}
    if($text -match '(?i)name too long|path too long|WinError 206'){return 'path_length'}
    if($text -match '(?i)exactly one mono|Invalid translation output'){return 'invalid_output'}
    return 'provider_or_runtime'
}

function ConvertTo-ProcessArgument {
    param([AllowEmptyString()][string]$Value)
    if ($Value -and $Value -notmatch '[\s"]') { return $Value }
    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Invoke-HiddenProcess {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$WorkingDirectory,
        [string]$LogDirectory
    )
    $stdoutPath = Join-Path $LogDirectory 'translator.stdout.log'
    $stderrPath = Join-Path $LogDirectory 'translator.stderr.log'
    $argumentList = ($Arguments | ForEach-Object { ConvertTo-ProcessArgument ([string]$_) }) -join ' '
    $process = Start-Process -FilePath $FilePath -ArgumentList $argumentList -WorkingDirectory $WorkingDirectory -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    $lines = @()
    if (Test-Path -LiteralPath $stdoutPath) { $lines += @(Get-Content -LiteralPath $stdoutPath) }
    if (Test-Path -LiteralPath $stderrPath) { $lines += @(Get-Content -LiteralPath $stderrPath) }
    return [pscustomobject]@{ exit_code = $process.ExitCode; lines = $lines }
}

function Add-NoProxyHost {
    param([string]$CurrentValue, [string]$HostName)
    $entries = @($CurrentValue -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($entries -notcontains $HostName) { $entries += $HostName }
    return $entries -join ','
}

function Test-BingTranslationService {
    param([string]$FromLanguage, [string]$ToLanguage)
    if ($SkipFallbackProbe) {
        return [pscustomobject]@{ available = $true; detail = 'probe skipped by caller' }
    }
    try {
        $headers = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/131.0.0.0 Safari/537.36 Edg/131.0.0.0' }
        $page = Invoke-WebRequest -Uri 'https://www.bing.com/translator' -Headers $headers -UseBasicParsing -TimeoutSec 20
        $igMatch = [regex]::Match($page.Content, '"ig":"([^"]+)"')
        $iidMatches = [regex]::Matches($page.Content, 'data-iid="([^"]+)"')
        $tokenMatch = [regex]::Match($page.Content, 'params_AbusePreventionHelper\s*=\s*\[(\d+),"([^"]+)"')
        if (-not $igMatch.Success -or $iidMatches.Count -eq 0 -or -not $tokenMatch.Success) {
            throw 'Bing translator page did not expose the expected session fields'
        }
        $from = if ($FromLanguage -eq 'auto') { 'en' } else { $FromLanguage }
        $to = switch ($ToLanguage.ToLowerInvariant()) {
            'zh' { 'zh-Hans' }
            'zh-cn' { 'zh-Hans' }
            'zh-tw' { 'zh-Hant' }
            default { $ToLanguage }
        }
        $endpoint = $page.BaseResponse.ResponseUri.GetLeftPart([UriPartial]::Authority) + '/ttranslatev3?IG=' + $igMatch.Groups[1].Value + '&IID=' + $iidMatches[$iidMatches.Count - 1].Groups[1].Value
        $body = @{
            fromLang = $from
            to = $to
            text = 'Research translation service check.'
            token = $tokenMatch.Groups[2].Value
            key = $tokenMatch.Groups[1].Value
        }
        $response = Invoke-RestMethod -Method Post -Uri $endpoint -Headers $headers -Body $body -TimeoutSec 20
        $translated = [string]$response[0].translations[0].text
        if (-not $translated.Trim()) { throw 'Bing returned an empty smoke-test translation' }
        return [pscustomobject]@{ available = $true; detail = 'short-text translation succeeded' }
    }
    catch {
        return [pscustomobject]@{ available = $false; detail = $_.Exception.Message }
    }
}

function Invoke-TranslationAttempt {
    param(
        [ValidateSet('qwenmt', 'bing')][string]$AttemptService,
        [string]$ApiKey
    )
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    # A short isolated directory avoids long source names and user run paths.
    $attemptDirectory = Join-Path ([IO.Path]::GetTempPath()) ('pzt-'+[guid]::NewGuid().ToString('N'))
    $diagnosticDirectory=Join-Path $OutputDirectory '.diagnostics'
    New-Item -ItemType Directory -Path $diagnosticDirectory -Force | Out-Null
    $diagnosticPath=Join-Path $diagnosticDirectory ($AttemptService+'-'+[guid]::NewGuid().ToString('N')+'.log')
    $attemptLogs = @()
    $attemptArtifacts = @()
    $publishedPaths = @()
    try {
        New-Item -ItemType Directory -Path $attemptDirectory -Force | Out-Null
        $stagedInput=Join-Path $attemptDirectory 'source.pdf'
        Copy-Item -LiteralPath $InputPdf -Destination $stagedInput
        $arguments = @($stagedInput, '--lang-in', $SourceLanguage, '--lang-out', $TargetLanguage, '--output', $attemptDirectory, '--disable-config-auto-save')
        if ($AttemptService -eq 'qwenmt') {
            $arguments += @('--qwenmt', '--qwenmt-model', $QwenModel, '--qwenmt-base-url', $QwenBaseUrl, '--qwenmt-api-key', $ApiKey, '--qps', [string]$QwenQps, '--pool-max-workers', [string]$QwenWorkers)
        }
        else { $arguments += '--bing' }
        if ($Pages) { $arguments += @('--pages', $Pages) }
        if($AutoEnableOcrWorkaround){$arguments+='--auto-enable-ocr-workaround'}

        $workingDirectory = Split-Path -Parent (Resolve-Path -LiteralPath $ExecutablePath)
        $previousNoProxy = [Environment]::GetEnvironmentVariable('NO_PROXY', 'Process')
        $restoreNoProxy = $AttemptService -eq 'qwenmt' -and $QwenNetwork -eq 'direct'
        try {
            if ([IO.Path]::GetExtension($ExecutablePath) -eq '.ps1') {
                $processArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ExecutablePath) + $arguments
                $modern=Get-Command pwsh.exe -ErrorAction SilentlyContinue
                $processFile=if($PSVersionTable.PSVersion.Major -ge 7){(Get-Process -Id $PID).Path}elseif($modern){$modern.Source}else{'powershell.exe'}
            }
            else {
                $processArguments = $arguments
                $processFile = $ExecutablePath
            }
            if ($restoreNoProxy) {
                $dashScopeHost = ([Uri]$QwenBaseUrl).Host
                $env:NO_PROXY = Add-NoProxyHost -CurrentValue $previousNoProxy -HostName $dashScopeHost
            }
            $processResult = Invoke-HiddenProcess -FilePath $processFile -Arguments $processArguments -WorkingDirectory $workingDirectory -LogDirectory $attemptDirectory
            $attemptLogs = @($processResult.lines)
            $exitCode = $processResult.exit_code
        }
        finally {
            if ($restoreNoProxy) { [Environment]::SetEnvironmentVariable('NO_PROXY', $previousNoProxy, 'Process') }
        }

        $attemptLogs = @(Protect-LogLines -Lines $attemptLogs -Secret $ApiKey)
        if ($exitCode -ne 0) { throw "PDFMathTranslate exited with code $exitCode" }
        $created = @(Get-ChildItem -LiteralPath $attemptDirectory -Filter '*.pdf' -File)
        $mono = @($created | Where-Object Name -match '(?i)(?:-|\.)mono\.pdf$')
        $dual = @($created | Where-Object Name -match '(?i)(?:-|\.)dual\.pdf$')
        if ($mono.Count -ne 1 -or $dual.Count -ne 1) {
            $failure = @($attemptLogs | Where-Object { $_ -match '(?i)HTTPError|RetryError|SubprocessError|ERROR' } | Select-Object -Last 1)
            $detail = if ($failure) { ': ' + $failure[0] } else { '' }
            throw ('PDFMathTranslate must create exactly one mono PDF and one dual PDF output' + $detail)
        }

        $outputPairs = @(@($mono[0], 'translated'), @($dual[0], 'bilingual'))
        foreach ($pair in $outputPairs) {
            if (-not (Test-OutputPdf $pair[0].FullName)) { throw "Invalid translation output: $($pair[0].FullName)" }
        }
        foreach ($pair in $outputPairs) {
            $file = $pair[0]
            $sourceStem=[IO.Path]::GetFileNameWithoutExtension($InputPdf)
            if($sourceStem.Length -gt 64){$sourceStem=$PaperId -replace '[^a-zA-Z0-9_-]','_'}
            $outputName=$file.Name -replace '^source(?=[.-])',$sourceStem
            $destination = Join-Path $OutputDirectory $outputName
            if(Test-Path -LiteralPath $destination){throw 'Output already exists; verify and reuse it before translating'}
            Move-Item -LiteralPath $file.FullName -Destination $destination -Force
            $publishedPaths += $destination
            $finalFile = Get-Item -LiteralPath $destination
            $attemptArtifacts += [pscustomobject]@{
                path = $finalFile.FullName
                role = $pair[1]
                sha256 = (Get-FileHash -LiteralPath $finalFile.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                size_bytes = $finalFile.Length
                verified = $true
            }
        }
        $stopwatch.Stop()
        return [pscustomobject]@{ service = $AttemptService; status = 'succeeded'; duration_seconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 3); error = $null; failure_kind=$null; logs = $attemptLogs; artifacts = $attemptArtifacts; diagnostic_path=$diagnosticPath }
    }
    catch {
        $stopwatch.Stop()
        foreach ($publishedPath in $publishedPaths) {
            if (Test-Path -LiteralPath $publishedPath) { [IO.File]::Delete($publishedPath) }
        }
        $message = $_.Exception.Message
        $failure = @($attemptLogs | Where-Object { $_ -match '(?i)HTTPError|RetryError|SubprocessError|ERROR' } | Select-Object -Last 1)
        if ($failure -and $message -notmatch [regex]::Escape([string]$failure[0])) { $message += ': ' + $failure[0] }
        $kind=Get-TranslationFailureKind $attemptLogs $message
        return [pscustomobject]@{ service = $AttemptService; status = 'failed'; duration_seconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 3); error = $message; failure_kind=$kind; logs = @(Protect-LogLines -Lines $attemptLogs -Secret $ApiKey); artifacts = @(); diagnostic_path=$diagnosticPath }
    }
    finally {
        $safeLogs=@(Protect-LogLines -Lines $attemptLogs -Secret $ApiKey)
        [IO.File]::WriteAllText($diagnosticPath,($safeLogs -join "`n"),[Text.UTF8Encoding]::new($false))
        $resolvedAttempt=[IO.Path]::GetFullPath($attemptDirectory)
        $resolvedTemp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
        if(-not $resolvedAttempt.StartsWith($resolvedTemp,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolvedAttempt) -notlike 'pzt-*'){throw 'Unexpected attempt cleanup target'}
        if (Test-Path -LiteralPath $resolvedAttempt) { Remove-Item -LiteralPath $resolvedAttempt -Recurse -Force }
    }
}

$errors = @()
$artifacts = @()
$attempts = @()
$allLogs = @()
$status = 'failed'
$serviceUsed = $null
$fallbackReason = $null
$resolvedQwenApiKey = $null
$diagnosticLogs=@()
$failureKind=$null

try {
    if (-not (Test-OutputPdf $InputPdf)) { throw 'Input is not a valid nontrivial PDF' }
    if (-not $ExecutablePath) {
        $installer = Join-Path $PSScriptRoot 'Install-Pdf2zh.ps1'
        $installed = & $installer
        if ($LASTEXITCODE -ne 0) { throw 'PDFMathTranslate installation failed' }
        $ExecutablePath = [string]$installed.executable_path
    }
    if (-not (Test-Path -LiteralPath $ExecutablePath)) { throw 'PDFMathTranslate executable does not exist' }
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

    if ($Service -eq 'qwenmt') {
        $resolvedQwenApiKey = Resolve-QwenApiKey
        if (-not $resolvedQwenApiKey) {
            $fallbackReason = 'DASHSCOPE_API_KEY is not configured for Qwen-MT Flash'
            $attempts += [pscustomobject]@{ service = 'qwenmt'; status = 'skipped'; duration_seconds = 0; error = $fallbackReason }
        }
        else {
            $primary = Invoke-TranslationAttempt -AttemptService 'qwenmt' -ApiKey $resolvedQwenApiKey
            $diagnosticLogs+=@([pscustomobject]@{service='qwenmt';path=$primary.diagnostic_path})
            $failureKind=$primary.failure_kind
            $attempts += [pscustomobject]@{ service = $primary.service; status = $primary.status; duration_seconds = $primary.duration_seconds; error = $primary.error }
            $allLogs += @($primary.logs | ForEach-Object { '[qwenmt] ' + $_ })
            if ($primary.status -eq 'succeeded') { $artifacts = @($primary.artifacts); $serviceUsed = 'qwenmt'; $status = 'succeeded' }
            else { $fallbackReason = [string]$primary.error }
        }
    }
    else {
        $primary = Invoke-TranslationAttempt -AttemptService 'bing'
        $diagnosticLogs+=@([pscustomobject]@{service='bing';path=$primary.diagnostic_path})
        $failureKind=$primary.failure_kind
        $attempts += [pscustomobject]@{ service = $primary.service; status = $primary.status; duration_seconds = $primary.duration_seconds; error = $primary.error }
        $allLogs += @($primary.logs | ForEach-Object { '[bing] ' + $_ })
        if ($primary.status -eq 'succeeded') { $artifacts = @($primary.artifacts); $serviceUsed = 'bing'; $status = 'succeeded' }
        else { throw [string]$primary.error }
    }

    if ($status -ne 'succeeded' -and $Service -eq 'qwenmt') {
        if($failureKind -in @('scanned_pdf','path_length','invalid_output')){throw $fallbackReason}
        if ($FallbackService -ne 'bing') { throw $fallbackReason }
        $probe = Test-BingTranslationService -FromLanguage $SourceLanguage -ToLanguage $TargetLanguage
        if (-not $probe.available) { throw ('Bing fallback smoke test failed: ' + $probe.detail + '; primary failure: ' + $fallbackReason) }
        $fallback = Invoke-TranslationAttempt -AttemptService 'bing'
        $diagnosticLogs+=@([pscustomobject]@{service='bing';path=$fallback.diagnostic_path})
        $failureKind=$fallback.failure_kind
        $attempts += [pscustomobject]@{ service = $fallback.service; status = $fallback.status; duration_seconds = $fallback.duration_seconds; error = $fallback.error }
        $allLogs += @($fallback.logs | ForEach-Object { '[bing] ' + $_ })
        if ($fallback.status -ne 'succeeded') { throw ('Bing fallback failed: ' + $fallback.error + '; primary failure: ' + $fallbackReason) }
        $artifacts = @($fallback.artifacts)
        $serviceUsed = 'bing'
        $status = 'succeeded'
    }
}
catch {
    $errors += [pscustomobject]@{ code = 'translation_failed'; kind=if($failureKind){$failureKind}else{'preflight'}; message = $_.Exception.Message }
}

$result = [pscustomobject][ordered]@{
    schema = 'translation-result.v1'
    schema_version = 1
    paper_id = $PaperId
    status = $status
    inputs = [pscustomobject]@{ input_pdf = $InputPdf; service = $Service; fallback_service = $FallbackService; qwen_model = $QwenModel; qwen_network = $QwenNetwork; qwen_qps = $QwenQps; qwen_workers = $QwenWorkers; source_language = $SourceLanguage; target_language = $TargetLanguage; pages = $Pages }
    outputs = [pscustomobject]@{
        artifacts = $artifacts
        service_used = $serviceUsed
        fallback_used = [bool]($serviceUsed -and $serviceUsed -ne $Service)
        fallback_reason = $fallbackReason
        attempts = $attempts
        log_tail = @($allLogs | Select-Object -Last 20)
        diagnostic_logs=$diagnosticLogs
        auto_enable_ocr_workaround=[bool]$AutoEnableOcrWorkaround
    }
    provenance = @([pscustomobject]@{ source = 'PDFMathTranslate-next'; executable = $ExecutablePath; service = $serviceUsed; model = if ($serviceUsed -eq 'qwenmt') { $QwenModel } else { $null }; qwen_network = if ($Service -eq 'qwenmt') { $QwenNetwork } else { $null } })
    errors = $errors
}

Write-Result $result
if ($status -eq 'succeeded') { exit 0 }
exit 1
