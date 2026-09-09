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

# ---------- 출력 ----------
# stg/main.tf 의 backend 와 관측 차트 values 에 이 값을 적는다.

output "tfstate_bucket" {
  value = aws_s3_bucket.tfstate.id
}

output "observability_buckets" {
  value = { for name, b in aws_s3_bucket.observability : name => b.id }
}
