# data — 클러스터 밖으로 뺀 둘. MySQL 은 RDS, Redis 는 ElastiCache 로.
#
# 집에서는 고를 것이 없었다. 노트북 한 대짜리 환경에 "클러스터 밖" 이라는 자리가 없어서
# 미들웨어가 전부 파드였다. 여기서 처음 선택이 생긴다.
#
# 둘을 각각 다른 것이 결정했다.
#   MySQL   목적.  데이터 보호가 아니다 — 담긴 것이 272 KiB 시드뿐이다.
#           prd 에서 MySQL 을 파드로 안 돌리기 때문이고, 전환에서 무엇이 걸리는지 보려는 것이다.
#   Redis   코드.  Lua 스크립트가 태그 없는 전역 키를 한 호출에 섞어서 Cluster Mode 를 못 쓴다.
#           그래서 관리형으로 가되 샤딩은 안 켠다.
# Kafka 는 반대로 파드에 남긴다. MSK 가 하루 $3.6 으로 60배다.

# ---------- 들어오는 문 ----------
# 노드에서만 열어 준다. 집에서 "포트포워딩을 안 한다" 에 해당하는 자리다.

resource "aws_security_group" "data" {
  name        = "${var.prefix}-data"
  description = "RDS and ElastiCache inbound from EKS nodes only"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.prefix}-data" }
}

resource "aws_vpc_security_group_ingress_rule" "mysql" {
  security_group_id = aws_security_group.data.id
  description       = "MySQL from EKS nodes"

  referenced_security_group_id = var.node_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
}

# ElastiCache 는 전송 구간 암호화를 켜야 비밀번호를 쓸 수 있다. Redis 프로토콜이 평문이라
# 암호화 없이 보내면 비밀번호가 그대로 흐르기 때문이다.
# 암호화를 끄기로 해서 비밀번호도 안 쓴다 — 격리는 이 규칙 하나가 맡는다.
resource "aws_vpc_security_group_ingress_rule" "redis" {
  security_group_id = aws_security_group.data.id
  description       = "Redis from EKS nodes"

  referenced_security_group_id = var.node_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
}

# ---------- MySQL ----------

resource "aws_db_subnet_group" "this" {
  name       = var.prefix
  subnet_ids = var.subnet_ids
}

resource "aws_db_parameter_group" "this" {
  name   = var.prefix
  family = var.rds_parameter_family

  # booking 은 JDBC 전송 암호화를 쓰지 않는다(URL 의 useSSL=false). 담기는 것이 데모 시드와 가상 사용자의
  # 예매뿐이라 암호화로 지킬 데이터가 없다. 이 값이 1 이면 평문 접속이 거부되어 booking 이 붙지 못한다.
  # 켜는 환경이라면 booking 쪽은 SPRING_DATASOURCE_URL 로 URL 전체를 덮어 sslMode 와 CA 를 준다.
  # 기본값도 0 이지만, 적어 두면 "띄운 뒤에 확인할 것" 이 "정한 값" 이 된다.
  parameter {
    name  = "require_secure_transport"
    value = "0"
  }
}

resource "aws_db_instance" "this" {
  identifier     = var.prefix
  engine         = "mysql"
  engine_version = var.mysql_version
  instance_class = var.rds_instance_class

  # 담기는 것이 272 KiB 다. 최소 크기로 둔다.
  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = var.db_name
  username = var.db_username

  # 비밀번호를 사람이 정하지 않는다. AWS 가 만들어 Secrets Manager 에 넣고,
  # Terraform 은 그 값을 받지 않는다 — 그래서 state 에 평문이 남지 않는다.
  # 만들어진 시크릿의 ARN 은 master_user_secret 속성으로 나온다(outputs.tf).
  # booking 은 이 마스터 계정(db_username)으로 붙으므로 이 값 하나가 곧 MYSQL_PASSWORD 다.
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  parameter_group_name   = aws_db_parameter_group.this.name
  vpc_security_group_ids = [aws_security_group.data.id]

  # 퍼블릭 서브넷에 있지만 밖에서 직접 못 붙는다. 노드를 거쳐야 한다.
  publicly_accessible = false

  # 대기 인스턴스를 다른 AZ 에 두고 동기로 복제한다(var.rds_multi_az). 대기는 읽기를 받지 않아 처리 능력은
  # 그대로고, 커밋이 대기의 기록까지 기다려 쓰기 지연이 는다 — 그 지연까지 prd 와 같은 조건으로 재려고 켠다.
  # 백업 · 최종 스냅숏 · 삭제 방지는 하루 켰다 지우는 환경이라 두지 않는다.
  multi_az                = var.rds_multi_az
  backup_retention_period = 0
  skip_final_snapshot     = true
  deletion_protection     = false

  # 스키마를 Hibernate 가 만든다(Flyway 가 없다). 빈 데이터베이스로 나와도 booking 이 뜨면서 만든다.
  # ★ 그리고 그래서 booking 을 여러 대로 못 늘린다 — 동시에 뜨면 DDL 이 부딪힌다.

  apply_immediately = true

  # CloudWatch exporter(YACE)가 자원을 태그 API 로 찾는다. 태그가 하나도 없는 자원은 거기 안 나온다.
  tags = { Name = var.prefix }
}

