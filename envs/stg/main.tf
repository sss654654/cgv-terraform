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
    # Redis 비밀번호를 만든다. ElastiCache 에는 RDS 의 manage_master_user_password 에 해당하는
    #   기능이 없어 값을 이쪽에서 만들어 넣는다.
    random = {
      source  = "hashicorp/random"
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

  # 이 state 가 만드는 모든 AWS 자원에 붙는다. 비용 보고서(Cost Explorer)에서 Environment=stg 로
  #   하루 환경의 비용만 거른다. 태그로 비용을 가르려면 결제 콘솔에서 이 키들을 비용 할당 태그로
  #   한 번 활성화해야 한다(Billing → Cost allocation tags).
  # provider 밖에서 생기는 자원(노드 EC2 · EBS CSI 볼륨 · ALB Controller 의 ALB)에는 안 붙는다.
  #   그쪽은 modules/eks 의 tags 와 cgv-infra 의 ALB Controller 값이 따로 붙인다.
  default_tags {
    tags = local.tags
  }
}

# 집 공인 IP. DDNS 라 날마다 바뀌어서 apply 시점에 조회한다.
# 이렇게 하면 공인 IP 가 코드에도 state 밖에도 안 남는다.
data "http" "myip" {
  url = "https://checkip.amazonaws.com"
}

locals {
  home_cidr = "${chomp(data.http.myip.response_body)}/32"

  # 공통 태그. bootstrap 은 Environment=shared 다 — 여러 환경이 같이 쓰고 클러스터보다 오래 산다.
  tags = {
    Project     = "cgv"
    Environment = "stg"
    ManagedBy   = "terraform"
  }

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
    "ebs-csi"    = ["kube-system:ebs-csi-controller-sa"]
    "alb"        = ["kube-system:aws-load-balancer-controller"]
    "cloudwatch" = ["observability:cloudwatch-exporter"]
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
  # 관측 노드는 AZ 하나에 고정한다 — 그 노드의 볼륨(Mimir · Loki · Tempo)이 AZ 에 묶이기 때문이다.
  #   목록 순서로 고르지 않고 AZ 이름으로 집는다. 순서로 고르면 AZ 목록이 바뀔 때 다른 AZ 를 집는다.
  obs_subnet_id = module.network.subnet_ids_by_az[var.obs_az]
  home_cidr     = local.home_cidr
  service_cidr  = var.service_cidr

  app_instance_type = var.app_instance_type
  app_node_count    = var.app_node_count
  obs_instance_type = var.obs_instance_type

  irsa_service_accounts = local.irsa_service_accounts
  observability_buckets = local.observability_buckets

  tags = local.tags
}

module "data" {
  source = "../../modules/data"

  prefix     = var.prefix
  vpc_id     = module.network.vpc_id
  subnet_ids = module.network.subnet_ids

  # EKS 가 만든 클러스터 보안 그룹에서 오는 것만 열어 준다.
  node_security_group_id = module.eks.cluster_security_group_id

  # 떠 있는 복제 그룹에 암호화를 켜는 동안에만 preferred 로 넘긴다(-var 로).
  #   평문 연결이 살아 있어 옛 파드가 계속 붙고, 앱이 전부 TLS 로 바뀐 뒤 required 로 되돌린다.
  redis_transit_encryption_mode = var.redis_transit_encryption_mode

  # 떠 있는 그룹에 토큰을 처음 붙일 때만 ROTATE 로 넘긴다(-var).
  #   토큰 없는 연결이 살아 있어 앱을 끊지 않고, 앱이 토큰을 들고 붙은 뒤 SET 으로 좁힌다.
  redis_auth_token_update_strategy = var.redis_auth_token_update_strategy

  mysql_version        = var.mysql_version
  rds_instance_class   = var.rds_instance_class
  rds_parameter_family = var.rds_parameter_family
  db_name              = var.db_name
  db_username          = var.db_username

  redis_version          = var.redis_version
  redis_node_type        = var.redis_node_type
  redis_parameter_family = var.redis_parameter_family

  rds_multi_az   = var.rds_multi_az
  redis_replicas = var.redis_replicas
}
