# cgv-terraform

CGV 예매 대기열 서비스의 **stg 환경을 AWS 에 만드는 Terraform** 이다.
온프레미스 k3s(dev)에서 부하 실측으로 정한 스펙을 EKS 위에 올려, 한 사이클(git push → 브라우저)과 동시 1만 · 2.5만 · 5만 명 부하를 돌린 뒤 지운다.
이 저장소는 AWS 자원까지만 만든다. 클러스터 안에 무엇을 배포할지는 [cgv-infra](https://github.com/sss654654/cgv-infra) 가 정하고, 집의 ArgoCD 가 배달한다. 앱은 [cgv-onprem](https://github.com/sss654654/cgv-onprem) 이다.

## 결과

| | |
|---|---|
| 배포 한 사이클 | 코드 머지 → 브라우저 **19분 41초** (사람 손을 뺀 기계 구간 1분 54초) |
| 부하 | 1만 · 2.5만 · **5만** 명 판에서 SLO 다섯(로비 · 줄서기 · 순번 조회 · 입장 전파 · 예매 여정) 전부 통과 · 5xx 0 |
| 구조가 부하로 바뀐 것 | 켠 날은 노드그룹 둘(app · observability)이었다. 1만 명 판에서 새로 뜬 booking(JVM)의 컴파일이 오픈 순간 노드를 채워 같은 노드의 Kafka 브로커가 밀렸고, **booking 전용 노드그룹**(AZ 마다 한 대)을 더했다 |
| 5만 위를 못 잰 이유 | 서비스가 아니라 부하 발생기 — 계정 EC2 vCPU 한도 64 안에서 발생기 4대(대당 12,500 VU)가 최대다 |

판별 수치와 대시보드는 cgv-infra 에 있다.

## 아키텍처

```
집 (온프레미스)
  GitLab ─ CI ─ publish-ecr 버튼 ──────────────────────────────▶ ECR (이미지 · 커밋 해시 태그)
  k3s dev
    ├ ArgoCD (허브, dev 와 stg 를 함께 배달) ── EKS API ──────▶ EKS 컨트롤 플레인
    │                                          (public, 집 공인 IP /32 만)
    └ image-updater ── ECR 폴링 → cgv-infra 에 태그 커밋
  브라우저 ── HTTP 80 (집 공인 IP 만) ────────────────────────▶ Grafana ALB

인터넷 (누구나) ── HTTPS 443 · 80→443 ─────────────────────────▶ 서비스 ALB (ACM · TLS 1.2/1.3 · 접근 로그 S3)

AWS ap-northeast-2 · VPC 10.20.0.0/16 · 퍼블릭 서브넷 2a · 2c · 2b · NAT 없음
  ALB  (cgv-infra 의 Ingress 를 보고 ALB Controller 가 만든다 · 파드 IP 를 대상으로)
   ├▶ app 노드그룹      m5.xlarge × 4 (AZ 셋에 2+1+1)   queue · frontend · Kafka(Strimzi, AZ 마다 브로커 하나)
   └▶ booking 노드그룹  m5.xlarge × 1 × 2 (2a · 2c · taint)   booking
        ├▶ RDS MySQL 8.4 db.m5.large Multi-AZ                          ┐ 노드 보안 그룹에서만 들어온다
        └▶ ElastiCache Redis 7.1 cache.m5.large 주 + 복제본 · TLS + AUTH ┘
  관측 노드그룹 m5.xlarge × 1 (2c 고정 · taint)   Mimir · Loki · Tempo · Grafana · Alloy · CloudWatch exporter
        └▶ S3 관측 버킷 셋 (IRSA)                ← bootstrap 이 만들고 지우지 않는다
부하 발생기 (저장소 밖 일회성 Terraform · 기본 VPC) c5.2xlarge × 4 ──▶ 서비스 ALB 공인 주소
```

집과 AWS 를 잇는 선은 둘뿐이다. 허브 ArgoCD 가 EKS API 에 붙는 선, CI 가 ECR 에 이미지를 올리는 선. VPN 은 없다.

## 저장소 구조

```
bootstrap/         클러스터보다 오래 사는 것. 한 번 만들고 지우지 않는다       로컬 state
envs/stg/          하루 환경. apply 로 켜고 destroy 로 끈다                  S3 state
  main.tf          모듈 셋을 잇는다 · 공통 태그 · apply 시점 집 공인 IP 조회
  variables.tf     값마다 근거(노드 수 · AZ · 인스턴스 · 버전)를 description 에 적는다
  outputs.tf       handoff(cgv-infra 에 옮길 값) · expected(cgv-infra 에 이미 적힌 값과 대조)
  loadgen.tf       VPC 안 발생기 한 대. loadgen_enabled 로 켜고 끈다 (아래 "부하 발생기")
modules/network/   VPC · 서브넷 · IGW · ALB 보안 그룹 둘
modules/eks/       클러스터 · 노드그룹 넷 · launch template · 애드온 · OIDC 공급자 · IRSA(irsa.tf)
  policies/        ALB Controller 공식 IAM 정책
modules/data/      RDS · ElastiCache · 데이터 보안 그룹 · Redis AUTH 토큰(Secrets Manager)
```

### state 를 둘로 나눈 이유

가르는 기준은 하나다 — **클러스터보다 오래 사는가.**

| state | 무엇 | 지우나 |
|---|---|---|
| `bootstrap/` | tfstate 버킷 · 관측 버킷 셋(Mimir · Loki · Tempo) · ALB 접근 로그 버킷 · ECR 셋 · IAM 사용자 둘(CI push · 이미지 태그 조회) · ACM 인증서 · 월 예산 경보 | 지우지 않는다 |
| `envs/stg/` | VPC · EKS · 노드 · 애드온 · IRSA · RDS · ElastiCache · Redis AUTH 시크릿 · (켰다면) 발생기 | 하루 살고 지운다 |

- 한 state 에 두면 `destroy` 한 번에 판 결과(관측 블록)와 이미지까지 사라진다. 판과 판을 비교하려면 결과가 클러스터보다 오래 살아야 하고, 켜는 날 apply 직후 바로 배포하려면 이미지가 이미 있어야 한다.
- `bootstrap` 이 backend 를 안 쓰는 것은 그 backend 버킷을 여기서 만들기 때문이다(만들기 전에 참조하는 순환).
- `envs/stg` 는 `bootstrap` 의 출력을 읽지 않고 이름 규칙(`<prefix>-<이름>-<계정ID>`)으로 버킷 이름을 다시 만든다. 한쪽 state 를 잃거나 지워도 다른 쪽이 영향을 받지 않는다.
- `envs/stg` 의 잠금은 S3 `use_lockfile` 이다. Terraform 1.10 부터 S3 조건부 쓰기로 잠그므로 DynamoDB 테이블을 만들지 않는다.
- IAM 사용자의 액세스 키는 Terraform 이 만들지 않는다. 만들면 비밀값이 state 에 평문으로 남아서, 콘솔에서 발급한다.

| bootstrap 자원 | 설정 | 이유 |
|---|---|---|
| tfstate 버킷 | 버전 관리 · 서버 측 암호화 · 공개 차단 | state 가 깨졌을 때 되돌리는 유일한 수단이고, state 에 민감값이 들어간다 |
| 관측 버킷 셋 | 20일 만료 · 끊긴 멀티파트 3일 · 암호화 · 공개 차단 | 도구 보존이 15일이다. 같게 두면 도구가 아직 인덱스에 든 블록을 S3 가 먼저 지워 쿼리가 깨진다 |
| ECR 셋 | MUTABLE · 푸시 시 스캔 · 최근 10개만 | IMMUTABLE 이면 같은 커밋에서 job 을 재시도할 때 push 가 거부된다. 나이로 지우면 판 사이가 벌어질 때 이미지가 사라진다. prd 면 IMMUTABLE |
| IAM 사용자 `ci-push` | ECR push + `BatchGetImage` | push 에도 읽기가 하나 필요하다 — docker 가 레이어를 다 올린 뒤 매니페스트를 HEAD 로 확인한다. 없으면 레이어는 다 올라가고 마지막에만 403 이 난다 |
| IAM 사용자 `image-updater` | ECR 목록 · 이미지 설정 읽기 | 태그 이름이 아니라 빌드 시각(newest-build)으로 고르므로 이미지 설정 블록까지 읽는다 |
| ALB 접근 로그 버킷 | 리전 ELB 서비스 계정에만 PutObject · SSE-S3 · 20일 | 쓰는 주체가 IAM 역할이 아니라 ELB 서비스 계정이다. KMS 로 두면 ALB 가 못 써 로그가 조용히 안 쌓인다. ALB 가 자기 선에서 끝낸 요청(차단 403 · 대상 없음 5xx · TLS 실패)은 여기에만 남는다 |
| ACM 인증서 | DNS 검증 · `create_before_destroy` | 클러스터보다 오래 산다. 검증 레코드가 남아 있는 동안 ACM 이 스스로 갱신한다. `aws_acm_certificate_validation` 은 두지 않는다 — 발급을 기다려야 하는 다음 자원이 Terraform 안에 없다(443 리스너는 ALB Controller 가 만든다) |
| 월 예산 | 실제 50 · 80 · 100% + 예측 100% · 크레딧 제외 | 지우는 것을 잊었을 때 알아차리려고. 비용 데이터가 8–12시간 늦어 켜 둔 동안의 감시로는 못 쓴다 |

## 설계

### 네트워크

- 퍼블릭 서브넷 셋(AZ 2a · 2c · 2b)을 쓰고 NAT 게이트웨이를 두지 않는다. 노드는 IGW 로 직접 나가고 공인 IP 가 붙는다. 들어오는 쪽은 보안 그룹이 좁힌다. NAT 하나는 그 AZ 가 죽을 때 다른 AZ 노드의 나가는 길까지 끊겨 AZ 셋 설계와 어긋나고, AZ 마다 두면 하루(8시간) 약 $1.4 에 처리 요금(GB 당 $0.059)이 붙는다.
- AZ 가 셋인 이유는 Kafka 다. 브로커 셋이 컨트롤러 과반 투표와 `min.insync.replicas` 2 를 겸해서, AZ 둘에 나누면 한쪽에 둘이 가고 그 AZ 가 죽으면 쓰기가 멈춘다. AZ 마다 하나씩 두면 어느 AZ 가 죽어도 둘이 남는다.
- AZ 를 자동으로 고르지 않는다. AZ 마다 제공하는 인스턴스 타입이 달라 없는 곳이 걸리면 노드그룹이 만들어지다 멈춘다. 서브넷 CIDR 은 `azs` 목록 순번으로 자르므로 새 AZ 는 목록 끝에 더한다.
- VPC 는 집 대역(192.168.0.0/24 · 10.0.0.0/24)과 겹치지 않게 잡고, /20 씩 자른다. VPC CNI 가 파드마다 VPC 주소를 하나씩 쓴다.
- ALB 가 둘이고 보안 그룹도 둘이다.
  - 서비스 ALB(`cgv-stg-alb-public`) — 인터넷 전체에 80 · 443. 80 은 443 으로 보내는 리다이렉트만 받는다.
  - Grafana ALB(`cgv-stg-alb-admin`) — 집 공인 IP(/32)에만 80.
  - 한 그룹을 같이 쓰면 서비스를 여는 순간 Grafana 도 열린다. cgv-infra 의 두 Ingress 가 이 이름(Name 태그)으로 가리킨다.
  - 리스너를 여는 것(cgv-infra 의 Ingress 애노테이션)과 문을 여는 것(이 규칙)은 따로다. 리스너만 만들면 ALB 는 443 을 듣는데 보안 그룹이 막아 연결이 시간 초과로 끝난다.
- 서브넷의 `kubernetes.io/role/elb` · `kubernetes.io/cluster/cgv-stg` 태그를 보고 ALB Controller 가 ALB 를 놓을 자리를 찾는다.

### EKS 클러스터

- 컨트롤 플레인은 AWS 가 돌리고 계정에는 인스턴스로 보이지 않는다. 집에서는 노드 셋이 컨트롤 플레인을 겸했고, 3만 명 판에서 노드 메모리가 차자 etcd 쓰기가 4초가 되며 k3s 가 재시작했다. 여기서는 그 부분이 노드와 떨어져 있다.
- API 는 public 이지만 허용 IP 가 하나다. apply 시점에 `checkip.amazonaws.com` 으로 조회한 집 공인 IP 라 코드에 IP 가 남지 않는다. 허브 ArgoCD 가 집에서 붙어야 해서 private 만으로는 안 된다.
- 서비스 CIDR 172.20.0.0/16 을 지정한다. CoreDNS 가 그 대역의 열 번째(172.20.0.10)로 정해져 cgv-infra 의 nginx resolver 에 미리 적는다. 지정하지 않으면 AWS 가 둘 중 하나를 골라 띄워 봐야 안다.
- `access_config` — 권한을 EKS access entry 로만 주고(aws-auth ConfigMap 을 안 쓴다), apply 를 실행한 IAM 주체를 관리자로 둔다. cgv-infra 의 `bootstrap/eks/register.sh` 가 허브용 계정을 만들 수 있는 것이 이 권한이다.
- 버전은 1.36 이다. 표준 지원이 끝난 버전은 연장 지원 요금이 붙는다(1.33 은 2026-07-29 에 끝났다). 1.36 은 2027-08-02 까지 표준이고 집 k3s(v1.36)와 같은 계열이다. `upgrade_policy` 를 `STANDARD` 로 두어 연장 지원 요금이 붙는 상태로 남지 않게 한다.

### 노드

| 노드그룹 | 스펙 · 배치 | 라벨 · taint | 무엇이 뜨나 |
|---|---|---|---|
| `app` | m5.xlarge × 4 고정 · 서브넷 셋 | `workload=app` | queue · frontend · Kafka · 오퍼레이터 · 컨트롤러 |
| `booking-2a` · `booking-2c` | m5.xlarge × 1 씩 · AZ 하나씩 | `workload=booking` · `NoSchedule` | booking |
| `observability` | m5.xlarge × 1 · **2c 고정** | `workload=observability` · `NoSchedule` | 관측 스택 |

- **app 이 넷인 이유** — queue 파드 수와 같다. 셋으로 줄였더니 queue 넷 중 둘이 한 노드에 앉았고, 2.5만 명 판에서 그 두 파드만 줄서기 1초 초과를 5,055 · 5,142 건 냈다(다른 노드의 둘은 0). 같은 시각 ElastiCache 엔진 CPU 는 1.88% 였다 — 느린 것은 Redis 가 아니라 CPU 차례였다.
- **booking 을 떼어 낸 이유** — 새로 뜬 JVM 은 오픈 순간 컴파일에 코어 2.4개와 처리에 1개를 써 4 vCPU 노드를 채웠다(런큐 대기 15 초/초 · CPU 압력 66%). 같은 노드의 Kafka 브로커가 밀려 발행 p99 가 3.6초가 됐다. 오픈 순간 튀는 파드는 booking 하나라 이것만 노드를 혼자 쓴다. AZ 둘로 나눠 한 AZ 가 죽어도 한 대가 남는다. nodeSelector 만으로는 다른 파드가 재시작 때 옮겨 앉는 것을 못 막아 taint 를 둔다. 브로커는 app 노드에 남긴다 — 실사용 0.15코어에 전용 노드 셋은 실측이 요구하지 않는다.
- **관측 노드를 AZ 하나에 고정한 이유** — 그 노드의 Mimir · Loki · Tempo 가 EBS 볼륨을 들고 있고 EBS 는 AZ 에 묶인다. 서브넷 셋을 줬을 때 노드그룹 교체에서 노드가 2c 에서 2b 로 옮겨 떴고, Mimir ingester 가 볼륨을 못 붙여 95분 동안 Pending 이었다. 상태를 든 노드그룹만 고정하고, 무상태인 app 은 흩는다. 대가: 그 AZ 가 죽으면 관측이 끊긴다.
- **관측 노드를 나눈 이유** — 온프레미스 3만 명 판에서 노드 메모리가 차면서 같은 노드의 관측 스택이 같이 재시작했고, 무너지는 순간의 지표가 남지 않았다.
- t 계열을 쓰지 않는다. 크레딧이 바닥나면 느려지는데 그것이 서비스 한계인지 크레딧 고갈인지 가릴 수 없다.
- 노드 수를 고정한다. 부하 판의 목적이 "무엇이 먼저 막히나"를 지목하는 것인데 노드가 스스로 늘면 그 막힘이 가려진다.
- launch template 을 노드그룹마다 하나씩 둔다(노드그룹 자원의 태그는 EC2 로 안 내려가서, 콘솔에서 인스턴스를 가르려면 LT 가 그룹마다 있어야 한다).
  - IMDSv2 필수 · hop limit 1 — 파드 네트워크에서는 인스턴스 메타데이터에 닿지 않아 파드가 노드 역할의 자격을 꺼내 쓸 수 없다. 리전이 필요한 파드는 cgv-infra 값 파일에 리전을 적었다.
  - 루트 볼륨 20 GiB gp3 암호화 · EC2 · 볼륨에 공통 태그와 Name.
  - ★ LT 가 바뀌면 노드그룹이 새로 만들어진다(노드 전부 교체). 켜 둔 채로 apply 하지 않는다.
- AMI 는 `AL2023_x86_64_STANDARD` 로 적는다.
- **계정 EC2 vCPU 한도(L-1216C47A)** — 기본 32 로는 노드 일곱(28 vCPU)과 발생기가 안 들어간다. 한도에 걸리면 노드그룹이 `CREATING` 에서 멈추는데, `describe-nodegroup` 의 health 도 CloudTrail 도 비어 있고 **실패는 ASG 의 scaling activities 에만** `VcpuLimitExceeded` 로 남는다. 정지한 인스턴스는 한도에 세지 않는다.

  ```
  aws autoscaling describe-scaling-activities --auto-scaling-group-name <노드그룹의 ASG> --max-items 5
  aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A
  ```

### 애드온

| 애드온 | 하는 일 | 집에서는 |
|---|---|---|
| vpc-cni | 파드에 VPC 주소를 준다 · NetworkPolicy 집행(`enableNetworkPolicy`) | Calico |
| kube-proxy | Service 라우팅 | k3s 내장 |
| coredns | 클러스터 DNS | k3s 번들 |
| aws-ebs-csi-driver | PVC 로 EBS 를 만들고 붙인다(IRSA) | 로컬 정적 PV |
| metrics-server | HPA · `kubectl top` 이 읽는 지표 API | k3s 번들 |

- vpc-cni 의 `enableNetworkPolicy` 가 꺼져 있으면 NetworkPolicy 객체가 Synced 이고 오류도 없는데 아무것도 안 막는다.
- 버전은 EKS 1.36 의 defaultVersion 으로 고정한다. 적지 않으면 apply 할 때마다 AWS 가 고른 버전이 들어가고, 기본 버전은 하루 사이에도 바뀐다. 켜는 날 아침에 `aws eks describe-addon-versions --kubernetes-version 1.36` 으로 다시 맞춘다.
- coredns · ebs-csi · metrics-server 는 파드로 뜨므로 노드그룹 뒤에 만든다.
- ebs-csi 는 자기가 만드는 볼륨(Kafka · 관측 WAL)에도 공통 태그를 붙인다(`controller.extraVolumeTags`).
- gp3 StorageClass 는 여기서 만들지 않는다. EBS CSI 애드온은 드라이버만 깔고 StorageClass 를 만들지 않는데, 쿠버네티스 오브젝트를 만들려면 kubernetes provider 를 이 state 에 들여야 하고 그러면 클러스터를 만드는 코드가 그 클러스터에 붙는 자격에 의존한다. cgv-infra 가 배달한다(없으면 PVC 가 영구 Pending).

### IRSA — 파드가 AWS 권한을 받는 길

파드는 AWS 자원이 아니다. 파드가 가진 것은 쿠버네티스 API 서버가 서명한 ServiceAccount 토큰이고, AWS 는 그 서명을 원래 모른다.
OIDC 공급자를 등록하면 IAM 이 그 서명을 믿는다. 역할의 신뢰 정책은 토큰의 `sub`(`system:serviceaccount:<네임스페이스>:<이름>`)와 `aud`(`sts.amazonaws.com`)로 어느 SA 가 맡을 수 있는지 한정하고,
파드는 STS `AssumeRoleWithWebIdentity` 로 임시 자격을 받는다.

노드 역할에는 그 노드의 모든 파드에 있어도 되는 것(클러스터 등록 · ENI · ECR 읽기)만 붙인다. 파드 하나만 필요한 권한은 아래 역할로 내린다.

| 역할 | 맡는 SA | 할 수 있는 것 | SA 애노테이션을 붙이는 곳 |
|---|---|---|---|
| `cgv-stg-obs-s3` | `observability` 의 `mimir` · `loki` · `tempo` | 관측 버킷 셋 읽기 · 쓰기 · 삭제 · 멀티파트 중단 | cgv-infra `envs/stg/observability/{mimir,loki,tempo}.yaml` |
| `cgv-stg-ebs-csi` | `kube-system:ebs-csi-controller-sa` | EBS 볼륨 만들기 · 붙이기(AWS 관리형 정책) | 애드온이 `service_account_role_arn` 으로 직접 붙인다 |
| `cgv-stg-alb` | `kube-system:aws-load-balancer-controller` | ALB · 대상그룹 · 보안 그룹 관리(컨트롤러 v2.13.4 공식 정책) | cgv-infra `envs/stg/aws-load-balancer-controller.yaml` |
| `cgv-stg-cloudwatch` | `observability:cloudwatch-exporter` | 태그로 자원 찾기 · CloudWatch 지표 읽기 | cgv-infra `envs/stg/observability/cloudwatch-exporter.yaml` |

- `cloudwatch` 의 자원이 `*` 인 것은 `tag:GetResources` · `cloudwatch:GetMetricData` 같은 동작이 자원 ARN 으로 좁혀지지 않아서다. 태그가 없는 자원은 `tag:GetResources` 에 안 나오므로 RDS · ElastiCache 에 Name 태그를 붙인다.
- 역할에 path 를 주지 않는다. 주면 ARN 이 `role/<path>/<이름>` 이 되어 cgv-infra 에 미리 적은 문자열과 어긋난다.

### 데이터

| | 구성 | 집에서는 |
|---|---|---|
| RDS MySQL 8.4 | db.m5.large · Multi-AZ · 20 GiB gp3 암호화 · 퍼블릭 접근 없음 · 백업 없음 · 연장 지원 끔 | data 네임스페이스의 MySQL 파드(9.4) |
| ElastiCache Redis 7.1 | cache.m5.large 주 1 + 복제본 1 · 자동 전환(다른 AZ) · 클러스터 모드 끔 · **전송 구간 암호화 + AUTH** · 저장 암호화 · `noeviction` | Sentinel HA 파드(평문) |

**무엇을 관리형으로 뺐나 — 칸마다 근거가 다르다**

- MySQL → RDS: 담긴 것이 시드뿐이라 데이터 보호가 이유가 아니다. prd 에서 MySQL 을 파드로 돌리지 않으므로 전환에서 무엇이 걸리는지 보려는 것이다.
- Redis → ElastiCache(클러스터 모드 끔): 대기열 Lua 스크립트가 해시태그 키와 태그 없는 전역 키를 한 호출에 섞어서 Cluster Mode 에서는 `CROSSSLOT` 으로 거부된다.
- Kafka 는 파드(Strimzi)로 둔다. MSK 가 하루 약 $3.6 으로 60배다.

**이중화**

- RDS Multi-AZ 는 커밋이 대기의 기록까지 기다려 쓰기 지연이 는다. prd 와 같은 조건에서 예매 확정의 DB 시간을 재려고 켠다(`rds_multi_az`).
- ElastiCache 복제본은 처리량에 안 보탠다(앱이 주 엔드포인트만 쓴다). Kafka 를 AZ 셋에 두어 AZ 장애를 견디게 한 것과 짝을 맞춰, 한 AZ 가 죽어도 데이터 계층이 남게 한다(`redis_replicas`). 복제가 비동기라 전환 순간 마지막 쓰기는 잃을 수 있다.

**비밀번호**

- RDS 비밀번호는 사람이 정하지 않는다. AWS 가 만들어 Secrets Manager 에 넣고(`manage_master_user_password`), Terraform 은 값을 받지 않아 state 에 남지 않는다.
- ElastiCache 에는 그 기능이 없어 `random_password` 로 만들어 Secrets Manager(`cgv-stg-redis-auth`)에 넣는다. 이 값은 state 에 남는다(state 버킷은 암호화 · 버전 관리 · 공개 차단). `recovery_window_in_days = 0` — 기본 30일 유예면 다음에 같은 이름을 만들 때 "삭제 예정"과 부딪혀 apply 가 멈춘다.
- cgv-infra 의 `bootstrap/eks/secrets.sh` 가 두 시크릿을 읽어 쿠버네티스 Secret 으로 옮긴다.

**Redis 에 암호화와 AUTH 를 켠 이유** — 이것이 없으면 6379 에 닿는 파드 하나가 대기열 · 좌석 락 · 입장 인증 전권을 갖는다. 보안 그룹은 "어디서 오는가"만 보고 "누구인가"는 안 본다. ElastiCache 는 전송 구간 암호화를 켜야 AUTH 를 받는다(프로토콜이 평문이라). 대가로 Redis CPU 를 더 쓰는데, 실서비스 조건에서 잰 값이 진짜 상한이라 켠 채로 쟀다.

★ **암호화를 켜면 주 엔드포인트 이름이 바뀐다.** 평문은 `<이름>.<조각>.ng.0001.<리전>…`, 암호화는 `master.<이름>.<조각>.<리전>…` 이다. 서버 인증서가 새 이름에만 맞아 옛 이름으로 TLS 를 맺으면 `x509: certificate is valid for …` 로 끊긴다.

**보안 그룹**

- RDS · ElastiCache 는 노드(EKS 클러스터) 보안 그룹에서 오는 3306 · 6379 만 받는다.
- 아웃바운드 규칙이 없다. Terraform 은 AWS 가 넣는 "전체 허용" 아웃바운드 기본 규칙을 지우고 코드에 적은 것만 남긴다. 보안 그룹은 상태를 기억해 들어온 연결의 응답은 나가므로 앱 → RDS · Redis 는 성립한다.
- MySQL 은 전송 구간 암호화를 쓰지 않는다(`require_secure_transport=0`) — booking 이 JDBC `useSSL=false` 이고 담기는 것이 데모 시드와 가상 사용자 예매뿐이다.
- 백업 · 최종 스냅숏 · 삭제 방지는 하루 켰다 지우는 환경이라 두지 않는다.

### 공통 태그와 기본값에 맡기지 않은 것

모든 자원에 `Project=cgv` · `Environment=stg`(bootstrap 은 `shared`) · `ManagedBy=terraform` 을 붙인다. 비용 보고서에서 `Environment=stg` 로 하루 환경의 비용을 거른다. 태그를 붙이는 것과 비용을 태그로 가르는 것은 따로다 — 결제 쪽에서 한 번 활성화해야 보고서에 칸이 생긴다.

```
aws ce list-cost-allocation-tags --status Inactive
aws ce update-cost-allocation-tags-status \
  --cost-allocation-tags-status TagKey=Project,Status=Active TagKey=Environment,Status=Active
```

태그가 붙은 자원이 만들어진 뒤에야 키가 목록에 뜨고(하루까지), 활성화한 뒤에도 보고서에 반영되기까지 하루가 더 걸린다. 활성화 이전의 비용은 태그로 갈리지 않는다.
provider 의 `default_tags` 가 안 닿는 곳 — 노드 EC2 · 루트 볼륨(launch template), EBS CSI 볼륨(애드온 설정), ALB Controller 가 만드는 ALB(cgv-infra 의 컨트롤러 값) — 은 각자 따로 붙인다.

| 항목 | 값 | 적지 않으면 |
|---|---|---|
| 클러스터 관리자 | `access_config` — API 모드 · 생성자 관리자 | AWS 기본값으로 정해져 코드에 안 보인다 |
| 노드 IMDS | v2 필수 · hop limit 1 | 자동 생성 launch template 의 기본값 — 파드가 노드 자격에 닿는다 |
| 노드 루트 디스크 | 20 GiB gp3 암호화 | 암호화 설정이 없다 |
| AMI | `AL2023_x86_64_STANDARD` | 1.30 이후 기본값과 같지만 코드에 안 보인다 |
| 애드온 버전 | 1.36 의 defaultVersion 으로 고정 | apply 할 때마다 AWS 가 고른 버전이 들어간다 |
| vpc-cni NetworkPolicy | `enableNetworkPolicy=true` | 정책을 읽고도 아무것도 안 막는다 |
| 서비스 CIDR | 172.20.0.0/16 | AWS 가 둘 중 하나를 골라 CoreDNS 주소를 띄워 봐야 안다 |
| RDS 비밀번호 | `manage_master_user_password` | 값이 state 에 평문으로 남는다 |
| Redis 암호화 · AUTH | `transit_encryption_enabled` · `auth_token` | 6379 에 닿으면 전권 |
| Secrets Manager 유예 | `recovery_window_in_days = 0` | 다시 만들 때 이름이 부딪혀 apply 가 멈춘다 |
| EKS 지원 정책 | `upgrade_policy = STANDARD` | 기본값이 EXTENDED 라 연장 지원 요금이 붙은 채 돈다 |
| RDS 지원 정책 | `engine_lifecycle_support` 끔, 엔진 8.4 | 표준 지원이 끝난 버전(8.0)으로도 만들어지고 연장 요금이 붙는다(대기 인스턴스에도) |

## 켜고 끄기

### 처음 한 번 — bootstrap

`bootstrap/terraform.tfvars` 에 경보를 받을 주소(`budget_email`)와 서비스 호스트 이름(`stg_hostname`)을 적는다(이 파일은 `.gitignore` 대상이다). 그다음 `bootstrap/` 에서 `terraform apply`.

그 뒤 남는 것.

- 콘솔에서 IAM 사용자 둘의 액세스 키를 발급해 GitLab CI 변수(ECR push)와 cgv-infra 봉인본(이미지 태그 조회)에 넣는다.
- `terraform output acm_validation_records` 의 CNAME 을 DNS 에 넣는다(Cloudflare 면 프록시 끄고 DNS only). 발급 확인: `aws acm describe-certificate --certificate-arn <arn> --query Certificate.Status`.
- 비용 할당 태그를 활성화한다(위 "공통 태그"). 자원이 한 번은 만들어져야 태그 키가 뜨므로 켜는 날보다 앞서 한다.
- 계정 vCPU 한도를 확인한다(위 "노드"). 노드 일곱이 28 vCPU 다.

### 켜는 날

| 칸 | 무엇 | 어디서 | kubectl |
|---|---|---|---|
| 1. Terraform | 이 저장소의 `envs/stg` 전부 | `terraform apply` | 없음 |
| 2. 사람 명령 한 번 | 내 kubectl 이 EKS 를 가리키게 한다 | `aws eks update-kubeconfig --region ap-northeast-2 --name cgv-stg --alias cgv-stg` (`terraform output handoff` 에 찍힌다) | 설정만 |
| 3. 스크립트 | `register.sh` — EKS 에 허브용 계정을 만들고 허브 ArgoCD 에 `cgv-stg` 라는 이름으로 등록한다<br>`secrets.sh` — Secrets Manager 에서 읽어 Secret 넷을 넣는다 | cgv-infra `bootstrap/eks/` | 스크립트 안에서 쓴다 |
| 4. 값 대조 | `terraform output handoff` 의 `mysql_host` · `redis_host` 가 cgv-infra `envs/stg/{booking,queue}.yaml` 과 같은지 보고, 다르면 고쳐 main 에 넣는다 | cgv-infra | 없음 |
| 5. GitOps | 허브 ArgoCD 가 wave 순서로 배달한다 — 네임스페이스 · StorageClass · CRD → Strimzi · ALB Controller → Kafka → NetworkPolicy → 관측 → 대시보드 → 앱 | 허브 ArgoCD | 없음 |

순서: 1 → 2 → `register.sh` → 4 → (5 가 도는 동안) `secrets.sh`. `secrets.sh` 는 네임스페이스가 생길 때까지 기다린다.

칸이 이렇게 갈린 이유:

- 스크립트 둘을 Terraform 으로 옮기지 않는다. `register.sh` 가 만드는 것은 EKS 안의 쿠버네티스 객체와 집 허브의 Secret 이라 kubernetes provider 가 필요하고(애드온 절의 StorageClass 와 같은 이유), `secrets.sh` 의 값을 Terraform 으로 만들면 state 에 평문으로 남는다.
- cgv-infra 는 stg 를 **클러스터 이름**(`destination.name: cgv-stg`)으로 가리킨다. EKS API 주소는 apply 해야 정해지지만 옮겨 적을 곳이 없다 — `register.sh` 가 그 이름으로 주소를 등록한다.
- IRSA 역할 ARN · CoreDNS 주소 · 버킷 이름 · ALB 보안 그룹은 이름 · 대역만 정하면 결정되므로 cgv-infra 에 이미 적혀 있다. `terraform output expected` 로 대조만 한다.

kubectl 이 들어가는 곳은 켜는 날 준비(스크립트 둘)와 지울 때뿐이다. 그 사이의 매 배포(코드 push → CI → `publish-ecr` 버튼 → 이미지 태그 되쓰기 → ArgoCD sync)에는 kubectl 이 없다.

### 떠 있는 Redis 에 암호화 · AUTH 를 붙일 때

빈 그룹을 새로 만들 때는 기본값(`required` · `SET`)으로 한 번에 만들어진다. 이미 떠 있는 평문 그룹에 붙일 때만 AWS 가 두 단계씩을 요구한다. 앱을 끊지 않는 순서:

```
1  terraform apply -var redis_transit_encryption_mode=preferred     평문 · 암호화 연결을 둘 다 받는다
2  secrets.sh → queue · booking 재기동                               앱이 TLS · 비밀번호로 붙는다 (엔드포인트가 master.… 로 바뀐다)
3  terraform apply                                                  required — 평문을 끊는다
4  terraform apply -var redis_auth_token_update_strategy=ROTATE    토큰을 더한다
5  terraform apply                                                  SET — 그 토큰만 받는다
```

preferred 인 동안은 평문 연결이 살아 있어 보안 그룹이 유일한 방어다. 오래 두지 않는다.

### 지울 때

1. 관측 데이터를 S3 에 올리고 확인한다. Mimir ingester 는 받은 지표를 자기 디스크(PVC, EBS)에 쌓다가 2시간 단위로 블록을 잘라 S3 에 올리고, 종료할 때 남은 것을 올리지 않는다(기본값). 그대로 지우면 가장 마지막 부하 구간이 PVC 와 함께 사라진다. ingester 의 `/ingester/flush` 를 불러 올리게 한 뒤 관측 버킷에 새 블록이 생겼는지 본다. Loki · Tempo 도 최근 것을 로컬에 들고 있다가 올리는 구조라 같이 한다.
2. 허브에서 클러스터 Secret(`cluster-cgv-stg`)을 지운다 — 허브가 stg 를 더 조정하지 않게.
3. `kubectl --context cgv-stg delete namespace app data observability observability-host`
   Ingress 가 지워지며 ALB Controller 가 ALB 를, PVC 가 지워지며 EBS CSI 가 볼륨을 지운다. 콘솔에서 ALB · EBS 가 사라졌는지 확인한다.
4. `envs/stg` 에서 `terraform destroy`
5. 발생기를 따로 켰다면 그 Terraform 도 `destroy`

RDS 가 만든 마스터 비밀번호 시크릿은 Terraform 자원이 아니라 destroy 가 손대지 않는데, 인스턴스를 지우면 AWS 가 같이 지운다. Redis AUTH 시크릿은 Terraform 자원이라 destroy 가 즉시 지운다(유예 0).

Application 을 지우는 것으로는 정리되지 않는다. cgv-infra 의 ApplicationSet 이 `preserveResourcesOnDeletion` 이고 직속 Application 에는 finalizer 가 없어서, Application 이 지워져도 Ingress · PVC 가 남는다.
그 상태로 destroy 하면 Terraform 밖에서 생긴 ALB · EBS 가 서브넷에 붙어 있어 삭제가 막힌다.

## 부하 발생기

두 가지가 있다.

| | 위치 | 구성 | 쓰임 |
|---|---|---|---|
| `envs/stg/loadgen.tf` | 이 저장소 · stg VPC 안 | c5.4xlarge 1대 · SSM 접속 · `loadgen_enabled` 로 켜고 끔 | 기록된 판에는 쓰지 않았다 |
| 일회성 Terraform | 저장소 밖 · 기본 VPC | c5.2xlarge × N (`generator_count`) · AZ 에 흩음 · SSH | 1만 · 2.5만 · 5만 명 판 전부 |

판을 여러 대로 나눈 이유 — 한 대(c5.2xlarge)가 오픈 순간 **133,432 pps** 까지는 넘기지 않았고(2.5만 VU), 3만 VU 에서 인스턴스 pps 한도를 넘겨 패킷이 **오류 없이 버려졌다**(`ethtool -S ens5` 의 `pps_allowance_exceeded`). 같은 시각 서버는 booking CPU 0.52코어 · ALB 5xx 0 으로 한가했다. 한도가 인스턴스마다 붙으므로 박스를 키우지 않고 대수를 늘렸다 — 대당 12,500 VU × 4대 = 5만. 10만은 8대(64 vCPU)에 클러스터 28 을 더해 계정 한도 64 를 넘는다.

발생기는 인터넷용 ALB 를 공인 주소로 부른다. ALB 가 보는 출발지가 발생기의 공인 IP 라 서비스 ALB 의 인터넷 전체 규칙으로 들어간다.

## 알려진 한계

- **하루 켰다 지우는 환경이다.** 장기 운영 · 버전 업그레이드 · 장애 대응을 거치지 않았다.
- 퍼블릭 서브넷만 쓰고 NAT 가 없다. 노드에 공인 IP 가 붙고 인바운드는 보안 그룹이 좁힌다. prd 는 노드 · RDS · ElastiCache 를 프라이빗 서브넷에 두고 AZ 마다 NAT 를 둔다(cgv-infra NetworkPolicy 의 대역도 퍼블릭 · 프라이빗으로 다시 나눠야 한다).
- RDS · ElastiCache 보안 그룹은 **노드** 보안 그룹에서 오는 것을 받는다. 보안 그룹이 노드의 네트워크 인터페이스에 붙어 노드 위 어느 파드든 통과한다 — 온프레미스에서 DB 파드에 걸었던 "booking · queue 파드만 받는다"가 노드 단위로 느슨해진다. 파드 단위 구분은 cgv-infra 의 앱 쪽 출구 NetworkPolicy 가 맡는다. prd 는 Security Groups for Pods.
- CI 가 ECR 에 올리는 자격은 IAM 사용자의 장기 액세스 키다. GitLab 이 사설 IP 라 AWS 가 GitLab 을 OIDC 발급자로 검증할 수 없다.
- EKS API 의 허용 IP 는 apply 시점의 집 공인 IP 다. 집 IP 가 바뀌면 다시 apply 해야 허브 ArgoCD 와 kubectl 이 붙는다. 허브(집)가 꺼진 동안 EKS 는 마지막 sync 상태로 돈다.
- 노드 수가 고정이다. 탄력성은 파드 HPA 로 보이고, prd 는 노드도 Karpenter 로 늘린다.
- 관측 노드가 AZ 하나다. 그 AZ 가 죽으면 관측이 끊긴다. prd 는 AZ 별로 두거나 별도 계정 · 리전에 둔다.
- 새로 뜬 booking 파드의 컴파일 폭풍은 전용 노드로 **격리만** 했다. 그 파드가 오픈 직전에 교체되면 그 오픈은 느리다.
- WAF · rate limit 이 없다. 익명 접속을 받는 데모 서비스라 서비스 ALB 가 인터넷 전체에 열려 있고, 밖의 트래픽이 부하 판 숫자에 섞일 수 있다(판 동안 ALB 요청 수를 발생기가 보낸 수와 대조한다).
- `bootstrap` state 는 로컬 파일 하나다. 잃으면 이름이 결정적이라 `terraform import` 로 되살린다(시도해 본 적은 없다).
- 계정 vCPU 한도가 판의 규모를 정한다. 5만 위를 재려면 한도 증설이 먼저다.
- 실제 비용을 아직 집계하지 않았다.
