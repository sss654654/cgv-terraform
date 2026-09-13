# envs/stg — 지우는 절차

stg 를 지우는 순서 · 명령 · 확인 방법. 명령은 Windows PowerShell 한 창 기준이다(kubectl · aws · terraform).

```
0 남길 것 ─> 1 관측 flush ─> 2 허브 연결 끊기 ─> 3 네임스페이스 삭제 ─> 4 terraform destroy
  ─> 5 발생기 destroy ─> 6 잔존 확인 ─> 7 클러스터 밖 정리 ─> 8 다음 날 비용
```

| 순서를 어기면 | 결과 |
|---|---|
| 1 을 건너뛴다 | Mimir ingester 가 아직 버킷에 올리지 않은 최근 데이터가 PVC 와 함께 사라진다. 종료할 때 남은 것을 올리지 않는다(기본값) |
| 2 보다 3 을 먼저 | 허브가 stg 를 계속 조정한다 |
| 3 보다 4 를 먼저 | Terraform 밖에서 생긴 ALB · 대상 그룹 · 보안 그룹 · EBS 가 서브넷에 붙어 destroy 가 막힌다. 노드가 먼저 지워지면 이것들을 지울 컨트롤러(ALB Controller · EBS CSI)도 없어진다 |
| 3 을 Application 삭제로 대신한다 | ApplicationSet 이 `preserveResourcesOnDeletion` 이라 Ingress · PVC 가 남는다 |

시작 전에 한 번:

```powershell
$env:AWS_PAGER = ''                      # CLI 가 결과를 페이저로 열어 멈추지 않게
$env:AWS_DEFAULT_REGION = 'ap-northeast-2'
$HUB = '<허브 컨텍스트>'                  # 집 k3s(ArgoCD 허브)를 가리키는 kubectl 컨텍스트
```

---

## 0. 지우면 다시 볼 수 없는 것

클러스터가 없어지면 아래 화면을 다시 띄울 방법이 없다. 필요한 것은 이 단계에서 남긴다.

| 무엇 | 어디서 | 지운 뒤 |
|---|---|---|
| stg 대시보드 — 부하 구간 | stg Grafana | 관측 블록은 S3 에 남지만 조회할 Mimir 가 없다 |
| 허브의 클러스터 목록 · stg Application 상태 | 허브 ArgoCD — Settings → Clusters · Applications | 2 에서 사라진다 |
| 노드그룹 · RDS · ElastiCache | AWS 콘솔 | 4 에서 사라진다 |
| 노드 · 파드 배치 | `kubectl --context cgv-stg get nodes -L topology.kubernetes.io/zone` · `get pod -A -o wide` | 3 · 4 에서 사라진다 |

---

## 1. 관측 데이터를 S3 에 올리고 확인

ingester 는 받은 데이터를 PVC 에 두고 주기로 버킷에 올린다. 지우기 전에 남은 것을 올리게 한다.

port-forward 는 창을 하나 더 열어 켜 둔다. PowerShell 의 `curl` 은 다른 명령의 별칭이라 `curl.exe` 로 부른다.

| 대상 | 다른 창 (켜 둔다) | 이 창 |
|---|---|---|
| Mimir ingester — 파드마다 | `kubectl --context cgv-stg -n observability port-forward pod/mimir-ingester-0 18080:8080` | `curl.exe -X POST "http://127.0.0.1:18080/ingester/flush?wait=true"` |
| Loki — 단일 바이너리 | `kubectl --context cgv-stg -n observability port-forward pod/loki-0 13100:3100` | `curl.exe -X POST http://127.0.0.1:13100/flush` |
| Tempo — 단일 바이너리 | `kubectl --context cgv-stg -n observability port-forward pod/tempo-0 13200:3200` | `curl.exe -X POST http://127.0.0.1:13200/flush` |

응답 코드는 올라갔는지를 말하지 않는다. 버킷에서 방금 시각의 객체를 본다.

```powershell
$acct = aws sts get-caller-identity --query Account --output text
foreach ($b in 'mimir', 'loki', 'tempo') {
  "--- $b"
  aws s3api list-objects-v2 --bucket "cgv-stg-$b-$acct" --query "sort_by(Contents, &LastModified)[-3:].[LastModified, Key]" --output text
}
```

- Tempo 는 몇 분 늦게 올라올 수 있다
- 끝까지 안 올라오면 그 파드의 `/shutdown` 을 부른다 — 내려가면서 남은 것을 올리고, StatefulSet 이 다시 띄운다

---

## 2. 허브에서 stg 연결을 끊는다

```powershell
kubectl --context $HUB -n argocd delete secret cluster-cgv-stg
```

- cgv-infra `bootstrap/eks/register.sh` 가 넣은 Secret 이다
- 지운 뒤에도 stg 를 가리키는 Application 은 허브에 남고, 대상 클러스터를 찾지 못하는 상태로 보인다 — 7 에서 정리한다

---

## 3. 네임스페이스를 지운다

```powershell
kubectl --context cgv-stg delete namespace app data observability observability-host
```

| 지워지는 것 | 누가 지우나 |
|---|---|
| ALB 둘(서비스 · Grafana) · 대상 그룹 · ALB 보안 그룹 | Ingress 삭제 → kube-system 의 ALB Controller |
| EBS 볼륨(Kafka · 관측 PVC) | PVC 삭제 → StorageClass `gp3` 의 `reclaimPolicy: Delete` → EBS CSI |

두 컨트롤러가 kube-system 에 살아 있어야 삭제가 끝난다. 그래서 destroy 보다 먼저다.

**확인 — 둘 다 빈 결과여야 4 로 간다**

