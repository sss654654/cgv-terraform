variable "prefix" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "서로 다른 AZ 의 서브넷. RDS 는 Multi-AZ 를 안 켜도 둘 이상을 요구한다. 주와 대기(복제본)를 AWS 가 이 중 서로 다른 AZ 에 놓는다."
  type        = list(string)
}

variable "rds_multi_az" {
  description = <<-EOT
    RDS 대기 인스턴스를 다른 AZ 에 두고 동기로 복제한다. 주 인스턴스나 그 AZ 가 죽으면 대기가 넘겨받는다.
    대기는 읽기도 쓰기도 받지 않는다 — 처리 능력은 그대로고, 커밋이 대기의 기록까지 기다려 쓰기 지연이 는다.
  EOT
  type        = bool
}

variable "redis_replicas" {
  description = <<-EOT
    주 노드 외 복제본 수. 1 이상이면 자동 전환을 켜고 복제본을 다른 AZ 에 둔다.
    복제본은 읽기를 받지 않는다(앱이 주 엔드포인트 하나만 쓴다) — 처리량은 그대로고 넘겨받기만 한다.
    복제가 비동기라 전환 순간 주에만 있던 마지막 쓰기는 사라질 수 있다.
  EOT
  type        = number
}

variable "node_security_group_id" {
  description = "EKS 가 만든 클러스터 보안 그룹. 여기서 오는 것만 3306·6379 를 통과시킨다."
  type        = string
}

variable "mysql_version" {
  type = string
}

variable "rds_instance_class" {
  type = string
}

variable "rds_parameter_family" {
  description = "mysql_version 과 짝이 맞아야 한다. 예: mysql8.0"
  type        = string
}

variable "db_name" {
  type = string
}

variable "db_username" {
  type = string
}

variable "redis_version" {
  type = string
}

variable "redis_node_type" {
  type = string
}

variable "redis_parameter_family" {
  description = "redis_version 과 짝이 맞아야 한다. 예: redis7"
  type        = string
}
