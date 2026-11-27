provider "aws" {
  region = "ap-south-1"
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

resource "aws_instance" "K8s_master" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "c7i-flex.large"
  key_name               = "DEVOPS"
  vpc_security_group_ids = ["sg-079e9d05fd359830c"]

  root_block_device {
    volume_size = 30
  }

  tags = {
    Name = "K8s-master_node"
  }
}

output "master_public_ip" {
  value = aws_instance.K8s_master.public_ip
}

output "master_private_ip" {
  value = aws_instance.K8s_master.private_ip
}
