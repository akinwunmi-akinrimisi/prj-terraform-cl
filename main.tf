# Define provider (AWS)
provider "aws" {
  region = var.aws_region
}

data "aws_ssm_parameter" "instance_ami" {
  name = "/aws/service/ami-amazon-linux-latest/amzn2-ami-hvm-x86_64-gp2"
}

# Create VPC
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name = "MainVPC"
  }
}

# Create an internet gateway for public subnet routing
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
}


#availability zones
# data "aws_availability_zones" "available" {}

# Create public subnets
resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.main.id
  count                   = 2
  cidr_block              = var.public_subnet_cidr[count.index]
  availability_zone       = var.availability_zone_public[count.index]
  map_public_ip_on_launch = true
  tags = {
    Name = "PublicSubnet_${count.index}"
  }
}

# Create private subnets
resource "aws_subnet" "private_subnet" {
  vpc_id            = aws_vpc.main.id
  count             = 4
  cidr_block        = var.private_subnet_cidr[count.index]
  availability_zone = var.availability_zone_private[count.index]
  tags = {
    Name = "PrivateSubnet_${count.index}"
  }
}


# Create route tables for public subnets
resource "aws_route_table" "public_route_table" {
  vpc_id = aws_vpc.main.id
  tags = {
    Name = "PublicRouteTable"
  }
}

