# modules/eks — 클러스터 · 노드그룹 · 애드온 · IRSA

```
 ┌─ AWS-managed ─────────────────────────────────────────────────┐
 │  EKS control plane 1.36   API: public (home IP /32) + private │
 └───────────────────────────────┬───────────────────────────────┘
 ┌─ my account ──────────────────┼───────────────────────────────┐
 │           ┌───────────────────┼───────────────────┐           │
 │           v                   v                   v           │
 │  ┌─ app x4 ───────┐  ┌─ booking x2 ───┐  ┌─ obs x1 ───────┐   │
 │  │ workload=app   │  │ booking only   │  │ mimir loki     │   │
 │  │ queue frontend │  │ taint          │  │ tempo grafana  │   │
 │  │ kafka, strimzi │  │ 2a x1, 2c x1   │  │ taint          │   │
 │  │ AZ 2a/2b/2c    │  │                │  │ pinned to 2c   │   │
 │  └────────────────┘  └────────────────┘  └────────────────┘   │
 │                                                               │
 │  OIDC ──> IRSA roles x4: obs-s3, ebs-csi, alb, cloudwatch     │
 └───────────────────────────────────────────────────────────────┘
```

집에서는 노드 셋이 컨트롤 플레인과 kubelet 을 겸했다. 3만 명 판에서 노드 메모리가 차자 etcd 쓰기가 4초가 되며 k3s 가 재시작했다. 여기서는 그 부분을 AWS 가 돌리고(시간당 $0.10) 노드와 떨어져 있다.

---

## 클러스터

| 설정 | 값 | 이유 |
|---|---|---|
| 엔드포인트 | public + private · public 허용 = 집 공인 IP /32 | 집의 허브 ArgoCD 와 kubectl 이 밖에서 붙어야 한다 |
| 서비스 CIDR | 172.20.0.0/16 | CoreDNS 가 172.20.0.10 으로 정해져 frontend nginx `resolver` 에 미리 적는다. 지정 안 하면 AWS 가 둘 중 하나를 골라 띄워 봐야 안다 |
| `access_config` | 인증 API 모드 · 생성자에게 관리자 access entry | aws-auth ConfigMap 을 안 쓴다. cgv-infra `register.sh` 가 허브용 계정을 만들 수 있는 권한 |
| `upgrade_policy` | STANDARD | 기본 EXTENDED 는 표준 지원이 끝난 버전에서 연장 요금이 붙은 채 돈다 |

---

## 노드그룹

| 노드그룹 | 수 · 배치 | 라벨 · taint | 뜨는 것 | 근거 |
|---|---|---|---|---|
| `app` | 4 · 서브넷 셋 | `workload=app` | queue · frontend · Kafka 브로커 · 오퍼레이터 | queue 파드 수와 같게 — 셋일 때 queue 둘이 한 노드에 앉아 그 둘만 줄서기 1초 초과 5,055 · 5,142건 |
| `booking-2a` · `booking-2c` | 1 씩 · AZ 하나씩 | `workload=booking` · NoSchedule | booking | 아래 |
| `observability` | 1 · **2c 고정** | `workload=observability` · NoSchedule | Mimir · Loki · Tempo · Grafana | 아래 |

전부 m5.xlarge · `AL2023_x86_64_STANDARD` · 수 고정(min = max = desired).

### booking 을 떼어 낸 이유

```
새로 뜬 booking JVM
 └─> 오픈 순간 컴파일 2.4코어 + 처리 1코어
      └─> 4 vCPU 노드 포화 — 런큐 대기 15 초/초 · CPU 압력 66%
           └─> 같은 노드의 Kafka 브로커 밀림 — 발행 p99 3.6초
                └─> 입장 전파 SLO 78–90%
```

- 오픈 순간 튀는 파드는 booking 하나다(queue 는 Go 라 컴파일 폭풍이 없다). 이것만 노드를 혼자 쓰게 하자 전파 SLO **100%**.
- 노드를 혼자 쓰므로 booking 의 CPU limit 4000m(노드 전부)이 정당하다 — 그 값의 전제가 이 노드그룹이다.
- **taint** — nodeSelector 만으로는 브로커 · 오퍼레이터가 재시작 때 이 노드로 옮겨 앉는 것을 못 막는다.
- **AZ 둘** — 한 AZ 가 죽어도 한 대가 남는다.
- 브로커는 app 노드에 남긴다. 실사용 0.15코어에 전용 노드 셋은 실측이 요구하지 않는다(cgv-infra 에서 Guaranteed 로 몫만 잠근다).

