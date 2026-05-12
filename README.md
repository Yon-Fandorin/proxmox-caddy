# proxmox-caddy

Proxmox 웹 UI(및 다른 내부 서비스)를 Caddy 리버스 프록시로 외부 노출하기 위한 셋업.
Alpine LXC 안에서 Docker로 Caddy를 돌리고, TLS는 Cloudflare DNS-01 챌린지로 자동 발급.

**현재 운영 모드: gray-cloud (DNS-only, CF 프록시 OFF)**
오리진 IP가 그대로 노출되므로 Caddy 자체에서 GeoIP / IP blocklist / rate-limit 으로 방어.

## 위협 모델 / 방어 계층

| 계층 | 어디서 | 무엇 |
|---|---|---|
| **L4** | ASUS 공유기 | 80/443 만 포워딩, AiProtection Pro on, 관리 페이지 LAN-only |
| **L7 — 적응형 IP** | CrowdSec + caddy bouncer | 액세스 로그 기반 시나리오 차단 + Community Blocklist (Console enroll) |
| **L7 — GeoIP** | Caddy `KR_ONLY` | DB-IP Lite mmdb로 비-KR 트래픽 403 |
| **L7 — UA** | Caddy `BAD_UA` | sqlmap/nikto/masscan/nuclei/ffuf/httpx/python-requests 등 스캐너·스크립트 UA + 부재/빈 UA 차단 |
| **L7 — Path** | Caddy `BLOCK_BOTS` | `/wp-admin`, `/.env`, `/actuator/*` 등 흔한 스캔 경로 |
| **L7 — Rate** | Caddy `RATE_LIMIT_DEFAULT` | IP당 300req/min (SPA 첫 로드 30~50req 흡수, 봇 스크레이핑 차단 가능 수준) |
| **L7 — Auth Rate** | Caddy `RATE_LIMIT_STRICT` | `/api/auth/*` 등 로그인 경로 10req/5min |
| **App** | Proxmox/Immich 자체 | 강한 패스워드 + (가능하면) 2FA |

## 구조

```
.
├── Caddyfile              # 글로벌 옵션 + snippets/sites import (crowdsec 글로벌 포함)
├── docker-compose.yml     # caddy (serfriz 빌드) + crowdsec 사이드카
├── install.sh             # 알파인 LXC에서 한 줄 부트스트랩 (cron + bouncer + cscli wrapper)
├── .env(.example)         # 토큰/도메인/업스트림 + CROWDSEC_BOUNCER_API_KEY (커밋 금지)
├── snippets/              # 재사용 블록 (CROWDSEC, KR_ONLY, BLOCK_BOTS, RATE_LIMIT_*, BAD_UA, …)
├── sites/                 # 사이트 1개당 파일 1개
├── geoip/                 # DB-IP Lite mmdb (gitignored, cron 자동 갱신)
├── crowdsec/
│   ├── acquis.d/          # 액세스 로그 acquisition (ro 마운트)
│   ├── whitelists/        # LAN 화이트리스트 파서 (setup-crowdsec.sh가 컨테이너에 복사)
│   ├── config/            # 컨테이너 관리 (gitignored)
│   └── data/              # 결정 DB (gitignored)
└── scripts/               # update-dbip.sh, setup-crowdsec.sh
```

호스트에 추가로 생기는 것:
- `/usr/bin/cscli` — `docker compose exec crowdsec cscli ...` 를 줄여주는 한 줄 wrapper.
  `pct enter` 가 /etc/profile 안 거쳐서 /usr/local/bin 이 PATH 에 없는 경우 대비.

## 부트스트랩 (Alpine LXC, root)

```sh
curl -fsSL https://raw.githubusercontent.com/Yon-Fandorin/proxmox-caddy/main/install.sh | sh
# .env 비어있으면 여기서 멈춤. 채우고 다시:
cd /root/proxmox-caddy && sh install.sh
```

설치 스크립트가 자동으로 처리:
- Docker + compose 설치
- DB-IP Lite mmdb 첫 다운로드
- crowdsec 먼저 기동 → bouncer 등록 → `.env` 에 API key 주입 → LAN 화이트리스트 → Caddyfile 검증 → caddy 기동 (순서 중요)
- `/usr/bin/cscli` wrapper 설치 (host 어디서든 `cscli ...` 동작)
- cron 등록 (mmdb 매월 1일)

