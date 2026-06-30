# 증권사 뉴스 모니터 (Naver Securities News Feed)

네이버 뉴스 검색 API로 **국내 주요 증권사** 관련 뉴스만 취합해
**날짜대 + 키워드 + 증권사** 필터로 모니터링하는 단일 화면.

구조: PowerShell 수집기 → `data/*.json`(현재+히스토리 누적) → GitHub Actions 크론 → 단독 `index.html`(외부 라이브러리 없음).

```
scripts/collect-news.ps1          # 수집기
data/companies.json               # 모니터링 대상 증권사 (편집 가능)
data/news.json                    # 최근 실행 스냅샷 (자동 생성)
data/news_history.json            # 누적·중복제거·보존 90일 (자동 생성, 현재는 샘플)
.github/workflows/fetch-news.yml  # 1시간 간격 자동 수집·커밋
index.html                        # 모니터링 화면
```

---

## 단계 0 — 네이버 검색 API 키 발급 (최초 1회)

1. https://developers.naver.com → 로그인 → **Application → 애플리케이션 등록**
2. 사용 API에서 **검색** 추가, 환경은 **WEB 설정**(URL은 아무 값이나, 예: `http://localhost`)
3. 발급된 **Client ID / Client Secret** 복사
4. 무료. 일 25,000콜 제한(이 프로젝트는 하루 약 1,000콜 미만 사용).

---

## 단계 1 — 로컬에서 수집기 실행·검증

PowerShell 7(`pwsh`)에서:

```powershell
$env:NAVER_CLIENT_ID     = '여기에_CLIENT_ID'
$env:NAVER_CLIENT_SECRET = '여기에_CLIENT_SECRET'
pwsh ./scripts/collect-news.ps1
```

→ `data/news.json`, `data/news_history.json` 갱신. 콘솔에 증권사별 건수가 출력됩니다.
모니터링 대상은 `data/companies.json` 에서 자유롭게 추가/삭제하세요.

옵션: `-PagesPerCompany 3`(증권사당 최대 300건), `-HistoryRetentionDays 120` 등.

---

## 단계 2 — 화면 로컬 미리보기

`file://` 로 직접 열면 fetch 가 막힙니다. 정적 서버로 여세요:

```powershell
python -m http.server 8080
# 브라우저: http://localhost:8080
```

날짜(오늘/7일/30일/전체) · 키워드(OR/AND, 하이라이트) · 증권사 칩 필터를 확인합니다.
※ 키 발급 전에도 `data/news_history.json` 의 **샘플 데이터**로 화면이 바로 보입니다.

### 관심어(키워드) 버튼 — 화면에서 직접 편집
- **관심어** 줄의 버튼을 누르면 검색창에 자동 반영(다시 누르면 해제), 기존 OR/AND·하이라이트와 연동.
- 우측 **✎ 편집** → 각 버튼에 ✕(삭제) 표시 + 하단에 추가 폼 등장:
  - `검색어`(실제 매칭어, 필수) · `표시명`(버튼에 보일 이름, 선택) · `카테고리`(장애·리스크 / 시장·실적 / 고객·상품 / 기타) → **+ 추가**
  - **기본값 복원** 으로 초기 20개로 되돌리기.
- 변경 내용은 브라우저 `localStorage` 에 저장되어 새로고침해도 유지됩니다(이 브라우저 한정).
- 기본 내장 목록은 `index.html` 의 `DEFAULT_KW` 배열에서 직접 바꿀 수도 있습니다.

---

## 단계 3 — GitHub Actions 자동 수집

1. 이 폴더를 GitHub 저장소로 push (공개 뉴스+코드만 담기므로 **public repo** 권장 — 무료 Actions·Pages).
   키는 코드에 없고 Secrets 에만 둡니다.
2. 저장소 **Settings → Secrets and variables → Actions → New repository secret**:
   - `NAVER_CLIENT_ID`
   - `NAVER_CLIENT_SECRET`
3. **Actions** 탭 → `fetch-news` → **Run workflow** 로 수동 실행 테스트.
   - 이후 매시 정각 자동 수집·커밋(`data/*.json`). 주기는 `fetch-news.yml` 의 cron 으로 조정.

---

## 단계 4 — GitHub Pages 배포

**Settings → Pages → Source: Deploy from a branch → main / (root)** →
발급된 URL 로 `index.html` 열람. 수집기가 커밋하는 JSON 을 자동 반영합니다.

---

## 텔레그램 알림 (키워드 매칭 기사 자동 전송)

키워드에 매칭되는 **새 기사**를 텔레그램 채널/그룹으로 자동 전송한다.

- **동작**: 매시 수집(`collect-news.ps1`) 직후 `notify-telegram.ps1` 이 `data/alerts.json` 의 키워드로 `data/news.json` 을 매칭 → 미전송 기사만 텔레그램 전송 → 보낸 기사는 `data/alerted.json` 에 기록(중복 방지).
- **첫 실행은 시드**: 과거 매칭분은 "이미 본 것"으로만 표시하고 전송하지 않음(폭주 방지). 이후 새 기사만 전송.
- **Secrets**: `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` (Settings → Secrets). 미설정 시 전송 단계는 조용히 skip.
- **키워드 설정**: 사이트 우상단 **🔔 알림 설정**(`alerts.html`)에서 편집. GitHub 토큰(Contents 쓰기)을 브라우저에 1회 저장하면 키워드 변경이 `data/alerts.json` 으로 커밋됨. 또는 `data/alerts.json` 을 직접 수정해도 됨.
- **alerts.json 스키마**: `{ keywords:[...], logic:"OR"|"AND", recentHours:72, maxPerRun:30 }`

### 봇/채널 준비
1. @BotFather → `/newbot` → 토큰
2. 채널 생성 → 봇을 **관리자(메시지 게시 권한)** 로 추가 → 채널에 글 1개 게시
3. chat id: 봇이 관리자인 상태에서 `https://api.telegram.org/bot<TOKEN>/getUpdates` 의 `channel_post.chat.id`(`-100...`)

## 참고 / 한계
- 네이버 검색 API 는 **날짜 범위 파라미터가 없어** 최신순(`sort=date`)으로만 조회 → 과거 날짜대는 **가동 이후 누적분**에서 검색됩니다(첫 실행 시점부터 쌓임).
- 언론사명은 API 가 직접 주지 않아 `originallink` 호스트로 추정합니다(미상이면 공백). `collect-news.ps1` 의 `$PRESS_MAP` 에서 보강 가능.
- 검색 결과에 동명·무관 맥락 노이즈가 섞일 수 있습니다 → 필요 시 `companies.json` 의 `query` 를 정교화하세요.
