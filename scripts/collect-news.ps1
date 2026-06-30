#requires -Version 7
<#
.SYNOPSIS
  네이버 뉴스 검색 API로 국내 주요 증권사 관련 뉴스를 수집해
  data/news.json(이번 실행 스냅샷) 갱신, data/news_history.json 에 누적(중복제거·보존기간 정리).

.DESCRIPTION
  - 대상 증권사 목록은 data/companies.json 에서 로드(편집 용이).
  - 증권사명 1건당 sort=date 로 1~N페이지(기본 2페이지=최근 200건) 페이징 조회.
  - 제목/요약의 <b> 태그·HTML 엔티티 제거, pubDate(RFC1123 +0900)를 ISO + KST 날짜로 파생.
  - 같은 기사가 여러 증권사에 걸리면 companies 배열로 병합(link 기준 dedup).

.NOTES
  - 인증: 환경변수 NAVER_CLIENT_ID / NAVER_CLIENT_SECRET (코드에 키를 넣지 말 것).
      로컬: $env:NAVER_CLIENT_ID='...'; $env:NAVER_CLIENT_SECRET='...'
      CI  : GitHub Secrets → workflow env 주입.
  - 시각은 pubDate가 이미 +0900(KST)이라 KST 기준으로 저장. lastUpdated 만 UTC.
  - 언론사명은 API가 직접 주지 않음 → originallink 호스트에서 best-effort 추정(미상이면 공백).
  - ubuntu-latest 의 pwsh 에서도 그대로 동작.
#>
[CmdletBinding()]
param(
  [string]$DataDir = (Join-Path $PSScriptRoot '..' 'data'),
  [int]$PagesPerCompany = 2,          # 증권사당 페이지 수 (1페이지=100건, start=1,101,...)
  [int]$HistoryRetentionDays = 90,
  [int]$ThrottleMs = 120              # 콜 간 간격(과호출 방지)
)
$ErrorActionPreference = 'Stop'

$ClientId     = $env:NAVER_CLIENT_ID
$ClientSecret = $env:NAVER_CLIENT_SECRET
if([string]::IsNullOrWhiteSpace($ClientId) -or [string]::IsNullOrWhiteSpace($ClientSecret)){
  throw "환경변수 NAVER_CLIENT_ID / NAVER_CLIENT_SECRET 가 필요합니다. (developers.naver.com 에서 '검색' API 키 발급)"
}
$ApiUrl = 'https://openapi.naver.com/v1/search/news.json'
$Headers = @{ 'X-Naver-Client-Id' = $ClientId; 'X-Naver-Client-Secret' = $ClientSecret }

# ---------- 유틸 ----------
function Remove-Bom([string]$s){ if($s){ return $s.TrimStart([char]0xFEFF,[char]0x200B) } return $s }

