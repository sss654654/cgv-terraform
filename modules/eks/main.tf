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

resource "aws_eks_node_group" "app" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "app"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.subnet_ids
  instance_types  = [var.app_instance_type]

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

  depends_on = [aws_iam_role_policy_attachment.node]
}

resource "aws_eks_node_group" "observability" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "observability"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.subnet_ids
  instance_types  = [var.obs_instance_type]

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

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_create = "OVERWRITE"

  # ★ NetworkPolicy 집행을 켠다.
  #   집에서는 Calico 가 집행했는데 VPC CNI 는 이 값이 꺼져 있으면 규칙을 읽고도 아무것도 안 막는다.
  #   객체는 Synced 이고 오류도 안 나서, 안 켜면 막고 있다고 믿은 채로 안 막힌다.
  #   manifests/netpol-app · netpol-data · netpol-observability 가 그 대상이다.
  configuration_values = jsonencode({
    enableNetworkPolicy = "true"
  })
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_create = "OVERWRITE"
}

# CoreDNS 는 뜰 노드가 있어야 한다. 노드그룹보다 먼저 만들면 Degraded 로 멈춘다.
resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"

  depends_on = [aws_eks_node_group.app]
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = aws_eks_cluster.this.name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = aws_iam_role.irsa["ebs-csi"].arn

  depends_on = [aws_eks_node_group.app]
}

# metrics-server — HPA 와 kubectl top 이 읽는 지표 API(metrics.k8s.io)를 낸다.
#   집 k3s 는 기본으로 깔아 줬고 EKS 는 안 깐다. stg queue 가 HPA(4-8대)를 쓰는데
#   이것이 없으면 HPA 가 지표를 못 읽어(<unknown>) 대수가 최소값에서 안 움직인다.
#   EKS 가 관리형 애드온으로 준다 — aws eks describe-addon-versions --addon-name metrics-server
#   (kubernetes 1.33 · publisher eks 확인). 뜰 노드가 있어야 해서 노드그룹 뒤다.
resource "aws_eks_addon" "metrics_server" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "metrics-server"

  depends_on = [aws_eks_node_group.app]
}

# ★ gp3 StorageClass 는 여기서 안 만든다.
#   EBS CSI 애드온은 드라이버만 설치하고 StorageClass 를 만들지 않는다. EKS 에 기본으로 있는 것은
#   gp2 하나라 이름이 gp3 인 것은 따로 만들어야 하는데, 그것은 쿠버네티스 오브젝트다.
#   여기서 만들려면 kubernetes provider 를 이 state 에 들여야 하고, provider 둘이 한 state 에
#   섞이면 destroy 가 꼬인다. 클러스터를 만드는 코드가 그 클러스터에 붙는 자격에 의존하게 된다.
#   → 클러스터를 세운 뒤 kubectl 로 만든다(집의 정적 PV 10장과 StorageClass 6종을 대신하는 한 덩어리).
