$ErrorActionPreference='Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'MixerCore.psm1') -Force
function Assert($condition,[string]$message){if(-not $condition){throw "ASSERT: $message"}}
$categories=Get-DefaultCategories;$map=@{};foreach($c in $categories){$map[$c.id]=$c}
function Clip($name,$cat,$duration){[pscustomobject]@{path=$name;category=$cat;duration=[double]$duration;hasAudio=$true}}
$pools=@{
 personHook=@((Clip h1 personHook 12),(Clip h2 personHook 14));fruitHook=@()
 product=@((Clip p1 product 25),(Clip p2 product 27));personTalk=@((Clip t1 personTalk 20),(Clip t2 personTalk 22))
}
$params=@{durationMin=40;durationMax=75;hookMin=1;hookMax=1;bodyMin=1;bodyMax=2;avoidAdjacent=$true}
$combos=@{};$uses=@{};$rng=[Random]::new(1234);$fps=@()
for($i=0;$i -lt 10;$i++){$r=Build-MixerVideoPlan $pools $map $params $combos $uses $rng 60;Assert ($r.clips.Count -ge 2) '每条应有钩子和正文';Assert ($map[$r.clips[0].category].layer -eq 'hook') '默认权重下钩子必须在前';Assert (@($r.clips.path|Select-Object -Unique).Count -eq $r.clips.Count) '单条内素材不得重复';$fps+=$r.fingerprint}
Assert (@($fps|Select-Object -Unique).Count -eq 10) '组合容量未耗尽前不得复用组合'
Assert (($combos.Values|Measure-Object -Maximum).Maximum-($combos.Values|Measure-Object -Minimum).Minimum -le 1) '组合复用应均匀'
$onlyBody=@{personHook=@();fruitHook=@();product=$pools.product;personTalk=$pools.personTalk};$r=Build-MixerVideoPlan $onlyBody $map @{durationMin=20;durationMax=70;hookMin=0;hookMax=2;bodyMin=1;bodyMax=2;avoidAdjacent=$true} @{} @{} ([Random]::new(9)) 30;Assert ($r.clips.Count -ge 1) '缺少钩子时应自动降级'
$cap=Get-MaxCombinationEstimate @{personHook=2;fruitHook=0;product=2;personTalk=0} 1 1 1 1;Assert ($cap -eq 4) '2×2 场景组合数应为4'
'ALL TESTS PASSED'
