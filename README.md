# proxmox-caddy

Proxmox 웹 UI(및 향후 다른 내부 서비스)를 Cloudflare 뒤의 Caddy로 리버스 프록시하기 위한 셋업.
Alpine LXC 안에서 Docker로 Caddy를 돌리고, TLS는 Cloudflare DNS-01 챌린지로 자동 발급.

## 구조

```
.
├── Caddyfile              # 글로벌 옵션 + snippets/sites import
├── docker-compose.yml     # caddy 컨테이너 (CaddyBuilds 이미지: cloudflare DNS + IP 플러그인 포함)
├── install.sh             # 알파인 LXC에서 한 줄 부트스트랩
├── .env(.example)         # 토큰/도메인/업스트림 (커밋 금지)
├── snippets/              # 재사용 블록 (LOGGING, SECURITY_HEADERS, CLOUDFLARE_ONLY, BLOCK_BOTS)
└── sites/                 # 사이트 1개당 파일 1개
```

## 부트스트랩 (Alpine LXC, root)

```sh
curl -fsSL https://raw.githubusercontent.com/Yon-Fandorin/proxmox-caddy/main/install.sh | sh
# .env 비어있으면 여기서 멈춤. 채우고 다시:
cd /root/proxmox-caddy && docker compose up -d
```

프라이빗 레포라면 `GH_PAT=ghp_xxx` 를 앞에 붙여 실행 (`install.sh` 헤더 참고).

## .env 채우기

`.env.example` → `.env` 복사 후 다음 4개를 채운다.

| 키 | 어디서 / 어떻게 |
|---|---|
| `ACME_EMAIL` | Let's Encrypt 만료 알림 받을 메일. 본인 메일이면 충분. |
| `CLOUDFLARE_API_TOKEN` | Cloudflare 대시보드 → My Profile → API Tokens → **Create Token** → "Edit zone DNS" 템플릿. **Zone Resources는 해당 도메인 1개로 한정**. 권한은 `Zone:Read` + `DNS:Edit`만. |
| `DOMAIN` | apex 도메인 (예: `example.com`). 모든 사이트가 공유. |
| `PVE_SUBDOMAIN` | Proxmox 가 노출될 서브도메인 (기본 `pve`). 최종 호스트 = `${PVE_SUBDOMAIN}.${DOMAIN}`. Cloudflare에 그 FQDN의 A 레코드(공인 IP 또는 터널)가 등록돼 있어야 함. |
| `PVE_HOST` / `PVE_PORT` | Proxmox 웹 UI의 LAN 주소. 보통 `PVE_PORT=8006` 그대로. |

> 토큰은 한 번만 표시되니 만들자마자 .env에 박아 넣을 것. 잃어버리면 재발급.

## 새 사이트 추가하는 법

1. `.env`에 그 사이트의 서브도메인 + 업스트림 변수 추가 (예: `PORTAINER_SUBDOMAIN=portainer`, `PORTAINER_HOST=192.168.x.y`). `DOMAIN` 은 이미 잡혀있으니 재사용.
2. `sites/<name>.caddy` 새로 만들기. 예시:

   ```caddy
   # sites/portainer.caddy — Portainer admin UI
   {$PORTAINER_SUBDOMAIN}.{$DOMAIN} {
   	import SECURITY_HEADERS
   	import CLOUDFLARE_ONLY
   	import BLOCK_BOTS
   	import LOGGING portainer

   	tls {
   		dns cloudflare {$CLOUDFLARE_API_TOKEN}
   		resolvers 1.1.1.1 1.0.0.1
   	}

   	reverse_proxy http://{$PORTAINER_HOST}:9000
   }
   ```

3. 검증 후 리로드:

   ```sh
   docker compose run --rm --entrypoint caddy caddy validate \
       --config /etc/caddy/Caddyfile --adapter caddyfile
   docker compose restart caddy   # 또는: docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
   ```

`sites/pve.caddy` 가 살아있는 레퍼런스. snippet import 순서 그대로 따라가면 보안 헤더/CF-only/봇 차단/로깅이 한 줄씩에 다 붙는다.

## 운영 메모

- **로그 위치**
  - 시스템 로그(ACME, 에러, 시작/리로드): `./data/caddy-system.log` (5MB × 3, 7일)
  - 사이트별 액세스 로그: `./data/access-<name>.log` (LOGGING snippet 정의 따름)
  - 컨테이너 stdout: `docker compose logs -f caddy` — `docker-compose.yml`에서 10MB × 3으로 회전 캡 걸어둠.
- **healthcheck**: Caddy 내부 admin API(`:2019/config/`)를 `wget --spider`로 찌른다. `docker ps` 에서 healthy/unhealthy 보임. unhealthy여도 자동 재시작은 안 됨 (`restart: unless-stopped` 는 unhealthy 신호로 안 죽음) — 필요해지면 `autoheal` 컨테이너 추가.
- **이미지 핀**: `ghcr.io/caddybuilds/caddy-cloudflare:2.11.2` 고정. 업그레이드는 [릴리스 노트](https://github.com/CaddyBuilds/caddy-cloudflare/releases) 보고 의도적으로.
- **trusted_proxies**: `cloudflare` IP 소스가 CF 공인 IP 대역을 자동 갱신해줌 — 수동 관리 불필요.
- **방화벽**: LXC/호스트에서 80, 443만 외부 노출. Proxmox 8006 포트는 외부에 직접 열지 말 것 (Caddy 통해서만).

## 트러블슈팅

| 증상 | 1차 점검 |
|---|---|
| `https://:8006` 같은 깨진 URL | `.env`에 빈 값 있음. `install.sh`가 잡아주지만 손편집 후엔 직접 확인. |
| ACME가 인증서 못 받음 | CF 토큰 권한(Zone:Read + DNS:Edit), Zone Resources 범위, `PVE_DOMAIN` 의 도메인이 그 zone에 속하는지. `data/caddy-system.log` 의 `acme` 라인 확인. |
| 502/504 from Caddy | LXC에서 `PVE_HOST:PVE_PORT` 로 직접 curl 되는지. Proxmox는 self-signed라서 `tls_insecure_skip_verify` 필수 (이미 들어가 있음). |
| unhealthy 표시 | 컨테이너 안에서 `wget --spider http://localhost:2019/config/` 직접 실행해 보기. 어드민 API가 떠있지 않으면 Caddy 자체가 부팅 실패. |