```powershell
aws resourcegroupstaggingapi get-resources --tag-filters Key=elbv2.k8s.aws/cluster,Values=cgv-stg --query "ResourceTagMappingList[].ResourceARN"
aws ec2 describe-volumes --filters Name=tag-key,Values=ebs.csi.aws.com/cluster --query "Volumes[].[VolumeId, State]"
```

- 태그 API 는 삭제 직후 지운 자원을 잠시 더 보여 줄 수 있다. 남으면 `aws elbv2 describe-load-balancers --query "LoadBalancers[].LoadBalancerName"` 로 직접 본다
- 네임스페이스가 `Terminating` 에서 멈추면 남은 객체와 컨트롤러 로그를 본다. **finalizer 를 손으로 지우면 AWS 자원이 남는다**

```powershell
kubectl --context cgv-stg get ingress,pvc -A
kubectl --context cgv-stg -n kube-system logs deploy/aws-load-balancer-controller --tail 50
```

---

## 4. `terraform destroy`

```powershell
cd <이 저장소>\envs\stg
terraform plan -destroy
terraform destroy
```

- 변수는 전부 기본값이 있어 `-var` 가 필요 없다
- 대상은 이 state 의 자원뿐이다 — tfstate · 관측 버킷 · ECR 은 `bootstrap/` state 라 목록에 없다
- RDS · ElastiCache 는 최종 스냅숏 없이 지워진다(`skip_final_snapshot` · 삭제 방지 끔)
- Redis AUTH 시크릿은 유예 0일이라 즉시 지워진다. RDS 마스터 비밀번호 시크릿은 Terraform 자원이 아니지만 인스턴스와 함께 AWS 가 지운다

**서브넷 · 보안 그룹 삭제가 `DependencyViolation` 으로 막히면** 네트워크 인터페이스가 남은 것이다.

```powershell
$vpc = aws ec2 describe-vpcs --filters Name=cidr,Values=10.20.0.0/16 --query "Vpcs[0].VpcId" --output text
aws ec2 describe-network-interfaces --filters Name=vpc-id,Values=$vpc --query "NetworkInterfaces[].[NetworkInterfaceId, Status, Description]" --output table
```

| Description | 뜻 | 할 일 |
|---|---|---|
| `ELB app/k8s-…` | 3 이 덜 끝났다 | ALB 가 지워졌는지 보고 destroy 를 다시 친다 |
| `aws-K8S-…` | 노드의 VPC CNI 인터페이스가 정리 중이다 | 몇 분 뒤 destroy 를 다시 친다 |

---

## 5. 부하 발생기

발생기는 이 저장소 밖의 일회성 Terraform 이다(기본 VPC · c5.2xlarge × N). 그 폴더에서:

```powershell
terraform destroy -var generator_count=<켰던 대수>
```

- 인스턴스 · 보안 그룹 · 키 페어가 지워진다
- 이 폴더의 `loadgen.tf` 는 `loadgen_enabled = false` 면 자원이 없다

---

## 6. 잔존 확인

이 계정에 stg 밖의 컴퓨트 · 데이터 자원이 없다는 전제에서, 전부 빈 결과여야 한다.

```powershell
aws eks list-clusters --query clusters
aws ec2 describe-instances --filters Name=instance-state-name,Values=pending,running,stopping,stopped --query "Reservations[].Instances[].[InstanceId, InstanceType]"
aws rds describe-db-instances --query "DBInstances[].DBInstanceIdentifier"
aws elasticache describe-replication-groups --query "ReplicationGroups[].ReplicationGroupId"
aws elbv2 describe-load-balancers --query "LoadBalancers[].LoadBalancerName"
aws ec2 describe-volumes --query "Volumes[].[VolumeId, State]"
aws ec2 describe-vpcs --filters Name=cidr,Values=10.20.0.0/16 --query "Vpcs[].VpcId"
aws secretsmanager list-secrets --query "SecretList[].Name"
```

**남아야 하는 것** — `bootstrap/` 의 tfstate 버킷 · 관측 버킷 셋 · ALB 로그 버킷 · ECR 셋 · IAM 사용자 둘 · ACM 인증서 · 월 예산. S3 · ECR 보관 요금은 계속 나간다.

---

## 7. 클러스터 밖 정리

| 무엇 | 어디서 | 비고 |
|---|---|---|
| 서비스 호스트 이름 CNAME | DNS(Cloudflare) | 가리키던 ALB 가 없어졌다. **ACM 검증 CNAME(`_` 로 시작)은 남긴다** — 지우면 인증서 자동 갱신이 멈춘다 |
| kubeconfig | `kubectl config delete-context cgv-stg` | `update-kubeconfig` 가 만든 cluster · user 항목(이름이 클러스터 ARN)은 `kubectl config get-clusters` 로 찾아 `delete-cluster` · `delete-user` |
| cgv-infra 의 stg 선언 | ApplicationSet 목록의 `cluster: cgv-stg` 항목 · `argocd/applications/*-stg.yaml` · AppProject 목적지 | 곧 다시 켤 거면 둔다. 끝낼 거면 되돌리는 커밋 |

---

## 8. 다음 날 — 비용

| 무엇 | 어디서 | 이유 |
|---|---|---|
| 켜 둔 기간 비용 | Cost Explorer — 일 단위 · 서비스별 | 비용 데이터가 8–12시간 늦게 들어온다 |
| stg 만 | 필터 `Environment = stg` | 비용 할당 태그는 활성화한 뒤의 비용에만 붙는다. 그 전 구간은 기간 · 서비스로 본다. 발생기는 이 태그가 없어 EC2 로만 보인다 |
| 예산 경보 | 메일 | 실제 50 · 80 · 100% · 예측 100% |
