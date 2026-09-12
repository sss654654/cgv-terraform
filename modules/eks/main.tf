# eks — 클러스터와 노드그룹, 그리고 애드온.
#
# 집에서는 노드 셋이 컨트롤 플레인과 kubelet 을 겸했다(kubectl get nodes 가 셋 다 control-plane,etcd).
# 여기서는 앞의 것을 AWS 가 돌리고 시간당 $0.10 을 받는다. 내 계정에 인스턴스로 안 보인다.
# 그래서 노드가 쓸 수 있는 용량이 는다 — 집 노드는 8 GiB 중 4.96 GiB 만 allocatable 이었다.

# ---------- 클러스터 ----------

resource "aws_iam_role" "cluster" {
  name = "${var.prefix}-cluster"

  # 클러스터를 EKS 서비스가 대신 조작한다. 그래서 맡는 쪽이 eks.amazonaws.com 이다.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_eks_cluster" "this" {
  name     = var.prefix
  role_arn = aws_iam_role.cluster.arn
  version  = var.kubernetes_version

  vpc_config {
    subnet_ids = var.subnet_ids

    # API 서버를 인터넷에 열되 소스를 좁힌다. 집 ArgoCD 와 kubectl 이 밖에서 붙어야 해서
    # private 만으로는 안 된다. 공인 IP 가 DDNS 라 apply 시점에 조회한 값이 들어온다.
    endpoint_public_access  = true
    endpoint_private_access = true
    public_access_cidrs     = [var.home_cidr]
  }

  # 서비스 CIDR 을 지정하면 CoreDNS 의 ClusterIP 가 그 대역의 열 번째 주소로 정해진다.
  # 지정 안 하면 AWS 가 10.100.0.0/16 또는 172.20.0.0/16 중 하나를 골라, 띄워 봐야 알 수 있다.
  # frontend 의 nginx resolver 에 그 주소를 적어야 해서 미리 정해 둔다.
  kubernetes_network_config {
    service_ipv4_cidr = var.service_cidr
  }

  # 누가 이 클러스터의 쿠버네티스 관리자인가.
  #   API  권한을 EKS access entry(AWS API 오브젝트)로만 준다. aws-auth ConfigMap 을 안 쓴다.
  #   bootstrap_cluster_creator_admin_permissions
  #        terraform apply 를 실행한 IAM 주체에게 클러스터 관리자 access entry 를 만든다.
  #        bootstrap/eks/register.sh(cgv-infra)가 argocd-manager 를 만들 수 있는 것이 이 권한이다.
  #   노드 역할의 access entry 는 관리형 노드그룹이 만들 때 EKS 가 자동으로 넣는다.
  # 블록을 생략하면 같은 결과가 AWS 기본값으로 정해지는데, 무엇으로 정해졌는지 코드에 안 보인다.
  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  # 표준 지원만 쓴다. 기본값(EXTENDED)이면 표준 지원이 끝난 버전에서 연장 지원 요금이 붙은 채 계속 돈다.
  #   STANDARD 면 표준 지원이 끝날 때 AWS 가 다음 버전으로 올린다 — 하루 켰다 지우는 클러스터라 올라갈 일이 없다.
  upgrade_policy {
    support_type = "STANDARD"
  }

  depends_on = [aws_iam_role_policy_attachment.cluster]
}

# ---------- OIDC 공급자 ----------
# EKS 가 API 서버의 공개키를 주소 하나에 올려 둔다. AWS 입장에서 그것은 남의 주소라
# 자동으로 믿지 않는다. 계정 주인이 "이 주소는 믿어라" 를 IAM 안에 오브젝트로 등록한다.
# 이것이 있어야 파드의 SA 토큰으로 IAM 역할을 맡을 수 있다(IRSA).

data "tls_certificate" "oidc" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "this" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]
}

# ---------- 노드 ----------

