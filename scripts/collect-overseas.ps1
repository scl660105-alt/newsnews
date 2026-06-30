#requires -Version 7
<#
.SYNOPSIS
  GNews.io 검색 API로 해외 외신(리테일 브로커·업계 테마·거래소/규제)을 수집해
  data/overseas.json(현재) 갱신, data/overseas_history.json 에 누적(중복제거·보존기간 정리).

.NOTES
  - 인증: 환경변수 GNEWS_API_KEY (GitHub Secret). 없으면 throw.
  - 무료 티어: 100콜/일, 요청당 최대 10건. 6시간 주기 × 토픽 수 만큼만 호출.
  - 토픽/쿼리: data/overseas_topics.json (편집 가능).
  - 시각은 publishedAt(ISO Z)을 KST로 변환해 저장. lastUpdated 만 UTC.
  - ubuntu-latest pwsh 에서도 그대로 동작.
#>
[CmdletBinding()]
param(
  [string]$DataDir = (Join-Path $PSScriptRoot '..' 'data'),
  [int]$HistoryRetentionDays = 60,
  [int]$MaxPerQuery = 10,        # GNews 무료 최대 10
  [int]$ThrottleMs = 1500
)
$ErrorActionPreference = 'Stop'

$Key = $env:GNEWS_API_KEY
if([string]::IsNullOrWhiteSpace($Key)){ throw "환경변수 GNEWS_API_KEY 가 필요합니다. (gnews.io 에서 발급)" }
$ApiUrl = 'https://gnews.io/api/v4/search'

