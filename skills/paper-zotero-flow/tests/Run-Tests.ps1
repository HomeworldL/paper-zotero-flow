$ErrorActionPreference = 'Stop'

$script:Passed = 0
$script:Failed = 0
$SkillRoot = Split-Path -Parent $PSScriptRoot
$Validator = Join-Path $SkillRoot 'scripts\Test-PaperZoteroFlowResult.ps1'
$Updater = Join-Path $SkillRoot 'scripts\Update-RunManifest.ps1'
$Orchestrator = Join-Path $SkillRoot 'scripts\Invoke-PaperZoteroFlow.ps1'
$TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('paper-zotero-flow-tests-' + [guid]::NewGuid().ToString('N'))

function Assert-Equal {
    param($Expected, $Actual, [string]$Name)
    if ($Expected -ne $Actual) {
        $script:Failed++
        Write-Host "FAIL: $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red
        return
    }
    $script:Passed++
    Write-Host "PASS: $Name"
}

function Write-JsonFile {
    param([string]$Path, [object]$Value)
    $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Invoke-PowerShellFile {
    param([string]$File, [string[]]$Arguments)
    $stdout = Join-Path $TempRoot ([guid]::NewGuid().ToString('N') + '.out')
    $stderr = Join-Path $TempRoot ([guid]::NewGuid().ToString('N') + '.err')
    $argumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $File + '"')) + $Arguments
    $process = Start-Process -FilePath (Get-Command pwsh.exe).Source -ArgumentList $argumentList -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    return $process.ExitCode
}