resource "aws_iam_role" "node" {
  name = "${var.prefix}-node"

  # 노드는 EC2 인스턴스다. 파드가 아니라 인스턴스가 이 역할을 맡는다.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# 노드 역할에는 그 노드의 모든 파드에 있어도 되는 것만 붙인다.
# 권한의 단위가 노드라, 파드 하나만 필요한 권한을 여기 붙이면 그 노드의 파드 전부가 갖게 된다.
# S3 쓰기 같은 것은 그래서 IRSA 로 내린다.
resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",          # 노드가 클러스터에 등록된다
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",               # 파드에 IP 를 주려고 ENI 를 조작한다
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly", # kubelet 이 ECR 에서 이미지를 받는다
  ])

  role       = aws_iam_role.node.name
  policy_arn = each.key
}

# 노드그룹마다 하나씩. 내용은 같고 Name 태그만 다르다 — 노드그룹 자원의 태그는 EC2 로 안 내려가서,
#   콘솔에서 어느 인스턴스가 어느 그룹인지 보이려면 launch template 이 그룹마다 있어야 한다.
#   노드그룹 인자로는 못 정하는 것(IMDS · 루트 볼륨 · 인스턴스 태그)만 둔다.
# ★ 이 자원이 바뀌면 노드그룹이 새로 만들어진다(노드 전부 교체). 켜 둔 채로 apply 하지 않는다.
resource "aws_launch_template" "node" {
  # booking 은 AZ 마다 노드그룹이 하나라 LT 도 AZ 마다 하나다.
  #   처음에 booking 셋이 LT 하나를 나눠 쓰게 했더니 먼저 만든 노드그룹만 ACTIVE 가 되고 나머지는
  #   CREATING 인 채 ASG 를 못 만들었다(2026-09-13, 2a · 2b 각각 20분 넘게). CloudTrail 에는 EKS 가
  #   DescribeLaunchTemplateVersions 만 반복했다. 노드그룹마다 LT 를 따로 주는 것이 app · observability 와도 같다.
  for_each = toset(concat(["app", "observability"], [for az in keys(var.booking_subnet_ids_by_az) : "booking-${trimprefix(az, "ap-northeast-")}"]))

  name_prefix = "${var.prefix}-${each.key}-"

  # IMDSv2 만 받는다(토큰 없는 요청 거부). hop limit 1 이면 파드 네트워크에서는 IMDS 에 닿지 않아
  #   파드가 노드 역할의 자격을 꺼내 쓰는 경로가 막힌다. AWS 자격이 필요한 파드는 IRSA 로 받는다.
  #   hostNetwork 로 도는 vpc-cni · kube-proxy 는 노드와 같은 네트워크라 영향이 없다.
  #   EBS CSI 노드 플러그인은 IMDS 에 못 닿으면 쿠버네티스 노드 정보(라벨 · providerID)로 넘어간다.
  #   리전이 필요한 파드(Mimir · Loki · Tempo · ALB Controller · YACE)는 값 파일에 리전을 적어 두었다.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  # 루트 볼륨. 관리형 노드그룹 기본(20 GiB)과 같은 크기에 암호화를 더한다.
  #   launch template 을 쓰면 노드그룹의 disk_size 를 못 쓰고 여기서 정한다.
  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = 20
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  # provider 의 default_tags 는 이 launch template 자원에만 붙고, 이것으로 뜨는 EC2 · 루트 볼륨에는
  #   안 붙는다. 하루 비용의 대부분이 노드라 여기서 따로 붙인다.
  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.tags, { Name = "${var.prefix}-${each.key}" })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(var.tags, { Name = "${var.prefix}-${each.key}" })
  }
}

