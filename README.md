# cgv-terraform

> 온프레미스 k3s 에서 부하 실측으로 스펙을 정한 예매 대기열 서비스를 **AWS EKS(stg)** 에 올리는 Terraform.
> 하루 켜서 배포 한 사이클과 5만 명 부하를 돌리고 지운다.

![Terraform](https://img.shields.io/badge/Terraform-1.10%2B-7B42BC?logo=terraform&logoColor=white)
![EKS](https://img.shields.io/badge/EKS-1.36-FF9900?logo=amazoneks&logoColor=white)
![RDS](https://img.shields.io/badge/RDS-MySQL_8.4-527FFF?logo=amazonrds&logoColor=white)
![ElastiCache](https://img.shields.io/badge/ElastiCache-Redis_7.1-DC382D?logo=redis&logoColor=white)

| | |
|---|---|
| **무엇** | stg 환경의 AWS 자원 — VPC · EKS · 노드그룹 · RDS · ElastiCache · ECR · IAM(IRSA) · ACM |
| **어디까지** | AWS 자원까지. 클러스터 안에 올리는 것은 [cgv-infra](https://github.com/sss654654/cgv-infra), 앱은 [cgv-onprem](https://github.com/sss654654/cgv-onprem) |
| **결과** | 배포 한 사이클 **19분 41초** · 1만 · 2.5만 · **5만 명** 부하에서 SLO 다섯 통과 · 5xx 0 |
| **수명** | `bootstrap/` 은 남기고 `envs/stg/` 는 하루 쓰고 `destroy` |

---

## 아키텍처

### 집과 AWS — 잇는 선은 둘

```
 ┌─ home (on-prem) ─────────┐                     ┌─ AWS ap-northeast-2 ─────┐
 │ GitLab CI (cgv-onprem)   │──── publish-ecr ───>│ ECR x3                   │
 │                          │                     │                          │
 │ image-updater            │<──── poll tags ─────│                          │
 │   └─> tag commit to      │                     │                          │
 │       cgv-infra envs/stg │                     │                          │
 │                          │                     │                          │
 │ ArgoCD hub (k3s dev)     │───── EKS API ──────>│ EKS 1.36 (cgv-stg)       │
 │   <── reads cgv-infra    │    home IP /32 only │   ^                      │
 └──────────────────────────┘                     │   │                      │
                                                  │ ALB (ACM, HTTPS)         │
                                                  └───^──────────────────────┘
                                                      │ 443
                                                  internet users
```

- `publish-ecr` — CI 의 수동 버튼. 같은 이미지를 커밋 해시 이름으로 ECR 에 올린다. 누르는 것이 stg 승격 결정이다
- `EKS API` — apply 시점의 집 공인 IP 에만 열린다. 허브는 이 선 하나로 stg 를 배달한다

| 저장소 | 맡는 것 |
|---|---|
| [cgv-onprem](https://github.com/sss654654/cgv-onprem) | 앱 코드 · CI — 같은 이미지를 커밋 해시 이름으로 ECR 에 올린다 |
| [cgv-infra](https://github.com/sss654654/cgv-infra) | 클러스터에 무엇을 어떤 값으로 올리나 — dev 와 같은 차트, 값만 `envs/stg` |
| **cgv-terraform** | **그 클러스터와 관리형 서비스를 AWS 에 만든다** |

### VPC 안

```
                                                internet
                                                    │ 443
 ┌─ VPC 10.20.0.0/16 ───────────────────────────────v─────────────────────┐
 │                                                  │                     │
 │                                      ALB (target type: pod IP)         │
 │                                                  │                     │
 │  ┌─ app x4 (spread over 2a/2b/2c) ───────────────v──────────────────┐  │
 │  │ queue x4 (1 per node)   frontend   kafka x3 (1 per AZ)           │  │
 │  └──────────────────────────────────────────────────────────────────┘  │
 │  ┌─ booking-2a x1 ─────┐  ┌─ booking-2c x1 ─────┐  ┌─ obs x1 (2c) ─┐   │
 │  │ booking             │  │ booking             │  │ mimir loki    │   │
 │  │ taint NoSchedule    │  │ taint NoSchedule    │  │ tempo grafana │   │
 │  │                     │  │                     │  │ pinned to 2c  │   │
 │  └─────────────────────┘  └─────────────────────┘  └───────────────┘   │
 │            │                        │                                  │
 │            v                        v                                  │
 │  ┌─ managed data (inbound from node SG only) ───────────────────────┐  │
 │  │ RDS MySQL 8.4 (Multi-AZ)            <- booking                   │  │
 │  │ ElastiCache Redis 7.1 (TLS + AUTH)  <- queue, booking            │  │
 │  └──────────────────────────────────────────────────────────────────┘  │
 └────────────────────────────────────────────────────────────────────────┘
   obs node ──IRSA──> S3 observability buckets (bootstrap)
```

- 퍼블릭 서브넷 셋(2a · 2b · 2c) · NAT 없음. 노드는 전부 m5.xlarge(4 vCPU) · 7대 · 28 vCPU
- 데이터는 노드 보안 그룹에서 오는 연결만 받는다

---

## 결과

| | 1만 | 2.5만 | 5만 |
|---|---|---|---|
| SLO 다섯 — 로비 · 줄서기 · 순번 조회 · 입장 전파 · 예매 여정 | 통과 | 통과 | 통과 |
| 입장 뒤 403 · 5xx | 0 · 0 | 0 · 0 | 0 · 0 |

**부하가 노드 구조를 바꿨다** — 켠 날은 노드그룹 둘(app · 관측)이었다. 1만 명 판에서 새로 뜬 booking(JVM)의 컴파일이 오픈 순간 노드를 채워 같은 노드의 Kafka 브로커가 밀렸고, **booking 전용 노드그룹**을 더하자 입장 전파 SLO 가 78–90% → 100% 가 됐다.

**5만 위를 못 잰 이유** — 서비스가 아니라 부하 발생기. 계정 vCPU 한도 64 안에서 발생기 4대가 최대다. → [부하 발생기](envs/stg/README.md#부하-발생기)

판별 수치와 대시보드는 [cgv-infra](https://github.com/sss654654/cgv-infra) 에 있다.

---

## 설계 결정

| 항목 | 선택 | 이유 | 자세히 |
|---|---|---|---|
| state | `bootstrap` / `envs/stg` 둘 | 판 결과(관측 블록)와 이미지가 클러스터보다 오래 살아야 한다 | [bootstrap](bootstrap/README.md) |
| AZ | 3 | Kafka 브로커 셋의 과반 · `min.insync.replicas 2` — AZ 둘이면 한 AZ 장애에 쓰기가 멈춘다 | [network](modules/network/README.md) |
| 서브넷 | 퍼블릭 · NAT 없음 | NAT 하나는 AZ 설계와 어긋나고 AZ 마다는 비용 → 보안 그룹으로 좁힌다 | [network](modules/network/README.md) |
| 노드 | m5.xlarge · 수 고정 | t 계열은 크레딧 고갈과 한계를 못 가른다 · 고정해야 막힘이 안 가려진다 | [eks](modules/eks/README.md) |
| booking 노드 | 전용 · AZ 마다 1대 | 새 JVM 의 컴파일이 이웃 파드를 민다 | [eks](modules/eks/README.md) |
| 관측 노드 | AZ 고정 | EBS 가 AZ 에 묶인다 — AZ 가 바뀌자 ingester 95분 Pending | [eks](modules/eks/README.md) |
| 파드 자격 | IRSA · IMDSv2 hop 1 | 권한 단위를 노드가 아니라 ServiceAccount 로 | [eks](modules/eks/README.md#irsa) |
| MySQL | RDS · Multi-AZ | prd 와 같은 쓰기 지연 조건 · 비밀번호를 AWS 가 관리 | [data](modules/data/README.md) |
| Redis | ElastiCache · 클러스터 모드 끔 · TLS + AUTH | Lua 가 `CROSSSLOT` · 6379 에 닿기만 하면 전권이 되지 않게 | [data](modules/data/README.md) |
| Kafka | 관리형 안 씀 | MSK 가 하루 약 60배 — 클러스터 안 Strimzi | — |
| 버전 | 표준 지원만 (EKS 1.36 · RDS 8.4) | 연장 지원의 시간당 추가 요금 | [envs/stg](envs/stg/README.md#기본값에-맡기지-않은-것) |

---

## 구조

| 경로 | 무엇 | state |
|---|---|---|
| [`bootstrap/`](bootstrap/README.md) | 클러스터보다 오래 사는 것 — tfstate · 관측 버킷 · ECR · IAM 사용자 · ACM · 예산 | 로컬 · 지우지 않음 |
| [`envs/stg/`](envs/stg/README.md) | 하루 환경 — 모듈 셋을 잇고, 켜고 끈다 | S3 · destroy |
| [`modules/network/`](modules/network/README.md) | VPC · 서브넷 · IGW · ALB 보안 그룹 | |
| [`modules/eks/`](modules/eks/README.md) | 클러스터 · 노드그룹 넷 · 애드온 · IRSA | |
| [`modules/data/`](modules/data/README.md) | RDS · ElastiCache · Redis AUTH 시크릿 | |

```
 ┌─ envs/stg (S3 state, destroyed after the run) ───────────┐
 │                                                          │
 │   network ───> eks ───> data                             │
 │     │           │                                        │
 └─────┼───────────┼────────────────────────────────────────┘
       │ state     │ IRSA
 ┌─────┼───────────┼─ bootstrap (local state, kept) ────────┐
 │     v           v                                        │
 │   tfstate      obs buckets x3   ECR x3   ACM cert        │
 │   ALB log bucket   IAM users x2   budget alarm           │
 └──────────────────────────────────────────────────────────┘
```

한 state 였다면 `destroy` 한 번에 판 결과와 이미지까지 사라진다.

---

## 켜고 끄기

| 언제 | 무엇 | 절차 |
|---|---|---|
| 처음 한 번 | 오래 사는 자원 · 인증서 검증 · 액세스 키 | [bootstrap/README](bootstrap/README.md#처음-한-번) |
| 켜는 날 | apply → 허브 등록 → 배달 | [envs/stg/README](envs/stg/README.md#켜는-날) |
| 지울 때 | 관측 flush → 허브 연결 끊기 → 네임스페이스 삭제 → destroy → 잔존 확인 | [envs/stg/destroy.md](envs/stg/destroy.md) |

> [!CAUTION]
> `destroy` 전에 클러스터의 네임스페이스를 먼저 지운다. Terraform 밖에서 생긴 ALB · EBS 가 서브넷에 붙어 있으면 삭제가 막힌다.

---

## 한계

| 한계 | prd 로 가면 |
|---|---|
| **하루 켰다 지우는 환경** — 장기 운영 · 업그레이드 · 장애 대응을 거치지 않았다 | — |
| 퍼블릭 서브넷 · 노드 공인 IP | 프라이빗 서브넷 + AZ 마다 NAT |
| 데이터 보안 그룹이 노드 단위 — 노드 위 어느 파드든 통과 | Security Groups for Pods |
| CI 가 IAM 사용자 장기 키 — GitLab 이 사설 IP 라 OIDC 불가 | OIDC 페더레이션 |
| 노드 수 고정 · 관측 노드 단일 AZ | Karpenter · 관측 AZ 별 |
| 새 booking 파드의 컴파일 폭풍은 격리만 했다 | 리허설 트래픽 · CRaC |
| 비용 미집계 | 비용 할당 태그로 판마다 집계 |
