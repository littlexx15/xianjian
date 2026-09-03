param([string]$ConfigPath = "", [switch]$PreviewCapture)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName WindowsFormsIntegration
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($script:Root)) {
    $script:Root = [AppDomain]::CurrentDomain.BaseDirectory.TrimEnd('\')
}
if ([string]::IsNullOrWhiteSpace($script:Root) -or -not (Test-Path -LiteralPath (Join-Path $script:Root 'MixerCore.psm1'))) {
    try { $script:Root = Split-Path -Parent ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) } catch {}
}
Import-Module (Join-Path $script:Root 'MixerCore.psm1') -Force
$script:ConfigFile = if ($ConfigPath) { $ConfigPath } else { Join-Path $script:Root "混剪配置.json" }
$script:CacheFile = Join-Path $script:Root 'loudnorm_cache.json'
$localFFmpeg = Join-Path $script:Root "ffmpeg.exe"
$systemFFmpeg = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue
$script:FFmpeg = if (Test-Path -LiteralPath $localFFmpeg) { $localFFmpeg } elseif ($systemFFmpeg) { $systemFFmpeg.Source } else { "ffmpeg.exe" }
$script:Running = $false
$script:Categories = @(Get-DefaultCategories)
$script:Types = [ordered]@{}
$script:CategoryMap = @{}
foreach($cat in $script:Categories){$script:Types[$cat.id]=$cat.name;$script:CategoryMap[$cat.id]=$cat}

function New-DefaultConfig {
    [ordered]@{
        ffmpeg = $script:FFmpeg
        output = (Join-Path $script:Root "输出")
        count = 10
        width = 1080
        height = 1920
        fps = 30
        folders = [ordered]@{ personHook=@(); fruitHook=@(); product=@(); personTalk=@() }
        weights = [ordered]@{ personHook=0; fruitHook=15; product=50; personTalk=70 }
        jitters = [ordered]@{ personHook=5; fruitHook=5; product=12; personTalk=12 }
        durationMin=45; durationMax=75; hookMin=0; hookMax=2; bodyMin=1; bodyMax=3
        avoidAdjacent=$true; enablePerturb=$false
        normalizeAudio=$true; speechLufs=-16.0; visualLufs=-19.0; truePeak=-1.5; silenceThreshold=-40.0
    }
}

function Load-Config {
    $cfg = New-DefaultConfig
    if (Test-Path -LiteralPath $script:ConfigFile) {
        try {
            $saved = Get-Content -LiteralPath $script:ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $saved.PSObject.Properties) {
                if($p.Name -in @('folders','weights','jitters')){continue}
                $cfg[$p.Name] = $p.Value
            }
            foreach($key in $script:Types.Keys){
                if($saved.folders -and $saved.folders.PSObject.Properties.Name -contains $key){$cfg.folders[$key]=@($saved.folders.$key)}
                if($saved.weights -and $saved.weights.PSObject.Properties.Name -contains $key){$cfg.weights[$key]=[double]$saved.weights.$key}
                if($saved.jitters -and $saved.jitters.PSObject.Properties.Name -contains $key){$cfg.jitters[$key]=[double]$saved.jitters.$key}
            }
        } catch {}
    }
    return $cfg
}

function Get-ListPaths($list) {
    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($item in $list.Items) {
        if ($item -and $item.Tag -and -not [string]::IsNullOrWhiteSpace([string]$item.Tag)) {
            $paths.Add([string]$item.Tag)
        }
    }
    return @($paths)
}

function Save-Config {
    $cfg = [ordered]@{
        ffmpeg = [string]$script:Settings.ffmpeg
        output = $txtOutput.Text.Trim()
        count = [int]$numCount.Value
        width = [int]$script:Settings.width
        height = [int]$script:Settings.height
        fps = [int]$script:Settings.fps
        folders = [ordered]@{}
        weights=[ordered]@{}; jitters=[ordered]@{}
        durationMin=[double]$script:Settings.durationMin; durationMax=[double]$script:Settings.durationMax
        hookMin=[int]$script:Settings.hookMin; hookMax=[int]$script:Settings.hookMax
        bodyMin=[int]$script:Settings.bodyMin; bodyMax=[int]$script:Settings.bodyMax
        avoidAdjacent=[bool]$script:Settings.avoidAdjacent; enablePerturb=$chkPerturb.Checked
        normalizeAudio=[bool]$script:Settings.normalizeAudio; speechLufs=[double]$script:Settings.speechLufs
        visualLufs=[double]$script:Settings.visualLufs; truePeak=[double]$script:Settings.truePeak; silenceThreshold=[double]$script:Settings.silenceThreshold
    }
    foreach ($key in $script:Types.Keys) {
        $cfg.folders[$key] = @(Get-ListPaths $lists[$key])
        $cfg.weights[$key]=[double]$script:Settings.weights.$key
        $cfg.jitters[$key]=[double]$script:Settings.jitters.$key
    }
    $script:Settings.output=$cfg.output; $script:Settings.count=$cfg.count; $script:Settings.enablePerturb=$cfg.enablePerturb; $script:Settings.folders=$cfg.folders
    $cfg | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:ConfigFile -Encoding UTF8
    return $cfg
}

function Add-Log([string]$text,[Drawing.Color]$color=[Drawing.Color]::Black) {
    if ($txtLog.InvokeRequired) {
        $txtLog.BeginInvoke([Action[string,Drawing.Color]]{ param($s,$c) Add-Log $s $c }, $text,$color) | Out-Null
    } else {
        $txtLog.SelectionStart=$txtLog.TextLength;$txtLog.SelectionColor=$color
        $txtLog.AppendText("[$(Get-Date -Format 'HH:mm:ss')] $text`r`n")
        $txtLog.SelectionColor=[Drawing.Color]::Black
        $txtLog.SelectionStart = $txtLog.TextLength
        $txtLog.ScrollToCaret()
    }
}

function Load-MediaCache {
    $script:MediaCache=@{}
    if(Test-Path -LiteralPath $script:CacheFile){try{$o=Get-Content -LiteralPath $script:CacheFile -Raw -Encoding UTF8|ConvertFrom-Json;foreach($p in $o.PSObject.Properties){$script:MediaCache[$p.Name]=$p.Value}}catch{}}
}
function Save-MediaCache {$script:MediaCache | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:CacheFile -Encoding UTF8}
function Get-CacheKey([string]$file){$i=Get-Item -LiteralPath $file; $raw="$($i.FullName)|$($i.LastWriteTimeUtc.Ticks)|$($i.Length)";$sha=[Security.Cryptography.SHA256]::Create();try{([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($raw)))).Replace('-','')}finally{$sha.Dispose()}}

function Invoke-CapturedProcess([string]$exe,[string[]]$arguments,[bool]$AllowFailure=$false){
    $psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName=$exe;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    $psi.Arguments=($arguments|ForEach-Object{Quote-Arg "$_"})-join' '
    $p=[Diagnostics.Process]::new();$p.StartInfo=$psi;$null=$p.Start();$outTask=$p.StandardOutput.ReadToEndAsync();$errTask=$p.StandardError.ReadToEndAsync()
    while(-not $p.HasExited){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 60};$p.WaitForExit();$out=$outTask.GetAwaiter().GetResult();$err=$errTask.GetAwaiter().GetResult()
    if($p.ExitCode -ne 0 -and -not $AllowFailure){throw (($err -split "`r?`n"|Where-Object{$_}|Select-Object -Last 10)-join"`n")}
    [pscustomobject]@{exitCode=$p.ExitCode;stdout=$out;stderr=$err}
}