resource "aws_eks_node_group" "app" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "app"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.subnet_ids
  instance_types  = [var.app_instance_type]

  # 쿠버네티스 1.30 부터 관리형 노드그룹의 기본 AMI 가 AL2023 이다. 기본값에 기대지 않고 적는다.
  ami_type = "AL2023_x86_64_STANDARD"

  launch_template {
    id      = aws_launch_template.node["app"].id
    version = aws_launch_template.node["app"].latest_version
  }

  # t 계열을 안 쓴다. 버스터블이라 크레딧이 바닥나면 baseline 으로 떨어지는데,
  # 그 순간 느려진 것이 서비스 한계인지 크레딧 고갈인지 가릴 수 없다.
  # 판정 조건 하나가 "무엇이 먼저 막히는지 지목한다" 라 그 답이 흐려진다.

  scaling_config {
    desired_size = var.app_node_count
    min_size     = var.app_node_count
    max_size     = var.app_node_count
  }

  # 노드를 바꿀 때 새 노드를 먼저 띄우고 옮긴다. 하루 쓰는 환경이라 실익은 적지만
  # 기본값이 이것이고 바꿀 이유가 없다.
  update_config {
    max_unavailable = 1
  }

  # 역할 라벨. queue · frontend · Kafka 브로커 · 오퍼레이터가 여기에 선다(queue 는 nodeSelector 로 고정).
  #   taint 는 없다 — 여기 오면 안 되는 파드가 없다. 라벨 변경은 노드 교체 없이 반영된다.
  labels = {
    "workload" = "app"
  }

  depends_on = [aws_iam_role_policy_attachment.node]
}

# booking 전용 노드. AZ 마다 하나씩, 노드그룹도 AZ 마다 하나(관측 노드와 같은 고정 방식).
#
# 2026-09-13 stg 1만 명 판에서 booking 파드가 앱 노드를 다른 파드와 나눠 쓰는 것이 오픈 순간의
#   지연 원인이었다. 새로 뜬 booking(JVM)은 오픈 순간 컴파일에 코어 2.4개를 쓰고 처리에 1개를 더 써
#   4 vCPU 노드를 채웠고(런큐 대기 15 스레드초/초 · CPU 압박 66%), 같은 노드의 Kafka 브로커가 밀려
#   발행 p99 3.6초 · 다른 노드의 queue 까지 줄서기 2.5초가 됐다. 파드 둘이 한 노드에 앉은 판(06:42 ·
#   07:08)은 전파 SLO 가 78–90%, 한 노드에 하나만 있고 데워진 판(05:33)은 100% 였다.
#   버스트하는 파드는 이것 하나다(queue 는 Go 라 컴파일 폭풍이 없고 0.2코어). 그래서 이 파드만
#   노드를 혼자 쓰게 하고, Kafka 브로커는 앱 노드에 남긴다(브로커 실사용 0.15코어에 전용 노드 셋은 과하다).
# taint 로 다른 파드를 막는다 — nodeSelector 만으로는 브로커 · 오퍼레이터가 재시작 때 여기로 옮겨 앉을 수 있다.
#   booking 파드와 DaemonSet(vpc-cni · kube-proxy · ebs-csi · node-exporter · alloy)만 toleration 으로 들어온다.
# AZ 둘(2a · 2c)로 나눈 이유: 앱 노드그룹의 queue anti-affinity 아래에서는 booking 이 2c 두 노드에만
#   앉을 수 있어 단일 AZ 였다. 노드그룹을 AZ 별로 두면 한 AZ 가 죽어도 한 대가 남는다.
# 노드를 혼자 쓰므로 booking 의 CPU limit(4000m = 노드 전부)이 정당하다 — 그 값의 전제가 이 노드그룹이다.
resource "aws_eks_node_group" "booking" {
  for_each = var.booking_subnet_ids_by_az

  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "booking-${trimprefix(each.key, "ap-northeast-")}"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = [each.value]
  instance_types  = [var.booking_instance_type]
  ami_type        = "AL2023_x86_64_STANDARD"

  launch_template {
    id      = aws_launch_template.node["booking-${trimprefix(each.key, "ap-northeast-")}"].id
    version = aws_launch_template.node["booking-${trimprefix(each.key, "ap-northeast-")}"].latest_version
  }

  scaling_config {
    desired_size = 1
    min_size     = 1
    max_size     = 1
  }

  taint {
    key    = "workload"
    value  = "booking"
    effect = "NO_SCHEDULE"
  }

  labels = {
    "workload" = "booking"
  }

  depends_on = [aws_iam_role_policy_attachment.node]
}