try {
    New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null
    $validPath = Join-Path $TempRoot 'valid.json'
    $invalidVersionPath = Join-Path $TempRoot 'invalid-version.json'
    $unknownPath = Join-Path $TempRoot 'unknown.json'
    $utf8NoBomPath = Join-Path $TempRoot 'utf8-no-bom.json'
    $manifestPath = Join-Path $TempRoot 'manifest.json'
    $utf8ManifestPath = Join-Path $TempRoot 'utf8-manifest.json'

    $baseResult = [ordered]@{
        schema = 'paper-record.v1'
        schema_version = 1
        paper_id = '11111111-1111-1111-1111-111111111111'
        status = 'succeeded'
        inputs = [ordered]@{ query = 'Example' }
        outputs = [ordered]@{
            identifiers = [ordered]@{ doi = '10.1000/example'; arxiv_id = $null; pmid = $null }
            metadata = [ordered]@{ title = 'Example'; authors = @(); year = 2026; venue = ''; url = ''; metadata_source = 'crossref' }
            pdf_candidates = @()
        }
        provenance = @()
        errors = @()
    }
    Write-JsonFile $validPath $baseResult
    $invalid = [ordered]@{} + $baseResult
    $invalid.schema_version = 2
    Write-JsonFile $invalidVersionPath $invalid
    $unknown = [ordered]@{} + $baseResult
    $unknown.schema = 'unknown.v1'
    Write-JsonFile $unknownPath $unknown
    $utf8Prefix = '{"schema":"paper-record.v1","schema_version":1,"paper_id":"11111111-1111-1111-1111-111111111111","status":"succeeded","inputs":{},"outputs":{"log_tail":["translate 100/'
    $utf8Suffix = '"]},"provenance":[],"errors":[]}'
    $utf8Bytes = @([System.Text.Encoding]::ASCII.GetBytes($utf8Prefix)) + @(0xE2, 0x80, 0xA6) + @([System.Text.Encoding]::ASCII.GetBytes($utf8Suffix))
    [System.IO.File]::WriteAllBytes($utf8NoBomPath, [byte[]]$utf8Bytes)

    $exitCode = Invoke-PowerShellFile $Validator @('-Path', ('"' + $validPath + '"'), '-ExpectedSchema', 'paper-record.v1')
    Assert-Equal 0 $exitCode 'accepts a supported version-1 result'

    $exitCode = Invoke-PowerShellFile $Validator @('-Path', ('"' + $invalidVersionPath + '"'), '-ExpectedSchema', 'paper-record.v1')
    Assert-Equal 1 $exitCode 'rejects an unsupported schema version'

    $exitCode = Invoke-PowerShellFile $Validator @('-Path', ('"' + $unknownPath + '"'), '-ExpectedSchema', 'unknown.v1')
    Assert-Equal 1 $exitCode 'rejects an unknown schema'

    $exitCode = Invoke-PowerShellFile $Validator @('-Path', ('"' + $utf8NoBomPath + '"'), '-ExpectedSchema', 'paper-record.v1')
    Assert-Equal 0 $exitCode 'accepts UTF-8 stage results without a BOM'

    $utf8UpdateArguments = @('-ManifestPath', ('"' + $utf8ManifestPath + '"'), '-StageResultPath', ('"' + $utf8NoBomPath + '"'), '-PaperId', $baseResult.paper_id)
    $exitCode = Invoke-PowerShellFile $Updater $utf8UpdateArguments
    Assert-Equal 0 $exitCode 'merges UTF-8 stage results without a BOM'

    $updateArguments = @('-ManifestPath', ('"' + $manifestPath + '"'), '-StageResultPath', ('"' + $validPath + '"'), '-PaperId', $baseResult.paper_id)
    $exitCode = Invoke-PowerShellFile $Updater $updateArguments
    Assert-Equal 0 $exitCode 'creates a manifest from a valid result'
    $exitCode = Invoke-PowerShellFile $Updater $updateArguments
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    Assert-Equal 1 @($manifest.papers).Count 'replaying a result does not duplicate the paper'
    Assert-Equal 'succeeded' $manifest.papers[0].status 'replaying preserves the result status'

    $translationPath = Join-Path $TempRoot 'translation.json'
    $translationResult = [ordered]@{
        schema = 'translation-result.v1'
        schema_version = 1
        paper_id = $baseResult.paper_id
        status = 'succeeded'
        inputs = [ordered]@{ service = 'qwenmt'; fallback_service = 'bing'; qwen_model = 'qwen-mt-flash'; qwen_network = 'direct'; qwen_qps = 1; qwen_workers = 1 }
        outputs = [ordered]@{
            artifacts = @(
                [ordered]@{ path = 'translated.pdf'; role = 'translated'; sha256 = ('a'*64); size_bytes = 2048; verified = $true },
                [ordered]@{ path = 'bilingual.pdf'; role = 'bilingual'; sha256 = ('b'*64); size_bytes = 2048; verified = $true }
            )
            service_used = 'bing'
            fallback_used = $true
            fallback_reason = 'primary failed'
            attempts = @(
                [ordered]@{ service = 'qwenmt'; status = 'failed'; duration_seconds = 3.5; error = 'primary failed' },
                [ordered]@{ service = 'bing'; status = 'succeeded'; duration_seconds = 2.0; error = $null }
            )
        }
        provenance = @()
        errors = @()
    }
    Write-JsonFile $translationPath $translationResult
    $translationArguments = @('-ManifestPath', ('"' + $manifestPath + '"'), '-StageResultPath', ('"' + $translationPath + '"'), '-PaperId', $baseResult.paper_id)
    $exitCode = Invoke-PowerShellFile $Updater $translationArguments
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    Assert-Equal 0 $exitCode 'merges a translation result into the manifest'
    Assert-Equal 'bing' $manifest.papers[0].translation_run.service_used 'retains the actual translation service in the manifest'
    Assert-Equal 2 @($manifest.papers[0].translation_run.attempts).Count 'retains per-attempt timings in the manifest'
    Assert-Equal 'direct' $manifest.papers[0].translation_run.qwen_network 'retains the Qwen network mode in the manifest'
    Assert-Equal 1 $manifest.papers[0].translation_run.qwen_qps 'retains the Qwen request rate in the manifest'
    Assert-Equal 1 $manifest.papers[0].translation_run.qwen_workers 'retains the Qwen worker count in the manifest'

    $before = Get-Content -LiteralPath $manifestPath -Raw
    $invalidArguments = @('-ManifestPath', ('"' + $manifestPath + '"'), '-StageResultPath', ('"' + $invalidVersionPath + '"'), '-PaperId', $baseResult.paper_id)
    $exitCode = Invoke-PowerShellFile $Updater $invalidArguments
    Assert-Equal 1 $exitCode 'invalid updates fail'
    $after = Get-Content -LiteralPath $manifestPath -Raw
    Assert-Equal $before $after 'invalid updates do not modify the manifest'

    $planPath = Join-Path $TempRoot 'plan.json'
    $exitCode = Invoke-PowerShellFile $Orchestrator @('-Input', 'Example', '-Mode', 'full', '-PlanOnly', '-ResultPath', ('"' + $planPath + '"'))
    $plan = Get-Content -LiteralPath $planPath -Raw | ConvertFrom-Json
    Assert-Equal 0 $exitCode 'plans the full workflow'
    Assert-Equal 'qwenmt' $plan.translation_service 'plans Qwen-MT as the default translation service'
    Assert-Equal 'bing' $plan.translation_fallback 'plans Bing as the default best-effort fallback'
    Assert-Equal 'direct' $plan.qwen_network 'plans direct DashScope access by default'
    Assert-Equal 1 $plan.qwen_qps 'plans one Qwen request per second'
    Assert-Equal 1 $plan.qwen_workers 'plans one Qwen translation worker'
    Assert-Equal 'verify' $plan.route[-1] 'full workflow includes a final completion check'
}
finally {
    if (Test-Path -LiteralPath $TempRoot) {
        Remove-Item -LiteralPath $TempRoot -Recurse -Force
    }
}

Write-Host "Result: $script:Passed passed, $script:Failed failed"
if ($script:Failed -gt 0) { exit 1 }