function Get-MediaInfo([string]$file){
    $key=Get-CacheKey $file;if($script:MediaCache.ContainsKey($key) -and $script:MediaCache[$key].duration){return $script:MediaCache[$key]}
    $ffprobe=Join-Path (Split-Path -Parent $script:FFmpeg) 'ffprobe.exe';$duration=0.0;$hasAudio=$false
    if(Test-Path -LiteralPath $ffprobe){
        $r=Invoke-CapturedProcess $ffprobe @('-v','error','-show_entries','format=duration','-of','csv=p=0',$file)
        $duration=[double]::Parse($r.stdout.Trim(),[Globalization.CultureInfo]::InvariantCulture)
        $a=Invoke-CapturedProcess $ffprobe @('-v','error','-select_streams','a:0','-show_entries','stream=index','-of','csv=p=0',$file) $true;$hasAudio=-not [string]::IsNullOrWhiteSpace($a.stdout)
    }else{$duration=Get-MediaDuration $file;$hasAudio=Has-Audio $file}
    $info=[pscustomobject]@{duration=$duration;hasAudio=$hasAudio;loudness=$null};$script:MediaCache[$key]=$info;Save-MediaCache;return $info
}

function Get-LoudnessMeasurement([string]$file,[double]$target,[double]$tp){
    $key=Get-CacheKey $file;$info=$script:MediaCache[$key]
    if($info.loudness -and [double]$info.loudness.target -eq $target -and [double]$info.loudness.tp -eq $tp){return $info.loudness}
    if(-not $info.hasAudio){return $null}
    $t=$target.ToString('0.0',[Globalization.CultureInfo]::InvariantCulture);$peak=$tp.ToString('0.0',[Globalization.CultureInfo]::InvariantCulture)
    $r=Invoke-CapturedProcess $script:FFmpeg @('-hide_banner','-i',$file,'-af',"loudnorm=I=$t`:TP=$peak`:LRA=11:print_format=json",'-f','null','-') $true
    $matches=[regex]::Matches($r.stderr,'(?s)\{\s*"input_i".*?\}')
    if(-not $matches.Count){throw "无法解析响度测量结果：$([IO.Path]::GetFileName($file))"}
    $m=$matches[$matches.Count-1].Value|ConvertFrom-Json
    $inputI=if("$($m.input_i)" -match 'inf'){-100.0}else{[double]::Parse($m.input_i,[Globalization.CultureInfo]::InvariantCulture)}
    $measure=[pscustomobject]@{target=$target;tp=$tp;input_i=$inputI;input_tp=$m.input_tp;input_lra=$m.input_lra;input_thresh=$m.input_thresh;target_offset=$m.target_offset}
    $info.loudness=$measure;$script:MediaCache[$key]=$info;Save-MediaCache;return $measure
}

function Get-Videos($folders) {
    $extensions = @(".mp4",".mov",".mkv",".avi",".m4v",".webm",".ts")
    $all = [System.Collections.Generic.List[string]]::new()
    foreach ($dir in @($folders)) {
        if ([string]::IsNullOrWhiteSpace($dir)) { continue }
        if (Test-Path -LiteralPath $dir -PathType Leaf) {
            $item = Get-Item -LiteralPath $dir
            if ($extensions -contains $item.Extension.ToLowerInvariant()) { $all.Add($item.FullName) }
        } elseif (Test-Path -LiteralPath $dir -PathType Container) {
            Get-ChildItem -LiteralPath $dir -File -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $extensions -contains $_.Extension.ToLowerInvariant() } |
                ForEach-Object { $all.Add($_.FullName) }
        }
    }
    return @($all | Select-Object -Unique)
}

function Quote-Arg([string]$value) {
    '"' + $value.Replace('"','\"') + '"'
}

function Run-FFmpeg([string[]]$arguments) {
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $script:FFmpeg
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardError = $true
    $psi.Arguments = ($arguments | ForEach-Object { Quote-Arg "$_" }) -join " "
    $p = [System.Diagnostics.Process]::new()
    $p.StartInfo = $psi
    $null = $p.Start()
    $errorTask = $p.StandardError.ReadToEndAsync()
    while (-not $p.HasExited) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 80
    }
    $p.WaitForExit()
    $errorOutput = $errorTask.GetAwaiter().GetResult()
    if ($p.ExitCode -ne 0) {
        $detail=($errorOutput -split "`r?`n" | Where-Object {$_} | Select-Object -Last 8) -join "`n"
        throw "视频处理失败（代码 $($p.ExitCode)）：`n$detail"
    }
}

function Has-Audio([string]$file) {
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $script:FFmpeg
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardError = $true
    $psi.Arguments = (Quote-Arg "-hide_banner") + " " + (Quote-Arg "-i") + " " + (Quote-Arg $file)
    $p = [System.Diagnostics.Process]::new(); $p.StartInfo = $psi
    $null = $p.Start(); $err = $p.StandardError.ReadToEnd(); $p.WaitForExit()
    return $err -match "Audio:"
}

function Get-MediaDuration([string]$file) {
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $script:FFmpeg
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardError = $true
    $psi.Arguments = (Quote-Arg "-hide_banner") + " " + (Quote-Arg "-i") + " " + (Quote-Arg $file)
    $p = [Diagnostics.Process]::new(); $p.StartInfo = $psi
    $null=$p.Start(); $err=$p.StandardError.ReadToEnd(); $p.WaitForExit()
    if ($err -match "Duration:\s*(\d+):(\d+):([\d.]+)") {
        return ([double]$Matches[1]*3600 + [double]$Matches[2]*60 + [double]::Parse($Matches[3],[Globalization.CultureInfo]::InvariantCulture))
    }
    throw "无法读取视频时长。"
}

