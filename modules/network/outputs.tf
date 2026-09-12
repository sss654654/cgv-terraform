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

output "subnet_ids_by_az" {
  description = <<-EOT
    AZ 이름으로 서브넷을 찾는다. 노드가 뜰 AZ 를 고정해야 하는 노드그룹이 쓴다.
    목록(subnet_ids)의 순서로 고르면 AZ 목록이 바뀔 때 다른 AZ 를 집는다.
  EOT
  value       = { for az, s in aws_subnet.public : az => s.id }
}

# cgv-infra 의 Ingress 는 이름(Name 태그)으로 가리킨다. ID 는 이름이 안 먹을 때 대신 적는 값이다.
#   애노테이션이 없으면 컨트롤러가 보안 그룹을 새로 만들어 0.0.0.0/0 으로 열어, 이 규칙이 안 걸린다.
output "alb_public_security_group_id" {
  description = "서비스(frontend) ALB. 인터넷 전체에 80."
  value       = aws_security_group.alb_public.id
}

output "alb_admin_security_group_id" {
  description = "Grafana ALB. 집 공인 IP 에만 80."
  value       = aws_security_group.alb_admin.id
}
