$ErrorActionPreference='Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'MixerCore.psm1') -Force -DisableNameChecking
function Assert($test,$message){if(-not $test){throw "FAIL: $message"}}
$map=@{};foreach($cat in Get-DefaultCategories){$map[$cat.id]=$cat}
$keys=@('personHook','fruitHook','product','personTalk');$pools=@{}
foreach($key in $keys){$pools[$key]=@(1..2|ForEach-Object{[pscustomobject]@{path="$key-$_.mp4";category=$key;duration=15.0;hasAudio=$true}})}
$params=@{durationMin=1;durationMax=100;allowSingle=$false};$rng=[Random]::new(2026)
$catalog=New-TemplateCatalog $pools $map $params $rng
Assert ($catalog.templateCount -eq 10) 'all ten templates available'
$templates=@{};$combos=@{};$uses=@{}
for($i=0;$i -lt 100;$i++){
    $r=Select-TemplateVideoPlan $catalog $templates $combos $uses $rng
    $expected=@(Get-MixerTemplates|Where-Object{$_.id -eq $r.templateId})[0]
    Assert (($r.clips.category -join ',') -eq ($expected.categories -join ',')) 'exact template order'
    Assert (@($r.clips.path|Select-Object -Unique).Count -eq $r.clips.Count) 'unique files in each video'
    Assert ($r.duration -le 100) 'max duration'
}
Assert (@($templates.Keys).Count -eq 10) 'all structures rotated'
Assert ((($templates.Values|Measure-Object -Maximum).Maximum - ($templates.Values|Measure-Object -Minimum).Minimum) -le 1) 'balanced template reuse'
# Every nonempty category subset: multi-category never silently falls to single.
for($mask=1;$mask -lt 16;$mask++){
    $sub=@{};$active=0
    for($i=0;$i -lt 4;$i++){if($mask -band (1 -shl $i)){$sub[$keys[$i]]=$pools[$keys[$i]];$active++}else{$sub[$keys[$i]]=@()}}
    if($active -eq 1){$blocked=$false;try{$null=New-TemplateCatalog $sub $map $params $rng}catch{$blocked=$true};Assert $blocked 'single category requires consent';continue}
    $c=New-TemplateCatalog $sub $map $params $rng
    foreach($p in $c.plans){Assert ($p.clips.Count -ge 2) 'no single-category fallback';foreach($clip in $p.clips){Assert (@($sub[$clip.category]).Count -gt 0) 'no missing category selected'}}
}
$pair=@{personHook=@();fruitHook=$pools.fruitHook;product=@();personTalk=$pools.personTalk}
$c=New-TemplateCatalog $pair $map $params $rng
Assert ($c.templateCount -eq 1 -and $c.combinationCount -eq 4) 'fruit plus talk has exactly four combinations'
$tc=@{};$cc=@{};$uc=@{}
1..8|ForEach-Object{$r=Select-TemplateVideoPlan $c $tc $cc $uc $rng;Assert (($r.clips.category-join ',') -eq 'fruitHook,personTalk') 'never all people'}
Assert (@($cc.Values|Where-Object{$_ -ne 2}).Count -eq 0) 'pair combinations reused twice each'
$over=New-TemplateCatalog $pair $map @{durationMin=5;durationMax=20} $rng;Assert ($over.combinationCount -eq 4) 'above reference max retained'
$short=New-TemplateCatalog $pair $map @{durationMin=40;durationMax=45} $rng;Assert ($short.combinationCount -eq 4) 'below reference min retained'
$narrow=New-TemplateCatalog $pools $map @{durationMin=1;durationMax=35} $rng
Assert ($narrow.templateCount -eq 10) 'reference duration never filters templates'
# Regression: real user durations formerly retained only three pairs with one speaker.
$realPair=@{fruitHook=@();personTalk=@()}
$i=0;foreach($d in @(11.05,15.07,15.07,15.07)){$realPair.fruitHook+= [pscustomobject]@{path="fruit-$i.mp4";category='fruitHook';duration=$d};$i++}
$i=0;foreach($d in @(12.28,9.15,13.44,13.72,12.42,15.07)){$realPair.personTalk+= [pscustomobject]@{path="talk-$i.mp4";category='personTalk';duration=$d};$i++}
foreach($seed in 1..30){
    $random=[Random]::new($seed)
    $real=New-TemplateCatalog $realPair $map @{durationMin=30;durationMax=45} $random
    Assert ($real.combinationCount -eq 24) 'all 24 real pairs retained'
    $tc=@{};$cc=@{};$uc=@{};$talks=@();$fruits=@()
    foreach($n in 1..6){
        $r=Select-TemplateVideoPlan $real $tc $cc $uc $random
        $talks+=$r.clips[1].path
        if($n -le 4){$fruits+=$r.clips[0].path}
        Assert ($r.duration -eq ($r.clips[0].duration+$r.clips[1].duration)) 'complete original durations'
    }
    Assert (@($talks|Select-Object -Unique).Count -eq 6) 'six different speakers before reuse'
    Assert (@($fruits|Select-Object -Unique).Count -eq 4) 'four different fruit clips before reuse'
}
$capacity=Get-TemplateCapacity @{personHook=1;fruitHook=1;product=1;personTalk=1}
Assert ($capacity.templates -eq 10 -and $capacity.combinations -eq 9) 'same four-file sets counted once'
'TEMPLATE TESTS PASSED: ten templates, 15 subsets, 100 plans, reuse, duration and ordering'