function Start-Generation($cfg) {
    try {
        $script:FFmpeg = $cfg.ffmpeg
        if (-not (Test-Path -LiteralPath $script:FFmpeg -PathType Leaf) -and -not (Get-Command $script:FFmpeg -ErrorAction SilentlyContinue)) { throw "找不到 FFmpeg：$script:FFmpeg" }
        if($cfg.durationMin -gt $cfg.durationMax){throw '最短时长不能大于最长时长。'}
        Load-MediaCache
        New-Item -ItemType Directory -Path $cfg.output -Force | Out-Null
        $pools=@{};$counts=@{}
        foreach ($key in $script:Types.Keys) {
            $items=[Collections.ArrayList]::new()
            foreach($file in @(Get-Videos $cfg.folders.$key)){$info=Get-MediaInfo $file;$null=$items.Add([pscustomobject]@{path=$file;category=$key;duration=[double]$info.duration;hasAudio=[bool]$info.hasAudio})}
            $pools[$key]=@($items);$counts[$key]=$items.Count;Add-Log "$($script:Types[$key])：找到 $($items.Count) 个视频"
        }
        if(($counts.Values|Measure-Object -Sum).Sum -eq 0){throw '所有素材类别都为空。'}
        foreach($cat in $script:Categories){$cat.baseWeight=[double]$cfg.weights.$($cat.id);$cat.jitter=[double]$cfg.jitters.$($cat.id);$cat.targetLufs=if($cat.id -eq 'fruitHook'){$cfg.visualLufs}else{$cfg.speechLufs};$script:CategoryMap[$cat.id]=$cat}
        $params=@{durationMin=[double]$cfg.durationMin;durationMax=[double]$cfg.durationMax;allowSingle=$false}
        if(@($counts.Keys|Where-Object{$counts[$_] -gt 0}).Count -eq 1){
            $answer=[Windows.Forms.MessageBox]::Show('当前只有一种素材类别，无法跨类搭配。是否继续生成单类型视频（每条使用一个完整素材）？','单类型确认','YesNo','Warning')
            if($answer -ne 'Yes'){Add-Log '已取消：请添加另一类素材后重试。';return}
            $params.allowSingle=$true
        }
        $rng=[Random]::new();$useCounts=@{};$comboCounts=@{};$templateCounts=@{}
        $catalog=New-TemplateCatalog $pools $script:CategoryMap $params $rng
        Add-Log "按现有类别可用模板：$($catalog.templateCount) 种；候选素材组合：$($catalog.combinationCount) 种。"
        Add-Log "时长 $($cfg.durationMin)–$($cfg.durationMax) 秒仅作参考，不筛除组合、不截短素材；优先轮换结构和素材。"
        if($catalog.sampled){Add-Log '素材组合较多，已建立有界候选池；组合数量为候选池统计，不代表穷尽全部素材组合。'}
        $batch = Get-Date -Format "yyyyMMdd_HHmmss"
        $tempRoot = Join-Path $env:TEMP "fruit_mix_$batch"
        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
        try {
            for ($n=1; $n -le [int]$cfg.count; $n++) {
                $result=Select-TemplateVideoPlan $catalog $templateCounts $comboCounts $useCounts $rng
                $plan=@($result.clips);$perturb=[bool]$cfg.enablePerturb
                if($result.reuseCount -gt 0){
                    Add-Log "⚠ 素材组合复用（第 $($result.reuseCount+1) 次）— 保持模板顺序，画面增强遵循你的开关设置。" ([Drawing.Color]::DarkOrange)
                }
                Add-Log "结构 $($result.templateId)：$($result.templateName) | $([Math]::Round($result.duration,1)) 秒"
                Add-Log "正在生成第 $n/$($cfg.count) 条（$($plan.Count) 个片段）..."
                $work = Join-Path $tempRoot ("job_{0:D3}" -f $n)
                New-Item -ItemType Directory -Path $work -Force | Out-Null
                $parts = [System.Collections.Generic.List[string]]::new()
                $renderedTotal=0.0
                for ($i=0; $i -lt $plan.Count; $i++) {
                    $p=$plan[$i];$cat=$script:CategoryMap[$p.category]
                    $part = Join-Path $work ("part_{0:D3}.mp4" -f $i)
                    $vf="scale=$($cfg.width):$($cfg.height):force_original_aspect_ratio=decrease,pad=$($cfg.width):$($cfg.height):(ow-iw)/2:(oh-ih)/2:color=black,fps=$($cfg.fps),setsar=1"
                    $speed=1.0
                    if($perturb){$speed=0.97+$rng.NextDouble()*0.06;$sat=0.97+$rng.NextDouble()*0.06;$bright=-0.03+$rng.NextDouble()*0.06;$crop=0.98+$rng.NextDouble()*0.01;$vf="crop=iw*$crop`:ih*$crop`:(iw-ow)/2:(ih-oh)/2,scale=$($cfg.width):$($cfg.height):force_original_aspect_ratio=decrease,pad=$($cfg.width):$($cfg.height):(ow-iw)/2:(oh-ih)/2:black,eq=brightness=$($bright.ToString('0.000',[Globalization.CultureInfo]::InvariantCulture)):saturation=$($sat.ToString('0.000',[Globalization.CultureInfo]::InvariantCulture)),setpts=PTS/$($speed.ToString('0.000',[Globalization.CultureInfo]::InvariantCulture)),fps=$($cfg.fps),setsar=1"}
                    $renderedTotal += $p.duration/$speed
                    $audioInfo='无音轨 → 静音轨';$af="atempo=$($speed.ToString('0.000',[Globalization.CultureInfo]::InvariantCulture)),aresample=48000:async=1:first_pts=0"
                    if($p.hasAudio){
                        if($cfg.normalizeAudio){$m=Get-LoudnessMeasurement $p.path $cat.targetLufs $cfg.truePeak;if($m.input_i -lt $cfg.silenceThreshold){$audioInfo="$($m.input_i) LUFS，近静音跳过"}else{$target=([double]$cat.targetLufs).ToString('0.0',[Globalization.CultureInfo]::InvariantCulture);$tp=([double]$cfg.truePeak).ToString('0.0',[Globalization.CultureInfo]::InvariantCulture);$af="loudnorm=I=$target`:TP=$tp`:LRA=11:measured_I=$($m.input_i):measured_TP=$($m.input_tp):measured_LRA=$($m.input_lra):measured_thresh=$($m.input_thresh):offset=$($m.target_offset):linear=true,atempo=$($speed.ToString('0.000',[Globalization.CultureInfo]::InvariantCulture)),aresample=48000";$audioInfo="$($m.input_i) → $target LUFS"}}else{$audioInfo='响度归一化关闭'}
                        Add-Log ("  [{0}] {1,-8} | {2} | {3:N1}s | {4}" -f ($i+1),$cat.name,[IO.Path]::GetFileName($p.path),$p.duration,$audioInfo)
                        Run-FFmpeg @('-y','-hide_banner','-loglevel','error','-i',$p.path,'-map','0:v:0','-map','0:a:0','-vf',$vf,'-af',$af,'-c:v','libx264','-preset','veryfast','-crf','20','-pix_fmt','yuv420p','-c:a','aac','-b:a','128k','-ar','48000','-ac','2',$part)
                    } else {
                        Add-Log ("  [{0}] {1,-8} | {2} | {3:N1}s | {4}" -f ($i+1),$cat.name,[IO.Path]::GetFileName($p.path),$p.duration,$audioInfo)
                        Run-FFmpeg @('-y','-hide_banner','-loglevel','error','-i',$p.path,'-f','lavfi','-i','anullsrc=channel_layout=stereo:sample_rate=48000','-map','0:v:0','-map','1:a:0','-vf',$vf,'-af',$af,'-c:v','libx264','-preset','veryfast','-crf','20','-pix_fmt','yuv420p','-c:a','aac','-b:a','128k','-ar','48000','-ac','2','-shortest',$part)
                    }
                    $parts.Add($part)
                }
                $listFile = Join-Path $work "concat.txt"
                $lines = $parts | ForEach-Object { "file '$($_.Replace("'","'\''"))'" }
                [IO.File]::WriteAllLines($listFile, $lines, [Text.UTF8Encoding]::new($false))
                $outputFile = Join-Path $cfg.output ("水果混剪_{0}_{1:D3}.mp4" -f $batch,$n)
                Run-FFmpeg @("-y","-hide_banner","-loglevel","error","-f","concat","-safe","0","-i",$listFile,"-c","copy","-movflags","+faststart",$outputFile)
                $total=($plan|Measure-Object duration -Sum).Sum
                if($total -lt $cfg.durationMin){Add-Log "⚠ 成片约 $([Math]::Round($total,1)) 秒，未达到最短目标，但已保留完整素材。" ([Drawing.Color]::DarkOrange)}
                Add-Log "完成：$([IO.Path]::GetFileName($outputFile))  总时长约 $([Math]::Round($renderedTotal,1))s"
            }
        } finally {
            if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
        }
        Add-Log "全部完成，输出目录：$($cfg.output)"
        [System.Windows.Forms.MessageBox]::Show("已生成 $($cfg.count) 条视频。`n`n输出目录：$($cfg.output)","完成","OK","Information") | Out-Null
    } catch {
        Add-Log "失败：$($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,"生成失败","OK","Error") | Out-Null
    } finally {
        $script:Running = $false
        $btnStart.Enabled = $true
        $btnStart.Text = "开始生成"
        if($progressBar){$progressBar.Visible=$false}
    }
}

$cfg = Load-Config
$script:Settings = [ordered]@{}
foreach ($k in $cfg.Keys) { $script:Settings[$k] = $cfg[$k] }
$script:CardMeta = [ordered]@{
    personHook = @{ title='人物出镜'; hint='打招呼、人设，适合开头' }
    fruitHook  = @{ title='水果特写'; hint='切开、特写，突出新鲜' }
    product    = @{ title='产品展示'; hint='装箱、摆拍、卖点' }
    personTalk = @{ title='人物口播'; hint='讲价格、促下单' }
}
$script:Theme = @{
    Bg         = [Drawing.Color]::FromArgb(247,241,233)
    Header     = [Drawing.Color]::FromArgb(255,252,248)
    Card       = [Drawing.Color]::White
    Ink        = [Drawing.Color]::FromArgb(45,36,28)
    Mute       = [Drawing.Color]::FromArgb(138,122,108)
    Line       = [Drawing.Color]::FromArgb(232,220,206)
    Accent     = [Drawing.Color]::FromArgb(226,87,43)
    AccentDark = [Drawing.Color]::FromArgb(196,64,28)
    Sage       = [Drawing.Color]::FromArgb(47,143,98)
    Soft       = [Drawing.Color]::FromArgb(255,244,236)
    Danger     = [Drawing.Color]::FromArgb(255,236,232)
}
$fontUi    = New-Object Drawing.Font('Microsoft YaHei UI', 9.5)
$fontSmall = New-Object Drawing.Font('Microsoft YaHei UI', 8.5)
$fontTitle = New-Object Drawing.Font('Microsoft YaHei UI', 12, [Drawing.FontStyle]::Bold)
$fontBrand = New-Object Drawing.Font('Microsoft YaHei UI', 18, [Drawing.FontStyle]::Bold)
$fontCta   = New-Object Drawing.Font('Microsoft YaHei UI', 12, [Drawing.FontStyle]::Bold)
$fontNav   = New-Object Drawing.Font('Microsoft YaHei UI', 10)

