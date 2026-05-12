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
| **L7 — UA** | Caddy `BAD_UA` | sqlmap/nikto/masscan 등 스캐너 UA + 빈 UA 차단 |
| **L7 — Path** | Caddy `BLOCK_BOTS` | `/wp-admin`, `/.env`, `/actuator/*` 등 흔한 스캔 경로 |
| **L7 — Rate** | Caddy `RATE_LIMIT_DEFAULT` | IP당 60req/min |
| **L7 — Auth Rate** | Caddy `RATE_LIMIT_STRICT` | `/api/auth/*` 등 로그인 경로 10req/5min |
| **App** | Proxmox/Immich 자체 | 강한 패스워드 + (가능하면) 2FA |

## 구조

```
.
├── Caddyfile              # 글로벌 옵션 + snippets/sites import (crowdsec 글로벌 포함)
├── docker-compose.yml     # caddy (serfriz 빌드) + crowdsec 사이드카
├── install.sh             # 알파인 LXC에서 한 줄 부트스트랩 (cron + bouncer 등록까지)
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

## 부트스트랩 (Alpine LXC, root)

```sh
curl -fsSL https://raw.githubusercontent.com/Yon-Fandorin/proxmox-caddy/main/install.sh | sh
# .env 비어있으면 여기서 멈춤. 채우고 다시:
cd /root/proxmox-caddy && sh install.sh
```

설치 스크립트가 자동으로 처리:
- Docker + compose 설치
- DB-IP Lite mmdb 첫 다운로드
- Caddyfile 검증 + 컨테이너 기동 (caddy + crowdsec)
- CrowdSec 컬렉션 설치 + bouncer 등록 (`.env` 에 API key 주입) + LAN 화이트리스트
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
2. `sites/portainer.caddy` 작성:
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

   	reverse_proxy http://{$PORTAINER_HOST}:9000
   }
   ```
3. CF 에 A 레코드(gray cloud) 추가 → 검증/리로드:
   ```sh
   docker compose run --rm --entrypoint caddy caddy validate \
   	--config /etc/caddy/Caddyfile --adapter caddyfile
   docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
   ```

`sites/pve.caddy` 가 살아있는 레퍼런스.

## 운영 메모

- **로그**
  - 시스템: `./data/caddy-system.log` (5MB × 3, 7일)
  - 사이트별 access: `./data/access-<name>.log`
  - cron: `./data/cron.log` (mmdb / IPsum 갱신 결과)
  - 컨테이너 stdout: `docker compose logs -f caddy`
- **healthcheck**: 내부 admin API(`:2019/config/`) 를 `wget --spider`. unhealthy 자동 재시작 안 됨 — 필요해지면 autoheal 컨테이너 추가.
- **이미지 핀**: `serfriz/caddy-cloudflare-crowdsec-geoip-ratelimit-security:2.11.2` + `crowdsecurity/crowdsec:v1.6.4`. 업그레이드는 [serfriz 릴리스](https://github.com/serfriz/caddy-custom-builds/releases) / [crowdsec 릴리스](https://github.com/crowdsecurity/crowdsec/releases) 확인 후 의도적으로.
- **caddy-security 모듈**: 이미지에 포함되어 있으나 dormant. forward-auth/2FA 게이트 필요해지면 활성화.
- **방화벽**: 공유기에서 80, 443 만 외부 노출. Proxmox 8006, SSH 등은 LAN-only.
- **mmdb 라이선스**: DB-IP Lite는 CC BY 4.0. 사적 origin 필터링은 attribution 의무 없음.

## 트러블슈팅

| 증상 | 1차 점검 |
|---|---|
| 모든 요청 403 | mmdb 못 읽었을 가능성. `ls -la geoip/dbip-country-lite.mmdb` 존재/크기 확인 → `sh scripts/update-dbip.sh` 재실행. 또는 KR 외 IP 에서 접속 중인 거 아닌지. |
| `.env` 빈 값 → 깨진 URL | install.sh 에서 잡아주지만 손편집 후엔 직접 확인. |
| ACME 인증서 못 받음 | CF 토큰 권한(Zone:Read + DNS:Edit), Zone Resources 범위, 도메인이 zone 에 속하는지. `data/caddy-system.log` 의 `acme` 라인 확인. |
| 502/504 | LXC에서 `${SVC_HOST}:${SVC_PORT}` 직접 curl 되는지. Proxmox 는 self-signed → `tls_insecure_skip_verify` 필수 (이미 적용). |
| unhealthy | `wget --spider http://localhost:2019/config/` 직접 실행. admin API 안 뜨면 부팅 실패. |
| cron 안 돔 | `service crond status`, `cat /etc/crontabs/root`, `tail data/cron.log`. Alpine 이라면 crond 자동 시작 안 되는 경우 있음 → `rc-update add crond default && service crond start`. |
| Immich 모바일 앱 업로드 실패 | `RATE_LIMIT_DEFAULT` 가 60/min 이라 대량 초기 동기화 시 일시 429. 한 번 정착하면 OK. 필요하면 `immich.caddy` 에서 `RATE_LIMIT_DEFAULT` 빼거나 zone 의 events 늘리기. |
| 정상 IP인데 403 | CrowdSec 결정이 차단했을 가능성. `docker compose exec crowdsec cscli decisions list` 로 확인 → 본인 IP면 `cscli decisions delete --ip <IP>`. LAN IP가 차단됐다면 화이트리스트 파서가 안 먹은 것 — `setup-crowdsec.sh` 재실행. |
| CrowdSec 컬렉션 누락 | `docker compose exec crowdsec cscli hub list` 로 설치 상태 확인. 누락 시 `cscli collections install crowdsecurity/<name>`. |

## 기존 설치 업그레이드

`install.sh` 는 처음 한 번만 쓰는 부트스트랩이고, 이후 갱신은 `git pull` 기반:

```sh
cd ~/proxmox-caddy
git pull
# KR_ONLY 가 mmdb 를 요구하므로 없으면 한 번 시드 (idempotent):
sh scripts/update-dbip.sh
# 새 이미지 pull + 재기동 (config 변경분 적용)
docker compose pull
docker compose up -d
```

cron 라인은 install.sh 가 idempotent 하게 등록하니 한 번 install.sh 돌렸다면 추가 작업 불필요.

## CrowdSec 운영

### 첫 설치 후 Console 등록 (Community Blocklist 받기)

1. https://app.crowdsec.net 무료 가입 → "Add a security engine" → enroll token 복사
2. LXC 에서:
   ```sh
   docker compose exec crowdsec cscli console enroll <enroll-token>
   ```
3. Console 웹 UI → 해당 엔진 → "Blocklists" → Community Blocklist 구독
4. 몇 분 뒤 결정 동기화:
   ```sh
   docker compose exec crowdsec cscli decisions list
   ```

### 일상 운영 명령

```sh
# 현재 차단 중인 IP 목록
docker compose exec crowdsec cscli decisions list

# 특정 IP 차단 해제 (오탐 / 본인 IP)
docker compose exec crowdsec cscli decisions delete --ip 1.2.3.4

# 결정 통계 / 시나리오 적중률
docker compose exec crowdsec cscli metrics

# 설치된 컬렉션
docker compose exec crowdsec cscli collections list

# 추가 컬렉션 설치 (예: nginx 추가 시 등)
docker compose exec crowdsec cscli collections install crowdsecurity/<name>
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
