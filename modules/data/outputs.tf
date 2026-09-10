# ★ 이 둘이 켜는 날 cgv-infra 에 손으로 옮기는 값이다.
# 이름에 AWS 가 붙이는 무작위 조각이 들어 있어 미리 알 수 없다.

output "mysql_host" {
  description = "envs/stg/booking.yaml 의 MYSQL_HOST"
  value       = aws_db_instance.this.address
}

output "redis_host" {
  description = <<-EOT
    envs/stg/booking.yaml 과 envs/stg/queue.yaml 의 REDIS_HOST.
    ★ queue 는 dev 에서 REDIS_SENTINEL_ADDRS 만 쓰고 REDIS_HOST 가 없다.
      stg 값 파일에는 새로 생기는 키다.
  EOT
  value       = aws_elasticache_replication_group.this.primary_endpoint_address
}

output "data_security_group_id" {
  value = aws_security_group.data.id
}
