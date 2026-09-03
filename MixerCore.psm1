Set-StrictMode -Version 2

function New-Category {
    param([string]$Id,[string]$Name,[string]$Layer,[double]$BaseWeight,[double]$Jitter,[double]$TargetLufs)
    [pscustomobject]@{ id=$Id; name=$Name; layer=$Layer; baseWeight=$BaseWeight; jitter=$Jitter; targetLufs=$TargetLufs }
}

function Get-DefaultCategories {
    @(
        New-Category 'personHook' '人物出镜' 'hook' 0 5 -16
        New-Category 'fruitHook'  '水果特写' 'hook' 15 5 -19
        New-Category 'product'    '产品展示' 'body' 50 12 -16
        New-Category 'personTalk' '人物口播' 'body' 70 12 -16
    )
}

function Get-UseCount([hashtable]$UseCounts,[string]$Path) {
    if ($UseCounts.ContainsKey($Path)) { return [int]$UseCounts[$Path] }
    return 0
}

function Select-WeightedClip {
    param([object[]]$Pool,[hashtable]$UseCounts,[System.Random]$Random)
    if (-not $Pool -or $Pool.Count -eq 0) { return $null }
    $weights=@($Pool | ForEach-Object { 1.0 / (1.0 + (Get-UseCount $UseCounts $_.path)) })
    $total=($weights | Measure-Object -Sum).Sum
    $needle=$Random.NextDouble()*$total; $running=0.0
    for($i=0;$i -lt $Pool.Count;$i++) { $running += $weights[$i]; if($needle -le $running){ return $Pool[$i] } }
    return $Pool[-1]
}

function Sort-MixerClips {
    param([object[]]$Clips,[hashtable]$CategoryMap,[System.Random]$Random,[bool]$AvoidAdjacent=$true)
    $ordered=@($Clips | ForEach-Object {
        $cat=$CategoryMap[$_.category]
        $_ | Add-Member -NotePropertyName orderKey -NotePropertyValue ($cat.baseWeight + (($Random.NextDouble()*2-1)*$cat.jitter)) -Force
        $_
    } | Sort-Object orderKey)
    if(-not $AvoidAdjacent){ return $ordered }
    $bodyPositions=@();$body=[Collections.ArrayList]::new()
    for($x=0;$x -lt $ordered.Count;$x++){if($CategoryMap[$ordered[$x].category].layer -eq 'body'){$bodyPositions+=$x;$null=$body.Add($ordered[$x])}}
    for($i=1;$i -lt $body.Count;$i++) {
        if($body[$i].category -eq $body[$i-1].category) {
            $swap=-1
            for($j=$i+1;$j -lt $body.Count;$j++){ if($body[$j].category -ne $body[$i-1].category){$swap=$j;break} }
            if($swap -ge 0){$tmp=$body[$i];$body[$i]=$body[$swap];$body[$swap]=$tmp}
        }
    }
    for($x=0;$x -lt $bodyPositions.Count;$x++){$ordered[$bodyPositions[$x]]=$body[$x]}
    return $ordered
}

function Get-ComboFingerprint([object[]]$Clips) {
    $joined=(@($Clips.path | Sort-Object) -join '|')
    $md5=[Security.Cryptography.MD5]::Create()
    try { ([BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($joined)))).Replace('-','').ToLowerInvariant() }
    finally { $md5.Dispose() }
}

