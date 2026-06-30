#requires -Version 7
<#
.SYNOPSIS
  data/news.json(최근 수집분) 중 data/alerts.json 의 키워드에 매칭되는 "새" 기사를
  텔레그램으로 전송. 이미 보낸 기사는 data/alerted.json 에 기록해 중복 전송하지 않음.

.NOTES
  - 인증: 환경변수 TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID (GitHub Secrets). 없으면 조용히 skip.
  - 첫 실행(alerted.json 없음) 시에는 현재 매칭분을 "이미 보낸 것"으로 시드만 하고 전송하지 않음
    → 과거 누적분이 한꺼번에 쏟아지는 것을 방지. 다음 실행부터 진짜 새 기사만 전송.
  - alerts.json: { keywords:[...], logic:"OR"|"AND", recentHours:72, maxPerRun:30, dedupeByTitle:true, requireCompanyInTitle:true }
  - dedupeByTitle=true 면 같은 헤드라인(정규화 제목 일치)은 URL이 달라도 1건만 전송(언론사 중복 컷).
  - requireCompanyInTitle=true 면 제목에 (태그된) 증권사명이 든 기사만 전송(본문 스쳐 언급·시황 제외).
#>
[CmdletBinding()]
param(
  [string]$DataDir = (Join-Path $PSScriptRoot '..' 'data')
)
$ErrorActionPreference = 'Stop'

$Token  = $env:TELEGRAM_BOT_TOKEN
$ChatId = $env:TELEGRAM_CHAT_ID
if([string]::IsNullOrWhiteSpace($Token) -or [string]::IsNullOrWhiteSpace($ChatId)){
  Write-Host "[알림] TELEGRAM_BOT_TOKEN/CHAT_ID 미설정 — 전송 skip"; return
}

# ---- 설정 로드 ----
$alertsPath = Join-Path $DataDir 'alerts.json'
if(-not (Test-Path $alertsPath)){ Write-Host "[알림] alerts.json 없음 — skip"; return }
$cfg = Get-Content $alertsPath -Raw -Encoding UTF8 | ConvertFrom-Json
$keywords = @($cfg.keywords | Where-Object { $_ -and $_.Trim() })
if($keywords.Count -eq 0){ Write-Host "[알림] 키워드 비어있음 — skip"; return }
$logic       = if($cfg.logic){ "$($cfg.logic)".ToUpper() } else { 'OR' }
$recentHours = if($cfg.recentHours){ [int]$cfg.recentHours } else { 72 }
$maxPerRun   = if($cfg.maxPerRun){ [int]$cfg.maxPerRun } else { 30 }
$dedupeByTitle = if($null -ne $cfg.dedupeByTitle){ [bool]$cfg.dedupeByTitle } else { $true }
$requireCompanyInTitle = if($null -ne $cfg.requireCompanyInTitle){ [bool]$cfg.requireCompanyInTitle } else { $true }

# ---- 현재 수집분 로드 ----
$newsPath = Join-Path $DataDir 'news.json'
if(-not (Test-Path $newsPath)){ Write-Host "[알림] news.json 없음 — skip"; return }
$news = @((Get-Content $newsPath -Raw -Encoding UTF8 | ConvertFrom-Json).news)

# ---- 매칭 ----
function Test-Match($item){
  $hay = (("$($item.title) $($item.description)")).ToLower()
  $hits = foreach($k in $keywords){ $hay.Contains($k.ToLower()) }
  if($logic -eq 'AND'){ return (@($hits) -notcontains $false) }
  return (@($hits) -contains $true)
}
function Get-MatchedKeywords($item){
  $hay = (("$($item.title) $($item.description)")).ToLower()
  @($keywords | Where-Object { $hay.Contains($_.ToLower()) })
}
# 정규화 제목(공백·특수문자 제거, 소문자) — 언론사 중복 컷용
function Norm-Title($t){ if([string]::IsNullOrWhiteSpace($t)){ return '' }; return (($t -replace '[^0-9A-Za-z가-힣]','')).ToLower() }
# 제목에 (태그된) 증권사명이 들어가야 '진짜 증권사 기사'로 간주(본문 스쳐 언급·시황 제외)
function Test-CompanyInTitle($item){
  if(-not $requireCompanyInTitle){ return $true }
  $t = "$($item.title)"
  foreach($c in @($item.companies)){ if($c -and $t.Contains($c)){ return $true } }
  return $false
}

$matched = @($news | Where-Object { (Test-Match $_) -and (Test-CompanyInTitle $_) })
Write-Host "[알림] 키워드 매칭 $($matched.Count)건 (logic=$logic, recentHours=$recentHours, 제목에증권사명=$requireCompanyInTitle)"