프라이빗 레포면 `GH_PAT=ghp_xxx` 앞에 붙여 실행.

> 첫 설치 후 CrowdSec Console 등록(무료) 한 번 더 하면 Community Blocklist 가 들어옴.
> 자세한 절차는 아래 [CrowdSec 운영](#crowdsec-운영) 섹션.

## .env 채우기

`.env.example` → `.env` 복사 후:

| 키 | 어디서 / 어떻게 |
|---|---|
| `ACME_EMAIL` | Let's Encrypt 만료 알림 받을 메일. |
| `CLOUDFLARE_API_TOKEN` | CF 대시보드 → My Profile → API Tokens → **Create Token** → "Edit zone DNS" 템플릿. **Zone Resources는 해당 도메인 1개로 한정**. 권한은 `Zone:Read` + `DNS:Edit`. |
| `DOMAIN` | apex 도메인 (예: `example.com`). 모든 사이트가 공유. |
| `PVE_SUBDOMAIN` | 기본 `pve`. 최종 호스트 = `${PVE_SUBDOMAIN}.${DOMAIN}`. |
| `PVE_HOST` / `PVE_PORT` | Proxmox 웹 UI의 LAN 주소. 보통 `PVE_PORT=8006`. |
| `IMMICH_SUBDOMAIN` / `IMMICH_HOST` / `IMMICH_PORT` | Immich 서비스 (없으면 sites 에서 immich.caddy 삭제). |
| `CROWDSEC_BOUNCER_API_KEY` | **건드리지 않음** — `scripts/setup-crowdsec.sh` 가 첫 설치 시 자동 주입. 로테이션 시에만 비우고 재실행. |

> CF 토큰은 한 번만 표시됨. 잃어버리면 재발급.

## DNS 설정 (CF, gray-cloud)

각 서브도메인의 A 레코드를 **공인 IP** 로 만들고, **Proxy 상태를 "DNS only" (회색 구름)** 으로. 오렌지(프록시) 면 CF 100MB 업로드 캡이 걸리고 KR_ONLY 가 CF IP 만 보게 돼서 정상 동작 안 함.

## 새 사이트 추가하는 법

1. `.env`에 서브도메인 + 업스트림 변수 추가:
   ```
   PORTAINER_SUBDOMAIN=portainer
   PORTAINER_HOST=192.168.x.y
   ```
2. `sites/portainer.caddy` 작성 — 단순 케이스 (auth 경로 분리 안 필요):
   ```caddy
   {$PORTAINER_SUBDOMAIN}.{$DOMAIN} {
   	import SECURITY_HEADERS
   	import CROWDSEC
   	import KR_ONLY
   	import BAD_UA
   	import BLOCK_BOTS
   	import RATE_LIMIT_DEFAULT portainer
   	import LOGGING portainer

   	tls {
   		dns cloudflare {$CLOUDFLARE_API_TOKEN}
   		resolvers 1.1.1.1 1.0.0.1
   	}

   	# top-level reverse_proxy — directive 우선순위상 respond 매처들이 다 평가된 뒤 발동.
   	# 절대 catch-all `handle { reverse_proxy }` 로 감싸지 말 것 (handle 이 respond 보다
   	# 먼저라 BAD_UA/BLOCK_BOTS/KR_ONLY 매처가 모두 우회됨).
   	reverse_proxy http://{$PORTAINER_HOST}:9000
   }
   ```

   auth 경로에 strict rate-limit 깔고 싶으면 `sites/immich.caddy` 참고 — `@auth path /api/auth/*` 매처 + `route @auth { import RATE_LIMIT_STRICT ... }` 패턴 (route 가 terminal handler 없으면 fall-through 하므로 strict rate-limit 만 더하고 catch-all reverse_proxy 가 처리).
3. CF 에 A 레코드(gray cloud) 추가 → 검증/리로드:
   ```sh
   docker compose run --rm --entrypoint caddy caddy validate \
   	--config /etc/caddy/Caddyfile --adapter caddyfile
   docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
   ```

`sites/pve.caddy` 가 살아있는 레퍼런스.

## 운영 메모

- **로그**
  - 시스템: `./data/caddy-system.log` (5MB × 3, 7일) — Caddy 가 default logger 를 여기로 리다이렉트하므로 `docker logs caddy` 엔 거의 안 보임
  - 사이트별 access: `./data/<service>-access.log` (예: `immich-access.log` — LOGGING snippet arg 기반, 서브도메인 무관)
  - cron: `./data/cron.log` (mmdb 갱신 결과)
  - 컨테이너 stdout: `docker compose logs -f caddy crowdsec`
- **healthcheck**: 내부 admin API(`http://127.0.0.1:2019/config/`)를 `wget --spider` 로 찌름. **`localhost` 대신 `127.0.0.1` 명시** 필수 — busybox wget 이 `localhost` 를 `::1` 로 resolve 하면서 v4 fallback 안 하고, Caddy admin 은 v4 만 listen 해서 v6 probe 가 refused → 컨테이너 unhealthy 오탐.
- **이미지 핀**: `serfriz/caddy-cloudflare-crowdsec-geoip-ratelimit-security:2.11.2` + `crowdsecurity/crowdsec:v1.6.4`. 업그레이드는 [serfriz 릴리스](https://github.com/serfriz/caddy-custom-builds/releases) / [crowdsec 릴리스](https://github.com/crowdsecurity/crowdsec/releases) 확인 후 의도적으로.
- **caddy-security 모듈**: 이미지에 포함되어 있으나 dormant. forward-auth/2FA 게이트 필요해지면 활성화.
- **방화벽**: 공유기에서 80, 443 만 외부 노출. Proxmox 8006, SSH 등은 LAN-only.
- **mmdb 라이선스**: DB-IP Lite는 CC BY 4.0. 사적 origin 필터링은 attribution 의무 없음.
- **immich routing 주의**: `sites/immich.caddy` 가 top-level `reverse_proxy` 를 쓰고 auth path 만 `route` 로 분기하는 이유 — `handle` 은 Caddy directive 우선순위에서 `respond` 보다 먼저라 catch-all `handle { reverse_proxy }` 를 두면 KR_ONLY/BAD_UA/BLOCK_BOTS respond 매처가 한 번도 못 도는 함정 있음.

## 트러블슈팅

| 증상 | 1차 점검 |
|---|---|
| 모든 요청 403 | mmdb 못 읽었을 가능성. `ls -la geoip/dbip-country-lite.mmdb` 존재/크기 확인 → `sh scripts/update-dbip.sh` 재실행. 또는 KR 외 IP 에서 접속 중인 거 아닌지. |
| `.env` 빈 값 → 깨진 URL | install.sh 에서 잡아주지만 손편집 후엔 직접 확인. |
| ACME 인증서 못 받음 | CF 토큰 권한(Zone:Read + DNS:Edit), Zone Resources 범위, 도메인이 zone 에 속하는지. `data/caddy-system.log` 의 `acme` 라인 확인. |
| 502/504 | LXC에서 `${SVC_HOST}:${SVC_PORT}` 직접 curl 되는지. Proxmox 는 self-signed → `tls_insecure_skip_verify` 필수 (이미 적용). |
| unhealthy | `wget --spider http://localhost:2019/config/` 직접 실행. admin API 안 뜨면 부팅 실패. |
| cron 안 돔 | `service crond status`, `cat /etc/crontabs/root`, `tail data/cron.log`. Alpine 이라면 crond 자동 시작 안 되는 경우 있음 → `rc-update add crond default && service crond start`. |
| Immich SPA 로드 시 429 | `RATE_LIMIT_DEFAULT` 가 너무 빡빡한 것. 현재 300/min 이라 정상이어야 하지만 대량 초기 동기화 + 다중 사용자 동시 접속 시엔 일시적으로 가능. `snippets/rate-limit.caddy` 의 `events 300` 을 `events 600` 으로 올리고 `caddy reload`. |
| 정상 IP인데 403 | CrowdSec 결정이 차단했을 가능성. `cscli decisions list` 로 확인 → 본인 IP면 `cscli decisions delete --ip <IP>`. LAN IP가 차단됐다면 화이트리스트 파서가 안 먹은 것 — `sh scripts/setup-crowdsec.sh` 재실행. |
| CrowdSec 컬렉션 누락 | `cscli hub list` 로 설치 상태 확인. 누락 시 `cscli collections install crowdsecurity/<name> && docker compose restart crowdsec`. |
| Caddy unhealthy 그러나 사이트는 정상 | healthcheck 의 wget 가 v6 로 `localhost` resolve 후 refused. `docker-compose.yml` 의 healthcheck URL 이 `127.0.0.1:2019` 인지 확인. |
| 방어 매처 (BAD_UA/BLOCK_BOTS/KR_ONLY) 가 안 잡힘 | site 파일에 top-level `handle` 블록 두지 마라. `handle` 이 directive 우선순위에서 `respond` 보다 먼저 — catch-all 이면 매처들 우회. `route` (terminal handler 없으면 fall-through) 사용. `sites/immich.caddy` 가 살아있는 참고. |

## 기존 설치 업그레이드

`install.sh` 는 idempotent 라 그대로 재실행하면 최신 코드 tarball 받아서 `/root/proxmox-caddy/` 에 덮어쓰고, 컨테이너 재기동 + cron + cscli wrapper 까지 모두 갱신:

```sh
sh /root/proxmox-caddy/install.sh
```

기존 `.env` 는 보존, bouncer API key 도 보존 (`setup-crowdsec.sh` 가 자동 스킵).

수동 git 기반으로 운영한다면 (`git clone` 으로 셋업한 경우):
```sh
cd ~/proxmox-caddy && git pull
sh scripts/update-dbip.sh           # mmdb 없으면 시드
docker compose pull && docker compose up -d
```

## CrowdSec 운영

### 첫 설치 후 Console 등록 (Community Blocklist 받기)

1. https://app.crowdsec.net 무료 가입 → "Add a security engine" → enroll token 복사
2. LXC 에서:
   ```sh
   cscli console enroll <enroll-token>
   ```
3. Console 웹 UI → **Security Engines** 에서 **Accept** 클릭
4. 엔진 상세 → **Blocklists** → Community Blocklist 구독 확인 (보통 자동 체크됨)
5. **Console-managed blocklists 활성화** (default 꺼져있어서 Community Blocklist 가 안 내려옴):
   ```sh
   cscli console enable console_management
   docker compose restart crowdsec
   ```
6. 5~10분 후 동기화 확인:
   ```sh
   cscli decisions list --origin CAPI -o raw | wc -l   # 수만 건 떠야 정상
   ```

### 일상 운영 명령

`install.sh` 가 `/usr/bin/cscli` wrapper 를 깔아두므로 호스트에서 그냥 `cscli ...` 쓰면 됨 (내부적으로 `docker compose exec crowdsec cscli ...` 로 위임).

```sh
# 현재 차단 중인 IP 목록 (community blocklist 포함하려면 --origin CAPI)
cscli decisions list
cscli decisions list --origin CAPI -o raw | wc -l   # community-blocklist 카운트

# 특정 IP 차단 해제 (오탐 / 본인 IP)
cscli decisions delete --ip 1.2.3.4

# 결정 통계 / 시나리오 적중률
cscli metrics

# 설치된 컬렉션
cscli collections list

# 추가 컬렉션 설치 (예: nginx 추가 시 등)
cscli collections install crowdsecurity/<name>
docker compose restart crowdsec

# bouncer API key 로테이션
# 1) .env 의 CROWDSEC_BOUNCER_API_KEY 라인을 빈 값으로
# 2) 재실행 (멱등 — 기존 bouncer 삭제 후 재등록)
sh scripts/setup-crowdsec.sh
```

## Cron 스크립트 수동 실행

```sh
# DB-IP Lite mmdb 갱신
sh scripts/update-dbip.sh
```

`caddy reload` 가 자동으로 호출됨 — 새 데이터 즉시 반영. CrowdSec 결정 DB 는 LAPI 가 자체 갱신하므로 cron 불필요.