function Set-RoundCorners([Windows.Forms.Control]$control, [int]$radius=14) {
    $w = $control.Width; $h = $control.Height
    if ($w -lt 8 -or $h -lt 8) { return }
    $path = New-Object Drawing.Drawing2D.GraphicsPath
    $d = [Math]::Min($radius * 2, [Math]::Min($w,$h) - 1)
    $path.AddArc(0,0,$d,$d,180,90)
    $path.AddArc($w-$d,0,$d,$d,270,90)
    $path.AddArc($w-$d,$h-$d,$d,$d,0,90)
    $path.AddArc(0,$h-$d,$d,$d,90,90)
    $path.CloseFigure()
    $old = $control.Region
    $control.Region = New-Object Drawing.Region($path)
    if ($old) { $old.Dispose() }
    $path.Dispose()
}

function New-FlatButton([string]$text, $back, $fore) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $text
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.BackColor = $back
    $b.ForeColor = $fore
    $b.Cursor = 'Hand'
    $b.Font = $fontUi
    $b.UseVisualStyleBackColor = $false
    return $b
}

function Add-MaterialPath($list, [string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) { return }
    $full = [IO.Path]::GetFullPath($path)
    foreach ($item in $list.Items) { if ([string]$item.Tag -eq $full) { return } }
    $isDir = Test-Path -LiteralPath $full -PathType Container
    $name = [IO.Path]::GetFileName($full)
    if ($isDir) { $name = $name + '\' }
    $item = New-Object Windows.Forms.ListViewItem($name)
    $item.Tag = $full
    $item.ToolTipText = $full
    $null = $list.Items.Add($item)
}

function Update-MaterialCard([string]$key) {
    $n = @(Get-Videos (Get-ListPaths $lists[$key])).Count
    $countLabels[$key].Text = "$n"
    $countLabels[$key].ForeColor = if ($n -gt 0) { $script:Theme.Sage } else { $script:Theme.Mute }
    $emptyLabels[$key].Visible = ($lists[$key].Items.Count -eq 0)
    if ($removeButtons.ContainsKey($key)) { $removeButtons[$key].Visible = ($lists[$key].Items.Count -gt 0) }
    if ($clearButtons.ContainsKey($key)) { $clearButtons[$key].Visible = ($lists[$key].Items.Count -gt 0) }
    Update-CapacityLabel
}

function Show-AddMenu([Windows.Forms.Control]$anchor, [string]$key) {
    $menu = New-Object Windows.Forms.ContextMenuStrip
    $menu.Font = $fontUi
    $null = $menu.Items.Add('添加文件夹')
    $null = $menu.Items.Add('添加视频')
    $menu.Items[0].Add_Click({
        $dlg = New-Object Windows.Forms.FolderBrowserDialog
        $dlg.Description = "选择$($script:CardMeta[$key].title)文件夹"
        if ($dlg.ShowDialog() -eq 'OK') { Add-MaterialPath $lists[$key] $dlg.SelectedPath; Update-MaterialCard $key }
    }.GetNewClosure())
    $menu.Items[1].Add_Click({
        $dlg = New-Object Windows.Forms.OpenFileDialog
        $dlg.Title = "选择$($script:CardMeta[$key].title)视频"
        $dlg.Filter = "视频文件|*.mp4;*.mov;*.mkv;*.avi;*.m4v;*.webm;*.ts|所有文件|*.*"
        $dlg.Multiselect = $true
        if ($dlg.ShowDialog() -eq 'OK') {
            foreach ($file in $dlg.FileNames) { Add-MaterialPath $lists[$key] $file }
            Update-MaterialCard $key
        }
    }.GetNewClosure())
    $menu.Show($anchor, 0, $anchor.Height)
}

function New-MaterialCard([string]$key) {
    $meta = $script:CardMeta[$key]
    $card = New-Object Windows.Forms.Panel
    $card.BackColor = $script:Theme.Card
    $card.Dock = 'Fill'
    $card.Margin = New-Object Windows.Forms.Padding(8)
    $card.Padding = New-Object Windows.Forms.Padding(16,14,16,12)
    $card.Add_Resize({ Set-RoundCorners $this 16 })

    $title = New-Object Windows.Forms.Label
    $title.Text = $meta.title
    $title.Font = $fontTitle
    $title.ForeColor = $script:Theme.Ink
    $title.AutoSize = $false
    $title.SetBounds(16,12,170,28)

    $count = New-Object Windows.Forms.Label
    $count.Text = '0'
    $count.Font = $fontTitle
    $count.ForeColor = $script:Theme.Mute
    $count.TextAlign = 'MiddleRight'
    $count.Anchor = 'Top,Right'
    $count.SetBounds(200,12,70,28)
    $countLabels[$key] = $count

    $hint = New-Object Windows.Forms.Label
    $hint.Text = $meta.hint
    $hint.Font = $fontSmall
    $hint.ForeColor = $script:Theme.Mute
    $hint.SetBounds(16,40,250,22)

    $list = New-Object Windows.Forms.ListView
    $list.View = 'Details'
    $list.HeaderStyle = 'None'
    $list.FullRowSelect = $true
    $list.MultiSelect = $true
    $list.BorderStyle = 'None'
    $list.BackColor = $script:Theme.Card
    $list.ShowItemToolTips = $true
    $list.HideSelection = $false
    $list.Anchor = 'Top,Bottom,Left,Right'
    $list.SetBounds(12,68,250,90)
    $null = $list.Columns.Add('name', 240)
    $list.Tag = $key
    $list.AllowDrop = $true
    $list.Add_Resize({ if ($this.Columns.Count) { $this.Columns[0].Width = [Math]::Max(80, $this.ClientSize.Width - 8) } })
    $list.Add_DragEnter({
        if ($_.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) { $_.Effect = 'Copy' }
    })
    $list.Add_DragDrop({
        $k = $this.Tag
        foreach ($p in @($_.Data.GetData([Windows.Forms.DataFormats]::FileDrop))) { Add-MaterialPath $lists[$k] $p }
        Update-MaterialCard $k
    })
    $list.Add_KeyDown({
        if ($_.Control -and $_.KeyCode -eq 'A') {
            foreach ($item in $this.Items) { $item.Selected = $true }
            $_.SuppressKeyPress = $true
        } elseif ($_.KeyCode -eq 'Delete') {
            while ($this.SelectedItems.Count) { $this.SelectedItems[0].Remove() }
            Update-MaterialCard $this.Tag
            $_.SuppressKeyPress = $true
        }
    })
    $empty = New-Object Windows.Forms.Label
    $empty.Text = '拖入视频，或点添加'
    $empty.Font = $fontSmall
    $empty.ForeColor = $script:Theme.Mute
    $empty.TextAlign = 'MiddleCenter'
    $empty.Anchor = 'Top,Bottom,Left,Right'
    $empty.SetBounds(12,88,250,40)
    $emptyLabels[$key] = $empty

    $btnAdd = New-FlatButton '添加' $script:Theme.Soft $script:Theme.Accent
    $btnAdd.Anchor = 'Bottom,Left'
    $btnAdd.SetBounds(16,168,72,30)
    $btnAdd.Tag = $key
    $btnAdd.Add_Click({ Show-AddMenu $this $this.Tag })

    $btnRemove = New-FlatButton '删除' $script:Theme.Card $script:Theme.Mute
    $btnRemove.Anchor = 'Bottom,Left'
    $btnRemove.SetBounds(94,168,72,30)
    $btnRemove.Tag = $key
    $btnRemove.Visible = $false
    $btnRemove.Add_Click({
        $lv = $lists[$this.Tag]
        while ($lv.SelectedItems.Count) { $lv.SelectedItems[0].Remove() }
        Update-MaterialCard $this.Tag
    })

    $btnClear = New-FlatButton '清空' $script:Theme.Card $script:Theme.Mute
    $btnClear.Anchor = 'Bottom,Right'
    $btnClear.SetBounds(188,168,72,30)
    $btnClear.Tag = $key
    $btnClear.Visible = $false
    $btnClear.Add_Click({
        if ($lists[$this.Tag].Items.Count -eq 0) { return }
        $answer = [Windows.Forms.MessageBox]::Show("清空「$($script:CardMeta[$this.Tag].title)」里的素材？",'确认','YesNo','Question')
        if ($answer -eq 'Yes') { $lists[$this.Tag].Items.Clear(); Update-MaterialCard $this.Tag }
    })

    $removeButtons[$key] = $btnRemove
    $clearButtons[$key] = $btnClear
    $card.Controls.AddRange(@($title,$count,$hint,$list,$empty,$btnAdd,$btnRemove,$btnClear))
    $card.Add_Resize({
        $c = $this
        $lv = $c.Controls | Where-Object { $_ -is [Windows.Forms.ListView] } | Select-Object -First 1
        $add = $c.Controls | Where-Object { $_ -is [Windows.Forms.Button] -and $_.Text -eq '添加' }
        $lv.SetBounds(12,68, $c.Width-24, $c.Height-118)
        $emptyLabels[$lv.Tag].SetBounds(12, [int](($c.Height-118)/2 + 48), $c.Width-24, 36)
        $add.Top = $c.Height - 44
        ($c.Controls | Where-Object { $_.Text -eq '删除' }).Top = $add.Top
        $clr = $c.Controls | Where-Object { $_.Text -eq '清空' }
        $clr.Top = $add.Top
        $clr.Left = $c.Width - 88
        $countLabels[$lv.Tag].Left = $c.Width - 90
        $countLabels[$lv.Tag].Width = 70
    })
    $lists[$key] = $list
    foreach ($v in @($cfg.folders.$key)) { Add-MaterialPath $list "$v" }
    return $card
}

function Show-SettingsDialog {
    $d = New-Object Windows.Forms.Form
    $d.Text = '设置'
    $d.Size = New-Object Drawing.Size(520,360)
    $d.StartPosition = 'CenterParent'
    $d.Font = $fontUi
    $d.BackColor = $script:Theme.Header
    $d.FormBorderStyle = 'FixedDialog'
    $d.MaximizeBox = $false
    $d.MinimizeBox = $false

    $l1 = New-Object Windows.Forms.Label; $l1.Text='成片尺寸'; $l1.SetBounds(28,28,90,28); $d.Controls.Add($l1)
    $cmb = New-Object Windows.Forms.ComboBox
    $cmb.DropDownStyle = 'DropDownList'
    $cmb.Items.AddRange(@('抖音竖屏  1080 × 1920','高清竖屏  720 × 1280','保持当前尺寸'))
    $cmb.SetBounds(130,26,330,30)
    if ($script:Settings.width -eq 1080 -and $script:Settings.height -eq 1920) { $cmb.SelectedIndex = 0 }
    elseif ($script:Settings.width -eq 720 -and $script:Settings.height -eq 1280) { $cmb.SelectedIndex = 1 }
    else { $cmb.SelectedIndex = 2 }
    $d.Controls.Add($cmb)

    $n = New-Object Windows.Forms.CheckBox
    $n.Text = '自动统一音量（推荐保持开启）'
    $n.Checked = [bool]$script:Settings.normalizeAudio
    $n.SetBounds(28,84,360,28)
    $d.Controls.Add($n)

    $l2 = New-Object Windows.Forms.Label; $l2.Text='FFmpeg'; $l2.SetBounds(28,138,90,28); $d.Controls.Add($l2)
    $f = New-Object Windows.Forms.TextBox
    $f.Text = [string]$script:Settings.ffmpeg
    $f.SetBounds(130,136,250,30)
    $d.Controls.Add($f)
    $bf = New-FlatButton '浏览' $script:Theme.Soft $script:Theme.Ink
    $bf.SetBounds(390,134,70,32)
    $bf.Add_Click({ $dlg=New-Object Windows.Forms.OpenFileDialog; $dlg.Filter='ffmpeg.exe|ffmpeg.exe|程序|*.exe'; if($dlg.ShowDialog()-eq'OK'){ $f.Text=$dlg.FileName } })
    $d.Controls.Add($bf)

    $info = New-Object Windows.Forms.Label
    $info.Text = '结构搭配、轮换和音量参数都由程序自动处理，日常使用不用改这里。'
    $info.ForeColor = $script:Theme.Mute
    $info.SetBounds(28,188,440,40)
    $d.Controls.Add($info)

    $ok = New-FlatButton '完成' $script:Theme.Accent ([Drawing.Color]::White)
    $ok.SetBounds(180,250,140,40)
    $ok.Font = $fontNav
    $ok.Add_Click({
        switch ($cmb.SelectedIndex) {
            0 { $script:Settings.width=1080; $script:Settings.height=1920; $script:Settings.fps=30 }
            1 { $script:Settings.width=720; $script:Settings.height=1280; $script:Settings.fps=30 }
        }
        $script:Settings.normalizeAudio = $n.Checked
        $script:Settings.ffmpeg = $f.Text.Trim()
        $d.DialogResult = 'OK'
        $d.Close()
    })
    $d.Controls.Add($ok)
    [void]$d.ShowDialog($form)
}

$form = New-Object Windows.Forms.Form
$form.Text = '鲜剪'
$form.Size = New-Object Drawing.Size(1120,760)
$form.MinimumSize = New-Object Drawing.Size(980,680)
$form.StartPosition = 'CenterScreen'
$form.Font = $fontUi
$form.BackColor = $script:Theme.Bg
$form.ForeColor = $script:Theme.Ink
$iconPath = Join-Path $script:Root '水果混剪器.ico'
if (-not (Test-Path -LiteralPath $iconPath)) { $iconPath = Join-Path $script:Root '鲜剪.ico' }
if (Test-Path -LiteralPath $iconPath) { try { $form.Icon = New-Object Drawing.Icon($iconPath) } catch {} }

$header = New-Object Windows.Forms.Panel
$header.Dock = 'Top'
$header.Height = 68
$header.BackColor = $script:Theme.Header
$header.Add_Paint({
    $pen = New-Object Drawing.Pen $script:Theme.Line
    $_.Graphics.DrawLine($pen, 0, $this.Height-1, $this.Width, $this.Height-1)
    $pen.Dispose()
})

$pic = New-Object Windows.Forms.PictureBox
$pic.SetBounds(18,14,40,40)
$pic.SizeMode = 'Zoom'
$logoPng = Join-Path $script:Root '水果混剪器-logo.png'
if (-not (Test-Path -LiteralPath $logoPng)) { $logoPng = Join-Path $script:Root '鲜剪-logo.png' }
if (Test-Path -LiteralPath $logoPng) { try { $pic.Image = [Drawing.Image]::FromFile($logoPng) } catch {} }
$header.Controls.Add($pic)

$brand = New-Object Windows.Forms.Label
$brand.Text = '鲜剪'
$brand.Font = $fontBrand
$brand.ForeColor = $script:Theme.Ink
$brand.SetBounds(66,8,90,32)
$header.Controls.Add($brand)

$sub = New-Object Windows.Forms.Label
$sub.Text = '水果带货，一键成片'
$sub.Font = $fontSmall
$sub.ForeColor = $script:Theme.Mute
$sub.SetBounds(68,38,180,22)
$header.Controls.Add($sub)

$btnNavMix = New-FlatButton '混剪' $script:Theme.Accent ([Drawing.Color]::White)
$btnNavMix.Font = $fontNav
$btnNavMix.Anchor = 'Top,Right'
$btnNavMix.SetBounds(760,18,88,34)
$btnNavEdit = New-FlatButton '剪辑' $script:Theme.Header $script:Theme.Ink
$btnNavEdit.Font = $fontNav
$btnNavEdit.Anchor = 'Top,Right'
$btnNavEdit.SetBounds(854,18,88,34)
$btnSettings = New-FlatButton '设置' $script:Theme.Header $script:Theme.Mute
$btnSettings.Font = $fontNav
$btnSettings.Anchor = 'Top,Right'
$btnSettings.SetBounds(948,18,88,34)
$header.Controls.AddRange(@($btnNavMix,$btnNavEdit,$btnSettings))
$header.Add_Resize({
    $btnSettings.Left = $this.Width - 110
    $btnNavEdit.Left = $this.Width - 206
    $btnNavMix.Left = $this.Width - 302
})

$pageMix = New-Object Windows.Forms.Panel
$pageMix.Dock = 'Fill'
$pageMix.BackColor = $script:Theme.Bg
$pageMix.Padding = New-Object Windows.Forms.Padding(16,12,16,16)

$pageEdit = New-Object Windows.Forms.Panel
$pageEdit.Dock = 'Fill'
$pageEdit.BackColor = $script:Theme.Bg
$pageEdit.Padding = New-Object Windows.Forms.Padding(16,12,16,16)
$pageEdit.Visible = $false

function Set-ActivePage([string]$name) {
    $script:ActivePage = $name
    $pageMix.Visible = ($name -eq 'mix')
    $pageEdit.Visible = ($name -eq 'edit')
    $btnNavMix.BackColor = if ($name -eq 'mix') { $script:Theme.Accent } else { $script:Theme.Header }
    $btnNavMix.ForeColor = if ($name -eq 'mix') { [Drawing.Color]::White } else { $script:Theme.Ink }
    $btnNavEdit.BackColor = if ($name -eq 'edit') { $script:Theme.Accent } else { $script:Theme.Header }
    $btnNavEdit.ForeColor = if ($name -eq 'edit') { [Drawing.Color]::White } else { $script:Theme.Ink }
}
$btnNavMix.Add_Click({ Set-ActivePage 'mix' })
$btnNavEdit.Add_Click({ Set-ActivePage 'edit' })
$btnSettings.Add_Click({ Show-SettingsDialog })

$split = New-Object Windows.Forms.TableLayoutPanel
$split.Dock = 'Fill'
$split.ColumnCount = 2
$split.RowCount = 1
$split.BackColor = $script:Theme.Bg
[void]$split.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 58)))
[void]$split.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 42)))
$pageMix.Controls.Add($split)

