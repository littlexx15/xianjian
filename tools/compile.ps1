$ErrorActionPreference = 'Stop'
$src = Split-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) -Parent
$outDir = Join-Path $src 'dist'
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
. (Join-Path $src 'tools\ps2exe.ps1')
$inputFile = Join-Path $src '水果混剪器.ps1'
$outputFile = Join-Path $outDir '鲜剪.exe'
$iconFile = Join-Path $src '鲜剪.ico'
Write-Host "Compiling $inputFile -> $outputFile"
Invoke-ps2exe -inputFile $inputFile -outputFile $outputFile -iconFile $iconFile -noConsole -STA -x64 -DPIAware -supportOS -title '鲜剪' -product '鲜剪' -description '水果带货，一键成片' -company '鲜剪' -copyright 'Xiaoxin' -version '1.0.0' -noError
Get-Item $outputFile | Format-List FullName, Length, LastWriteTime
