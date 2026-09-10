output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "★ 켜는 날 cgv-infra 에 넣을 값 중 하나. 미리 알 수 없다."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_security_group_id" {
  description = <<-EOT
    EKS 가 자동으로 만드는 보안 그룹. 노드와 컨트롤 플레인이 이것으로 통신한다.
    RDS·ElastiCache 로 들어오는 문을 이 그룹에만 열어 준다.
  EOT
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.this.arn
}

output "oidc_issuer" {
  value = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

output "irsa_role_arns" {
  description = <<-EOT
    cgv-infra 의 SA 애노테이션 eks.amazonaws.com/role-arn 에 적는 값.
    ★ 다만 이 값은 이름만 정하면 결정되므로(arn:aws:iam::<계정>:role/<이름>)
      apply 를 기다리지 않고 미리 적어 둘 수 있다. 여기서는 대조용으로 찍는다.
  EOT
  value       = { for k, r in aws_iam_role.irsa : k => r.arn }
}

output "coredns_cluster_ip" {
  description = <<-EOT
    frontend 의 nginx resolver 에 넣는 값. 서비스 대역의 열 번째 주소다.
    집은 10.43.0.10 이었다.
  EOT
  value       = cidrhost(var.service_cidr, 10)
}
