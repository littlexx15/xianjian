$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$source=Get-Content (Join-Path $root '水果混剪器.ps1') -Raw -Encoding UTF8
$source=$source.Replace('$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path',('$script:Root = '''+$root.Replace("'","''")+''''))
$probe=@'
if(-not $form){throw 'Form missing'}
if(-not $pageMix -or -not $pageEdit){throw 'Two pages required'}
if(-not $btnStart){throw 'Generate button missing'}
if($lists.Count -ne 4){throw 'Four material lists required'}
if(-not $chkPerturb){throw 'Simple variation toggle missing'}
if(-not $btnSettings){throw 'Settings button missing'}
Update-CapacityLabel
if([string]::IsNullOrWhiteSpace($lblCapacity.Text)){throw 'Capacity label empty'}
Write-Output 'GUI CONSTRUCTION PASSED'
$previewTimer.Stop()
$form.Dispose()
'@
$old=@'
try {
    [void]$form.ShowDialog()
} catch {
    $crashFile = Join-Path $script:Root '程序错误日志.txt'
    "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')]`r`n$($_ | Out-String)`r`n$($_.ScriptStackTrace)" | Add-Content -LiteralPath $crashFile -Encoding UTF8
    [Windows.Forms.MessageBox]::Show("程序遇到错误，详情已保存到：`n$crashFile",'程序错误','OK','Error') | Out-Null
}
'@
if($source.IndexOf($old) -lt 0){throw 'Could not locate form startup block for GUI test'}
$source=$source.Replace($old, $probe)
Invoke-Expression $source