$lists = @{}; $countLabels = @{}; $emptyLabels = @{}; $removeButtons = @{}; $clearButtons = @{}
$leftGrid = New-Object Windows.Forms.TableLayoutPanel
$leftGrid.Dock = 'Fill'
$leftGrid.ColumnCount = 2
$leftGrid.RowCount = 2
$leftGrid.BackColor = $script:Theme.Bg
[void]$leftGrid.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 50)))
[void]$leftGrid.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 50)))
[void]$leftGrid.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 50)))
[void]$leftGrid.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 50)))
$i = 0
foreach ($key in $script:Types.Keys) {
    $card = New-MaterialCard $key
    $leftGrid.Controls.Add($card, ($i % 2), [int][Math]::Floor($i / 2))
    $i++
}
$split.Controls.Add($leftGrid, 0, 0)

$right = New-Object Windows.Forms.TableLayoutPanel
$right.Dock = 'Fill'
$right.ColumnCount = 1
$right.RowCount = 2
$right.BackColor = $script:Theme.Bg
[void]$right.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))
[void]$right.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 318)))
[void]$right.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 100)))
$split.Controls.Add($right, 1, 0)

$genCard = New-Object Windows.Forms.Panel
$genCard.Dock = 'Fill'
$genCard.BackColor = $script:Theme.Card
$genCard.Margin = New-Object Windows.Forms.Padding(8)
$genCard.Add_Resize({ Set-RoundCorners $this 16 })
$right.Controls.Add($genCard, 0, 0)

