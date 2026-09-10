variable "prefix" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "RDS 는 서로 다른 AZ 의 서브넷 둘을 요구한다. Multi-AZ 를 안 켜도 그렇다."
  type        = list(string)
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