### 관측 노드를 AZ 하나에 고정한 이유

- 그 노드의 Mimir · Loki · Tempo 가 **EBS 볼륨을 들고 있고 EBS 는 AZ 에 묶인다.**
- 서브넷 셋을 줬을 때 노드그룹 교체에서 노드가 2c → 2b 로 옮겨 떴고, Mimir ingester 가 볼륨을 못 붙여 **95분 Pending** — 그동안 새 지표가 저장되지 않았다.
- 상태를 든 노드그룹만 고정하고, 무상태인 app 은 흩는다. 대가: 그 AZ 가 죽으면 관측이 끊긴다.
- 관측을 앱과 가른 이유: 집의 3만 명 판에서 노드 메모리가 차면서 관측 스택이 같이 재시작해 무너지는 순간의 지표가 남지 않았다.

### launch template — 노드그룹마다 하나

| 설정 | 값 | 이유 |
|---|---|---|
| IMDS | v2 필수 · hop limit 1 | 파드 네트워크에서 인스턴스 메타데이터에 닿지 않아 파드가 노드 역할 자격을 못 꺼낸다. 리전이 필요한 파드는 cgv-infra 값에 리전을 적었다 |
| 루트 볼륨 | 20 GiB gp3 암호화 | LT 를 쓰면 노드그룹 `disk_size` 를 못 쓴다 |
| 태그 | EC2 · 볼륨에 공통 태그 + Name | 노드그룹 자원의 태그는 EC2 로 안 내려간다 |

> [!WARNING]
> LT 가 바뀌면 노드그룹이 새로 만들어진다(노드 전부 교체). 켜 둔 채로 apply 하지 않는다.

### t 계열을 안 쓰는 이유 · 수를 고정한 이유

- 버스터블은 크레딧이 바닥나면 느려지는데, 그 순간이 서비스 한계인지 크레딧 고갈인지 가릴 수 없다.
- 부하 판의 목적이 "무엇이 먼저 막히나"인데 노드가 스스로 늘면 그 막힘이 가려진다.

---

## 계정 vCPU 한도

> [!IMPORTANT]
> 계정 EC2 vCPU 한도(L-1216C47A) 기본값은 32 다. 노드 일곱이 28 이라 발생기를 더하면 넘는다.
> 한도에 걸린 노드그룹은 `CREATING` 에서 멈추는데, **`describe-nodegroup` 의 health 도 CloudTrail 도 비어 있다.** 실패는 ASG 의 scaling activities 에만 `VcpuLimitExceeded` 로 남는다. 정지한 인스턴스는 한도에 세지 않는다.

```
aws autoscaling describe-scaling-activities --auto-scaling-group-name <노드그룹 ASG> --max-items 5
aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A
```

---

## 애드온

| 애드온 | 하는 일 | 집(k3s)에서는 | 설정 · 주의 |
|---|---|---|---|
| vpc-cni | 파드에 VPC 주소 · NetworkPolicy 집행 | Calico | `enableNetworkPolicy=true` — 꺼져 있으면 정책이 Synced 인데 아무것도 안 막는다 |
| kube-proxy | Service 라우팅 | 내장 | — |
| coredns | 클러스터 DNS | 번들 | 노드그룹 뒤에 만든다(뜰 노드가 없으면 Degraded) |
| aws-ebs-csi-driver | PVC → EBS 생성 · 부착 | 정적 PV | IRSA · `controller.extraVolumeTags` 로 볼륨에 공통 태그 |
| metrics-server | HPA · `kubectl top` 지표 API | 번들 | EKS 는 기본으로 안 깐다 |

