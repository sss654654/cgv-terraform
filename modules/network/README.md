# modules/network — VPC 와 그 안의 길

```
                          internet
                              │
                      Internet Gateway
                              │
 ┌─ VPC 10.20.0.0/16 ─────────┼───────────────────────────────┐
 │                            │ route table 0.0.0.0/0 -> IGW  │
 │          ┌─────────────────┼─────────────────┐             │
 │          v                 v                 v             │
 │   ┌─ subnet 2a ─┐   ┌─ subnet 2c ─┐   ┌─ subnet 2b ─┐      │
 │   │ /20, public │   │ /20, public │   │ /20, public │      │
 │   └─────────────┘   └─────────────┘   └─────────────┘      │
 │                                                            │
 │   SG alb-public   80, 443  <- 0.0.0.0/0                    │
 │   SG alb-admin    80       <- home IP /32                  │
 └────────────────────────────────────────────────────────────┘
```

## 집(온프레미스)과 짝을 맞추면

| 집 | 여기 |
|---|---|
| Proxmox `vmbr1` 대역 | VPC CIDR |
| `vmbr1` 가상 스위치 | 서브넷 |
| OPNsense 라우팅 · NAT | 라우팅 테이블 · Internet Gateway |
| OPNsense 방화벽 | 보안 그룹 |
| (없음) | **가용 영역** — 서브넷 하나는 AZ 하나 안에만 있다 |

집은 가만히 두면 닫혀 있고(포트포워딩을 안 하면 못 들어온다), 클라우드는 가만히 두면 열 수 있다. 여기서 적극적으로 좁힌다.

---

## 설정

| 설정 | 값 | 이유 |
|---|---|---|
| VPC | 10.20.0.0/16 · DNS support · hostnames | 집 대역(192.168.0.0/24 · 10.0.0.0/24)과 안 겹치게. RDS · ElastiCache 엔드포인트가 이름이라 DNS |
| 서브넷 | /20 × 3 (한 칸 4,091 주소) | VPC CNI 가 파드마다 VPC 주소를 하나씩 쓴다 |
| AZ | 변수로 받는다 · 목록 순번 = CIDR 순번 | AZ 마다 제공하는 인스턴스 타입이 달라 자동 선택하면 노드그룹이 멈출 수 있다. 새 AZ 는 목록 끝에 더해야 기존 서브넷이 안 바뀐다 |
| 서브넷 종류 | **퍼블릭만 · NAT 없음** · 공인 IP 자동 부여 | 아래 |
| 서브넷 태그 | `kubernetes.io/role/elb=1` · `kubernetes.io/cluster/<prefix>=shared` | ALB Controller 가 인터넷용 ALB 를 놓을 서브넷을 찾는다. 없으면 Ingress 를 만들다 멈춘다 |

### NAT 를 두지 않은 이유

| 선택지 | 결과 |
|---|---|
| 프라이빗 서브넷 + NAT 하나 | 그 AZ 가 죽으면 다른 AZ 노드도 밖으로 못 나간다 — AZ 셋으로 둔 뜻과 어긋난다 |
| 프라이빗 서브넷 + AZ 마다 NAT | 하루(8시간) 약 $1.4 + 처리 GB 당 $0.059 |
| **퍼블릭 서브넷 · IGW** | 노드마다 공인 IPv4 시간당 $0.005. 대신 노드에 공인 IP 가 붙어 보안 그룹으로 좁힌다 |

prd 는 프라이빗 서브넷 + AZ 마다 NAT 로 간다.

---

## 보안 그룹 — ALB 가 둘이라 둘

| 보안 그룹 | 인바운드 | 쓰는 곳 |
|---|---|---|
| `<prefix>-alb-public` | 80 · 443 ← `0.0.0.0/0` | 서비스 ALB. 누구나 대기열 · 예매를 쓴다. 80 은 443 리다이렉트만 받는다 |
| `<prefix>-alb-admin` | 80 ← 집 공인 IP /32 | Grafana ALB. 관측 화면은 운영자만 |

- 한 그룹을 같이 쓰면 서비스를 여는 순간 Grafana 도 열린다.
- 아웃바운드는 둘 다 전체 허용 — ALB 가 노드로 보낼 수 있는 범위이지 들어오는 문이 아니다.
- cgv-infra 의 두 Ingress 가 **이름(Name 태그)**으로 가리킨다. 이름이 정해져 있어 켜는 날 옮길 값이 없다.
- 부하 발생기도 `alb-public` 으로 들어온다. VPC 안에서 인터넷용 ALB 를 불러도 주소가 공인 IP 로 풀려, ALB 가 보는 출발지가 발생기의 공인 IP 가 된다.

> [!NOTE]
> 리스너를 여는 것(cgv-infra Ingress 의 `listen-ports`)과 보안 그룹을 여는 것은 따로다. 리스너만 만들면 ALB 는 443 을 듣는데 보안 그룹이 막아 연결이 시간 초과로 끝난다.

---

## 입력 · 출력

| 입력 | 무엇 |
|---|---|
| `prefix` | 자원 이름 앞머리 (`cgv-stg`) |
| `azs` | AZ 목록 |
| `vpc_cidr` | VPC 대역 |
| `home_cidr` | 집 공인 IP /32 — `envs/stg` 가 apply 시점에 조회해 넘긴다 |

| 출력 | 받는 곳 |
|---|---|
| `vpc_id` · `vpc_cidr` | modules/data · 발생기 |
| `subnet_ids` | modules/eks(클러스터 · app 노드그룹) · modules/data |
| `subnet_ids_by_az` | modules/eks — 관측 · booking 노드그룹을 AZ **이름**으로 집는다(순서로 집으면 목록이 바뀔 때 다른 AZ 를 집는다) |
| `alb_public_security_group_id` · `alb_admin_security_group_id` | `envs/stg` 출력 `expected` — 이름 지정이 안 먹을 때의 대체값 |
