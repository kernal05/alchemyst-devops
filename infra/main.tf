terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

resource "aws_vpc" "iii_vpc" {
  cidr_block           = "10.10.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = { Name = "iii-vpc" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.iii_vpc.id
  cidr_block              = "10.10.1.0/24"
  availability_zone       = "${var.region}a"
  map_public_ip_on_launch = true
  tags = { Name = "iii-public-subnet" }
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.iii_vpc.id
  cidr_block        = "10.10.2.0/24"
  availability_zone = "${var.region}a"
  tags = { Name = "iii-private-subnet" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.iii_vpc.id
  tags = { Name = "iii-igw" }
}

resource "aws_eip" "nat" {
  domain = "vpc"
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id
  tags = { Name = "iii-nat" }
  depends_on = [aws_internet_gateway.igw]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.iii_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "iii-public-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.iii_vpc.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
  tags = { Name = "iii-private-rt" }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

resource "aws_security_group" "gateway" {
  name        = "iii-gateway-sg"
  vpc_id      = aws_vpc.iii_vpc.id
  description = "Gateway: HTTP API + SSH"
  ingress {
    from_port   = 3111
    to_port     = 3111
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 49134
    to_port     = 49134
    protocol    = "tcp"
    cidr_blocks = ["10.10.0.0/16"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "iii-gateway-sg" }
}

resource "aws_security_group" "inference" {
  name        = "iii-inference-sg"
  vpc_id      = aws_vpc.iii_vpc.id
  description = "Inference: private only"
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.10.0.0/16"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "iii-inference-sg" }
}

resource "aws_key_pair" "iii_key" {
  key_name   = "iii-key"
  public_key = var.ssh_public_key
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "gateway" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.gateway_instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.gateway.id]
  key_name               = aws_key_pair.iii_key.key_name
  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }
  tags = { Name = "iii-gateway" }
}

resource "aws_instance" "inference" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.inference_instance_type
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.inference.id]
  key_name               = aws_key_pair.iii_key.key_name
  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }
  tags = { Name = "iii-inference" }
}

output "gateway_public_ip" {
  value = aws_instance.gateway.public_ip
}

output "inference_private_ip" {
  value = aws_instance.inference.private_ip
}
