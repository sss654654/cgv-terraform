# network — VPC 와 그 안의 길.
#
# 집에서 한 일과 짝을 맞추면 이렇다.
#   Proxmox 의 vmbr1 로 대역을 잡은 것   → VPC 의 CIDR
#   vmbr1 이라는 가상 스위치 자체         → 서브넷
#   OPNsense 의 라우팅                  → 라우팅 테이블
#   OPNsense 의 NAT (밖으로 나가는 길)    → Internet Gateway
#   OPNsense 의 방화벽                  → 보안 그룹
#
# 집에 없던 축이 하나 있다 — 가용 영역(AZ). 서브넷 하나는 AZ 하나 안에만 있고,
# EKS 는 서로 다른 AZ 의 서브넷을 최소 둘 요구한다. 노드 셋이 한 노트북 안이던 집에는
# "건물이 나뉜다" 가 성립하지 않아 이 축이 아예 없었다.

# AZ 를 자동으로 고르지 않고 변수로 받는다.
# 목록의 앞 둘을 그냥 집으면 그중에 원하는 인스턴스 타입이 없는 AZ 가 걸릴 수 있고,
# 그때 노드그룹이 만들어지다 멈춘다. 같은 코드가 두 번 같은 결과를 내야 하는 것도 이유다.
locals {
  azs = var.azs
}

resource "aws_vpc" "this" {
  cidr_block = var.vpc_cidr

  # VPC CNI 가 파드에 VPC 주소를 직접 준다. 파드가 서로를 이름으로 찾으려면 DNS 가 필요하고,
  # RDS·ElastiCache 엔드포인트도 이름이라 둘 다 켠다.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = var.prefix }
}

# ---------- 서브넷 ----------
# 퍼블릭 서브넷만 만든다. 프라이빗 서브넷을 두면 노드가 밖으로 나가는 데 NAT Gateway 가 필요한데
# 서울 단가가 시간당 $0.059 에 처리 GB 당 $0.059 다. 하나만 두면 그 AZ 가 죽을 때 다른 AZ 노드도 못 나가
# AZ 셋으로 둔 뜻과 어긋나고, AZ 마다 두면 하루(8시간) 약 $1.4 에 처리 요금이 더 붙는다.
# 노드를 퍼블릭에 두고 IGW 로 내보내면 그 값이 0 이다(공인 IPv4 가 노드당 시간당 $0.005).
# 대신 노드에 공인 IP 가 붙으므로 보안 그룹으로 좁힌다. prd 는 프라이빗 서브넷 + AZ 마다 NAT 로 간다.

resource "aws_subnet" "public" {
  for_each = { for i, az in local.azs : az => i }
  # 집 대역과 안 겹치게 잡는다. 집은 192.168.0.0/24(LAN)과 10.0.0.0/24(vmbr1)를 쓴다.
  # 겹치면 나중에 두 곳을 잇게 될 때 라우팅이 성립하지 않는다. 지금은 안 잇지만 대역은 미리 피한다.

  vpc_id            = aws_vpc.this.id
  availability_zone = each.key
  # /16 을 /20 씩 자른다. 한 칸이 4,091 주소다.
  # VPC CNI 는 파드마다 VPC 주소를 하나씩 쓴다 — m5.xlarge 가 최대 58파드라 노드 다섯이면 약 290 개다.
  cidr_block = cidrsubnet(var.vpc_cidr, 4, each.value)

  # 노드가 IGW 로 직접 나가려면 공인 IP 가 있어야 한다.
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.prefix}-public-${each.key}"

    # ALB Controller 가 "인터넷용 로드밸런서를 어느 서브넷에 놓을지" 를 이 태그로 찾는다.
    # 없으면 서브넷을 못 골라 Ingress 를 만들다 멈춘다.
    "kubernetes.io/role/elb" = "1"

    # 이 서브넷이 어느 클러스터의 것인지. shared 는 다른 것과 같이 써도 된다는 뜻이다.
    "kubernetes.io/cluster/${var.prefix}" = "shared"
  }
}