# 네이버가 돌려주는 <b>강조</b> 태그와 HTML 엔티티를 평문으로 정제
function Clear-Html([string]$s){
  if([string]::IsNullOrWhiteSpace($s)){ return '' }
  $t = $s -replace '<[^>]+>',''
  $t = $t -replace '&lt;','<' -replace '&gt;','>' -replace '&amp;','&' `
          -replace '&quot;','"' -replace '&apos;',"'" -replace '&#39;',"'" -replace '&nbsp;',' '
  return $t.Trim()
}

# RFC1123(예: "Mon, 26 Sep 2022 18:00:00 +0900") → @{ iso='2022-09-26T18:00:00+09:00'; date='2022-09-26' }
function Convert-PubDate([string]$s){
  $res = @{ iso = ''; date = '' }
  if([string]::IsNullOrWhiteSpace($s)){ return $res }
  $dto = [DateTimeOffset]::MinValue
  if([DateTimeOffset]::TryParse($s, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$dto)){
    $kst = $dto.ToOffset([TimeSpan]::FromHours(9))
    $res.iso  = $kst.ToString("yyyy-MM-ddTHH:mm:sszzz")
    $res.date = $kst.ToString('yyyy-MM-dd')
  }
  return $res
}

# originallink 호스트로 언론사 best-effort 추정 (미상이면 '')
$PRESS_MAP = @{
  'yna.co.kr'='연합뉴스'; 'yonhapnews'='연합뉴스'; 'hankyung.com'='한국경제'; 'mk.co.kr'='매일경제';
  'sedaily.com'='서울경제'; 'edaily.co.kr'='이데일리'; 'mt.co.kr'='머니투데이'; 'fnnews.com'='파이낸셜뉴스';
  'asiae.co.kr'='아시아경제'; 'newspim.com'='뉴스핌'; 'news1.kr'='뉴스1'; 'newsis.com'='뉴시스';
  'heraldcorp.com'='헤럴드경제'; 'mtn.co.kr'='머니투데이방송'; 'biz.chosun.com'='조선비즈';
  'chosun.com'='조선일보'; 'donga.com'='동아일보'; 'joongang.co.kr'='중앙일보'; 'hani.co.kr'='한겨레';
  'khan.co.kr'='경향신문'; 'kmib.co.kr'='국민일보'; 'segye.com'='세계일보'; 'seoul.co.kr'='서울신문';
  'wowtv.co.kr'='한국경제TV'; 'thebell.co.kr'='더벨'; 'paxnet'='팍스넷'; 'inews24.com'='아이뉴스24';
  'dt.co.kr'='디지털타임스'; 'etnews.com'='전자신문'; 'ajunews.com'='아주경제'; 'kukinews.com'='쿠키뉴스'
}
function Get-Press([string]$url){
  if([string]::IsNullOrWhiteSpace($url)){ return '' }
  $urlHost = ''
  try { $urlHost = ([uri]$url).Host } catch { return '' }
  foreach($k in $PRESS_MAP.Keys){ if($urlHost -match [regex]::Escape($k)){ return $PRESS_MAP[$k] } }
  return ''
}

# ---------- 증권사 목록 로드 ----------
$companiesPath = Join-Path $DataDir 'companies.json'
if(-not (Test-Path $companiesPath)){ throw "증권사 목록 없음: $companiesPath" }
$companyList = @((Get-Content $companiesPath -Raw -Encoding UTF8 | ConvertFrom-Json).companies)
if(-not $companyList -or $companyList.Count -eq 0){ throw "companies.json 의 companies 가 비어있음" }
Write-Host "[설정] 대상 증권사 $($companyList.Count)곳, 증권사당 $PagesPerCompany 페이지"

# ---------- 수집 ----------
$items = @()          # 원시 수집 항목
$callCount = 0
foreach($c in $companyList){
  $name  = $c.name
  $query = if($c.query){ $c.query } else { $c.name }
  $got = 0
  for($p=0; $p -lt $PagesPerCompany; $p++){
    $start = 1 + ($p * 100)
    if($start -gt 1000){ break }
    $uri = "{0}?query={1}&display=100&start={2}&sort=date" -f $ApiUrl, [uri]::EscapeDataString($query), $start
    try{
      $resp = Invoke-RestMethod -Uri $uri -Headers $Headers -TimeoutSec 30
      $callCount++
    }catch{
      Write-Warning "[$name] 조회 실패(start=$start): $($_.Exception.Message)"
      break
    }
    if(-not $resp.items -or $resp.items.Count -eq 0){ break }
    foreach($it in $resp.items){
      $pd = Convert-PubDate $it.pubDate
      $link = if($it.link){ $it.link } else { $it.originallink }
      $items += [ordered]@{
        title       = Clear-Html $it.title
        description = Clear-Html $it.description
        link        = $link
        originallink= $it.originallink
        press       = Get-Press $it.originallink
        pubDate     = $pd.iso
        date        = $pd.date
        company     = $name
      }
      $got++
    }
    if($resp.items.Count -lt 100){ break }   # 마지막 페이지
    if($ThrottleMs -gt 0){ Start-Sleep -Milliseconds $ThrottleMs }
  }
  Write-Host ("[{0}] {1}건" -f $name, $got)
}
Write-Host "[수집] 원시 $($items.Count)건 (API 콜 $callCount회)"

# ---------- dedup (link 기준; 없으면 정규화 제목) + 증권사 병합 ----------
function Get-Key($h){
  if(-not [string]::IsNullOrWhiteSpace($h.link)){ return "L|$($h.link)" }
  return "T|$(($h.title -replace '\s+','').ToLower())"
}
$byKey = [ordered]@{}
foreach($h in $items){
  $k = Get-Key $h
  if($byKey.Contains($k)){
    $ex = $byKey[$k]
    if($ex.companies -notcontains $h.company){ $ex.companies = @($ex.companies + $h.company) }
  } else {
    $byKey[$k] = [ordered]@{
      title=$h.title; description=$h.description; link=$h.link; originallink=$h.originallink
      press=$h.press; pubDate=$h.pubDate; date=$h.date; companies=@($h.company)
    }
  }
}
$current = @($byKey.Values | Sort-Object -Stable -Descending -Property @{Expression={ "$($_.pubDate)" }})
Write-Host "[dedup] 고유 $($current.Count)건"

$nowUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
if(-not (Test-Path $DataDir)){ New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }

# ---------- news.json (이번 실행 스냅샷) ----------
$newsObj = [ordered]@{
  lastUpdated = $nowUtc
  source      = 'Naver News Search API (https://openapi.naver.com/v1/search/news.json)'
  count       = $current.Count
  news        = @($current)
}
$newsPath = Join-Path $DataDir 'news.json'
($newsObj | ConvertTo-Json -Depth 8) | Set-Content -Path $newsPath -Encoding UTF8
Write-Host "→ $newsPath ($($current.Count)건)"

# ---------- news_history.json (누적) ----------
$histPath = Join-Path $DataDir 'news_history.json'
$existing = @()
if(Test-Path $histPath){
  try{ $existing = @((Get-Content $histPath -Raw -Encoding UTF8 | ConvertFrom-Json).news) }catch{ $existing=@() }
}
# 병합: 키 기준 dedup, 기존+신규 합치고 companies 합집합
$merged = [ordered]@{}
foreach($h in @($existing) + @($current)){
  if($null -eq $h){ continue }
  $k = Get-Key $h
  if($merged.Contains($k)){
    $ex = $merged[$k]
    foreach($co in @($h.companies)){ if($ex.companies -notcontains $co){ $ex.companies = @($ex.companies + $co) } }
    if([string]::IsNullOrWhiteSpace($ex.press) -and $h.press){ $ex.press = $h.press }
  } else {
    $merged[$k] = [ordered]@{
      title=$h.title; description=$h.description; link=$h.link; originallink=$h.originallink
      press=$h.press; pubDate=$h.pubDate; date=$h.date; companies=@($h.companies)
    }
  }
}
# 보존기간 정리(date 기준) + 정렬
$cut = (Get-Date).AddDays(-$HistoryRetentionDays).ToString('yyyy-MM-dd')
$mergedArr = @($merged.Values) |
  Where-Object { [string]::IsNullOrWhiteSpace($_.date) -or $_.date -ge $cut }
$mergedArr = @($mergedArr | Sort-Object -Stable -Descending -Property @{Expression={ "$($_.pubDate)" }})

$histObj = [ordered]@{
  lastUpdated = $nowUtc
  source      = 'Naver News Search API'
  retentionDays = $HistoryRetentionDays
  count       = $mergedArr.Count
  news        = @($mergedArr)
}
($histObj | ConvertTo-Json -Depth 8) | Set-Content -Path $histPath -Encoding UTF8
Write-Host "→ $histPath (누적 $($mergedArr.Count)건, 보존 ${HistoryRetentionDays}일)"
Write-Host "완료: $nowUtc"