# ---- dedup 저장소 ----
$alertedPath = Join-Path $DataDir 'alerted.json'
$firstRun = -not (Test-Path $alertedPath)
$sent = New-Object System.Collections.Generic.HashSet[string]
$sentTitles = New-Object System.Collections.Generic.HashSet[string]
if(-not $firstRun){
  try{
    $a = Get-Content $alertedPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach($l in @($a.sent)){ if($l){ [void]$sent.Add($l) } }
    foreach($t in @($a.sentTitles)){ if($t){ [void]$sentTitles.Add($t) } }
  }catch{}
}

function Save-Alerted(){
  # 최근 5000건만 보존
  $arr  = @($sent)       | Select-Object -Last 5000
  $arrT = @($sentTitles) | Select-Object -Last 5000
  ([ordered]@{ updated=(Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); sent=$arr; sentTitles=$arrT } | ConvertTo-Json -Depth 5) |
    Set-Content -Path $alertedPath -Encoding UTF8
}

# 첫 실행: 현재 매칭분을 보낸 것으로 시드만 하고 종료(과거분 폭주 방지)
if($firstRun){
  foreach($m in $matched){
    $key = if($m.link){$m.link}else{$m.title}; [void]$sent.Add($key)
    $nt = Norm-Title $m.title; if($nt){ [void]$sentTitles.Add($nt) }
  }
  Save-Alerted
  Write-Host "[알림] 첫 실행 — $($matched.Count)건 시드 완료(전송 안 함). 다음 실행부터 새 기사만 전송."
  return
}

# ---- 보낼 후보: 미전송 + 최근 N시간 ----
$cut = (Get-Date).ToUniversalTime().AddHours(-$recentHours)
$cands = @()
foreach($m in $matched){
  $key = if($m.link){$m.link}else{$m.title}
  if($sent.Contains($key)){ continue }
  if($dedupeByTitle){ $nt=Norm-Title $m.title; if($nt -and $sentTitles.Contains($nt)){ continue } }  # 이미 보낸 헤드라인 스킵
  # 최근성 필터(파싱 실패 시 통과)
  $fresh = $true
  if($m.pubDate){ $dto=[DateTimeOffset]::MinValue; if([DateTimeOffset]::TryParse($m.pubDate,[ref]$dto)){ $fresh = ($dto.UtcDateTime -ge $cut) } }
  if($fresh){ $cands += $m }
}
# 최신순 정렬 후 상한 적용
$cands = @($cands | Sort-Object -Stable -Descending -Property @{Expression={ "$($_.pubDate)" }})
$total = $cands.Count
if($total -gt $maxPerRun){ $cands = @($cands | Select-Object -First $maxPerRun) }
Write-Host "[알림] 전송 후보 $total건 (이번 실행 최대 $maxPerRun건)"

# ---- 텔레그램 전송 ----
$api = "https://api.telegram.org/bot$Token/sendMessage"
$ok = 0
foreach($m in $cands){
  $nt = Norm-Title $m.title
  if($dedupeByTitle -and $nt -and $sentTitles.Contains($nt)){ continue }  # 같은 실행 내 동일 헤드라인 1건만
  $kw = (Get-MatchedKeywords $m) -join ', '
  $co = (@($m.companies) -join ', ')
  $when = if($m.pubDate){ try{ ([DateTimeOffset]$m.pubDate).ToString('MM-dd HH:mm') }catch{ $m.date } } else { $m.date }
  $press = if($m.press){ " · $($m.press)" } else { '' }
  $link = if($m.link){$m.link}else{$m.originallink}
  $text = "🔔 [$kw] $($m.title)`n🏷 $co$press · $when`n$link"
  $body = @{ chat_id=$ChatId; text=$text; disable_web_page_preview=$false }
  $sentOk=$false
  for($try=0; $try -lt 4 -and -not $sentOk; $try++){
    try{
      Invoke-RestMethod -Uri $api -Method Post -Body $body -TimeoutSec 20 | Out-Null
      $sentOk=$true
    }catch{
      $code=0; try{ $code=[int]$_.Exception.Response.StatusCode }catch{}
      if($code -eq 429){
        $ra=5; try{ $d=$_.ErrorDetails.Message | ConvertFrom-Json; if($d.parameters.retry_after){ $ra=[int]$d.parameters.retry_after } }catch{}
        Write-Host "[알림] 429 rate limit — $ra초 대기 후 재시도"
        Start-Sleep -Seconds ([Math]::Min(60,$ra+1))
      } else {
        Write-Warning "[알림] 전송 실패: $($_.Exception.Message)"; break
      }
    }
  }
  if($sentOk){
    [void]$sent.Add($(if($m.link){$m.link}else{$m.title}))
    if($nt){ [void]$sentTitles.Add($nt) }
    $ok++
  }
  Start-Sleep -Milliseconds 3500   # 채널 전송 rate limit 여유(약 17건/분)
}
Save-Alerted
Write-Host "[알림] 전송 완료 $ok/$($cands.Count)건"
if($total -gt $maxPerRun){ Write-Host "[알림] (상한 초과 $($total-$maxPerRun)건은 다음 실행에서 전송)" }
