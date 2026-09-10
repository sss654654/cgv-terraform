# IRSA — 파드의 신원인 ServiceAccount 가 IAM 역할을 맡을 수 있게 하는 것.
#
# AWS 는 파드를 모른다. 파드는 AWS 자원이 아니라 쿠버네티스 안의 것이고,
# 파드가 가진 토큰은 쿠버네티스 API 서버가 서명한 것이다.
# 그 토큰을 AWS 가 믿게 만드는 장치가 위의 OIDC 공급자이고, 여기서 그것을 신뢰 정책에 건다.
#
# 역할마다 둘을 갖는다.
#   권한 정책   맡고 나면 무엇을 할 수 있나
#   신뢰 정책   누가 맡을 수 있나          ← Condition 의 sub 가 SA 를 한정한다
#
# ★ 역할에 path 를 주지 않는다. 주면 ARN 이 role/<path>/<이름> 이 되어,
#   cgv-infra 의 SA 애노테이션에 미리 적어 둔 문자열과 어긋난다.

locals {
  # 신뢰 정책의 Condition 에 쓸 키. OIDC 공급자 주소에서 https:// 를 떼면 그 형태가 된다.
  oidc_host = replace(aws_iam_openid_connect_provider.this.url, "https://", "")
}

# 어느 SA 가 맡을 수 있는지를 적는 신뢰 정책을 만든다.
# sub 는 토큰 안의 "누구인가" 이고 형식이 system:serviceaccount:<네임스페이스>:<이름> 이다.
# aud 를 같이 보는 이유 — 그 토큰을 받을 상대가 STS 라는 것까지 맞아야 한다.
# Condition 을 빼면 이 클러스터가 발급한 토큰이면 어느 SA 든 이 역할을 맡을 수 있게 된다.
data "aws_iam_policy_document" "assume_irsa" {
  for_each = var.irsa_service_accounts

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.this.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = [for sa in each.value : "system:serviceaccount:${sa}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "irsa" {
  for_each = var.irsa_service_accounts

  name               = "${var.prefix}-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.assume_irsa[each.key].json
}

# ---------- 관측 셋이 S3 에 쓰는 권한 ----------
# Mimir·Loki·Tempo 가 블록을 올리고 쿼리 때 다시 읽는다.
# SA 는 셋인데 역할은 하나다 — 셋이 같은 버킷 묶음을 쓰기 때문에 신뢰 정책의 sub 를 셋 적었다.

data "aws_iam_policy_document" "obs_s3" {
  # 버킷 자체에 하는 일. 목록을 읽는 것은 객체가 아니라 버킷에 대한 동작이라 자원이 다르다.
  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [for b in var.observability_buckets : "arn:aws:s3:::${b}"]
  }

  # 객체에 하는 일. compactor 가 병합하고 보존을 적용하면서 지우므로 Delete 가 필요하다.
  statement {
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [for b in var.observability_buckets : "arn:aws:s3:::${b}/*"]
  }

  # 멀티파트 업로드는 조각을 올리다 끊길 수 있어 중단·조회 권한이 따로 있다.
  statement {
    effect    = "Allow"
    actions   = ["s3:AbortMultipartUpload", "s3:ListMultipartUploadParts", "s3:ListBucketMultipartUploads"]
    resources = [for b in var.observability_buckets : "arn:aws:s3:::${b}/*"]
  }
}

resource "aws_iam_policy" "obs_s3" {
  name   = "${var.prefix}-obs-s3"
  policy = data.aws_iam_policy_document.obs_s3.json
}

resource "aws_iam_role_policy_attachment" "obs_s3" {
  role       = aws_iam_role.irsa["obs-s3"].name
  policy_arn = aws_iam_policy.obs_s3.arn
}

# ---------- EBS CSI ----------
# 관리형 정책이 있어서 만들 것이 없다. PVC 가 생기면 볼륨을 만들고 노드에 붙인다.
# ★ 이 역할은 애드온 리소스가 service_account_role_arn 으로 받아서 SA 애노테이션을 직접 붙인다.
#   그래서 cgv-infra 에서 손댈 것이 없다. 관측 셋·ALB 와 갈리는 지점이다.

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.irsa["ebs-csi"].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# ---------- AWS Load Balancer Controller ----------
# Ingress 를 보고 ALB 를 만든다. 집에서 MetalLB 와 Traefik 이 하던 일을 대신한다.
# 정책은 지어낼 수 있는 문서가 아니라 컨트롤러가 공식으로 배포하는 것을 그대로 쓴다.
# 출처: kubernetes-sigs/aws-load-balancer-controller v2.13.4 의 docs/install/iam_policy.json

resource "aws_iam_policy" "alb" {
  name   = "${var.prefix}-alb"
  policy = file("${path.module}/policies/alb-controller.json")
}

resource "aws_iam_role_policy_attachment" "alb" {
  role       = aws_iam_role.irsa["alb"].name
  policy_arn = aws_iam_policy.alb.arn
}
