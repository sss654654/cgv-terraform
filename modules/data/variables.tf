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

variable "redis_transit_encryption_mode" {
  description = <<-EOT
    ElastiCache 전송 구간 암호화 모드.
      preferred  암호화 연결과 평문 연결을 둘 다 받는다. 이미 떠 있는 그룹에 암호화를 켜는 도중에만 쓴다
      required   평문을 끊는다. 정상 상태
    AWS 는 떠 있는 그룹을 required 로 한 번에 못 바꾸게 한다 — preferred 를 거쳐야 한다.
    빈 클러스터를 새로 만들 때는 required 로 바로 만들어진다.
  EOT
  type        = string
  default     = "required"

  validation {
    condition     = contains(["preferred", "required"], var.redis_transit_encryption_mode)
    error_message = "preferred 또는 required 여야 한다."
  }
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
