param([string]$TranslatorPath)
$ErrorActionPreference='Stop'
$taskSkill=Split-Path -Parent $PSScriptRoot
$taskRoot=Join-Path ([IO.Path]::GetTempPath()) ('pzt-diagnostics-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $taskRoot | Out-Null
$script:Passed=0;$script:Failed=0
function Check($Expected,$Actual,[string]$Name){if($Expected -eq $Actual){$script:Passed++;Write-Output ('PASS: '+$Name)}else{$script:Failed++;Write-Output ("FAIL: $Name (expected $Expected, got $Actual)")}}
$taskPreviousKey=[Environment]::GetEnvironmentVariable('DASHSCOPE_API_KEY','Process')
$taskPreviousCalls=[Environment]::GetEnvironmentVariable('PZT_DIAGNOSTIC_CALLS','Process')
if(-not $TranslatorPath){$TranslatorPath=Join-Path $taskSkill 'scripts\Invoke-PaperTranslation.ps1'}
try{
    $taskPdf=Join-Path $taskRoot 'paper.pdf'
    $taskBytes=[byte[]]::new(2048);[Array]::Copy([Text.Encoding]::ASCII.GetBytes('%PDF-1.4'),$taskBytes,8);[IO.File]::WriteAllBytes($taskPdf,$taskBytes)
    $taskFake=Join-Path $taskRoot 'fake.ps1'
    [IO.File]::WriteAllText($taskFake,@'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Rest)
Add-Content -LiteralPath $env:PZT_DIAGNOSTIC_CALLS -Value $(if($Rest -contains '--qwenmt'){'qwenmt'}else{'bing'})
if($Rest -contains '--auto-enable-ocr-workaround'){Add-Content -LiteralPath $env:PZT_DIAGNOSTIC_CALLS -Value 'ocr_compatibility_enabled'}
Write-Output 'Scanned PDF detected.'
Write-Output 'diagnostic-test-secret'
1..40 | ForEach-Object {Write-Output ('trailing status '+$_)}
exit 0
'@,[Text.UTF8Encoding]::new($true))
    $env:DASHSCOPE_API_KEY='diagnostic-test-secret'
    $env:PZT_DIAGNOSTIC_CALLS=Join-Path $taskRoot 'calls.txt'
    $taskResultPath=Join-Path $taskRoot 'result.json'
    $taskChild=Start-Process -FilePath (Get-Command pwsh.exe).Source -ArgumentList @('-NoProfile','-File',('"'+$TranslatorPath+'"'),'-InputPdf',('"'+$taskPdf+'"'),'-OutputDirectory',('"'+(Join-Path $taskRoot 'output')+'"'),'-ExecutablePath',('"'+$taskFake+'"'),'-FallbackService','none','-ResultPath',('"'+$taskResultPath+'"')) -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput (Join-Path $taskRoot 'out.log') -RedirectStandardError (Join-Path $taskRoot 'err.log')
    $taskResult=Get-Content $taskResultPath -Raw | ConvertFrom-Json
    Check 'failed' $taskResult.status 'exit zero without PDFs is not a successful translation'
    $taskLogs=@($taskResult.outputs.diagnostic_logs)
    Check $true ($taskLogs.Count -gt 0 -and (Test-Path -LiteralPath ([string]$taskLogs[0].path))) 'retains a durable diagnostic log after cleanup'
    if($taskLogs.Count -gt 0 -and (Test-Path -LiteralPath ([string]$taskLogs[0].path))){
        $taskText=Get-Content -LiteralPath $taskLogs[0].path -Raw
        Check $true ($taskText -match 'Scanned PDF detected') 'full log keeps root cause outside the last twenty lines'
        Check $false ($taskText -match 'diagnostic-test-secret') 'durable log redacts the translation credential'
    }
    Check 'scanned_pdf' $taskResult.errors[0].kind 'classifies scan detection separately from provider failures'
    Remove-Item -LiteralPath $env:PZT_DIAGNOSTIC_CALLS -Force
    $taskChild=Start-Process -FilePath (Get-Command pwsh.exe).Source -ArgumentList @('-NoProfile','-File',('"'+$TranslatorPath+'"'),'-InputPdf',('"'+$taskPdf+'"'),'-OutputDirectory',('"'+(Join-Path $taskRoot 'default-fallback')+'"'),'-ExecutablePath',('"'+$taskFake+'"'),'-SkipFallbackProbe','-ResultPath',('"'+$taskResultPath+'"')) -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput (Join-Path $taskRoot 'fallback.out') -RedirectStandardError (Join-Path $taskRoot 'fallback.err')
    $taskCalls=@(Get-Content $env:PZT_DIAGNOSTIC_CALLS)
    Check 0 @($taskCalls | Where-Object {$_ -eq 'bing'}).Count 'scan detection never invokes a second provider even when fallback is configured'
    Remove-Item -LiteralPath $env:PZT_DIAGNOSTIC_CALLS -Force
    $taskChild=Start-Process -FilePath (Get-Command pwsh.exe).Source -ArgumentList @('-NoProfile','-File',('"'+$TranslatorPath+'"'),'-InputPdf',('"'+$taskPdf+'"'),'-OutputDirectory',('"'+(Join-Path $taskRoot 'ocr-compatibility')+'"'),'-ExecutablePath',('"'+$taskFake+'"'),'-FallbackService','none','-AutoEnableOcrWorkaround','-ResultPath',('"'+$taskResultPath+'"')) -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput (Join-Path $taskRoot 'ocr.out') -RedirectStandardError (Join-Path $taskRoot 'ocr.err')
    $taskCalls=if(Test-Path $env:PZT_DIAGNOSTIC_CALLS){@(Get-Content $env:PZT_DIAGNOSTIC_CALLS)}else{@()}
    Check 1 @($taskCalls|Where-Object {$_ -eq 'ocr_compatibility_enabled'}).Count 'passes explicit OCR compatibility to the engine without changing engines'
}finally{
    [Environment]::SetEnvironmentVariable('DASHSCOPE_API_KEY',$taskPreviousKey,'Process')
    [Environment]::SetEnvironmentVariable('PZT_DIAGNOSTIC_CALLS',$taskPreviousCalls,'Process')
    if((Split-Path -Leaf $taskRoot) -notlike 'pzt-diagnostics-*'){throw 'Unexpected test cleanup target'}
    Remove-Item -LiteralPath $taskRoot -Recurse -Force
}
Write-Output ("Result: $script:Passed passed, $script:Failed failed")
if($script:Failed){exit 1}
