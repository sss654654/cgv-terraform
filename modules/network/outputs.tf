output "vpc_id" {
  value = aws_vpc.this.id
}

output "vpc_cidr" {
  value = aws_vpc.this.cidr_block
}

output "subnet_ids" {
  description = "EKS 가 서로 다른 AZ 의 서브넷을 최소 둘 요구한다. RDS·ElastiCache 서브넷 그룹도 이것을 쓴다."
  value       = [for s in aws_subnet.public : s.id]
}

output "alb_security_group_id" {
  description = "cgv-infra 의 Ingress 애노테이션에 적는다. 안 적으면 컨트롤러가 SG 를 새로 만들어 이 규칙이 안 걸린다."
  value       = aws_security_group.alb.id
}