# ---------- 나가는 길 ----------

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = var.prefix }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "${var.prefix}-public" }
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# ---------- 들어오는 규칙 ----------
# 온프레미스는 가만히 두면 닫혀 있다. 포트포워딩을 안 하면 아무도 못 들어온다.
# 클라우드는 반대라 가만히 두면 열 수 있다. 여기서 적극적으로 좁힌다.

# ALB 가 둘이다 — 서비스(frontend)와 Grafana. 여는 범위가 달라 보안 그룹을 가른다.
#   서비스   인터넷 전체에 80. 누구나 대기열 · 예매를 쓴다
#   Grafana  집 공인 IP 에만 80. 관측 화면은 운영자만 본다
# 한 보안 그룹을 같이 쓰면 서비스를 여는 순간 Grafana 도 같이 열린다.
# cgv-infra 의 두 Ingress 가 이 이름(Name 태그)으로 가리킨다 — ALB Controller 의 security-groups
#   애노테이션은 ID 와 Name 태그를 둘 다 받는다. 이름이 정해져 있어 켜는 날 옮길 값이 없다.
# 서비스 ALB 는 80 과 443 을 연다 — 80 은 443 으로 보내는 리다이렉트만 받는다.
#   리스너를 여는 것(cgv-infra 의 Ingress 애노테이션)과 문을 여는 것(이 규칙)은 따로다.
#   리스너만 만들면 ALB 는 443 을 듣고 있는데 보안 그룹이 막아 연결이 시간 초과로 끝난다.
# Grafana ALB 는 80 뿐이다 — 집 공인 IP 에서만 열리고 인증서를 쓰지 않는다.

resource "aws_security_group" "alb_public" {
  name        = "${var.prefix}-alb-public"
  description = "service ALB inbound from the internet"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${var.prefix}-alb-public" }
}

# 부하 발생기도 이 규칙으로 들어온다. VPC 안에서 인터넷용 ALB 를 부르면 주소가 공인 IP 로 풀려
#   트래픽이 IGW 로 나갔다 들어오고, ALB 가 보는 출발지가 부하 발생기의 공인 IP 가 된다.
resource "aws_vpc_security_group_ingress_rule" "alb_public_http" {
  security_group_id = aws_security_group.alb_public.id
  description       = "internet - redirect to 443"

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "tcp"
  from_port   = 80
  to_port     = 80
}

# 서비스가 실제로 지나는 문. 80 을 닫지 않는 이유는 주소를 http 로 친 사람을 https 로 보내기
#   위해서다 — 닫으면 그 사람은 리다이렉트를 못 받고 연결 실패만 본다.
resource "aws_vpc_security_group_ingress_rule" "alb_public_https" {
  security_group_id = aws_security_group.alb_public.id
  description       = "internet"

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "tcp"
  from_port   = 443
  to_port     = 443
}

resource "aws_security_group" "alb_admin" {
  name        = "${var.prefix}-alb-admin"
  description = "Grafana ALB inbound from home only"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${var.prefix}-alb-admin" }
}

resource "aws_vpc_security_group_ingress_rule" "alb_admin_from_home" {
  security_group_id = aws_security_group.alb_admin.id
  description       = "home public IP"

  cidr_ipv4   = var.home_cidr
  ip_protocol = "tcp"
  from_port   = 80
  to_port     = 80
}

# ALB 가 노드로 보내는 길. 대상 포트가 무엇이 될지는 서비스마다 달라 전부 연다 —
# 나가는 쪽이라 이 규칙이 여는 것은 ALB 가 보낼 수 있는 범위이지 밖에서 들어오는 문이 아니다.
resource "aws_vpc_security_group_egress_rule" "alb_all" {
  for_each = {
    public = aws_security_group.alb_public.id
    admin  = aws_security_group.alb_admin.id
  }

  security_group_id = each.value
  description       = "to nodes"

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "-1"
}
