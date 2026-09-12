# 출력 이름을 영문으로 둔다. terraform output <이름> 으로 꺼낼 때 한글이면 셸에서 깨진다.

# ★ 켜는 날 cgv-infra 에 손으로 옮기는 값. 이름에 AWS 가 붙이는 무작위 조각이 있어 미리 알 수 없다.
output "handoff" {
  value = {
    kubeconfig = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
    eks_api    = module.eks.cluster_endpoint
    mysql_host = module.data.mysql_host
    redis_host = module.data.redis_host

    # AWS 가 만든 마스터 비밀번호가 든 시크릿. 이 ARN 으로 값을 읽어 booking-secrets 를 만든다.
    mysql_secret_arn = module.data.mysql_secret_arn
    # Redis 비밀번호가 든 시크릿. queue-secrets · booking-secrets 양쪽에 같은 값이 들어간다.
    redis_secret_arn = module.data.redis_secret_arn
  }
}

# 이 값들은 이름·대역만 정하면 결정되므로 cgv-infra 에 이미 적혀 있어야 한다.
# 여기서는 대조용으로만 찍는다. 다르면 cgv-infra 쪽을 고친다.
output "expected" {
  value = {
    irsa_role_arns = module.eks.irsa_role_arns
    dns_resolver   = module.eks.coredns_cluster_ip
    obs_buckets    = local.observability_buckets
    # cgv-infra 는 이름(cgv-stg-alb-public · cgv-stg-alb-admin)으로 가리킨다. 이름이 안 먹으면 이 ID 로 바꾼다.
    alb_public_sg = module.network.alb_public_security_group_id
    alb_admin_sg  = module.network.alb_admin_security_group_id
  }
}

output "loadgen" {
  value = var.loadgen_enabled ? {
    instance_id = aws_instance.loadgen[0].id
    connect     = "aws ssm start-session --target ${aws_instance.loadgen[0].id} --region ${var.region}"
    note        = "VPC 안이지만 ALB 를 공인 주소로 부른다. 서비스 ALB 가 인터넷 전체에 열려 있어 따로 열 것이 없다"
    } : {
    instance_id = "(꺼져 있음)"
    connect     = "loadgen_enabled = true 로 apply 하면 뜬다"
    note        = "시간당 $0.768 이라 판 돌릴 때만 켠다"
  }
}

output "checks" {
  value = {
    home_cidr_at_apply = local.home_cidr
    oidc_issuer        = module.eks.oidc_issuer
    azs                = var.azs
  }
}
