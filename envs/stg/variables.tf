variable "region" {
  type    = string
  default = "ap-northeast-2"
}

variable "account_id" {
  description = "버킷 이름에 들어간다. bootstrap 이 만든 이름과 글자까지 같아야 한다."
  type        = string
  default     = "527170477076"
}

variable "prefix" {
  type    = string
  default = "cgv-stg"
}

# ---------- 네트워크 ----------

variable "azs" {
  description = <<-EOT
    서브넷을 놓을 가용 영역 셋. Kafka 브로커 셋을 AZ 마다 하나씩 두려고 셋이다.
      브로커 셋이 KRaft 컨트롤러 과반 투표와 min.insync.replicas 2 를 겸한다. AZ 둘에 나누면 한쪽에
      둘이 가고, 그 AZ 가 죽으면 하나만 남아 리더를 못 뽑고 쓰기가 거부된다. AZ 셋이면 어느 AZ 가 죽어도 둘이 남는다.
      RDS · ElastiCache 는 AWS 가 밖에서 전환을 정해 이 중 두 AZ 를 쓴다.
    목록 순서가 서브넷 CIDR 순번이다(modules/network) — 새 AZ 는 끝에 더해야 기존 서브넷이 그대로 남는다.
    목록의 앞을 자동으로 집지 않는다 — AZ 마다 제공하는 인스턴스 타입이 다르고, 없는 곳이 걸리면
    노드그룹이 만들어지다 멈춘다. m5.xlarge · c5.4xlarge 는 서울 네 AZ 모두 제공한다(2026-09-11 조회).
    바꾸기 전에 확인: aws ec2 describe-instance-type-offerings --location-type availability-zone
                     --filters Name=instance-type,Values=m5.xlarge --region ap-northeast-2
  EOT
  type        = list(string)
  default     = ["ap-northeast-2a", "ap-northeast-2c", "ap-northeast-2b"]
}

variable "vpc_cidr" {
  description = <<-EOT
    집과 안 겹치게. 집은 192.168.0.0/24(LAN)과 10.0.0.0/24(vmbr1)를 쓴다.
    /16 을 /20 넷으로 자르면 한 칸이 4,091 주소다 — VPC CNI 가 파드마다 하나씩 쓴다.
  EOT
  type        = string
  default     = "10.20.0.0/16"
}

variable "service_cidr" {
  description = <<-EOT
    쿠버네티스 서비스 대역. CoreDNS 가 이 대역의 열 번째(172.20.0.10)가 된다.
    허용 대역이 10.100.0.0/16 계열 또는 172.16.0.0/12 안이라 집의 10.43.0.0/16 은 못 쓴다.
    VPC 대역(10.20.0.0/16)과도 겹치면 안 된다.
  EOT
  type        = string
  default     = "172.20.0.0/16"
}

# ---------- EKS ----------

variable "kubernetes_version" {
  description = <<-EOT
    EKS 버전. 표준 지원 중인 것만 쓴다 — 표준 지원이 끝난 버전은 연장 지원 요금이 붙는다
    (1.33 은 2026-07-29 에 끝났다). 1.36 은 2027-08-02 까지 표준이고 집 k3s(v1.36)와 같은 계열이다.
    확인: aws eks describe-cluster-versions. 바꾸면 modules/eks 의 애드온 버전도 같이 다시 고른다.
  EOT
  type        = string
  default     = "1.36"
}

variable "app_instance_type" {
  description = <<-EOT
    앱 노드. 5만 기준 request 합이 5,400m / 6,416Mi 라 m5.xlarge(4 vCPU · 16 GiB) 넷이면 37% 다.
    t 계열은 안 쓴다 — 크레딧이 바닥나면 느려지는데 그것이 서비스 한계인지 가릴 수 없다.
  EOT
  type        = string
  default     = "m5.xlarge"
}

variable "app_node_count" {
  type    = number
  default = 4
}

variable "obs_instance_type" {
  description = "관측 노드 하나. request 합 1,610m / 4,012Mi 라 m5.large 는 83% 로 빠듯하다."
  type        = string
  default     = "m5.xlarge"
}

# ---------- 데이터 ----------