$genTitle = New-Object Windows.Forms.Label
$genTitle.Text = '生成成片'
$genTitle.Font = $fontTitle
$genTitle.SetBounds(20,16,200,28)
$genCard.Controls.Add($genTitle)

$lblOut = New-Object Windows.Forms.Label
$lblOut.Text = '保存到'
$lblOut.ForeColor = $script:Theme.Mute
$lblOut.SetBounds(20,56,70,24)
$genCard.Controls.Add($lblOut)
$txtOutput = New-Object Windows.Forms.TextBox
$txtOutput.Text = [string]$cfg.output
$txtOutput.BorderStyle = 'FixedSingle'
$txtOutput.SetBounds(90,52,210,28)
$txtOutput.Anchor = 'Top,Left,Right'
$genCard.Controls.Add($txtOutput)
$btnOut = New-FlatButton '浏览' $script:Theme.Soft $script:Theme.Ink
$btnOut.SetBounds(308,50,70,32)
$btnOut.Anchor = 'Top,Right'
$btnOut.Add_Click({ $d=New-Object Windows.Forms.FolderBrowserDialog; if($d.ShowDialog()-eq'OK'){ $txtOutput.Text=$d.SelectedPath } })
$genCard.Controls.Add($btnOut)

$lblCount = New-Object Windows.Forms.Label
$lblCount.Text = '生成'
$lblCount.ForeColor = $script:Theme.Mute
$lblCount.SetBounds(20,100,50,24)
$genCard.Controls.Add($lblCount)
$numCount = New-Object Windows.Forms.NumericUpDown
$numCount.Minimum = 1; $numCount.Maximum = 999
$numCount.Value = [decimal][Math]::Max(1,[int]$cfg.count)
$numCount.SetBounds(90,96,80,28)
$genCard.Controls.Add($numCount)
$lblCountUnit = New-Object Windows.Forms.Label
$lblCountUnit.Text = '条'
$lblCountUnit.SetBounds(176,100,40,24)
$genCard.Controls.Add($lblCountUnit)

$chkPerturb = New-Object Windows.Forms.CheckBox
$chkPerturb.Text = '每条成片略有画面差异'
$chkPerturb.Checked = [bool]$cfg.enablePerturb
$chkPerturb.SetBounds(20,136,360,28)
$chkPerturb.Anchor = 'Top,Left,Right'
$genCard.Controls.Add($chkPerturb)

$lblCapacity = New-Object Windows.Forms.Label
$lblCapacity.Text = '先在左侧放入素材'
$lblCapacity.ForeColor = $script:Theme.Mute
$lblCapacity.SetBounds(20,168,360,24)
$lblCapacity.Anchor = 'Top,Left,Right'
$genCard.Controls.Add($lblCapacity)

$btnStart = New-FlatButton '开始生成' $script:Theme.Accent ([Drawing.Color]::White)
$btnStart.Font = $fontCta
$btnStart.SetBounds(20,204,360,52)
$btnStart.Anchor = 'Top,Left,Right'
$genCard.Controls.Add($btnStart)
$genCard.Add_Resize({
    $txtOutput.Width = $this.Width - 180
    $btnOut.Left = $this.Width - 82
    $btnStart.Width = $this.Width - 40
    $lblCapacity.Width = $this.Width - 40
    $chkPerturb.Width = $this.Width - 40
})

$logCard = New-Object Windows.Forms.Panel
$logCard.Dock = 'Fill'
$logCard.BackColor = $script:Theme.Card
$logCard.Margin = New-Object Windows.Forms.Padding(8,4,8,8)
$logCard.Padding = New-Object Windows.Forms.Padding(12)
$logCard.Add_Resize({ Set-RoundCorners $this 16 })
$right.Controls.Add($logCard, 0, 1)