- 버전은 1.36 의 defaultVersion 으로 고정한다. 기본 버전은 하루 사이에도 바뀌므로 켜는 날 아침 `aws eks describe-addon-versions --kubernetes-version 1.36` 으로 다시 맞춘다.
- 이미 기본 설치가 있는 셋(vpc-cni · kube-proxy · coredns)은 `resolve_conflicts_on_create = OVERWRITE`.
- **gp3 StorageClass 는 여기서 안 만든다.** EBS CSI 는 드라이버만 깐다. 쿠버네티스 오브젝트를 만들려면 kubernetes provider 를 이 state 에 섞어야 하고, 그러면 클러스터를 만드는 코드가 그 클러스터에 붙는 자격에 의존한다 → cgv-infra 가 배달한다.

---

## IRSA

파드는 AWS 자원이 아니다. 파드가 가진 것은 쿠버네티스 API 서버가 서명한 ServiceAccount 토큰이고, AWS 는 그 서명을 원래 모른다.

```
1  Pod ──> STS   AssumeRoleWithWebIdentity (SA 토큰)
2  STS ──> IAM   이 발급자(OIDC 공급자)를 믿나? 신뢰 정책의 sub · aud 가 맞나?
3  IAM ──> STS   맞다
4  STS ──> Pod   임시 자격
```

| 신뢰 정책 조건 | 값 | 빼면 |
|---|---|---|
| `sub` | `system:serviceaccount:<네임스페이스>:<이름>` | 이 클러스터가 발급한 어느 SA 든 역할을 맡는다 |
| `aud` | `sts.amazonaws.com` | 토큰의 수신자가 STS 라는 것을 안 본다 |

| 역할 | 맡는 ServiceAccount | 권한 | SA 애노테이션 |
|---|---|---|---|
| `<prefix>-obs-s3` | observability `mimir` · `loki` · `tempo` | 관측 버킷 셋 읽기 · 쓰기 · 삭제(compactor) · 멀티파트 중단 | cgv-infra 관측 값 |
| `<prefix>-ebs-csi` | `kube-system:ebs-csi-controller-sa` | AWS 관리형 EBS CSI 정책 | 애드온이 `service_account_role_arn` 으로 직접 |
| `<prefix>-alb` | `kube-system:aws-load-balancer-controller` | 컨트롤러 v2.13.4 공식 정책(`policies/alb-controller.json`) | cgv-infra ALB Controller 값 |
| `<prefix>-cloudwatch` | `observability:cloudwatch-exporter` | `tag:GetResources` · CloudWatch 지표 읽기 (ARN 으로 좁혀지지 않아 `*`) | cgv-infra 관측 값 |

- **노드 역할**에는 그 노드의 모든 파드에 있어도 되는 것만 — `AmazonEKSWorkerNodePolicy` · `AmazonEKS_CNI_Policy` · `AmazonEC2ContainerRegistryReadOnly`. 권한 단위가 노드라 파드 하나만 필요한 권한을 여기 붙이면 그 노드의 파드 전부가 갖는다.
- 역할에 path 를 주지 않는다 — ARN 이 `role/<path>/<이름>` 이 되어 cgv-infra 에 미리 적은 문자열과 어긋난다.

---

## 입력 · 출력

| 입력 | 무엇 |
|---|---|
| `prefix` · `kubernetes_version` · `tags` | 이름 · 버전 · 공통 태그 |
| `subnet_ids` · `service_cidr` · `home_cidr` | 클러스터 · app 노드그룹 서브넷 · 서비스 대역 · API 허용 IP |
| `obs_subnet_id` · `booking_subnet_ids_by_az` | AZ 에 고정할 노드그룹의 서브넷 |
| `app_instance_type` · `app_node_count` · `obs_instance_type` · `booking_instance_type` | 노드 스펙 · 수 |
| `irsa_service_accounts` | 역할 이름 → 맡을 수 있는 SA 목록 (`envs/stg/main.tf`) |
| `observability_buckets` | 관측 역할이 쓸 버킷 이름 |

| 출력 | 받는 곳 |
|---|---|
| `cluster_name` · `cluster_endpoint` | `envs/stg` 출력 `handoff` (kubeconfig) |
| `cluster_security_group_id` | modules/data — RDS · ElastiCache 가 이 그룹에서 오는 것만 받는다 |
| `oidc_provider_arn` · `oidc_issuer` | 대조용 |
| `irsa_role_arns` · `coredns_cluster_ip` | `envs/stg` 출력 `expected` — cgv-infra 에 적힌 값과 대조 |
