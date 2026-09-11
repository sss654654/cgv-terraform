# cgv-terraform

CGV 예매 대기열 서비스의 **stg 환경을 AWS 에 만드는 Terraform** 이다.
온프레미스 k3s(dev)에서 부하 실측으로 정한 스펙을 EKS 위에 올려, 한 사이클(git push → 브라우저)과 동시 3만-5만 부하를 돌린 뒤 지운다.
이 저장소는 AWS 자원까지만 만든다. 클러스터 안에 무엇을 배포할지는 [cgv-infra](https://github.com/sss654654/cgv-infra) 가 정하고, 집의 ArgoCD 가 배달한다.

## 아키텍처

```
집 (온프레미스)
  GitLab ─ CI ─ publish-ecr 버튼 ────────────────────────────▶ ECR (이미지 · 커밋 해시 태그)
  k3s dev
    └ ArgoCD (허브, dev 와 stg 를 함께 배달) ── EKS API ──────▶ EKS 컨트롤 플레인
                                             (public, 집 공인 IP 만)
  브라우저 ── HTTP 80 (집 공인 IP 만) ─────────────────────────▶ ALB

AWS ap-northeast-2 · VPC 10.20.0.0/16 · 퍼블릭 서브넷 2a · 2c · 2b · NAT 없음
  ALB  (cgv-infra 의 Ingress 를 보고 ALB Controller 가 만든다)
   └▶ 앱 노드그룹 m5.xlarge × 4 (AZ 셋에 2+1+1)   queue · booking · frontend · Kafka(Strimzi, AZ 마다 브로커 하나)
        ├▶ RDS MySQL 8.4 db.m5.large Multi-AZ (주 + 대기)            ┐ 노드 보안 그룹에서만 들어온다
        └▶ ElastiCache Redis 7.1 cache.m5.large (주 + 복제본, 자동 전환) ┘
  관측 노드그룹 m5.xlarge × 1 (taint)  Mimir · Loki · Tempo · Grafana · Alloy · YACE
        └▶ S3 관측 버킷 셋 (IRSA)       ← bootstrap 이 만들고 지우지 않는다
  부하 발생기 c5.4xlarge (판을 돌릴 때만) ──▶ ALB
```

집과 AWS 를 잇는 선은 둘뿐이다. 허브 ArgoCD 가 EKS API 에 붙는 선, CI 가 ECR 에 이미지를 올리는 선. VPN 은 없다.

## 저장소 구조

```
bootstrap/         클러스터보다 오래 사는 것. 한 번 만들고 지우지 않는다       로컬 state
envs/stg/          하루 환경. apply 로 켜고 destroy 로 끈다                  S3 state
  main.tf          모듈 셋을 잇는다 · 공통 태그 · apply 시점 집 공인 IP 조회
  loadgen.tf       부하 발생기. loadgen_enabled 로 켜고 끈다
  outputs.tf       handoff(cgv-infra 에 옮길 값) · expected(cgv-infra 에 이미 적힌 값과 대조)
modules/network/   VPC · 서브넷 · IGW · ALB 보안 그룹
modules/eks/       클러스터 · 노드그룹 · launch template · 애드온 · OIDC 공급자 · IRSA(irsa.tf)
modules/data/      RDS · ElastiCache · 보안 그룹
```

### state 를 둘로 나눈 이유

가르는 기준은 하나다 — **클러스터보다 오래 사는가.**

| state | 무엇 | 지우나 |
|---|---|---|
| `bootstrap/` | tfstate 버킷 · 관측 버킷 셋(Mimir · Loki · Tempo) · ECR 셋 · IAM 사용자 둘(CI push · 이미지 태그 조회) | 지우지 않는다 |
| `envs/stg/` | VPC · EKS · 노드 · 애드온 · IRSA · RDS · ElastiCache · 부하 발생기 | 하루 살고 지운다 |

- 한 state 에 두면 `destroy` 한 번에 판 결과(관측 블록)와 이미지까지 사라진다. 판과 판을 비교하려면 결과가 클러스터보다 오래 살아야 한다.
- `bootstrap` 이 backend 를 안 쓰는 것은 그 backend 버킷을 여기서 만들기 때문이다(만들기 전에 참조하는 순환).
- `envs/stg` 는 `bootstrap` 의 출력을 읽지 않고 이름 규칙(`<prefix>-<이름>-<계정ID>`)으로 버킷 이름을 다시 만든다. 한쪽 state 를 잃거나 지워도 다른 쪽이 영향을 받지 않는다.
- IAM 사용자의 액세스 키는 Terraform 이 만들지 않는다. 만들면 비밀값이 state 에 평문으로 남아서, 콘솔에서 발급한다.

## 설계

### 네트워크

- 퍼블릭 서브넷 셋(AZ 2a · 2c · 2b)을 쓰고 NAT 게이트웨이를 두지 않는다. 노드는 IGW 로 직접 나가고 공인 IP 가 붙는다. 들어오는 쪽은 보안 그룹이 좁힌다.
- AZ 가 셋인 이유는 Kafka 다. 브로커 셋이 컨트롤러 과반 투표와 `min.insync.replicas` 2 를 겸해서, AZ 둘에 나누면 한쪽에 둘이 가고 그 AZ 가 죽으면 리더를 못 뽑아 쓰기가 멈춘다. AZ 마다 하나씩 두면(cgv-infra 의 zone 분산 규칙) 어느 AZ 가 죽어도 둘이 남는다.
  앱 파드 · RDS · ElastiCache 는 AZ 둘이면 된다. 앱 파드는 서로 대체되고, RDS · ElastiCache 는 AWS 가 밖에서 전환을 정한다.
- 서브넷 CIDR 은 `azs` 목록 순번으로 자른다. 새 AZ 는 목록 끝에 더해야 기존 서브넷이 바뀌지 않는다.
- ALB 보안 그룹은 80 을 두 곳에만 연다. 집 공인 IP(/32)와 VPC 안(부하 발생기).
- 서브넷의 `kubernetes.io/role/elb` · `kubernetes.io/cluster/cgv-stg` 태그를 보고 ALB Controller 가 ALB 를 놓을 자리를 찾는다.

### EKS 클러스터

- 컨트롤 플레인은 AWS 가 돌리고 내 계정에는 인스턴스로 보이지 않는다. 집에서는 노드 셋이 컨트롤 플레인을 겸했고, 3만 판에서 노드 메모리가 차자 etcd 가 느려지며 k3s 가 재시작했다. 여기서는 그 부분이 노드와 떨어져 있다.
- API 는 public 이지만 허용 IP 가 하나다. apply 시점에 `checkip.amazonaws.com` 으로 조회한 집 공인 IP 라 코드에 IP 가 남지 않는다. 허브 ArgoCD 가 집에서 붙어야 해서 private 만으로는 안 된다.
- 서비스 CIDR 172.20.0.0/16 을 지정한다. CoreDNS 가 그 대역의 열 번째(172.20.0.10)로 정해져, cgv-infra 의 nginx resolver 에 미리 적어 둘 수 있다.
- `access_config` — 권한을 EKS access entry 로만 주고, apply 를 실행한 IAM 주체를 관리자로 둔다. cgv-infra 의 `bootstrap/eks/register.sh` 가 argocd-manager 를 만들 수 있는 것이 이 권한이다.
- 버전은 1.36 이다. EKS 는 버전마다 표준 지원이 14 개월이고, 끝나면 연장 지원으로 넘어가 시간당 요금이 더 붙는다(1.33 은 2026-07-29 에 끝났다). 1.36 은 2027-08-02 까지 표준이고 집 k3s(v1.36)와 같은 계열이다. `upgrade_policy` 를 `STANDARD` 로 두어 연장 지원 요금이 붙는 상태로 남지 않게 한다.

### 노드

| 노드그룹 | 스펙 | 무엇이 뜨나 |
|---|---|---|
| `app` | m5.xlarge × 4 (고정) | queue · booking · frontend · Kafka · 컨트롤러들 |
| `observability` | m5.xlarge × 1 (고정) | 관측 스택. taint `workload=observability:NoSchedule` 로 앱 파드를 막는다 |

- 관측 노드를 가른 이유: 3만 판에서 노드 메모리가 차면서 같은 노드의 Mimir · Loki · Tempo 가 같이 재시작했고, 무너지는 순간의 지표가 남지 않았다.
- t 계열을 쓰지 않는다. 버스터블은 크레딧이 바닥나면 baseline 으로 떨어지는데, 그 순간 느려진 것이 서비스 한계인지 크레딧 고갈인지 가릴 수 없다.
- launch template 으로 두 노드그룹의 인스턴스 설정을 정한다.
  - IMDSv2 필수 · hop limit 1 — 파드 네트워크에서는 인스턴스 메타데이터에 닿지 않아, 파드가 노드 역할의 자격을 꺼내 쓸 수 없다.
  - 루트 볼륨 20 GiB gp3 암호화.
  - EC2 · 루트 볼륨에 공통 태그(provider 의 default_tags 는 여기까지 안 닿는다).
- AMI 는 `AL2023_x86_64_STANDARD` 로 적는다.

### 애드온

| 애드온 | 하는 일 | 집에서는 |
|---|---|---|
| vpc-cni | 파드에 VPC 주소를 준다 · NetworkPolicy 집행(`enableNetworkPolicy`) | Calico |
| kube-proxy | Service 라우팅 | k3s 내장 |
| coredns | 클러스터 DNS | k3s 번들 |
| aws-ebs-csi-driver | PVC 로 EBS 를 만들고 붙인다(IRSA) | 로컬 정적 PV |
| metrics-server | HPA · `kubectl top` 이 읽는 지표 API | k3s 번들 |

- 버전은 EKS 1.36 의 defaultVersion 으로 고정한다. 적지 않으면 apply 할 때마다 AWS 가 고른 버전이 들어간다.
- coredns · ebs-csi · metrics-server 는 파드로 뜨므로 노드그룹 뒤에 만든다. 먼저 만들면 뜰 노드가 없어 Degraded 로 멈춘다.
- ebs-csi 는 자기가 만드는 볼륨(Kafka · 관측 WAL)에도 공통 태그를 붙인다(`controller.extraVolumeTags`).
- gp3 StorageClass 는 여기서 만들지 않는다. 쿠버네티스 오브젝트라 kubernetes provider 를 이 state 에 들여야 하는데, provider 둘이 한 state 에 섞이면 클러스터를 만드는 코드가 그 클러스터에 붙는 자격에 의존하게 된다. cgv-infra 가 배달한다.

### IRSA — 파드가 AWS 권한을 받는 길

파드는 AWS 자원이 아니다. 파드가 가진 것은 쿠버네티스 API 서버가 서명한 ServiceAccount 토큰이고, AWS 는 그 서명을 원래 모른다.
OIDC 공급자를 등록하면 IAM 이 그 서명을 믿는다. 역할의 신뢰 정책은 토큰의 `sub`(`system:serviceaccount:<네임스페이스>:<이름>`)와 `aud`(`sts.amazonaws.com`)로 어느 SA 가 맡을 수 있는지 한정하고,
파드는 STS `AssumeRoleWithWebIdentity` 로 임시 자격을 받는다.

노드 역할에는 그 노드의 모든 파드에 있어도 되는 것(클러스터 등록 · ENI · ECR 읽기)만 붙인다. 파드 하나만 필요한 권한은 아래 역할로 내린다.

| 역할 | 맡는 SA | 할 수 있는 것 | SA 애노테이션을 붙이는 곳 |
|---|---|---|---|
| `cgv-stg-obs-s3` | `observability` 의 `mimir` · `loki` · `tempo` | 관측 버킷 셋 읽기 · 쓰기 · 삭제 | cgv-infra `envs/stg/observability/{mimir,loki,tempo}.yaml` |
| `cgv-stg-ebs-csi` | `kube-system:ebs-csi-controller-sa` | EBS 볼륨 만들기 · 붙이기(AWS 관리형 정책) | 애드온이 `service_account_role_arn` 으로 직접 붙인다 |
| `cgv-stg-alb` | `kube-system:aws-load-balancer-controller` | ALB · 대상그룹 · 보안 그룹 관리(컨트롤러 v2.13.4 공식 정책) | cgv-infra `envs/stg/aws-load-balancer-controller.yaml` |
| `cgv-stg-cloudwatch` | `observability:cloudwatch-exporter` | 태그로 자원 찾기 · CloudWatch 지표 읽기 | cgv-infra `envs/stg/observability/cloudwatch-exporter.yaml` |

`cloudwatch` 의 자원이 `*` 인 것은 `tag:GetResources` · `cloudwatch:GetMetricData` 같은 동작이 자원 ARN 으로 좁혀지지 않아서다.

### 데이터

| | 구성 | 집에서는 |
|---|---|---|
| RDS MySQL 8.4 | db.m5.large · Multi-AZ(다른 AZ 에 동기 복제 대기) · 20 GiB gp3 암호화 · 퍼블릭 접근 없음 · 백업 없음 | data 네임스페이스의 MySQL 파드(9.4) |
| ElastiCache Redis 7.1 | cache.m5.large 주 1 + 복제본 1 · 자동 전환(다른 AZ) · 클러스터 모드 끔 · 전송 구간 암호화 없음(AUTH 없음) | Sentinel HA 파드 |

- 이중화를 켠다. 이유가 둘 다 다르다.
  - RDS Multi-AZ 는 커밋이 대기의 기록까지 기다려 쓰기 지연이 는다. prd 와 같은 조건에서 booking 확정의 DB 시간을 재려고 켠다(`rds_multi_az`).
  - ElastiCache 복제본은 처리량에 안 보탠다(앱이 주 엔드포인트만 쓴다). Kafka 를 AZ 셋에 두어 AZ 장애를 견디게 한 것과 짝을 맞춰, 한 AZ 가 죽어도 데이터 계층이 남게 한다(`redis_replicas`). 복제가 비동기라 전환 순간 마지막 쓰기는 잃을 수 있다.
- 둘 다 대기(복제본)는 읽기를 받지 않는다. 처리 능력을 늘리는 것은 인스턴스를 키우거나 읽기 복제본을 따로 두는 일이다.
- RDS 비밀번호는 사람이 정하지 않는다. AWS 가 만들어 Secrets Manager 에 넣고(`manage_master_user_password`), Terraform 은 값을 받지 않아 state 에 남지 않는다. cgv-infra 의 `secrets.sh` 가 그 시크릿을 읽어 쿠버네티스 Secret 으로 옮긴다.
- 둘 다 노드 보안 그룹에서만 3306 · 6379 로 들어온다. 전송 구간 암호화는 둘 다 쓰지 않는다 — MySQL 은 담기는 것이 데모 시드와 가상 사용자 예매뿐이라(`require_secure_transport=0`), Redis 는 TLS 가 명령 처리 코어를 더 써서 병목을 가리는 판에 변수가 하나 늘어서다.
- Kafka 는 관리형(MSK)으로 옮기지 않고 파드(Strimzi)로 둔다.
- 백업 · 최종 스냅숏 · 삭제 방지는 하루 켰다 지우는 환경이라 두지 않는다.

### 공통 태그와 기본값에 맡기지 않은 것

모든 자원에 `Project=cgv` · `Environment=stg`(bootstrap 은 `shared`) · `ManagedBy=terraform` 을 붙인다. 비용 보고서에서 `Environment=stg` 로 하루 환경의 비용을 거른다(결제 콘솔에서 비용 할당 태그로 한 번 활성화해야 한다).
provider 의 `default_tags` 가 안 닿는 곳 — 노드 EC2 · 루트 볼륨, EBS CSI 볼륨, ALB Controller 가 만드는 ALB — 은 각자 따로 붙인다(ALB 는 cgv-infra 의 컨트롤러 값).

| 항목 | 값 | 적지 않으면 |
|---|---|---|
| 클러스터 관리자 | `access_config` — API 모드 · 생성자 관리자 | AWS 기본값으로 정해져 코드에 안 보인다 |
| 노드 IMDS | v2 필수 · hop limit 1 | 자동 생성 launch template 의 기본값 |
| 노드 루트 디스크 | 20 GiB gp3 암호화 | 암호화 설정이 없다 |
| AMI | `AL2023_x86_64_STANDARD` | 1.30 이후 기본값과 같지만 코드에 안 보인다 |
| 애드온 버전 | 1.36 의 defaultVersion 으로 고정 | apply 할 때마다 AWS 가 고른 버전이 들어간다 |
| 서비스 CIDR | 172.20.0.0/16 | AWS 가 둘 중 하나를 골라 CoreDNS 주소를 띄워 봐야 안다 |
| RDS 비밀번호 | `manage_master_user_password` | 값이 state 에 평문으로 남는다 |
| EKS 지원 정책 | `upgrade_policy = STANDARD` | 기본값이 EXTENDED 라 표준 지원이 끝난 버전에서 연장 지원 요금이 붙는다 |
| RDS 지원 정책 | `engine_lifecycle_support` 끔, 엔진 8.4 | 표준 지원이 끝난 버전(8.0)으로도 만들어지고 연장 지원 요금이 붙는다(대기 인스턴스에도) |

## 켜고 끄기

### 처음 한 번 — bootstrap

`bootstrap/` 에서 `terraform apply`. 그 뒤 콘솔에서 IAM 사용자 둘의 액세스 키를 발급해 GitLab CI 변수(ECR push)와 cgv-infra 봉인본(이미지 태그 조회)에 넣는다.

### 켜는 날

| 칸 | 무엇 | 어디서 | kubectl |
|---|---|---|---|
| 1. Terraform | 이 저장소의 `envs/stg` 전부 | `terraform apply` | 없음 |
| 2. 사람 명령 한 번 | 내 kubectl 이 EKS 를 가리키게 한다 | `aws eks update-kubeconfig --region ap-northeast-2 --name cgv-stg --alias cgv-stg` (`terraform output handoff` 에 찍힌다) | 설정만 |
| 3. 스크립트 | `register.sh` — EKS 에 허브용 계정을 만들고 허브 ArgoCD 에 클러스터로 등록한다<br>`secrets.sh` — RDS 비밀번호 등 Secret 넷을 넣는다 | cgv-infra `bootstrap/eks/` | 스크립트 안에서 쓴다 |
| 4. git 커밋 한 번 | `STG_EKS_ENDPOINT` 를 EKS 주소로, `PLACEHOLDER`(RDS · Redis 주소, ALB 보안 그룹, 이미지 태그)를 `terraform output` 값으로 채워 main 에 머지한다 | cgv-infra | 없음 |
| 5. GitOps | 허브 ArgoCD 가 wave 순서로 배달한다 — 네임스페이스 · StorageClass · CRD → Strimzi · ALB Controller → Kafka → 관측 → 앱 | 허브 ArgoCD | 없음 |

순서: 1 → 2 → `register.sh` → 4 → (5 가 도는 동안) `secrets.sh`. `secrets.sh` 는 네임스페이스가 생길 때까지 기다린다.

칸이 이렇게 갈린 이유:

- 스크립트 둘을 Terraform 으로 옮기지 않는다. `register.sh` 가 만드는 것은 EKS 안의 쿠버네티스 객체와 집 허브의 Secret 이라 kubernetes provider 가 필요하고(애드온 절의 StorageClass 와 같은 이유), `secrets.sh` 의 값을 Terraform 으로 만들면 state 에 평문으로 남는다.
- 4 가 사람 손인 것은 EKS · RDS · Redis 주소가 apply 해야 정해지기 때문이다(AWS 가 이름에 무작위 조각을 붙인다). 클러스터에 들어갈 값은 git 에 있어야 ArgoCD 가 배달한다.

kubectl 이 들어가는 곳은 켜는 날 준비(스크립트 둘)와 지울 때뿐이다. 그 사이의 매 배포(코드 push → CI → `publish-ecr` 버튼 → 이미지 태그 되쓰기 → ArgoCD sync)에는 kubectl 이 없다.

### 지울 때

1. 관측 데이터를 S3 에 올리고 확인한다. Mimir ingester 는 받은 지표를 자기 디스크(PVC, EBS)에 쌓다가
   2시간 단위로 블록을 잘라 S3 에 올리고, 종료할 때 남은 것을 올리지 않는다(기본값). 그대로 지우면
   아직 안 올라간 최근 구간(가장 마지막 부하 구간)이 PVC 와 함께 사라진다.
   ingester 의 `/ingester/flush` 를 불러 올리게 한 뒤 관측 버킷에 새 블록이 생겼는지 본다.
   Loki · Tempo 도 최근 것을 로컬에 들고 있다가 올리는 구조라 같이 한다(정확한 명령은 리허설에서 확정)
2. 허브에서 클러스터 Secret(`cluster-cgv-stg`)을 지운다 — 허브가 stg 를 더 조정하지 않게
3. `kubectl --context cgv-stg delete namespace app data observability observability-host`
   Ingress 가 지워지며 ALB Controller 가 ALB 를, PVC 가 지워지며 EBS CSI 가 볼륨을 지운다. 콘솔에서 ALB · EBS 가 사라졌는지 확인한다
4. `envs/stg` 에서 `terraform destroy`
5. stg 를 켠 커밋을 되돌린다(곧 다시 켤 거면 되돌리지 않고 주소만 바꾼다)

Application 을 지우는 것으로는 정리되지 않는다. cgv-infra 의 ApplicationSet 이 `preserveResourcesOnDeletion` 이고 직속 Application 에는 finalizer 가 없어서, Application 이 지워져도 Ingress · PVC 가 남는다.
그 상태로 destroy 하면 Terraform 밖에서 생긴 ALB · EBS 가 서브넷에 붙어 있어 삭제가 막힌다.

## 알려진 한계

- 퍼블릭 서브넷만 쓰고 NAT 가 없다. 노드에 공인 IP 가 붙고, 인바운드는 보안 그룹이 좁힌다(노드 보안 그룹은 클러스터 안에서 오는 것만, ALB 는 집 공인 IP 와 부하 발생기만). prd 는 노드 · RDS · ElastiCache 를 프라이빗 서브넷에 두고 AZ 마다 NAT 를 둔다. stg 에서 안 한 이유 — NAT 하나는 그 AZ 가 죽을 때 다른 AZ 노드의 나가는 길까지 끊겨 AZ 셋 설계와 어긋나고, AZ 마다 두면 하루 약 $1.4 에 처리 요금(GB 당 $0.059)이 붙으며 cgv-infra NetworkPolicy 의 대역도 퍼블릭(ALB) · 프라이빗(DB)으로 다시 나눠야 한다.
- EKS API 의 허용 IP 는 apply 시점의 집 공인 IP 다. 집 IP 가 바뀌면 다시 apply 해야 허브 ArgoCD 와 kubectl 이 붙는다.
- CI 가 ECR 에 올리는 자격은 IAM 사용자의 장기 액세스 키다. GitLab 이 사설 IP 라 AWS 가 GitLab 을 OIDC 발급자로 검증할 수 없다.
- 노드 수가 고정이다(오토스케일링 없음).
- `bootstrap` state 는 로컬 파일 하나다. 잃으면 이름이 결정적이라 `terraform import` 로 되살린다(시도해 본 적은 없다).
- RDS · ElastiCache 보안 그룹은 **노드** 보안 그룹에서 오는 것을 받는다. 보안 그룹은 노드의 네트워크 인터페이스에 붙어 노드 위 어느 파드든 통과한다 — 온프레미스에서 DB 파드에 걸었던 "booking · queue 파드만 받는다" 는 입구 규칙이 여기서는 노드 단위로 느슨해진다. 파드 단위 구분은 cgv-infra 의 앱 쪽 출구 NetworkPolicy 하나가 맡는다(VPC CNI 에이전트가 실제로 막는지는 켜는 날 음성 시험으로 확인한다). prd 는 Security Groups for Pods 로 파드에 보안 그룹을 붙이고 DB 보안 그룹의 출처를 그 보안 그룹으로 좁힌다.