# ---- 유틸 ----
function Clear-Html([string]$s){
  if([string]::IsNullOrWhiteSpace($s)){ return '' }
  $t = $s -replace '<[^>]+>',''
  $t = $t -replace '&lt;','<' -replace '&gt;','>' -replace '&amp;','&' `
          -replace '&quot;','"' -replace '&#39;',"'" -replace '&apos;',"'" -replace '&nbsp;',' '
  return $t.Trim()
}
# ISO("2026-06-30T12:34:56Z") → @{ iso='...+09:00'; date='yyyy-MM-dd' } (KST)
function Convert-PubDate([string]$s){
  $res = @{ iso=''; date='' }
  if([string]::IsNullOrWhiteSpace($s)){ return $res }
  $dto = [DateTimeOffset]::MinValue
  if([DateTimeOffset]::TryParse($s, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$dto)){
    $kst = $dto.ToOffset([TimeSpan]::FromHours(9))
    $res.iso  = $kst.ToString("yyyy-MM-ddTHH:mm:sszzz")
    $res.date = $kst.ToString('yyyy-MM-dd')
  }
  return $res
}

# ---- 토픽 로드 ----
$topicsPath = Join-Path $DataDir 'overseas_topics.json'
if(-not (Test-Path $topicsPath)){ throw "토픽 목록 없음: $topicsPath" }
$topics = @((Get-Content $topicsPath -Raw -Encoding UTF8 | ConvertFrom-Json).topics)
if(-not $topics -or $topics.Count -eq 0){ throw "overseas_topics.json 의 topics 가 비어있음" }
Write-Host "[설정] 토픽 $($topics.Count)개"

# ---- 수집 ----
$items = @()
$callCount = 0
foreach($tp in $topics){
  $cat = $tp.category; $label = if($tp.label){ $tp.label } else { $cat }
  $firms = @($tp.firms | Where-Object { $_ -and "$_".Trim() })
  $uri = "{0}?q={1}&lang=en&max={2}&sortby=publishedAt&apikey={3}" -f $ApiUrl, [uri]::EscapeDataString($tp.query), $MaxPerQuery, $Key
  try{
    $resp = Invoke-RestMethod -Uri $uri -TimeoutSec 30
    $callCount++
  }catch{
    Write-Warning "[$label] 조회 실패: $($_.Exception.Message)"
    continue
  }
  $arts = @($resp.articles)
  foreach($a in $arts){
    $pd = Convert-PubDate $a.publishedAt
    $title = Clear-Html $a.title
    $desc  = Clear-Html $a.description
    # 브로커 태그: firms 중 제목/요약에 있는 것. 없으면 카테고리 라벨.
    $tags = @()
    if($firms.Count -gt 0){
      $hay = "$title $desc"
      $tags = @($firms | Where-Object { $hay -match [regex]::Escape($_) })
    }
    if($tags.Count -eq 0){ $tags = @($label) }
    $items += [ordered]@{
      title       = $title
      description = $desc
      link        = $a.url
      press       = if($a.source){ $a.source.name } else { '' }
      pubDate     = $pd.iso
      date        = $pd.date
      category    = $cat
      companies   = @($tags)
    }
  }
  Write-Host ("[{0}] {1}건" -f $label, $arts.Count)
  if($ThrottleMs -gt 0){ Start-Sleep -Milliseconds $ThrottleMs }
}
Write-Host "[수집] 원시 $($items.Count)건 (API 콜 $callCount회)"

# ---- dedup (link 기준; 없으면 정규화 제목) + 태그 병합 ----
function Get-Key($h){
  if(-not [string]::IsNullOrWhiteSpace($h.link)){ return "L|$($h.link)" }
  return "T|$(($h.title -replace '\s+','').ToLower())"
}
$byKey = [ordered]@{}
foreach($h in $items){
  $k = Get-Key $h
  if($byKey.Contains($k)){
    $ex = $byKey[$k]
    foreach($t in @($h.companies)){ if($ex.companies -notcontains $t){ $ex.companies = @($ex.companies + $t) } }
  } else {
    $byKey[$k] = [ordered]@{
      title=$h.title; description=$h.description; link=$h.link; press=$h.press
      pubDate=$h.pubDate; date=$h.date; category=$h.category; companies=@($h.companies)
    }
  }
}
$current = @($byKey.Values | Sort-Object -Stable -Descending -Property @{Expression={ "$($_.pubDate)" }})
Write-Host "[dedup] 고유 $($current.Count)건"

$nowUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
if(-not (Test-Path $DataDir)){ New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }

# ---- overseas.json (현재 스냅샷) ----
$obj = [ordered]@{
  lastUpdated = $nowUtc
  source      = 'GNews.io (https://gnews.io/api/v4/search)'
  count       = $current.Count
  news        = @($current)
}
$path = Join-Path $DataDir 'overseas.json'
($obj | ConvertTo-Json -Depth 8) | Set-Content -Path $path -Encoding UTF8
Write-Host "→ $path ($($current.Count)건)"

# ---- overseas_history.json (누적) ----
$histPath = Join-Path $DataDir 'overseas_history.json'
$existing = @()
if(Test-Path $histPath){
  try{ $existing = @((Get-Content $histPath -Raw -Encoding UTF8 | ConvertFrom-Json).news) }catch{ $existing=@() }
}
$merged = [ordered]@{}
foreach($h in @($existing) + @($current)){
  if($null -eq $h){ continue }
  $k = Get-Key $h
  if($merged.Contains($k)){
    $ex = $merged[$k]
    foreach($t in @($h.companies)){ if($ex.companies -notcontains $t){ $ex.companies = @($ex.companies + $t) } }
    if([string]::IsNullOrWhiteSpace($ex.press) -and $h.press){ $ex.press = $h.press }
  } else {
    $merged[$k] = [ordered]@{
      title=$h.title; description=$h.description; link=$h.link; press=$h.press
      pubDate=$h.pubDate; date=$h.date; category=$h.category; companies=@($h.companies)
    }
  }
}
$cut = (Get-Date).AddDays(-$HistoryRetentionDays).ToString('yyyy-MM-dd')
$mergedArr = @($merged.Values) |
  Where-Object { [string]::IsNullOrWhiteSpace($_.date) -or $_.date -ge $cut }
$mergedArr = @($mergedArr | Sort-Object -Stable -Descending -Property @{Expression={ "$($_.pubDate)" }})

$histObj = [ordered]@{
  lastUpdated = $nowUtc
  source      = 'GNews.io'
  retentionDays = $HistoryRetentionDays
  count       = $mergedArr.Count
  news        = @($mergedArr)
}
($histObj | ConvertTo-Json -Depth 8) | Set-Content -Path $histPath -Encoding UTF8
Write-Host "→ $histPath (누적 $($mergedArr.Count)건, 보존 ${HistoryRetentionDays}일)"
Write-Host "완료: $nowUtc"
