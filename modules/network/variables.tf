variable "prefix" {
  description = "이름 앞에 붙는 말. 클러스터 이름이기도 해서 서브넷 태그에 그대로 들어간다."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC 대역. 집(192.168.0.0/24 · 10.0.0.0/24)과 겹치지 않아야 한다."
  type        = string
}

variable "azs" {
  description = "서브넷을 놓을 가용 영역 둘. EKS 가 서로 다른 AZ 를 최소 둘 요구한다."
  type        = list(string)
}

variable "home_cidr" {
  description = "집 공인 IP /32. apply 시점에 조회한 값이 들어온다 — DDNS 라 날마다 바뀔 수 있다."
  type        = string
}
