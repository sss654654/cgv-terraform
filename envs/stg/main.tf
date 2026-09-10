# stg — 하루 만들고 지운다.
#
# bootstrap 과 state 를 가른 기준은 하나다. "클러스터보다 오래 사는가."
#   bootstrap   state 버킷 · 관측 버킷 · ECR · IAM 사용자    지우지 않는다
#   stg         여기 있는 전부                              하루 살고 지운다
# 가르지 않으면 destroy 한 번에 관측 블록과 이미지까지 사라진다.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.0"
    }
  }

  backend "s3" {
    bucket = "cgv-stg-tfstate-527170477076"
    key    = "stg/terraform.tfstate"
    region = "ap-northeast-2"

    encrypt = true

    # 같은 state 를 둘이 동시에 고치는 것을 막는다.
    # 예전에는 DynamoDB 테이블이 필요했는데 Terraform 1.10 부터 S3 조건부 쓰기로 한다.
    # 테이블을 안 만드는 이유가 그것이다.
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region
}

# 집 공인 IP. DDNS 라 날마다 바뀌어서 apply 시점에 조회한다.
# 이렇게 하면 공인 IP 가 코드에도 state 밖에도 안 남는다.
data "http" "myip" {
  url = "https://checkip.amazonaws.com"
}

locals {
  home_cidr = "${chomp(data.http.myip.response_body)}/32"

  # bootstrap 이 만든 버킷들. 이름이 결정적이라(<prefix>-<이름>-<계정ID>) 여기 적을 수 있다.
  # 다른 state 의 출력을 참조하지 않는 이유 — 그러면 stg 가 bootstrap state 를 읽어야 해서
  # 두 state 가 다시 묶인다. 가른 뜻이 없어진다.
  observability_buckets = [
    for name in ["mimir", "loki", "tempo"] :
    "${var.prefix}-${name}-${var.account_id}"
  ]

  # 어느 SA 가 어느 역할을 맡을 수 있나. 이것이 그대로 신뢰 정책의 Condition sub 가 된다.
  # 관측 셋은 SA 가 셋인데 역할은 하나다 — 같은 버킷 묶음을 쓰기 때문이다.
  irsa_service_accounts = {
    "obs-s3" = [
      "observability:mimir",
      "observability:loki",
      "observability:tempo",
    ]
    "ebs-csi" = ["kube-system:ebs-csi-controller-sa"]
    "alb"     = ["kube-system:aws-load-balancer-controller"]
  }
}

module "network" {
  source = "../../modules/network"

  prefix    = var.prefix
  azs       = var.azs
  vpc_cidr  = var.vpc_cidr
  home_cidr = local.home_cidr
}

module "eks" {
  source = "../../modules/eks"

  prefix             = var.prefix
  kubernetes_version = var.kubernetes_version
  subnet_ids         = module.network.subnet_ids
  home_cidr          = local.home_cidr
  service_cidr       = var.service_cidr

  app_instance_type = var.app_instance_type
  app_node_count    = var.app_node_count
  obs_instance_type = var.obs_instance_type

  irsa_service_accounts = local.irsa_service_accounts
  observability_buckets = local.observability_buckets
}

module "data" {
  source = "../../modules/data"

  prefix     = var.prefix
  vpc_id     = module.network.vpc_id
  subnet_ids = module.network.subnet_ids

  # EKS 가 만든 클러스터 보안 그룹에서 오는 것만 열어 준다.
  node_security_group_id = module.eks.cluster_security_group_id

  mysql_version        = var.mysql_version
  rds_instance_class   = var.rds_instance_class
  rds_parameter_family = var.rds_parameter_family
  db_name              = var.db_name
  db_username          = var.db_username

  redis_version          = var.redis_version
  redis_node_type        = var.redis_node_type
  redis_parameter_family = var.redis_parameter_family
}
