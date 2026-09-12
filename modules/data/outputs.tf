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

output "redis_secret_arn" {
  description = <<-EOT
    Redis 비밀번호가 담긴 Secrets Manager 시크릿. MySQL 과 달리 AWS 가 아니라 Terraform 이 만든다
    — ElastiCache 에는 비밀번호를 대신 관리해 주는 기능이 없다.
    켜는 날 이 ARN 으로 값을 읽어 app 네임스페이스의 queue-secrets · booking-secrets 에 넣는다.
      aws secretsmanager get-secret-value --secret-id <이 값> --query SecretString --output text
    돌아오는 것은 JSON 이 아니라 비밀번호 문자열 그대로다.
  EOT
  value       = aws_secretsmanager_secret.redis_auth.arn
}

output "mysql_secret_arn" {
  description = <<-EOT
    AWS 가 만든 마스터 비밀번호가 담긴 Secrets Manager 시크릿.
    켜는 날 이 ARN 으로 값을 읽어 app 네임스페이스의 booking-secrets 를 만든다.
      aws secretsmanager get-secret-value --secret-id <이 값> --query SecretString --output text
    돌아오는 것은 {"username":...,"password":...} 형태의 JSON 이라 password 만 꺼내 쓴다.
  EOT
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}