# ---------- Redis ----------

resource "aws_elasticache_subnet_group" "this" {
  name       = var.prefix
  subnet_ids = var.subnet_ids
}

resource "aws_elasticache_parameter_group" "this" {
  name   = var.prefix
  family = var.redis_parameter_family

  # ElastiCache 기본값은 volatile-lru 다. 만료가 없는 키를 지워 버릴 수 있어서 지정한다.
  # 집 설정과 같은 값이다.
  parameter {
    name  = "maxmemory-policy"
    value = "noeviction"
  }
}

resource "aws_elasticache_replication_group" "this" {
  replication_group_id = var.prefix
  description          = "${var.prefix} queue and seat locks"

  engine         = "redis"
  engine_version = var.redis_version
  node_type      = var.redis_node_type
  port           = 6379

  # 샤딩을 안 켠다. Lua 스크립트가 해시태그 키와 태그 없는 전역 키(active_movies·waiting_movies)를
  # 한 호출에 섞어서 Cluster Mode 에서는 CROSSSLOT 으로 거부된다.
  # 그 둘에 태그를 붙일 수도 없다 — 승격 루프가 "지금 사람이 붙어 있는 영화가 무엇인가" 를 알아야
  # 도는데, 영화별로 쪼개면 목록 자체를 찾을 수 없다.
  # ★ cluster_enabled 는 적을 수 없는 값이다. num_node_groups 를 안 쓰면 자동으로 꺼진다.
  #   아래 num_cache_clusters 를 쓰는 것 자체가 "샤딩 안 함" 을 뜻한다.

  # 주 1 + 복제본 var.redis_replicas. 복제본은 처리량에 안 보탠다 — 집에서 슬레이브 둘이 처리량에 안 보탰다
  # (FailoverOptions 에 ReplicaOnly 도 RouteByLatency 도 없어 읽기까지 마스터로 갔다). 여기서도 앱은 주
  # 엔드포인트 하나만 쓴다. 두는 이유는 넘겨받기다 — 주 노드나 그 AZ 가 죽으면 다른 AZ 의 복제본이 주가 된다.
  # Kafka 를 AZ 셋에 두어 AZ 장애를 견디게 한 것과 짝을 맞춘다. 복제가 비동기라 전환 순간 마지막 쓰기는 잃을 수 있다.
  num_cache_clusters = 1 + var.redis_replicas

  subnet_group_name    = aws_elasticache_subnet_group.this.name
  parameter_group_name = aws_elasticache_parameter_group.this.name
  security_group_ids   = [aws_security_group.data.id]

  # CloudWatch exporter(YACE)가 자원을 태그 API 로 찾는다. 태그가 하나도 없는 자원은 거기 안 나온다.
  tags = { Name = var.prefix }

  # TLS 를 켜면 Redis CPU 를 10-30% 더 쓴다. 1코어가 이 설계의 절대 상한이라
  # 병목을 지목하는 판에 변수가 하나 느는 셈이다. t 계열을 피하는 것과 같은 이유다.
  # prd 라면 켠다. 켜면 인증이 딸려 온다.
  transit_encryption_enabled = false
  at_rest_encryption_enabled = true

  # 하루 켰다 지운다.
  snapshot_retention_limit = 0

  # 복제본이 있을 때만 켤 수 있다. multi_az 는 자동 전환이 켜져 있어야 쓸 수 있고, 복제본을 주와 다른 AZ 에 둔다.
  #   전환하면 주 엔드포인트(redis_host)가 새 주를 가리킨다 — 앱은 주소를 바꾸지 않고 다시 붙는다.
  automatic_failover_enabled = var.redis_replicas > 0
  multi_az_enabled           = var.redis_replicas > 0

  apply_immediately = true
}
