# 부하 발생기 — VPC 안에서 ALB 를 때린다.
#
# 밖에서 때리지 않는 이유가 둘이다.
#   집 회선이 먼저 막힌다.  3만 명 판이 초당 약 6,000 요청이다
#   ALB 앞의 인터넷 구간이 변수가 된다.  무엇이 먼저 막히는지 지목하는 것이 판정 조건이다
# 안에서 때리면 ALB 부터가 측정 구간이 된다.
#
# ★ count 로 켜고 끈다. c5.4xlarge 가 시간당 $0.768 이라 클러스터를 세워 두는 내내 켜 두면
#   비용이 배로 는다. 배포를 확인하는 동안은 꺼 두고, 판을 돌릴 때만 켠다.

locals {
  loadgen_count = var.loadgen_enabled ? 1 : 0
}

data "aws_ssm_parameter" "al2023" {
  # 최신 Amazon Linux 2023 AMI. AMI ID 를 코드에 적으면 리전마다 다르고 시간이 지나면 사라진다.
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# SSM 으로 붙는다. SSH 키를 만들고 22 를 여는 것보다 열 것이 적다.
resource "aws_iam_role" "loadgen" {
  name = "${var.prefix}-loadgen"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "loadgen_ssm" {
  role       = aws_iam_role.loadgen.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "loadgen" {
  name = "${var.prefix}-loadgen"
  role = aws_iam_role.loadgen.name
}

resource "aws_security_group" "loadgen" {
  name        = "${var.prefix}-loadgen"
  description = "load generator. outbound only"
  vpc_id      = module.network.vpc_id

  tags = { Name = "${var.prefix}-loadgen" }
}

# 들어오는 규칙이 없다. SSM 은 인스턴스가 밖으로 나가서 붙는 방식이라 문을 열 필요가 없다.
resource "aws_vpc_security_group_egress_rule" "loadgen_all" {
  security_group_id = aws_security_group.loadgen.id
  description       = "to ALB and SSM"

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "-1"
}

resource "aws_instance" "loadgen" {
  count = local.loadgen_count

  ami           = data.aws_ssm_parameter.al2023.value
  instance_type = var.loadgen_instance_type
  subnet_id     = module.network.subnet_ids[0]

  vpc_security_group_ids = [aws_security_group.loadgen.id]
  iam_instance_profile   = aws_iam_instance_profile.loadgen.name

  key_name = var.loadgen_key_name != "" ? var.loadgen_key_name : null

  # 부하 도구는 판마다 다르게 쓸 수 있어 여기서 설치하지 않는다.
  # 켜는 날 SSM 으로 붙어 필요한 것만 올린다.

  root_block_device {
    volume_type = "gp3"
    volume_size = 30
  }

  tags = { Name = "${var.prefix}-loadgen" }
}

# ★ 이 규칙이 없으면 부하가 ALB 에 닿지 않는다.
#
# ALB 는 인터넷용(internet-facing)이라 VPC 안에서 그 DNS 이름을 불러도 주소가 공인 IP 로 풀린다.
# 그러면 트래픽이 IGW 로 나갔다 다시 들어오고, ALB 가 보는 출발지는 VPC 사설 주소가 아니라
# 이 인스턴스의 공인 IP 다. 같은 이유로 보안 그룹끼리 참조하는 방식도 안 통한다.
#
# network 모듈의 ALB 보안 그룹에 VPC 대역을 열어 뒀지만 그것으로는 안 맞는다.
# 인스턴스가 받은 공인 IP 를 그때그때 규칙으로 더한다.
resource "aws_vpc_security_group_ingress_rule" "alb_from_loadgen" {
  count = local.loadgen_count

  security_group_id = module.network.alb_security_group_id
  description       = "load generator public IP"

  cidr_ipv4   = "${aws_instance.loadgen[0].public_ip}/32"
  ip_protocol = "tcp"
  from_port   = 80
  to_port     = 80
}