resource "aws_eks_node_group" "observability" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "observability"
  node_role_arn   = aws_iam_role.node.arn

  # ★ AZ 하나에 고정한다. 앱 노드그룹과 갈리는 유일한 자리다.
  #
  # 이 노드에 뜨는 Mimir · Loki · Tempo 가 EBS 볼륨을 들고 있는데, EBS 는 AZ 에 묶인다.
  #   서브넷 셋을 주면 노드를 다시 만들 때 AWS 가 그중 아무 데나 고르고, 볼륨이 있는 AZ 와
  #   어긋나면 파드가 영영 Pending 이 된다(PersistentVolume's node affinity).
  #   2026-09-12 노드그룹 교체에서 관측 노드가 2c 에서 2b 로 옮겨 떠 Mimir ingester 가 멈췄고,
  #   ingester 가 없으면 새 지표가 하나도 저장되지 않는다.
  # 노드가 1대라 AZ 를 흩는 뜻이 애초에 없다 — 서브넷 셋을 준 것은 앱 노드그룹 값을 그대로
  #   넘긴 것이었고, 그것이 원인이었다.
  # 앱 노드그룹은 반대다. 무상태라 AZ 를 흩어야 한 AZ 가 죽어도 받는다.
  # 대가: 이 AZ 가 죽으면 관측이 끊긴다. 서비스는 계속 돌지만 그동안을 못 본다.
  #   prd 는 관측을 별도 계정 · 별도 리전에 두거나, 이 노드그룹을 AZ 마다 하나씩 세 대로 둔다.
  subnet_ids = [var.obs_subnet_id]

  instance_types = [var.obs_instance_type]
  ami_type       = "AL2023_x86_64_STANDARD"

  launch_template {
    id      = aws_launch_template.node["observability"].id
    version = aws_launch_template.node["observability"].latest_version
  }

  scaling_config {
    desired_size = 1
    min_size     = 1
    max_size     = 1
  }

  # 앱 파드가 여기 못 뜨게 막는다.
  # 3만 판에서 노드 메모리가 차면서 그 노드의 Mimir·Loki·Tempo 가 같이 재시작했고,
  # 무너지는 순간의 지표가 안 남았다. 재려던 그 순간이 가장 안 보이는 구조였다.
  taint {
    key    = "workload"
    value  = "observability"
    effect = "NO_SCHEDULE"
  }

  labels = {
    "workload" = "observability"
  }

  depends_on = [aws_iam_role_policy_attachment.node]
}

# ---------- 애드온 ----------
# 집에서 손으로 설치하던 것들을 EKS 가 관리형으로 준다.
# EBS CSI 만 IRSA 가 필요하다 — 볼륨을 만들려면 EC2 API 를 불러야 한다.
#
# ★ 앞의 셋은 EKS 가 클러스터를 만들 때 이미 설치해 둔 것이 있다.
#   애드온으로 다시 만들면 "이미 있다" 로 실패한다. OVERWRITE 는 그때 우리 것으로 덮으라는 뜻이다.
#   EBS CSI 는 기본 설치가 없어서 이 값이 필요 없다.

