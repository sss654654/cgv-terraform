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

variable "db_password" {
  description = <<-EOT
    ★ 이 값은 state 에 평문으로 들어간다. Terraform 이 만든 자원의 속성을 그대로 기록하기 때문이다.
      그래서 state 버킷에 암호화를 걸어 뒀다(bootstrap 의 aws_s3_bucket_server_side_encryption_configuration).
      코드나 tfvars 파일에 적지 않는다 — apply 할 때 TF_VAR_db_password 로 넣는다.
  EOT
  type        = string
  sensitive   = true
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
