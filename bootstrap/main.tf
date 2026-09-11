# bootstrap — stg 클러스터보다 오래 사는 것만 둔다.
# stg 는 하루 만들고 지우지만 여기 있는 넷은 지우지 않는다.
#   state 버킷      지우면 Terraform 이 자기가 만든 것을 잊는다
#   관측 버킷 3개    판 결과가 클러스터보다 오래 살아야 판 사이 비교가 된다

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # backend 를 안 쓴다. state 버킷 자체를 여기서 만들기 때문에,
  # 그 버킷을 backend 로 지정하면 만들기 전에 참조하는 순환이 된다.
  # 이 state 는 로컬 파일로 남고 .gitignore 로 제외된다.
}

provider "aws" {
  region = var.region

  # 이 state 가 만드는 모든 AWS 자원에 붙는다. Environment=shared 는 여러 환경이 같이 쓰고
  #   클러스터보다 오래 사는 것이라는 뜻이다(envs/stg 는 Environment=stg).
  default_tags {
    tags = {
      Project     = "cgv"
      Environment = "shared"
      ManagedBy   = "terraform"
    }
  }
}

variable "region" {
  type    = string
  default = "ap-northeast-2"
}

variable "prefix" {
  type    = string
  default = "cgv-stg"
}

data "aws_caller_identity" "current" {}

locals {
  # S3 버킷 이름은 AWS 전체에서 유일해야 한다. "mimir" 는 이미 누가 쓰고 있다.
  suffix = data.aws_caller_identity.current.account_id

  # 집 MinIO 의 버킷 셋과 같은 이름. Mimir 는 한 버킷 안을 blocks/ ruler/ 로 나눠 쓴다.
  observability_buckets = ["mimir", "loki", "tempo"]

  # GitLab 레지스트리와 같은 경로. 앞의 주소와 태그가 달라진다.
  #   192.168.0.167:5050/cgv/cgv-onprem/queue-go:main-106-3b6bd07c
  #   <계정ID>.dkr.ecr.ap-northeast-2.amazonaws.com/cgv/cgv-onprem/queue-go:3b6bd07c
  # ECR 쪽 태그에는 브랜치·환경이 들어가지 않는다 — 같은 이미지를 여러 환경이 같은 이름으로
  # 부르려면 이름이 환경과 무관해야 한다.
  ecr_repositories = [
    "cgv/cgv-onprem/queue-go",
    "cgv/cgv-onprem/booking",
    "cgv/cgv-onprem/frontend",
  ]
}

# ---------- Terraform state ----------

resource "aws_s3_bucket" "tfstate" {
  bucket = "${var.prefix}-tfstate-${local.suffix}"
}

# state 가 깨졌을 때 되돌리는 유일한 수단
resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

# state 에 RDS 비밀번호와 IAM 액세스 키가 평문으로 들어간다
resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------- 관측 블록 ----------

resource "aws_s3_bucket" "observability" {
  for_each = toset(local.observability_buckets)

  bucket = "${var.prefix}-${each.key}-${local.suffix}"
}

# Mimir·Loki·Tempo 의 보존이 15일이다. S3 쪽을 20일로 두는 이유:
# 같은 값이면 도구가 아직 인덱스에 들고 있는 블록을 S3 가 먼저 지워 쿼리가 깨진다.
resource "aws_s3_bucket_lifecycle_configuration" "observability" {
  for_each = aws_s3_bucket.observability

  bucket = each.value.id

  rule {
    id     = "expire-after-20d"
    status = "Enabled"

    filter {}

    expiration {
      days = 20
    }

    # 업로드하다 끊긴 조각도 과금된다
    abort_incomplete_multipart_upload {
      days_after_initiation = 3
    }
  }
}

resource "aws_s3_bucket_public_access_block" "observability" {
  for_each = aws_s3_bucket.observability

  bucket = each.value.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------- 컨테이너 이미지 ----------
# stg 를 지워도 여기 이미지는 남긴다. 켜는 날 apply 하자마자 배포하려면 이미지가 이미 있어야 한다.
# ECR 을 stg state 에 두면 destroy 때 같이 지워져서, 켤 때마다 CI 부터 돌리고 기다리게 된다.
# 저장 요금이 GB당 월 $0.10 이라 이미지 셋이면 사실상 0 이다.

resource "aws_ecr_repository" "app" {
  for_each = toset(local.ecr_repositories)

  name = each.key

  # 태그가 커밋 해시라 커밋마다 다르다. IMMUTABLE 로 잠가도 평소엔 안 걸리지만,
  # 같은 커밋에서 job 을 재시도하면 태그가 같아 push 가 거부된다.
  # 켜 둔 시간이 그대로 비용이라 그 자리에서 막히지 않는 쪽으로 둔다. prd 면 IMMUTABLE 이다.
  image_tag_mutability = "MUTABLE"

  # 기본 스캔은 추가 요금이 없다. Inspector 를 쓰는 확장 스캔만 유료다.
  image_scanning_configuration {
    scan_on_push = true
  }
}

# 개수로만 지운다. 나이로 지우면 판과 판 사이가 벌어졌을 때 이미지가 사라지고,
# 그러면 ECR 을 stg 밖에 둔 이유가 없어진다.
resource "aws_ecr_lifecycle_policy" "app" {
  for_each = aws_ecr_repository.app

  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "최근 10개만 남긴다"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = {
        type = "expire"
      }
    }]
  })
}