locals {
  # 애드온 버전. 적지 않으면 apply 할 때 AWS 가 고른 버전이 들어가 켤 때마다 달라질 수 있다.
  #   값은 aws eks describe-addon-versions --kubernetes-version 1.36 의 기본 버전(defaultVersion)이다
  #   (2026-09-12 조회). 클러스터 버전을 올리면 같은 명령으로 다시 고른다.
  #   기본 버전은 하루 사이에도 바뀐다 — 09-11 과 09-12 사이에 다섯 중 셋이 올라갔다.
  #   옛 값도 apply 는 되지만(목록에서 안 빠진다), 켜는 날 아침에 같은 명령으로 한 번 더 맞춘다.
  addon_versions = {
    "vpc-cni"            = "v1.22.4-eksbuild.3"
    "kube-proxy"         = "v1.36.0-eksbuild.21"
    "coredns"            = "v1.14.3-eksbuild.16"
    "aws-ebs-csi-driver" = "v1.66.0-eksbuild.1"
    "metrics-server"     = "v0.9.0-eksbuild.10"
  }
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "vpc-cni"
  addon_version               = local.addon_versions["vpc-cni"]
  resolve_conflicts_on_create = "OVERWRITE"

  # ★ NetworkPolicy 집행을 켠다.
  #   집에서는 Calico 가 집행했는데 VPC CNI 는 이 값이 꺼져 있으면 규칙을 읽고도 아무것도 안 막는다.
  #   객체는 Synced 이고 오류도 안 나서, 안 켜면 막고 있다고 믿은 채로 안 막힌다.
  #   cgv-infra 의 charts/platform/netpol(app · data · observability 정책)이 그 대상이다.
  configuration_values = jsonencode({
    enableNetworkPolicy = "true"
  })
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "kube-proxy"
  addon_version               = local.addon_versions["kube-proxy"]
  resolve_conflicts_on_create = "OVERWRITE"
}

# CoreDNS 는 뜰 노드가 있어야 한다. 노드그룹보다 먼저 만들면 Degraded 로 멈춘다.
resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "coredns"
  addon_version               = local.addon_versions["coredns"]
  resolve_conflicts_on_create = "OVERWRITE"

  depends_on = [aws_eks_node_group.app]
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = aws_eks_cluster.this.name
  addon_name               = "aws-ebs-csi-driver"
  addon_version            = local.addon_versions["aws-ebs-csi-driver"]
  service_account_role_arn = aws_iam_role.irsa["ebs-csi"].arn

  # PVC 로 만드는 볼륨(Kafka 60Gi × 3 · 관측 WAL)에 붙일 태그. Terraform 밖에서 생겨
  #   default_tags 가 안 닿는다. 키 이름은 애드온 설정 스키마의 controller.extraVolumeTags 다
  #   (aws eks describe-addon-configuration --addon-name aws-ebs-csi-driver).
  configuration_values = jsonencode({
    controller = {
      extraVolumeTags = var.tags
    }
  })

  depends_on = [aws_eks_node_group.app]
}

# metrics-server — HPA 와 kubectl top 이 읽는 지표 API(metrics.k8s.io)를 낸다.
#   집 k3s 는 기본으로 깔아 줬고 EKS 는 안 깐다. stg queue 가 HPA(4-8대)를 쓰는데
#   이것이 없으면 HPA 가 지표를 못 읽어(<unknown>) 대수가 최소값에서 안 움직인다.
#   EKS 가 관리형 애드온으로 준다 — aws eks describe-addon-versions --addon-name metrics-server
#   (kubernetes 1.36 · publisher eks 확인). 뜰 노드가 있어야 해서 노드그룹 뒤다.
resource "aws_eks_addon" "metrics_server" {
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "metrics-server"
  addon_version = local.addon_versions["metrics-server"]

  depends_on = [aws_eks_node_group.app]
}

# ★ gp3 StorageClass 는 여기서 안 만든다.
#   EBS CSI 애드온은 드라이버만 설치하고 StorageClass 를 만들지 않는다. EKS 에 기본으로 있는 것은
#   gp2 하나라 이름이 gp3 인 것은 따로 만들어야 하는데, 그것은 쿠버네티스 오브젝트다.
#   여기서 만들려면 kubernetes provider 를 이 state 에 들여야 하고, provider 둘이 한 state 에
#   섞이면 destroy 가 꼬인다. 클러스터를 만드는 코드가 그 클러스터에 붙는 자격에 의존하게 된다.
#   → 클러스터를 세운 뒤 kubectl 로 만든다(집의 정적 PV 10장과 StorageClass 6종을 대신하는 한 덩어리).
