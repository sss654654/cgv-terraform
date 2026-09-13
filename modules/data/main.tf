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

# Redis 는 이 규칙과 비밀번호 두 겹으로 막는다. 이 규칙만 있으면 노드 위의 어떤 파드든
# 6379 에 닿는 순간 대기열 전체를 읽고 쓴다 — 파드 하나가 뚫리면 그게 곧 전권이다.
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

  # 표준 지원만 쓴다. 기본값(연장 지원 켜짐)이면 표준 지원이 끝난 버전으로도 만들어지고 연장 지원
  #   요금이 붙는다(Multi-AZ 대기 인스턴스에도). 끄면 그런 버전으로는 생성이 거부되고, 이미 지난
  #   인스턴스는 다음 메이저로 올라간다 — 하루 켰다 지우는 인스턴스라 올라갈 일이 없다.
  engine_lifecycle_support = "open-source-rds-extended-support-disabled"

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

  # 스키마와 시드는 booking 의 Flyway 가 기동 때 만든다. 빈 데이터베이스(db_name)로 나오면 V1 · V2 가 적용된다.
  #   Flyway 가 DB 잠금 아래에서 한 대만 적용해 booking 을 여러 대로 띄울 수 있다(cgv-infra stg 는 두 대).

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

# Redis 비밀번호. RDS 는 AWS 가 만들어 Secrets Manager 에 넣어 주지만(manage_master_user_password)
#   ElastiCache 에는 그 기능이 없어 여기서 만들고 같은 자리에 넣는다 — 켜는 날 두 비밀번호를
#   같은 방법으로 꺼내게 된다(bootstrap/eks/secrets.sh).
# 값은 state 에 남는다. state 버킷은 암호화 · 버전 관리 · 공개 차단이 걸려 있다.
# ElastiCache 가 받는 형식: 16-128자, `/` `"` `@` 와 공백은 못 쓴다.
resource "random_password" "redis_auth" {
  length           = 48
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_secretsmanager_secret" "redis_auth" {
  name = "${var.prefix}-redis-auth"

  # 기본값은 30일 유예다. 이 환경은 하루 만들고 지우므로, 유예가 있으면 다음 판에서 같은 이름을
  #   만들 때 "삭제 예정" 과 부딪혀 apply 가 멈춘다. 0 이면 destroy 와 함께 즉시 사라진다.
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "redis_auth" {
  secret_id     = aws_secretsmanager_secret.redis_auth.id
  secret_string = random_password.redis_auth.result
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

  # 전송 구간 암호화와 비밀번호는 한 묶음이다 — ElastiCache 는 암호화를 켜야 비밀번호를 받는다.
  #   Redis 프로토콜이 평문이라, 암호화 없이 보내면 비밀번호가 그대로 흐르기 때문이다.
  # 켜는 이유는 인증이다. 이것이 없으면 Redis 는 "6379 에 닿을 수 있으면 전권" 이 된다 —
  #   대기열 · 좌석 락 · 입장 인증이 전부 그 안에 있어, 파드 하나가 뚫리면 남의 자리를 지우거나
  #   좌석 락을 풀 수 있다. 보안 그룹은 "어디서 오는가" 만 보고 "누구인가" 는 안 본다.
  # 암호화 자체도 값을 한다. 노드와 ElastiCache 사이는 VPC 안이지만 관리형 서비스 구간이라
  #   인스턴스 간 자동 암호화의 보장 밖이다.
  # 대가로 Redis CPU 를 더 쓴다. 이 설계의 상한이 1코어라 부하 판의 한계값이 같이 움직인다 —
  #   실제 서비스 조건에서 잰 값이 진짜 상한이므로 켠 채로 재고, dev(평문)와 갈린 것을 기록한다.
  transit_encryption_enabled = true
  # 이미 떠 있는 복제 그룹의 암호화를 켤 때는 한 번에 못 바꾼다. AWS 가 두 단계를 요구한다.
  #   preferred  암호화 연결과 평문 연결을 둘 다 받는다. 앱을 TLS 로 바꾸는 동안 옛 파드가 계속 붙는다
  #   required   평문을 끊는다. 앱이 전부 TLS 로 붙은 뒤에 옮긴다
  # 빈 클러스터를 새로 만들 때는 required 로 바로 만들 수 있다 — 다음 판부터는 이 값이 required 다.
  # ★ preferred 인 동안은 평문 연결이 살아 있으므로 보안 그룹이 유일한 방어다. 오래 두지 않는다.
  transit_encryption_mode = var.redis_transit_encryption_mode
  auth_token              = random_password.redis_auth.result
  # 이미 떠 있는 그룹에 토큰을 처음 붙일 때는 SET 을 못 쓴다 — 바꿀 옛 토큰이 없기 때문이다.
  #   ROTATE  토큰을 더한다. 이 상태에서는 토큰을 보내는 연결과 안 보내는 연결이 둘 다 통한다
  #   SET     그 토큰만 받는다. 앱이 전부 토큰을 들고 붙은 뒤에 옮긴다
  # 두 단계라 앱을 끊지 않고 넘어갈 수 있다. 빈 클러스터를 새로 만들 때는 만들면서 토큰이
  #   함께 들어가므로 이 값이 쓰이지 않는다 — 기본값을 정상 상태인 SET 으로 둔다.
  auth_token_update_strategy = var.redis_auth_token_update_strategy
  at_rest_encryption_enabled = true

  # 하루 켰다 지운다.
  snapshot_retention_limit = 0

  # 복제본이 있을 때만 켤 수 있다. multi_az 는 자동 전환이 켜져 있어야 쓸 수 있고, 복제본을 주와 다른 AZ 에 둔다.
  #   전환하면 주 엔드포인트(redis_host)가 새 주를 가리킨다 — 앱은 주소를 바꾸지 않고 다시 붙는다.
  automatic_failover_enabled = var.redis_replicas > 0
  multi_az_enabled           = var.redis_replicas > 0

  apply_immediately = true
}
