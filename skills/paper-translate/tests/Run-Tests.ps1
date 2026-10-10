$ErrorActionPreference = 'Stop'
$script:Passed=0;$script:Failed=0
$SkillRoot=Split-Path -Parent $PSScriptRoot
$Installer=Join-Path $SkillRoot 'scripts\Install-Pdf2zh.ps1'
$Translator=Join-Path $SkillRoot 'scripts\Invoke-PaperTranslation.ps1'
$TempRoot=Join-Path ([IO.Path]::GetTempPath()) ('paper-translate-tests-'+[guid]::NewGuid().ToString('N'))
function Assert-Equal{param($Expected,$Actual,[string]$Name)if($Expected -ne $Actual){$script:Failed++;Write-Host "FAIL: $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red}else{$script:Passed++;Write-Host "PASS: $Name"}}
function Assert-True{param([bool]$Actual,[string]$Name)Assert-Equal $true $Actual $Name}
function Invoke-Child{param([string]$File,[string[]]$Arguments)$out=Join-Path $TempRoot ([guid]::NewGuid().ToString('N')+'.out');$err=Join-Path $TempRoot ([guid]::NewGuid().ToString('N')+'.err');$args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$File+'"'))+$Arguments;$p=Start-Process -FilePath (Get-Command pwsh.exe).Source -ArgumentList $args -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $out -RedirectStandardError $err;return $p.ExitCode}
try{
 New-Item -ItemType Directory $TempRoot -Force|Out-Null
 $archiveSource=Join-Path $TempRoot 'archive-source';New-Item -ItemType Directory (Join-Path $archiveSource 'pdf2zh') -Force|Out-Null
 [IO.File]::WriteAllText((Join-Path $archiveSource 'pdf2zh\pdf2zh.exe'),'fake executable')
 $archive=Join-Path $TempRoot 'runtime.zip';Compress-Archive -Path (Join-Path $archiveSource '*') -DestinationPath $archive
 $hash=(Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant();$size=(Get-Item $archive).Length;$installRoot=Join-Path $TempRoot ('tools-'+[char]0x2026)
 $exit=Invoke-Child $Installer @('-InstallRoot',('"'+$installRoot+'"'),'-ArchivePath',('"'+$archive+'"'),'-ExpectedSize',[string]$size,'-ExpectedSha256',('0'*64),'-SkipVersionCheck')
 Assert-Equal 1 $exit 'rejects a mismatched archive checksum'
 $exit=Invoke-Child $Installer @('-InstallRoot',('"'+$installRoot+'"'),'-ArchivePath',('"'+$archive+'"'),'-ExpectedSize',[string]$size,'-ExpectedSha256',$hash,'-SkipVersionCheck')
 Assert-Equal 0 $exit 'installs a verified archive fixture'
 $record=[IO.File]::ReadAllText((Join-Path $installRoot 'v2.9.0\install.json'),[Text.Encoding]::UTF8)|ConvertFrom-Json
 Assert-True (Test-Path $record.executable_path) 'records the executable path'
 $firstPath=$record.executable_path
 $exit=Invoke-Child $Installer @('-InstallRoot',('"'+$installRoot+'"'),'-ArchivePath',('"'+$archive+'"'),'-ExpectedSize',[string]$size,'-ExpectedSha256',$hash,'-SkipVersionCheck')
 $second=([IO.File]::ReadAllText((Join-Path $installRoot 'v2.9.0\install.json'),[Text.Encoding]::UTF8)|ConvertFrom-Json).executable_path
 Assert-Equal 0 $exit 'reuses an existing verified installation'
 Assert-Equal $firstPath $second 'returns the same executable on reinstall'
 $tampered=[IO.File]::ReadAllText((Join-Path $installRoot 'v2.9.0\install.json'),[Text.Encoding]::UTF8)|ConvertFrom-Json;$tampered.archive_sha256=('0'*64);$tampered|ConvertTo-Json -Depth 10|Set-Content (Join-Path $installRoot 'v2.9.0\install.json') -Encoding UTF8
 $exit=Invoke-Child $Installer @('-InstallRoot',('"'+$installRoot+'"'),'-ArchivePath',('"'+$archive+'"'),'-ExpectedSize',[string]$size,'-ExpectedSha256',$hash,'-SkipVersionCheck')
 $repaired=[IO.File]::ReadAllText((Join-Path $installRoot 'v2.9.0\install.json'),[Text.Encoding]::UTF8)|ConvertFrom-Json
 Assert-Equal $hash $repaired.archive_sha256 'reinstalls when the recorded archive pin does not match'

 $input=Join-Path $TempRoot 'paper.pdf';$inputBytes=New-Object byte[] 12000;[Array]::Copy([Text.Encoding]::ASCII.GetBytes('%PDF-1.4'),$inputBytes,8);[IO.File]::WriteAllBytes($input,$inputBytes)
 $fake=Join-Path $TempRoot 'fake-translator.ps1'
 @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Rest)
$service=if($Rest -contains '--qwenmt'){'qwenmt'}elseif($Rest -contains '--bing'){'bing'}else{'unknown'}
Add-Content -LiteralPath $env:PZF_FAKE_ARGS -Value ("CALL:"+$service) -Encoding UTF8
Add-Content -LiteralPath $env:PZF_FAKE_ARGS -Value $Rest -Encoding UTF8
Add-Content -LiteralPath $env:PZF_FAKE_ARGS -Value ("NO_PROXY:"+$service+":"+$env:NO_PROXY) -Encoding UTF8
Add-Content -LiteralPath $env:PZF_FAKE_ARGS -Value 'ENDCALL' -Encoding UTF8
(Get-Location).Path | Set-Content -LiteralPath $env:PZF_FAKE_CWD -Encoding UTF8
if($service -eq 'qwenmt' -and $env:PZF_FAKE_FAIL_QWEN -eq '1'){'simulated qwen failure';exit 23}
$outputIndex=[Array]::IndexOf($Rest,'--output')
$output=$Rest[$outputIndex+1]
New-Item -ItemType Directory $output -Force|Out-Null
foreach($suffix in @('.zh.mono.pdf','.zh.dual.pdf')){$length=if($suffix -match 'dual' -and $env:PZF_FAKE_INVALID_DUAL -eq '1'){20}else{12000};$bytes=New-Object byte[] $length;[Array]::Copy([Text.Encoding]::ASCII.GetBytes('%PDF-1.4'),$bytes,8);[IO.File]::WriteAllBytes((Join-Path $output ('paper'+$suffix)),$bytes)}
'@ | Set-Content -LiteralPath $fake -Encoding UTF8
 $env:PZF_FAKE_ARGS=Join-Path $TempRoot 'fake-args.txt';$env:PZF_FAKE_CWD=Join-Path $TempRoot 'fake-cwd.txt'
 $env:DASHSCOPE_API_KEY='test-qwen-key';$env:PZF_FAKE_FAIL_QWEN='0'
 $outputDir=Join-Path $TempRoot 'translated';$resultPath=Join-Path $TempRoot 'translation.json'
 $exit=Invoke-Child $Translator @('-InputPdf',('"'+$input+'"'),'-OutputDirectory',('"'+$outputDir+'"'),'-ExecutablePath',('"'+$fake+'"'),'-Pages','1-2','-ResultPath',('"'+$resultPath+'"'))
 $result=Get-Content $resultPath -Raw|ConvertFrom-Json
 Assert-Equal 0 $exit 'accepts translated and bilingual outputs'
 Assert-Equal 'succeeded' $result.status 'reports translation success'
 Assert-Equal 'translated' (@($result.outputs.artifacts)|Where-Object role -eq 'translated').role 'classifies mono output'
 Assert-Equal 'bilingual' (@($result.outputs.artifacts)|Where-Object role -eq 'bilingual').role 'classifies dual output'
 $fakeArgs=@(Get-Content $env:PZF_FAKE_ARGS)
 Assert-True ($fakeArgs -contains '--qwenmt') 'uses Qwen-MT by default'
 Assert-Equal 'qwen-mt-flash' $fakeArgs[([Array]::IndexOf($fakeArgs,'--qwenmt-model'))+1] 'selects the Qwen-MT Flash model'
 Assert-Equal '1' $fakeArgs[([Array]::IndexOf($fakeArgs,'--qps'))+1] 'limits Qwen-MT to one request per second'
 Assert-Equal '1' $fakeArgs[([Array]::IndexOf($fakeArgs,'--pool-max-workers'))+1] 'uses one Qwen-MT worker'
 Assert-True (@($fakeArgs|Where-Object {$_ -like 'NO_PROXY:qwenmt:*dashscope.aliyuncs.com*'}).Count -eq 1) 'bypasses the system proxy only for the DashScope host'
 Assert-True ($fakeArgs -contains '--disable-config-auto-save') 'does not persist API credentials in PDFMathTranslate config'
 Assert-Equal 'qwenmt' $result.outputs.service_used 'records the service that produced the artifacts'
 Assert-Equal $false $result.outputs.fallback_used 'does not report fallback for a successful Qwen run'
 Assert-True (-not (($result|ConvertTo-Json -Depth 30) -match 'test-qwen-key')) 'does not write the API key to the result'
 Assert-Equal '1-2' $fakeArgs[([Array]::IndexOf($fakeArgs,'--pages'))+1] 'passes the requested page range to PDFMathTranslate'
 Assert-Equal (Split-Path -Parent $fake) (Get-Content $env:PZF_FAKE_CWD -Raw).Trim() 'runs PDFMathTranslate from its executable directory'
 Assert-Equal 'direct' $result.inputs.qwen_network 'records the default direct Qwen network mode'
 Assert-Equal 1 $result.inputs.qwen_qps 'records the Qwen request rate'
 Assert-True ((Get-Content -LiteralPath $Translator -Raw) -match 'Start-Process.+-WindowStyle\s+Hidden') 'starts PDFMathTranslate in a hidden window'

 Remove-Item -LiteralPath $env:PZF_FAKE_ARGS -Force
 $env:PZF_FAKE_FAIL_QWEN='1';$env:NO_PROXY='existing.example'
 $fallbackOutput=Join-Path $TempRoot 'fallback-output';$fallbackResult=Join-Path $TempRoot 'fallback.json'
 $exit=Invoke-Child $Translator @('-InputPdf',('"'+$input+'"'),'-OutputDirectory',('"'+$fallbackOutput+'"'),'-ExecutablePath',('"'+$fake+'"'),'-SkipFallbackProbe','-ResultPath',('"'+$fallbackResult+'"'))
 $fallback=Get-Content $fallbackResult -Raw|ConvertFrom-Json
 $fallbackArgs=@(Get-Content $env:PZF_FAKE_ARGS)
 Assert-Equal 0 $exit 'falls back when Qwen-MT fails'
 Assert-Equal 1 @($fallbackArgs|Where-Object {$_ -eq 'CALL:qwenmt'}).Count 'attempts Qwen-MT once before fallback'
 Assert-Equal 1 @($fallbackArgs|Where-Object {$_ -eq 'CALL:bing'}).Count 'attempts Bing once as fallback'
 Assert-Equal 'bing' $fallback.outputs.service_used 'records Bing as the service that produced fallback artifacts'
 Assert-Equal $true $fallback.outputs.fallback_used 'records that fallback was used'
 Assert-True ([string]$fallback.outputs.fallback_reason -match 'code 23') 'records the primary failure without losing the successful result'
 Assert-Equal 2 @($fallback.outputs.attempts).Count 'records both translation attempts'
 Assert-True (@($fallbackArgs|Where-Object {$_ -eq 'NO_PROXY:bing:existing.example'}).Count -eq 1) 'restores the original proxy environment before Bing fallback'

 $env:PZF_FAKE_FAIL_QWEN='0';$env:PZF_FAKE_INVALID_DUAL='1'
 $invalidPairOutput=Join-Path $TempRoot 'invalid-pair-output';$invalidPairResult=Join-Path $TempRoot 'invalid-pair.json'
 $exit=Invoke-Child $Translator @('-InputPdf',('"'+$input+'"'),'-OutputDirectory',('"'+$invalidPairOutput+'"'),'-ExecutablePath',('"'+$fake+'"'),'-FallbackService','none','-ResultPath',('"'+$invalidPairResult+'"'))
 Assert-Equal 1 $exit 'fails when either translation output is invalid'
 Assert-Equal 0 @(Get-ChildItem -LiteralPath $invalidPairOutput -Filter '*.pdf' -File).Count 'publishes no partial PDFs when output validation fails'

 $emptyFake=Join-Path $TempRoot 'empty-translator.ps1';'param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Rest)'|Set-Content $emptyFake -Encoding UTF8
 $emptyResult=Join-Path $TempRoot 'empty.json';$emptyOutput=Join-Path $TempRoot 'empty-output'
 $exit=Invoke-Child $Translator @('-InputPdf',('"'+$input+'"'),'-OutputDirectory',('"'+$emptyOutput+'"'),'-ExecutablePath',('"'+$emptyFake+'"'),'-FallbackService','none','-ResultPath',('"'+$emptyResult+'"'))
 Assert-Equal 1 $exit 'fails when the translator creates no PDFs'
 Assert-Equal 'failed' (Get-Content $emptyResult -Raw|ConvertFrom-Json).status 'records no-output failure'
}finally{if(Test-Path $TempRoot){Remove-Item -LiteralPath $TempRoot -Recurse -Force}}
Write-Host "Result: $script:Passed passed, $script:Failed failed";if($script:Failed -gt 0){exit 1}