function Select-MixerClips {
    param([hashtable]$Pools,[hashtable]$CategoryMap,[hashtable]$Params,[hashtable]$UseCounts,[System.Random]$Random)
    $selected=[Collections.ArrayList]::new()
    $availableHook=[Collections.ArrayList]@($Pools.Values | ForEach-Object {$_} | Where-Object {$CategoryMap[$_.category].layer -eq 'hook'})
    $availableBody=[Collections.ArrayList]@($Pools.Values | ForEach-Object {$_} | Where-Object {$CategoryMap[$_.category].layer -eq 'body'})
    $hookUpper=[Math]::Min([int]$Params.hookMax,$availableHook.Count)
    $hookLower=[Math]::Min([int]$Params.hookMin,$hookUpper)
    $hookCount=if($hookUpper -ge $hookLower){$Random.Next($hookLower,$hookUpper+1)}else{0}
    for($i=0;$i -lt $hookCount;$i++){
        $c=Select-WeightedClip @($availableHook) $UseCounts $Random
        if($null -eq $c){break};$null=$selected.Add($c);$availableHook.Remove($c)
    }
    $total=0.0;foreach($chosen in $selected){$total += [double]$chosen.duration}
    $bodyMax=[Math]::Min([int]$Params.bodyMax,$availableBody.Count)
    $bodyMin=[Math]::Min([int]$Params.bodyMin,$bodyMax)
    $tries=0
    while($availableBody.Count -gt 0 -and $selected.Count -lt ($hookCount+$bodyMax) -and $tries -lt 20){
        $tries++
        $c=Select-WeightedClip @($availableBody) $UseCounts $Random
        $availableBody.Remove($c)
        $bodyNow=@($selected | Where-Object {$CategoryMap[$_.category].layer -eq 'body'}).Count
        $would=$total+[double]$c.duration
        if($would -le [double]$Params.durationMax){$null=$selected.Add($c);$total=$would}
        $bodyNow=@($selected | Where-Object {$CategoryMap[$_.category].layer -eq 'body'}).Count
        if($total -ge [double]$Params.durationMin -and $bodyNow -ge $bodyMin){break}
    }
    if(@($selected | Where-Object {$CategoryMap[$_.category].layer -eq 'body'}).Count -lt $bodyMin){return @()}
    return @(Sort-MixerClips @($selected) $CategoryMap $Random ([bool]$Params.avoidAdjacent))
}

function Build-MixerVideoPlan {
    param([hashtable]$Pools,[hashtable]$CategoryMap,[hashtable]$Params,[hashtable]$ComboCounts,[hashtable]$UseCounts,[System.Random]$Random,[int]$CandidateCount=30)
    $candidates=[Collections.ArrayList]::new()
    for($i=0;$i -lt $CandidateCount;$i++){
        $clips=@(Select-MixerClips $Pools $CategoryMap $Params $UseCounts $Random)
        if(-not $clips.Count){continue}
        $fp=Get-ComboFingerprint $clips
        $reuse=if($ComboCounts.ContainsKey($fp)){[int]$ComboCounts[$fp]}else{0}
        $usage=($clips | ForEach-Object {Get-UseCount $UseCounts $_.path} | Measure-Object -Sum).Sum
        $null=$candidates.Add([pscustomobject]@{reuse=$reuse;usage=$usage;fingerprint=$fp;clips=$clips})
        if($reuse -eq 0){break}
    }
    if(-not $candidates.Count){throw '素材不足，无法组成任何合法片段组合。'}
    $best=$candidates | Sort-Object reuse,usage | Select-Object -First 1
    $ComboCounts[$best.fingerprint]=[int]$best.reuse+1
    foreach($c in $best.clips){$UseCounts[$c.path]=(Get-UseCount $UseCounts $c.path)+1}
    [pscustomobject]@{clips=@($best.clips);reuseCount=[int]$best.reuse;fingerprint=$best.fingerprint}
}

function Get-MaxCombinationEstimate {
    param([hashtable]$Counts,[int]$HookMin,[int]$HookMax,[int]$BodyMin,[int]$BodyMax)
    function Comb([int]$n,[int]$k){if($k -lt 0 -or $k -gt $n){return 0L};if($k -eq 0 -or $k -eq $n){return 1L};$k=[Math]::Min($k,$n-$k);$r=1L;for($i=1;$i -le $k;$i++){$r=[long]($r*($n-$k+$i)/$i)};return $r}
    $h=[int]$Counts.personHook+[int]$Counts.fruitHook;$b=[int]$Counts.product+[int]$Counts.personTalk;$total=0L
    for($hk=$HookMin;$hk -le $HookMax;$hk++){for($bk=$BodyMin;$bk -le $BodyMax;$bk++){$total += (Comb $h $hk)*(Comb $b $bk)}}
    return $total
}

. (Join-Path $PSScriptRoot 'TemplatePlanner.ps1')
Export-ModuleMember -Function Get-DefaultCategories,Sort-MixerClips,Get-ComboFingerprint,Select-MixerClips,Build-MixerVideoPlan,Get-MaxCombinationEstimate,Get-MixerTemplates,Get-AvailableMixerTemplates,New-TemplateCatalog,Select-TemplateVideoPlan,Get-TemplateCapacity