variable "mysql_version" {
  description = <<-EOT
    RDS MySQL 메이저 버전. 8.4(LTS)는 표준 지원이 2029-07-31 까지다. 8.0 은 2026-07-31 에 끝나
    연장 지원으로만 만들 수 있고 요금이 붙는다(Multi-AZ 대기에도). 9.x 는 RDS 운영 환경에 없다.
    집(dev)은 9.4 라 버전이 다르다. booking 의 Flyway 11.7 은 MySQL 8.1 까지 공식 지원이라
    9.4 에서 "시험 안 된 버전" 경고를 냈다(동작은 했다). 8.4 에서도 같은 경고가 날 수 있다.
  EOT
  type        = string
  default     = "8.4"
}

variable "rds_parameter_family" {
  description = "mysql_version 과 짝이 맞아야 한다."
  type        = string
  default     = "mysql8.4"
}

variable "rds_instance_class" {
  description = "실측 0.17 코어 × 3 이 약 0.5 코어라 db.t3.small 의 0.4 를 넘는다."
  type        = string
  default     = "db.m5.large"
}

variable "db_name" {
  type    = string
  default = "cgv"
}

variable "db_username" {
  type    = string
  default = "cgv"
}

# ★ db_password 변수는 없앴다 (2026-09-11).
#   RDS 의 manage_master_user_password 로 AWS 가 값을 만들어 Secrets Manager 에 넣는다.
#   Terraform 이 그 값을 안 받으므로 state 에 평문이 남지 않고, apply 에 환경변수도 필요 없다.
#   파드가 받는 MYSQL_PASSWORD 는 그 시크릿에서 읽어 kubectl 로 만든다(handoff 의 mysql_secret_arn).

variable "redis_version" {
  type    = string
  default = "7.1"
}

variable "redis_parameter_family" {
  type    = string
  default = "redis7"
}

variable "redis_node_type" {
  description = <<-EOT
    Redis 는 명령을 코어 하나로 처리한다. 그것이 이 설계의 절대 상한이고 계산상 약 68,000명이다.
    cache.t3.small 은 지속 성능이 0.4 vCPU 라 필요한 약 1.0 코어에 못 미친다.
    메모리는 문제가 아니다 — 실측 최대가 46 MB 다.
  EOT
  type        = string
  default     = "cache.m5.large"
}

variable "rds_multi_az" {
  description = <<-EOT
    RDS 를 Multi-AZ(다른 AZ 에 동기 복제 대기)로 둔다. 커밋이 대기의 기록까지 기다려 쓰기 지연이 는다.
    prd 는 Multi-AZ 로 둔다. 단일 AZ 로 재면 booking 확정의 DB 시간이 prd 보다 짧게 나와 스펙이 어긋난다.
  EOT
  type        = bool
  default     = true
}

variable "redis_replicas" {
  description = <<-EOT
    ElastiCache 복제본 수. 1 이면 다른 AZ 에 복제본을 두고 자동 전환을 켠다.
    처리량을 위한 것이 아니다(복제본은 읽기를 안 받는다). Kafka 는 AZ 셋으로 AZ 장애를 견디는데
    Redis 가 한 AZ 에만 있으면 그 AZ 가 죽을 때 서비스가 멈춰 AZ 설계가 한쪽만 성립한다.
  EOT
  type        = number
  default     = 1
}

# ---------- 부하 발생기 ----------

variable "loadgen_enabled" {
  description = <<-EOT
    부하 발생기를 띄울지. 시간당 $0.768 이라 배포를 확인하는 동안은 꺼 두고 판을 돌릴 때만 켠다.
    켜고 끄는 것은 이 값을 바꿔 apply 하면 된다 — 클러스터는 안 건드린다.
  EOT
  type        = bool
  default     = false
}

variable "loadgen_instance_type" {
  description = "3만 판을 클라우드 인스턴스 한 대(16코어·32GB)로 냈다."
  type        = string
  default     = "c5.4xlarge"
}

variable "loadgen_key_name" {
  description = "SSH 로 붙을 때 쓰는 키 쌍 이름. 안 쓰면 빈 값으로 두고 SSM 으로 붙는다."
  type        = string
  default     = ""
}
