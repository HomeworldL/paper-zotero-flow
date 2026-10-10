[CmdletBinding()]
param(
    [string]$InstallRoot,
    [switch]$Force,
    [string]$ArchivePath,
    [int64]$ExpectedSize = 0,
    [string]$ExpectedSha256,
    [switch]$SkipVersionCheck
)

$ErrorActionPreference='Stop'
$SkillRoot=Split-Path -Parent $PSScriptRoot
$pin=[IO.File]::ReadAllText((Join-Path $SkillRoot 'references\pdf2zh-release.json'),[Text.Encoding]::UTF8)|ConvertFrom-Json
if(-not $InstallRoot){$root=if($env:LOCALAPPDATA){$env:LOCALAPPDATA}else{Join-Path $HOME 'AppData\Local'};$InstallRoot=Join-Path $root 'PaperZoteroFlow\tools\pdf2zh-next'}
if(-not $ExpectedSize){$ExpectedSize=[int64]$pin.size}
if(-not $ExpectedSha256){$ExpectedSha256=[string]$pin.sha256}
$target=Join-Path $InstallRoot ([string]$pin.version)
$recordPath=Join-Path $target 'install.json'

try{
 if((Test-Path $recordPath)-and -not $Force){
  $existing=[IO.File]::ReadAllText($recordPath,[Text.Encoding]::UTF8)|ConvertFrom-Json
  if($existing.version -eq $pin.version -and $existing.archive_sha256 -eq $ExpectedSha256.ToLowerInvariant() -and (Test-Path -LiteralPath $existing.executable_path)){
   $exeHash=(Get-FileHash -LiteralPath $existing.executable_path -Algorithm SHA256).Hash.ToLowerInvariant()
   if($exeHash -eq $existing.executable_sha256){$existing;exit 0}
  }
 }
 New-Item -ItemType Directory $InstallRoot -Force|Out-Null
 $operation=[guid]::NewGuid().ToString('N');$download=Join-Path $InstallRoot ('.'+$pin.asset+'.'+$operation+'.partial');$extract=Join-Path $InstallRoot ('.extract-'+$operation)
 $source=$ArchivePath
 if(-not $source){Invoke-WebRequest -Uri $pin.url -OutFile $download -UseBasicParsing -TimeoutSec 1800;$source=$download}
 $info=Get-Item -LiteralPath $source
 if($info.Length -ne $ExpectedSize){throw "PDFMathTranslate archive size mismatch: expected $ExpectedSize, got $($info.Length)"}
 $hash=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
 if($hash -ne $ExpectedSha256.ToLowerInvariant()){throw 'PDFMathTranslate archive checksum mismatch'}
 New-Item -ItemType Directory $extract -Force|Out-Null;Expand-Archive -LiteralPath $source -DestinationPath $extract -Force
 $exe=Get-ChildItem -LiteralPath $extract -Recurse -File|Where-Object Name -in @('pdf2zh_next.exe','pdf2zh.exe')|Sort-Object @{Expression={if($_.Name -eq 'pdf2zh_next.exe'){0}else{1}}}|Select-Object -First 1
 if(-not $exe){throw 'Verified archive does not contain pdf2zh_next.exe or pdf2zh.exe'}
 if(-not $SkipVersionCheck){& $exe.FullName --version|Out-Null;if($LASTEXITCODE -ne 0){throw 'pdf2zh_next.exe --version failed'}}
 if(Test-Path $target){Remove-Item -LiteralPath $target -Recurse -Force}
 Move-Item -LiteralPath $extract -Destination $target
 $installedExe=Get-ChildItem -LiteralPath $target -Recurse -File|Where-Object Name -in @('pdf2zh_next.exe','pdf2zh.exe')|Sort-Object @{Expression={if($_.Name -eq 'pdf2zh_next.exe'){0}else{1}}}|Select-Object -First 1
 $record=[pscustomobject][ordered]@{version=[string]$pin.version;asset=[string]$pin.asset;archive_sha256=$hash;executable_path=$installedExe.FullName;executable_sha256=(Get-FileHash $installedExe.FullName -Algorithm SHA256).Hash.ToLowerInvariant();installed_at=[DateTime]::UtcNow.ToString('o');upstream=[string]$pin.upstream;license=[string]$pin.license}
 [IO.File]::WriteAllText($recordPath,($record|ConvertTo-Json -Depth 10),(New-Object Text.UTF8Encoding($false)))
 $record;exit 0
}catch{Write-Error $_.Exception.Message;exit 1}finally{if($download -and (Test-Path $download)){Remove-Item -LiteralPath $download -Force};if($extract -and (Test-Path $extract)){Remove-Item -LiteralPath $extract -Recurse -Force}}