$txtLog = New-Object Windows.Forms.RichTextBox
$txtLog.ReadOnly = $true
$txtLog.BorderStyle = 'None'
$txtLog.Dock = 'Fill'
$txtLog.BackColor = $script:Theme.Card
$txtLog.ForeColor = $script:Theme.Ink
$txtLog.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)
$txtLog.DetectUrls = $false
$logPlace = New-Object Windows.Forms.Label
$logPlace.Text = "生成时，这里会显示进度"
$logPlace.ForeColor = $script:Theme.Mute
$logPlace.Font = $fontSmall
$logPlace.TextAlign = 'MiddleCenter'
$logPlace.Dock = 'Fill'
$logCard.Controls.Add($logPlace)
$logCard.Controls.Add($txtLog)
$txtLog.Visible = $false

$progressBar = New-Object Windows.Forms.ProgressBar
$progressBar.Style = 'Marquee'
$progressBar.MarqueeAnimationSpeed = 25
$progressBar.Dock = 'Top'
$progressBar.Height = 6
$progressBar.Visible = $false
$logCard.Controls.Add($progressBar)

function Update-CapacityLabel {
    $counts = @{}
    foreach ($key in $script:Types.Keys) { $counts[$key] = @(Get-Videos (Get-ListPaths $lists[$key])).Count }
    $filled = @($counts.Keys | Where-Object { $counts[$_] -gt 0 }).Count
    $sum = ($counts.Values | Measure-Object -Sum).Sum
    if ($sum -eq 0) { $lblCapacity.Text = '先在左侧放入素材，建议至少两类' }
    elseif ($filled -eq 1) { $lblCapacity.Text = '目前只有一类素材，生成前会再确认一次' }
    else {
        $capacity = Get-TemplateCapacity $counts
        $lblCapacity.Text = "已放入 $filled 类 · 约 $([int]$capacity.combinations) 种搭配"
    }
    $lblCapacity.ForeColor = $script:Theme.Mute
}
$numCount.Add_ValueChanged({ Update-CapacityLabel })
$btnStart.Add_Click({
    if ($script:Running) { return }
    $script:Running = $true
    $btnStart.Enabled = $false
    $btnStart.Text = '正在生成…'
    if ($progressBar) { $progressBar.Visible = $true }
    $current = Save-Config
    $txtLog.Clear()
    $txtLog.ForeColor = $script:Theme.Ink
    $txtLog.Visible = $true
    if ($logPlace) { $logPlace.Visible = $false }
    [Windows.Forms.Application]::DoEvents()
    Start-Generation $current
})

# 预览剪辑
$editCard = New-Object Windows.Forms.Panel
$editCard.Dock = 'Fill'
$editCard.BackColor = $script:Theme.Card
$editCard.Add_Resize({ Set-RoundCorners $this 16 })
$pageEdit.Controls.Add($editCard)

$script:EditFile = $null
$script:EditDuration = 0.0
$script:Segments = [Collections.ArrayList]::new()
$script:StopAt = $null
$script:IsPlaying = $false

$mediaHost = New-Object Windows.Forms.Integration.ElementHost
$mediaHost.SetBounds(16,16,620,430)
$mediaHost.BackColor = 'Black'
$mediaHost.Anchor = 'Top,Bottom,Left,Right'
$media = New-Object Windows.Controls.MediaElement
$media.LoadedBehavior = [Windows.Controls.MediaState]::Manual
$media.UnloadedBehavior = [Windows.Controls.MediaState]::Manual
$media.Stretch = [Windows.Media.Stretch]::Uniform
$media.ScrubbingEnabled = $true
$mediaHost.Child = $media
$editCard.Controls.Add($mediaHost)

$btnOpenEdit = New-FlatButton '打开成片' $script:Theme.Soft $script:Theme.Ink
$btnOpenEdit.SetBounds(656,20,130,36)
$btnOpenEdit.Anchor = 'Top,Right'
$editCard.Controls.Add($btnOpenEdit)
$btnPlay = New-FlatButton '播放 / 暂停' $script:Theme.Accent ([Drawing.Color]::White)
$btnPlay.SetBounds(796,20,130,36)
$btnPlay.Anchor = 'Top,Right'
$editCard.Controls.Add($btnPlay)

$lblTime = New-Object Windows.Forms.Label
$lblTime.Text = '00:00.000 / 00:00.000'
$lblTime.SetBounds(656,68,270,24)
$lblTime.Anchor = 'Top,Right'
$editCard.Controls.Add($lblTime)

$track = New-Object Windows.Forms.TrackBar
$track.Minimum = 0; $track.Maximum = 10000; $track.TickStyle = 'None'
$track.SetBounds(16,452,620,36)
$track.Anchor = 'Bottom,Left,Right'
$editCard.Controls.Add($track)

$lblParts = New-Object Windows.Forms.Label
$lblParts.Text = '片段（双击可预览）'
$lblParts.ForeColor = $script:Theme.Mute
$lblParts.SetBounds(656,108,270,22)
$lblParts.Anchor = 'Top,Right'
$editCard.Controls.Add($lblParts)

$segmentList = New-Object Windows.Forms.ListView
$segmentList.View = 'Details'
$segmentList.FullRowSelect = $true
$segmentList.GridLines = $false
$segmentList.BorderStyle = 'FixedSingle'
$segmentList.SetBounds(656,134,270,310)
$segmentList.Anchor = 'Top,Bottom,Right'
$null = $segmentList.Columns.Add('片段', 50)
$null = $segmentList.Columns.Add('开始', 100)
$null = $segmentList.Columns.Add('结束', 100)
$editCard.Controls.Add($segmentList)

$btnSplit = New-FlatButton '在这里切开' $script:Theme.Soft $script:Theme.Ink
$btnSplit.SetBounds(16,502,150,40)
$btnSplit.Anchor = 'Bottom,Left'
$editCard.Controls.Add($btnSplit)
$btnDelete = New-FlatButton '删掉这段' $script:Theme.Danger ([Drawing.Color]::FromArgb(176,48,32))
$btnDelete.SetBounds(176,502,150,40)
$btnDelete.Anchor = 'Bottom,Left'
$editCard.Controls.Add($btnDelete)
$btnExport = New-FlatButton '导出新视频' $script:Theme.Sage ([Drawing.Color]::White)
$btnExport.SetBounds(336,502,180,40)
$btnExport.Anchor = 'Bottom,Left'
$editCard.Controls.Add($btnExport)

$editTip = New-Object Windows.Forms.Label
$editTip.Text = '拖到要剪的位置 → 切开 → 选中不要的片段 → 删除 → 导出'
$editTip.ForeColor = $script:Theme.Mute
$editTip.SetBounds(16,550,700,24)
$editTip.Anchor = 'Bottom,Left,Right'
$editCard.Controls.Add($editTip)

$editCard.Add_Resize({
    $rightW = 300
    $btnPlay.Left = $this.Width - 146
    $btnOpenEdit.Left = $this.Width - 286
    $lblTime.Left = $this.Width - 286
    $lblParts.Left = $this.Width - 286
    $segmentList.Left = $this.Width - 286
    $segmentList.Height = [Math]::Max(120, $this.Height - 260)
    $mediaHost.Width = $this.Width - 320
    $mediaHost.Height = [Math]::Max(180, $this.Height - 150)
    $track.Top = $mediaHost.Bottom + 8
    $track.Width = $mediaHost.Width
    $btnSplit.Top = $this.Height - 70
    $btnDelete.Top = $btnSplit.Top
    $btnExport.Top = $btnSplit.Top
    $editTip.Top = $this.Height - 32
})

