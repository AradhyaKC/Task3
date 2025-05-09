provider "aws" {
  region = "us-east-1"
}

terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

# Get default VPC and AZ
data "aws_vpc" "default" {
  default = true
}

data "aws_availability_zones" "available" {}

# Subnets
# resource "aws_subnet" "public" {
#   vpc_id                  = data.aws_vpc.default.id
#   cidr_block              = cidrsubnet(data.aws_vpc.default.cidr_block, 8, 0)
#   availability_zone       = data.aws_availability_zones.available.names[0]
#   map_public_ip_on_launch = true

#   tags = {
#     Name = "public-subnet"
#   }
# }

# resource "aws_subnet" "private" {
#   vpc_id            = data.aws_vpc.default.id
#   cidr_block        =cidrsubnet(data.aws_vpc.default.cidr_block, 8, 1)
#   availability_zone = data.aws_availability_zones.available.names[0]

#   tags = {
#     Name = "private-subnet"
#   }
# }

# Security Groups
resource "aws_security_group" "frontend_lb" {
  name        = "frontend-lb-sg"
  description = "Allow HTTP from internet"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "frontend_ec2" {
  name        = "frontend-ec2-sg"
  description = "Allow port 3000 from LB"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [aws_security_group.frontend_lb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "backend_ec2" {
  name        = "backend-ec2-sg"
  description = "Allow port 5000 from frontend EC2"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port       = 5000
    to_port         = 5000
    protocol        = "tcp"
    security_groups = [aws_security_group.frontend_ec2.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# User Data Scripts
data "template_file" "frontend_user_data" {
  template = <<-EOF
    #!/bin/bash
    sudo apt update -y
    sudo apt install -y nodejs npm git
    git clone https://github.com/AradhyaKC/Task3.git /home/ubuntu/app
    cd /home/ubuntu/app/frontend
    npm install
    npx serve -l 3000 .  # Adjust if using express
  EOF
}

data "template_file" "backend_user_data" {
  template = <<-EOF
    #!/bin/bash
    sudo apt update -y
    sudo apt install -y nodejs npm git
    git clone https://github.com/AradhyaKC/Task3.git /home/ubuntu/app
    cd /home/ubuntu/app/backend
    npm install
    node index.js
  EOF
}

# Launch Templates
resource "aws_launch_template" "frontend_lt" {
  name_prefix   = "frontend-lt-"
  image_id      = "ami-0c94855ba95c71c99"
  instance_type = "t2.micro"

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.frontend_ec2.id]
  }

  user_data = base64encode(data.template_file.frontend_user_data.rendered)

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "frontend"
    }
  }
}

resource "aws_launch_template" "backend_lt" {
  name_prefix   = "backend-lt-"
  image_id      = "ami-0c94855ba95c71c99"
  instance_type = "t2.micro"

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.backend_ec2.id]
  }

  user_data = base64encode(data.template_file.backend_user_data.rendered)

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "backend"
    }
  }
}

# Target Groups
resource "aws_lb_target_group" "frontend_tg" {
  name     = "frontend-tg"
  port     = 3000
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id
}

resource "aws_lb_target_group" "backend_tg" {
  name     = "backend-tg"
  port     = 5000
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id
}

# Load Balancers
resource "aws_lb" "frontend_lb" {
  name               = "frontend-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.frontend_lb.id]
#   subnets            = [aws_subnet.public.id]
  subnets            = ["subnet-02030688cd3d8c597","subnet-0e6c750072bbb664e"]
}

resource "aws_lb" "backend_lb" {
  name               = "backend-lb"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.backend_ec2.id]
#   subnets            = [aws_subnet.private.id]
  subnets            = ["subnet-07df562d8898db2fd", "subnet-023bb26cf11675427"]
}

# Listeners
resource "aws_lb_listener" "frontend_listener" {
  load_balancer_arn = aws_lb.frontend_lb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend_tg.arn
  }
}

resource "aws_lb_listener" "backend_listener" {
  load_balancer_arn = aws_lb.backend_lb.arn
  port              = 5000
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend_tg.arn
  }
}

# Auto Scaling Groups
resource "aws_autoscaling_group" "frontend_asg" {
  desired_capacity    = 1
  max_size            = 1
  min_size            = 1
  vpc_zone_identifier = ["subnet-02030688cd3d8c597"]
  target_group_arns   = [aws_lb_target_group.frontend_tg.arn]

  launch_template {
    id      = aws_launch_template.frontend_lt.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "frontend-instance"
    propagate_at_launch = true
  }
}

resource "aws_autoscaling_group" "backend_asg" {
  desired_capacity    = 1
  max_size            = 1
  min_size            = 1
  vpc_zone_identifier = ["subnet-07df562d8898db2fd"]
  target_group_arns   = [aws_lb_target_group.backend_tg.arn]

  launch_template {
    id      = aws_launch_template.backend_lt.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "backend-instance"
    propagate_at_launch = true
  }
}
