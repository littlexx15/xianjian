# Template-first planning. Category order is part of the template, never re-sorted.
function Get-MixerTemplates {
    $rows=@(
        'personHook,product,personTalk',
        'personHook,personTalk',
        'personHook,product',
        'product,personTalk',
        'fruitHook,product,personTalk',
        'fruitHook,product',
        'fruitHook,personTalk',
        'personHook,fruitHook,product,personTalk',
        'personHook,product,personTalk,fruitHook',
        'personHook,product,fruitHook'
    )
    for($i=0;$i -lt $rows.Count;$i++){
        [pscustomobject]@{id=('T{0:00}' -f ($i+1));categories=@($rows[$i].Split(','))}
    }
}

function Get-AvailableMixerTemplates([hashtable]$Counts) {
    $available=@($Counts.Keys | Where-Object {[int]$Counts[$_] -gt 0})
    if($available.Count -eq 1){
        return [pscustomobject]@{id='SINGLE';categories=@($available[0])}
    }
    $templates=@(Get-MixerTemplates | Where-Object {
        $missing=@($_.categories | Where-Object {-not $Counts.ContainsKey($_) -or [int]$Counts[$_] -eq 0})
        $missing.Count -eq 0
    })
    if($templates.Count -eq 0 -and $available.Count -eq 2){
        return [pscustomobject]@{id='PAIR';categories=@('personHook','fruitHook')}
    }
    return $templates
}

function New-TemplateCatalog {
    param([hashtable]$Pools,[hashtable]$CategoryMap,[hashtable]$Params,[Random]$Random,[int]$LimitPerTemplate=3000)
    $counts=@{};foreach($key in $Pools.Keys){$counts[$key]=@($Pools[$key]).Count}
    $templates=@(Get-AvailableMixerTemplates $counts)
    if(-not $templates.Count){throw '没有素材可用于组合。'}
    $single=($templates[0].id -eq 'SINGLE')
    if($single -and (-not $Params.ContainsKey('allowSingle') -or -not $Params.allowSingle)){
        throw '只有一种素材类别，不能跨类搭配。请补充素材，或明确确认生成单类型视频。'
    }
    $all=[Collections.Generic.List[object]]::new();$sampled=$false
    foreach($template in $templates){
        $options=@{};$invalid=$false
        foreach($category in $template.categories){
            $valid=@($Pools[$category] | Where-Object {$_.duration -gt 0} | Sort-Object {$Random.NextDouble()})
            if(-not $valid.Count){$invalid=$true;break}
            $options[$category]=$valid
        }
        if($invalid){continue}
        $found=[Collections.Generic.List[object]]::new()
        function Visit-Template([int]$index,[object[]]$clips,[double]$duration){
            if($found.Count -ge $LimitPerTemplate){return}
            if($index -eq $template.categories.Count){
                $fp=Get-ComboFingerprint $clips
                $names=@($template.categories|ForEach-Object{$CategoryMap[$_].name})
                $found.Add([pscustomobject]@{templateId=$template.id;templateName=($names -join ' → ');clips=@($clips);duration=$duration;fingerprint=$fp})
                return
            }
            $category=$template.categories[$index]
            foreach($clip in $options[$category]){
                if($found.Count -ge $LimitPerTemplate){break}
                if(@($clips|Where-Object{$_.path -eq $clip.path}).Count){continue}
                $next=$duration+[double]$clip.duration
                Visit-Template ($index+1) (@($clips)+@($clip)) $next
            }
        }
        Visit-Template 0 @() 0.0
        if($found.Count -ge $LimitPerTemplate){$sampled=$true}
        foreach($plan in $found){$all.Add($plan)}
    }
    if(-not $all.Count){throw '没有可用的完整素材组合，请检查素材是否有效，以及不同类别是否选用了同一个文件。'}
    $plans=@($all)
    [pscustomobject]@{plans=$plans;single=$single;sampled=$sampled;templateCount=@($plans.templateId|Select-Object -Unique).Count;combinationCount=@($plans.fingerprint|Select-Object -Unique).Count}
}

function Select-TemplateVideoPlan {
    param($Catalog,[hashtable]$TemplateCounts,[hashtable]$ComboCounts,[hashtable]$UseCounts,[Random]$Random)
    # Balanced structures first, then material usage, then combination reuse.
    # Duration is informational only. Only the accepted plan updates counters.
    $ids=@($Catalog.plans.templateId|Select-Object -Unique)
    $minimum=($ids|ForEach-Object{Get-UseCount $TemplateCounts $_}|Measure-Object -Minimum).Minimum
    $eligible=@($ids|Where-Object{(Get-UseCount $TemplateCounts $_) -eq $minimum})
    $id=$eligible[$Random.Next($eligible.Count)]
    $candidates=@($Catalog.plans|Where-Object{$_.templateId -eq $id})
    $ranked=@($candidates|ForEach-Object{
        $usage=0;foreach($clip in $_.clips){$usage+=Get-UseCount $UseCounts $clip.path}
        [pscustomobject]@{plan=$_;reuse=(Get-UseCount $ComboCounts $_.fingerprint);usage=$usage;tie=$Random.NextDouble()}
    }|Sort-Object usage,reuse,tie)
    $best=$ranked[0];$plan=$best.plan
    $TemplateCounts[$id]=(Get-UseCount $TemplateCounts $id)+1
    $ComboCounts[$plan.fingerprint]=$best.reuse+1
    foreach($clip in $plan.clips){$UseCounts[$clip.path]=(Get-UseCount $UseCounts $clip.path)+1}
    [pscustomobject]@{clips=@($plan.clips);templateId=$id;templateName=$plan.templateName;duration=$plan.duration;reuseCount=$best.reuse;fingerprint=$plan.fingerprint}
}

function Get-TemplateCapacity([hashtable]$Counts){
    $seen=@{};$total=0.0;$templates=@(Get-AvailableMixerTemplates $Counts)
    foreach($template in $templates){
        # T08 and T09 have identical content sets: count once for content capacity.
        $key=(@($template.categories|Sort-Object)-join '|')
        if($seen.ContainsKey($key)){continue};$seen[$key]=$true;$n=1.0
        foreach($category in $template.categories){$n*=[double]$Counts[$category]};$total+=$n
    }
    [pscustomobject]@{templates=$templates.Count;combinations=$total}
}
