variable "prefix" {
  description = "클러스터 이름이자 자원 이름 앞머리."
  type        = string
}

variable "kubernetes_version" {
  description = "EKS 버전. 집 k3s 와 같은 계열로 맞춘다."
  type        = string
}

variable "subnet_ids" {
  description = "서로 다른 AZ 의 서브넷(EKS 는 최소 둘을 요구한다). 앱 노드그룹이 이 서브넷들에 노드를 AZ 별로 고르게 띄운다."
  type        = list(string)
}

variable "obs_subnet_id" {
  description = <<-EOT
    관측 노드그룹이 뜰 서브넷 하나. AZ 를 고정하는 값이다.
    이 노드의 Mimir · Loki · Tempo 가 EBS 볼륨을 들고 있고 EBS 는 AZ 에 묶이므로,
    서브넷을 여럿 주면 노드를 다시 만들 때 볼륨과 AZ 가 어긋나 파드가 Pending 이 된다.
    ★ 이미 볼륨이 있는 환경에서 이 값을 바꾸면 그 볼륨을 못 쓴다. 바꿀 때는 볼륨을 같이 버린다.
  EOT
  type        = string
}

variable "home_cidr" {
  description = "API 서버에 붙을 수 있는 곳. 집 공인 IP /32."
  type        = string
}

variable "service_cidr" {
  description = <<-EOT
    쿠버네티스 서비스 대역. 지정하면 CoreDNS ClusterIP 가 이 대역의 열 번째 주소로 정해진다.
    허용 대역이 10.100.0.0/16 계열 또는 172.16.0.0/12 안이라, 집 k3s 의 10.43.0.0/16 은 못 쓴다.
  EOT
  type        = string
}

variable "app_instance_type" {
  type = string
}

variable "app_node_count" {
  type = number
}

variable "booking_subnet_ids_by_az" {
  description = <<-EOT
    booking 전용 노드가 뜰 AZ → 서브넷. AZ 마다 노드그룹 하나 · 노드 하나가 선다.
    booking 파드 수와 같아야 한다(파드는 노드 분산 required 라 노드보다 많으면 Pending).
  EOT
  type        = map(string)
}

variable "booking_instance_type" {
  type = string
}

variable "obs_instance_type" {
  type = string
}

variable "irsa_service_accounts" {
  description = <<-EOT
    역할 이름 → 그 역할을 맡을 수 있는 SA 목록(<네임스페이스>:<이름>).
    이 목록이 그대로 신뢰 정책의 Condition sub 가 된다. 여기 없는 SA 는 역할을 못 맡는다.
  EOT
  type        = map(list(string))
}

variable "observability_buckets" {
  description = "관측 셋이 쓰는 S3 버킷 이름. bootstrap 이 만든 것을 받는다."
  type        = list(string)
}

variable "tags" {
  description = <<-EOT
    provider 의 default_tags 가 닿지 않는 자원에 붙일 태그.
    노드 EC2 · 루트 볼륨(launch template)과 EBS CSI 가 PVC 로 만드는 볼륨이다.
  EOT
  type        = map(string)
}
