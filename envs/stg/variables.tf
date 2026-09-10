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
    서브넷을 놓을 가용 영역 둘. 목록의 앞 둘을 자동으로 집지 않는다 —
    AZ 마다 제공하는 인스턴스 타입이 다르고, 없는 곳이 걸리면 노드그룹이 만들어지다 멈춘다.
    바꾸기 전에 확인: aws ec2 describe-instance-type-offerings --location-type availability-zone
                     --filters Name=instance-type,Values=m5.xlarge --region ap-northeast-2
  EOT
  type        = list(string)
  default     = ["ap-northeast-2a", "ap-northeast-2c"]
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
  description = "집 k3s 가 v1.36 계열이다."
  type        = string
  default     = "1.33"
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
  type    = string
  default = "8.0"
}

variable "rds_parameter_family" {
  type    = string
  default = "mysql8.0"
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

variable "db_password" {
  description = <<-EOT
    ★ 코드에도 tfvars 에도 적지 않는다. apply 할 때 환경변수로 넣는다.
      PowerShell   $env:TF_VAR_db_password = "..."
      bash         export TF_VAR_db_password='...'
    이 값은 state 에 평문으로 남는다 — 그래서 state 버킷에 암호화를 걸어 뒀다.
    booking 파드가 받는 MYSQL_PASSWORD 와 같은 값이어야 붙는다.
  EOT
  type        = string
  sensitive   = true
}

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