function Format-Time([double]$seconds) {
    $ts = [TimeSpan]::FromSeconds([Math]::Max(0,$seconds))
    return "{0:00}:{1:00}.{2:000}" -f [int]$ts.TotalMinutes, $ts.Seconds, $ts.Milliseconds
}
function Refresh-Segments {
    $segmentList.Items.Clear()
    for ($i=0; $i -lt $script:Segments.Count; $i++) {
        $s = $script:Segments[$i]
        $item = New-Object Windows.Forms.ListViewItem(("$($i+1)"))
        $null = $item.SubItems.Add((Format-Time $s.start))
        $null = $item.SubItems.Add((Format-Time $s.end))
        $null = $segmentList.Items.Add($item)
    }
}
$previewTimer = New-Object Windows.Forms.Timer
$previewTimer.Interval = 150
$previewTimer.Add_Tick({
    if (-not $script:EditFile) { return }
    $pos = $media.Position.TotalSeconds
    if ($script:EditDuration -gt 0 -and -not $track.Focused) { $track.Value = [Math]::Min(10000,[Math]::Max(0,[int](10000*$pos/$script:EditDuration))) }
    $lblTime.Text = "$(Format-Time $pos) / $(Format-Time $script:EditDuration)"
    if ($null -ne $script:StopAt -and $pos -ge [double]$script:StopAt) { $media.Pause(); $script:IsPlaying=$false; $script:StopAt=$null }
})
$previewTimer.Start()
$btnOpenEdit.Add_Click({
    $d = New-Object Windows.Forms.OpenFileDialog
    $d.Filter = "视频文件|*.mp4;*.mov;*.mkv;*.avi;*.m4v;*.webm|所有文件|*.*"
    if (Test-Path -LiteralPath $txtOutput.Text) { $d.InitialDirectory = $txtOutput.Text }
    if ($d.ShowDialog() -ne 'OK') { return }
    try {
        $script:FFmpeg = [string]$script:Settings.ffmpeg
        $script:EditFile = $d.FileName
        $script:EditDuration = Get-MediaDuration $d.FileName
        $script:Segments.Clear()
        $null = $script:Segments.Add([pscustomobject]@{start=0.0;end=$script:EditDuration})
        Refresh-Segments
        $media.Stop(); $media.Source = New-Object Uri($d.FileName); $media.Position = [TimeSpan]::Zero; $media.Play(); $script:IsPlaying = $true
    } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message,'打开失败','OK','Error') | Out-Null }
})
$btnPlay.Add_Click({
    if (-not $script:EditFile) { return }
    if ($script:IsPlaying) { $media.Pause(); $script:IsPlaying=$false } else { $media.Play(); $script:IsPlaying=$true }
    $script:StopAt = $null
})
$track.Add_MouseDown({ $media.Pause(); $script:IsPlaying=$false })
$track.Add_MouseUp({
    if (-not $script:EditFile) { return }
    $seconds = $script:EditDuration * $track.Value / 10000.0
    $media.Position = [TimeSpan]::FromSeconds($seconds); $script:StopAt=$null; $media.Play(); $script:IsPlaying=$true
})
$segmentList.Add_DoubleClick({
    if (-not $segmentList.SelectedIndices.Count) { return }
    $s = $script:Segments[$segmentList.SelectedIndices[0]]
    $media.Position = [TimeSpan]::FromSeconds([double]$s.start); $script:StopAt=[double]$s.end; $media.Play(); $script:IsPlaying=$true
})
$btnSplit.Add_Click({
    if (-not $script:EditFile) { return }
    $at = $media.Position.TotalSeconds
    $index = -1
    for ($i=0; $i -lt $script:Segments.Count; $i++) { if ($at -gt $script:Segments[$i].start+0.05 -and $at -lt $script:Segments[$i].end-0.05) { $index=$i; break } }
    if ($index -lt 0) { [Windows.Forms.MessageBox]::Show('当前位置已经在片段边界上。','提示') | Out-Null; return }
    $old = $script:Segments[$index]
    $script:Segments.RemoveAt($index)
    $script:Segments.Insert($index, [pscustomobject]@{start=[double]$old.start;end=[double]$at})
    $script:Segments.Insert($index+1, [pscustomobject]@{start=[double]$at;end=[double]$old.end})
    Refresh-Segments
})
$btnDelete.Add_Click({
    if (-not $segmentList.SelectedIndices.Count) { return }
    $index = $segmentList.SelectedIndices[0]
    if ($script:Segments.Count -le 1) { [Windows.Forms.MessageBox]::Show('至少要留下一段。','提示') | Out-Null; return }
    $script:Segments.RemoveAt($index); Refresh-Segments
})
$btnExport.Add_Click({
    if (-not $script:EditFile -or -not $script:Segments.Count) { [Windows.Forms.MessageBox]::Show('请先打开视频，并至少留下一段。','提示') | Out-Null; return }
    $d = New-Object Windows.Forms.SaveFileDialog
    $d.Filter = 'MP4 视频|*.mp4'
    $d.FileName = ([IO.Path]::GetFileNameWithoutExtension($script:EditFile) + '_剪辑版.mp4')
    if ($d.ShowDialog() -ne 'OK') { return }
    $btnExport.Enabled = $false; $btnExport.Text = '正在导出…'
    try {
        $tmp = Join-Path $env:TEMP ("fruit_edit_"+[Guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $tmp | Out-Null
        $parts = @()
        for ($i=0; $i -lt $script:Segments.Count; $i++) {
            $s = $script:Segments[$i]; $part = Join-Path $tmp ("part_{0:D3}.mp4" -f $i)
            $start = [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:0.###}', [double]$s.start)
            $length = [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:0.###}', ([double]$s.end - [double]$s.start))
            Run-FFmpeg @('-y','-hide_banner','-loglevel','error','-ss',$start,'-i',$script:EditFile,'-t',$length,'-map','0:v:0','-map','0:a:0?','-c:v','libx264','-preset','veryfast','-crf','20','-pix_fmt','yuv420p','-c:a','aac','-b:a','160k',$part)
            $parts += $part
        }
        $listFile = Join-Path $tmp 'concat.txt'
        [IO.File]::WriteAllLines($listFile, @($parts | ForEach-Object { "file '$($_.Replace("'","'\''"))'" }), [Text.UTF8Encoding]::new($false))
        Run-FFmpeg @('-y','-hide_banner','-loglevel','error','-f','concat','-safe','0','-i',$listFile,'-c','copy','-movflags','+faststart',$d.FileName)
        [Windows.Forms.MessageBox]::Show("剪辑完成：`n$($d.FileName)",'完成','OK','Information') | Out-Null
    } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message,'导出失败','OK','Error') | Out-Null }
    finally {
        if ($tmp -and (Test-Path -LiteralPath $tmp)) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
        $btnExport.Enabled = $true; $btnExport.Text = '导出新视频'
    }
})

$form.Controls.Add($pageEdit)
$form.Controls.Add($pageMix)
$form.Controls.Add($header)
Set-ActivePage 'mix'

$form.Add_FormClosing({
    if ($script:Running) {
        $_.Cancel = $true
        [Windows.Forms.MessageBox]::Show('正在生成视频，请等待完成后再关闭。','提示') | Out-Null
    } else { Save-Config | Out-Null }
})
$form.Add_Shown({
    foreach ($key in $script:Types.Keys) { Update-MaterialCard $key }
    Update-CapacityLabel
    if ($PreviewCapture) {
        $this.Update()
        [Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 300
        $bmp = New-Object Drawing.Bitmap $form.ClientSize.Width, $form.ClientSize.Height
        $form.DrawToBitmap($bmp, (New-Object Drawing.Rectangle 0,0,$form.ClientSize.Width,$form.ClientSize.Height))
        $bmp.Save((Join-Path $script:Root 'ui-preview-mix.png'))
        Set-ActivePage 'edit'
        $this.Update(); [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 200
        $bmp2 = New-Object Drawing.Bitmap $form.ClientSize.Width, $form.ClientSize.Height
        $form.DrawToBitmap($bmp2, (New-Object Drawing.Rectangle 0,0,$form.ClientSize.Width,$form.ClientSize.Height))
        $bmp2.Save((Join-Path $script:Root 'ui-preview-edit.png'))
        $form.Close()
    }
})

try {
    [void]$form.ShowDialog()
} catch {
    $crashFile = Join-Path $script:Root '程序错误日志.txt'
    "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')]`r`n$($_ | Out-String)`r`n$($_.ScriptStackTrace)" | Add-Content -LiteralPath $crashFile -Encoding UTF8
    [Windows.Forms.MessageBox]::Show("程序遇到错误，详情已保存到：`n$crashFile",'程序错误','OK','Error') | Out-Null
}