# Create route for public subnets
resource "aws_route" "public_route" {
  route_table_id         = aws_route_table.public_route_table.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

# Associate route table with public subnets
resource "aws_route_table_association" "public_subnet_association" {
  count          = 2
  subnet_id      = aws_subnet.public_subnet[count.index].id
  route_table_id = aws_route_table.public_route_table.id
}


# Create route tables for private subnets
resource "aws_route_table" "private_route_table" {
  vpc_id = aws_vpc.main.id
  tags = {
    Name = "PrivateRouteTable"
  }
}

# Create route for private subnets to route through the bastion host
resource "aws_route" "private_route" {
  route_table_id         = aws_route_table.private_route_table.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.nat_gateway.id
}

# Associate route table with private subnets
resource "aws_route_table_association" "private_subnet_association" {
  count          = 4
  subnet_id      = aws_subnet.private_subnet[count.index].id
  route_table_id = aws_route_table.private_route_table.id
}


# Create security groups
resource "aws_security_group" "bastion_security_group" {
  vpc_id = aws_vpc.main.id
  name   = "BastionSecurityGroup"

  ingress {
    from_port   = 22
    to_port     = 22
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


resource "aws_security_group" "internet_facing_alb_security_group" {
  vpc_id = aws_vpc.main.id
  name   = "InternetFacingALBSecurityGroup"

  # Allow incoming HTTP traffic
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow incoming HTTPS traffic
  ingress {
    from_port   = 443
    to_port     = 443
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

#check this ....
resource "aws_security_group" "internal_alb_security_group" {
  vpc_id = aws_vpc.main.id
  name   = "InternalALBSecurityGroup"

  # Allow incoming traffic from frontend ASG on port 8080 (adjust as needed)
  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.internet_facing_alb_security_group.id] #here
  }

  ingress {
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.internet_facing_alb_security_group.id] #here
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Create bastion host
resource "aws_instance" "bastion_host" {
  ami             = data.aws_ssm_parameter.instance_ami.value
  instance_type   = var.instance_type
  subnet_id       = aws_subnet.public_subnet[0].id
  security_groups = [aws_security_group.bastion_security_group.id]
  key_name        = var.keyname
  tags = {
    Name = "BastionHost"
  }
}

# Create NAT Gateway (for private subnets to access the internet)
# Create Elastic IP for NAT Gateway
resource "aws_eip" "nat_eip" {
  domain = "vpc"
}

# Create NAT Gateway
resource "aws_nat_gateway" "nat_gateway" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = aws_subnet.public_subnet[1].id
}
#  
# ..............................
# Create Application Load Balancers (ALBs)
# Internet-facing ALB

resource "aws_elb" "internet_facing_alb" {
  name = "InternetFacingALB"
  internal                   = false
  security_groups = [
    "${aws_security_group.internet_facing_alb_security_group.id}"
  ]
  subnets = [
    "${aws_subnet.public_subnet[0].id}",
    "${aws_subnet.public_subnet[1].id}"
  ]

  cross_zone_load_balancing = true
  

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 3
    interval            = 30
    target              = "HTTP:80/"
  }

  listener {
    lb_port           = 80
    lb_protocol       = "http"
    instance_port     = "80"
    instance_protocol = "http"
  }

}
# Internal ALB

resource "aws_elb" "internal_alb" {
  name = "InternalALB"
  internal                   = true
  security_groups = [
    "${aws_security_group.internal_alb_security_group.id}"
  ]
  subnets = [
    "${aws_subnet.private_subnet[0].id}",
    "${aws_subnet.private_subnet[1].id}"
  ]

  cross_zone_load_balancing = true
  

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 3
    interval            = 30
    target              = "HTTP:80/"
  }

  listener {
    lb_port           = 80
    lb_protocol       = "http"
    instance_port     = "80"
    instance_protocol = "http"
  }

}

# ////////////
# Create Auto Scaling groups and launch configurations for Frontend and Backend
# Frontend Auto Scaling Group

#Creating Auto Scaling Group
resource "aws_autoscaling_group" "frontend_asg" {
  name = "${aws_launch_configuration.frontend_launch_config.name}-asg"

  min_size         = 2
  desired_capacity = 3
  max_size         = 4

  health_check_type = "ELB"
  load_balancers = [
    "${aws_elb.internet_facing_alb.id}"
  ]

  launch_configuration = aws_launch_configuration.frontend_launch_config.name

  enabled_metrics = [
    "GroupMinSize",
    "GroupMaxSize",
    "GroupDesiredCapacity",
    "GroupInServiceInstances",
    "GroupTotalInstances"
  ]

  metrics_granularity = "1Minute"

  vpc_zone_identifier = [
    "${aws_subnet.public_subnet[0].id}",
    "${aws_subnet.public_subnet[1].id}"
  ]

  # Required to redeploy without an outage.
  lifecycle {
    create_before_destroy = true
  }

  tag {
    key                 = "Name"
    value               = "frontend-instance"
    propagate_at_launch = true
  }

}

# //////////////////

# # Frontend Launch Configuration
resource "aws_launch_configuration" "frontend_launch_config" {
  name                        = "frontend-launch-config"
  image_id                    = data.aws_ssm_parameter.instance_ami.value
  instance_type               = var.instance_type
  key_name                    = var.keyname
  user_data                   = file("userdata.sh")
  associate_public_ip_address = true
  security_groups             = [aws_security_group.internet_facing_alb_security_group.id]
  lifecycle {
    create_before_destroy = true
  }
}



# # Backend Auto Scaling Group
resource "aws_autoscaling_group" "backend_asg" {
  name = "${aws_launch_configuration.backend_launch_config.name}-backasg"

  min_size         = 2
  desired_capacity = 3
  max_size         = 4

  health_check_type = "ELB"
  load_balancers = [
    "${aws_elb.internal_alb.id}"
  ]

  launch_configuration = aws_launch_configuration.backend_launch_config.id

  enabled_metrics = [
    "GroupMinSize",
    "GroupMaxSize",
    "GroupDesiredCapacity",
    "GroupInServiceInstances",
    "GroupTotalInstances"
  ]

  metrics_granularity = "1Minute"

  vpc_zone_identifier = [
    "${aws_subnet.private_subnet[0].id}",
    "${aws_subnet.private_subnet[1].id}"
  ]

  # Required to redeploy without an outage.
  lifecycle {
    create_before_destroy = true
  }

  tag {
    key                 = "Name"
    value               = "backend-instance"
    propagate_at_launch = true
  }

}
# ///

# Backend Launch Configuration
resource "aws_launch_configuration" "backend_launch_config" {
  name                        = "backend-launch-config"
  image_id                    = data.aws_ssm_parameter.instance_ami.value
  instance_type               = var.instance_type
  key_name                    = var.keyname
  user_data                   = file("userdata.sh")
  associate_public_ip_address = false
  security_groups             = [aws_security_group.internal_alb_security_group.id]
  lifecycle {
    create_before_destroy = true
  }
}

# Allow traffic from backend ASG to the database
resource "aws_security_group" "db_security_group" {
  name        = "DBSecurityGroup"
  description = "Security group for RDS database"
  vpc_id      = aws_vpc.main.id # Replace with your VPC ID

  ingress {
    from_port       = 3306 # Assuming MySQL, adjust the port as needed
    to_port         = 3306
    protocol        = "tcp"
    cidr_blocks     = ["0.0.0.0/0"]
    security_groups = [aws_security_group.internal_alb_security_group.id] # Adjust the source IP range as needed
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}


# Create Database resources (RDS)
resource "aws_db_instance" "db_1" {
  identifier           = "mydb-1"
  allocated_storage    = 20
  storage_type         = "gp2"
  engine               = "mysql"
  engine_version       = "5.7"
  instance_class       = "db.t2.micro"
  username             = var.db_username
  password             = var.db_password
  parameter_group_name = "default.mysql5.7"
  publicly_accessible  = false
  db_subnet_group_name = aws_db_subnet_group.database_subnet_group.name
  skip_final_snapshot  = true
}

resource "aws_db_instance" "db_2" {
  identifier           = "mydb-2"
  allocated_storage    = 20
  storage_type         = "gp2"
  engine               = "mysql"
  engine_version       = "5.7"
  instance_class       = "db.t2.micro"
  username             = var.db_username
  password             = var.db_password
  parameter_group_name = "default.mysql5.7"
  publicly_accessible  = false
  db_subnet_group_name = aws_db_subnet_group.database_subnet_group.name
  skip_final_snapshot  = true
}

# Create a Database Subnet Group for RDS
resource "aws_db_subnet_group" "database_subnet_group" {
  name        = "database_subnet_group"
  description = "Subnet group for RDS database"
  subnet_ids  = [aws_subnet.private_subnet[2].id, aws_subnet.private_subnet[3].id]
}


