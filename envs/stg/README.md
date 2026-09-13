# envs/stg — 하루 환경

모듈 셋을 이어 stg 를 만든다. `apply` 로 켜고 `destroy` 로 끈다.

```
 home public IP /32 (looked up at apply) ──> network (alb-admin SG), eks (API allow-list)

 ┌─ modules/network ─┐               ┌─ modules/eks ──────┐
 │ VPC, subnets, SG  │ subnet_ids ──>│ cluster, nodegroups│
 └─────────┬─────────┘               └─────────┬──────────┘
           │ vpc_id, subnet_ids                │ cluster_security_group_id
           │                                   │
           │         ┌─ modules/data ────┐     │
           └───────> │ RDS, ElastiCache  │ <───┘
                     └───────────────────┘
```

| 파일 | 무엇 |
|---|---|
| `main.tf` | backend(S3 · `use_lockfile`) · provider(공통 태그) · 집 IP 조회 · 모듈 셋 · IRSA 대상 SA 목록 |
| `variables.tf` | 값마다 근거를 `description` 에 적는다 |
| `outputs.tf` | `handoff` — cgv-infra 에 옮길 값 · `expected` — 이미 적힌 값과 대조 |
| `loadgen.tf` | VPC 안 발생기 한 대 (기록된 판에는 안 씀 — [부하 발생기](#부하-발생기)) |
| `destroy.md` | 지우는 순서 · 명령 · 잔존 확인 |

잠금은 S3 조건부 쓰기(`use_lockfile`, Terraform 1.10+)라 DynamoDB 테이블이 없다.

---

## 주요 변수

| 변수 | 기본값 | 근거 |
|---|---|---|
| `azs` | 2a · 2c · 2b | Kafka 브로커 셋을 AZ 마다 하나씩. 목록 순번이 CIDR 순번 — 새 AZ 는 끝에 |
| `obs_az` | 2c | 관측 노드의 AZ. **볼륨이 있는 AZ 에서 바꾸면 그 볼륨을 못 쓴다** |
| `booking_azs` | 2a · 2c | booking 전용 노드. cgv-infra booking `replicaCount` 와 같아야 한다 |
| `app_node_count` | 4 | queue 파드 수와 같게 — 셋일 때 둘이 한 노드에 앉았다 |
| `*_instance_type` | m5.xlarge | t 계열 금지 |
| `vpc_cidr` · `service_cidr` | 10.20.0.0/16 · 172.20.0.0/16 | 집 대역과 안 겹치게 · CoreDNS 가 172.20.0.10 |
| `kubernetes_version` | 1.36 | 2027-08-02 까지 표준 지원 · 집 k3s 와 같은 계열 |
| `mysql_version` · `rds_instance_class` | 8.4 · db.m5.large | 8.0 은 표준 지원 종료 · 실측 0.5코어가 t3.small(0.4) 초과 |
| `rds_multi_az` | true | prd 와 같은 쓰기 지연 조건 |
| `redis_node_type` · `redis_replicas` | cache.m5.large · 1 | Redis 는 명령을 코어 하나로 처리 · AZ 장애 대비 |
| `redis_transit_encryption_mode` | required | 떠 있는 그룹에 암호화를 붙일 때만 `-var` 로 preferred |
| `redis_auth_token_update_strategy` | SET | 떠 있는 그룹에 토큰을 처음 붙일 때만 `-var` 로 ROTATE |
| `loadgen_enabled` | false | 시간당 과금이라 판을 돌릴 때만 |

RDS 비밀번호 변수는 없다 — AWS 가 만들어 Secrets Manager 에 넣고 Terraform 은 값을 받지 않는다.

---

## 켜는 날

```
1 terraform apply ─> 2 kubeconfig ─> 3 register.sh ─> 4 데이터 주소 대조 ─> 5 허브가 배달
                                          └─> secrets.sh (5 와 병행)
```

| # | 무엇 | 명령 · 위치 | kubectl |
|---|---|---|---|
| 1 | AWS 자원 | 이 폴더에서 `terraform apply` (약 30–40분) | — |
| 2 | 내 kubectl 이 EKS 를 가리키게 | `aws eks update-kubeconfig --region ap-northeast-2 --name cgv-stg --alias cgv-stg` | 설정만 |
| 3 | 허브 ArgoCD 에 `cgv-stg` 로 등록 | cgv-infra `bootstrap/eks/register.sh` | 스크립트 안 |
| 4 | `terraform output handoff` 의 `mysql_host` · `redis_host` 대조 | cgv-infra `envs/stg/{booking,queue}.yaml` — 다르면 커밋 | — |
| 5 | 네임스페이스 · StorageClass · CRD → Strimzi · ALB Controller → Kafka → NetworkPolicy → 관측 → 앱 | 허브 ArgoCD (sync-wave) | — |
| — | Secret 넷 (Secrets Manager → 쿠버네티스) | cgv-infra `bootstrap/eks/secrets.sh` — 네임스페이스가 생길 때까지 기다린다 | 스크립트 안 |

**칸이 이렇게 갈린 이유**

- cgv-infra 는 stg 를 **클러스터 이름**으로 가리킨다 → EKS API 주소를 옮겨 적을 곳이 없다.
- IRSA 역할 ARN · CoreDNS 주소 · 버킷 이름 · ALB 보안 그룹은 이름 · 대역만으로 정해져 이미 적혀 있다 → `terraform output expected` 로 대조만 한다.
- 스크립트 둘을 Terraform 으로 옮기지 않는다 — kubernetes provider 를 이 state 에 섞게 되고, 시크릿 값이 state 에 남는다.
- 그 뒤 매 배포(push → CI → `publish-ecr` 버튼 → 태그 되쓰기 → sync)에는 kubectl 이 없다.

> [!NOTE]
> EKS API 는 apply 시점의 집 공인 IP 에만 열린다. 집 IP 가 바뀌면 `terraform apply` 를 다시 친다.

---

## 지울 때

```
0 남길 것 ─> 1 관측 flush ─> 2 허브 cluster Secret 삭제 ─> 3 네임스페이스 삭제 ─> 4 terraform destroy
  ─> 5 발생기 destroy ─> 6 잔존 확인 ─> 7 DNS · kubeconfig · cgv-infra 정리 ─> 8 다음 날 비용
```

명령 · 확인 방법 · 막혔을 때는 [destroy.md](destroy.md).

> [!CAUTION]
> Application 을 지우는 것으로는 정리되지 않는다. cgv-infra ApplicationSet 이 `preserveResourcesOnDeletion` 이라 Ingress · PVC 가 남고, Terraform 밖에서 생긴 ALB · EBS 가 서브넷에 붙어 **destroy 가 막힌다.**

RDS 마스터 비밀번호 시크릿은 Terraform 자원이 아니지만 인스턴스를 지우면 AWS 가 같이 지운다. Redis AUTH 시크릿은 유예 0일이라 destroy 와 함께 즉시 사라진다.

---

## 기본값에 맡기지 않은 것

모든 자원에 `Project=cgv` · `Environment=stg` · `ManagedBy=terraform`. provider `default_tags` 가 안 닿는 노드 EC2 · EBS CSI 볼륨 · ALB 는 각자 붙인다(launch template · 애드온 설정 · cgv-infra 컨트롤러 값).

| 항목 | 값 | 적지 않으면 |
|---|---|---|
| 클러스터 관리자 | access entry · API 모드 · 생성자 관리자 | AWS 기본값이 코드에 안 보인다 |
| 노드 IMDS | v2 필수 · hop limit 1 | 파드가 노드 역할 자격에 닿는다 |
| 노드 루트 디스크 | 20 GiB gp3 암호화 | 암호화가 없다 |
| AMI | `AL2023_x86_64_STANDARD` | 기본값과 같지만 코드에 안 보인다 |
| 애드온 버전 | 1.36 defaultVersion 고정 | apply 마다 AWS 가 고른 버전 |
| vpc-cni | `enableNetworkPolicy=true` | NetworkPolicy 를 읽고도 아무것도 안 막는다 |
| 서비스 CIDR | 172.20.0.0/16 | CoreDNS 주소를 띄워 봐야 안다 |
| RDS 비밀번호 | `manage_master_user_password` | state 에 평문 |
| Redis | 전송 암호화 + AUTH | 6379 에 닿으면 전권 |
| Secrets Manager 유예 | 0일 | 다시 만들 때 이름 충돌로 apply 가 멈춘다 |
| EKS 지원 정책 | `upgrade_policy = STANDARD` | 연장 지원 요금이 붙은 채 돈다 |
| RDS 지원 정책 | `engine_lifecycle_support` 끔 | 표준 지원이 끝난 버전으로도 만들어지고 연장 요금 |

---

## 부하 발생기

| | 위치 | 구성 | 쓰임 |
|---|---|---|---|
| `loadgen.tf` | 이 폴더 · VPC 안 | c5.4xlarge 1대 · SSM 접속 | 기록된 판에는 안 씀 |
| 일회성 Terraform | 저장소 밖 · 기본 VPC | c5.2xlarge × N · AZ 에 흩음 | 1만 · 2.5만 · 5만 명 판 전부 |

**대수를 늘린 이유 — 발생기가 서비스보다 먼저 막혔다**

| 1대 · 2.5만 VU | 1대 · 3만 VU |
|---|---|
| 오픈 순간 133,432 pps · 초과 없음 | 인스턴스 pps 한도 초과 → 패킷이 **오류 없이 버려짐** |
| | 같은 시각 서버: booking CPU 0.52코어 · ALB 5xx 0 |

```
ethtool -S ens5 | grep allowance     # pps_allowance_exceeded 가 오르면 발생기 쪽 한도
```

→ 한도가 인스턴스마다 붙으므로 박스를 키우지 않고 대수로. 대당 12,500 VU × 4대 = 5만.

| 규모 | 발생기 vCPU | + 클러스터 28 | 계정 한도 64 |
|---|---|---|---|
| 5만 | 4대 × 8 = 32 | 60 | 들어간다 |
| 10만 | 8대 × 8 = 64 | 92 | **넘는다** — 한도 증설이 먼저 |

발생기는 인터넷용 ALB 를 공인 주소로 부른다. ALB 가 보는 출발지가 발생기의 공인 IP 라 서비스 ALB 의 인터넷 전체 규칙으로 들어간다.