# ---------- AWS 밖에서 ECR 에 붙는 둘 ----------
# 집 GitLab 러너와 argocd-image-updater 는 AWS 계정 밖에 있어 역할을 맡을 수 없다.
# 그래서 사용자를 만들고 액세스 키로 붙는다. EKS 노드는 계정 안이라 노드 역할을 쓰고 여기 없다.
#
# ★ 액세스 키는 Terraform 이 만들지 않는다. 만들면 비밀값이 state 에 평문으로 남는다.
#   콘솔에서 발급해 GitLab CI 변수와 클러스터 Secret 에 각각 넣는다.
# ★ GetAuthorizationToken 만 Resource 를 못 좁힌다. 리포지토리가 아니라 레지스트리 단위 동작이다.

# 켜는 날 이미지를 올린다
resource "aws_iam_user" "ci_push" {
  name = "${var.prefix}-ci-push"

  # 콘솔에서 액세스 키를 발급할 때 적은 설명이 사용자 태그로 저장된다(키는 태그 이름, 설명은 값).
  # 코드에 없으니 Terraform 이 지우려 하는데, 키를 재발급할 때마다 같은 차이가 다시 생긴다.
  # 무시하지 않으면 그 차이가 plan 에 계속 떠서 실제 변경과 섞인다.
  lifecycle {
    ignore_changes = [tags, tags_all]
  }
}

resource "aws_iam_user_policy" "ci_push" {
  name = "ecr-push"
  user = aws_iam_user.ci_push.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability", # 이미 올라간 레이어는 다시 안 올린다
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          # ★ push 인데 읽기가 하나 필요하다. docker 는 레이어를 다 올린 뒤
          #   매니페스트가 이미 있는지 HEAD 로 확인하고, ECR 은 그 동작을 이 권한으로 판정한다.
          #   없으면 레이어는 전부 올라가고 마지막에만 403 이 난다 — 2026-09-10 에 실제로 그랬다.
          "ecr:BatchGetImage",
        ]
        Resource = [for r in aws_ecr_repository.app : r.arn]
      },
    ]
  })
}

# 2분마다 새 태그가 있는지 본다
resource "aws_iam_user" "image_updater" {
  name = "${var.prefix}-image-updater"

  # ci_push 와 같은 이유. 콘솔에서 발급한 액세스 키의 설명이 태그로 남는다.
  lifecycle {
    ignore_changes = [tags, tags_all]
  }
}

resource "aws_iam_user_policy" "image_updater" {
  name = "ecr-read"
  user = aws_iam_user.image_updater.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        # update-strategy 가 newest-build 라 태그 목록만으로는 안 된다.
        # 태그 이름이 아니라 빌드 시각으로 고르는데 그 값이 이미지 설정 블록 안에 있어서,
        # 매니페스트와 그 블록을 받아 와야 읽힌다. 뒤의 둘이 그 몫이다.
        Effect = "Allow"
        Action = [
          "ecr:DescribeRepositories",
          "ecr:ListImages",
          "ecr:DescribeImages",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
        ]
        Resource = [for r in aws_ecr_repository.app : r.arn]
      },
    ]
  })
}

# ---------- 출력 ----------
# stg/main.tf 의 backend, 관측 차트 values, GitLab CI 의 push 대상에 이 값을 적는다.

output "tfstate_bucket" {
  value = aws_s3_bucket.tfstate.id
}

output "observability_buckets" {
  value = { for name, b in aws_s3_bucket.observability : name => b.id }
}

output "ecr_repositories" {
  value = { for name, r in aws_ecr_repository.app : name => r.repository_url }
}

# 이 둘의 액세스 키를 콘솔에서 발급한다. Terraform 이 안 만든다.
output "ecr_users" {
  value = {
    push = aws_iam_user.ci_push.name
    poll = aws_iam_user.image_updater.name
  }
}
