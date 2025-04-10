resource "aws_vpc" "my-vpc" {
  cidr_block = var.vpc_cidr
  tags = {
    Name = var.vpc_name
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.my-vpc.id

  tags = {
    Name = var.igw_name
  }
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.my-vpc.id

  route {
    cidr_block = var.pub_rt_igw_access_cidr
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = var.rt_name
  }
}

resource "aws_subnet" "subnets" {
  for_each = { for idx, subnet in var.subnets : subnet.name => subnet }

  vpc_id                  = aws_vpc.my-vpc.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = each.value.type == "loadbalancer" || each.value.type == "jump" ? true : false

  tags = {
    Name = each.value.name
  }
}

resource "aws_route_table_association" "public_subnet_association" {
  for_each = { for subnet in var.subnets : subnet.name => subnet if subnet.type == "loadbalancer" || subnet.type == "jump" }
  subnet_id      = aws_subnet.subnets[each.key].id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.my-vpc.id

  tags = {
    Name = var.pri_rt
  }
}

resource "aws_route_table_association" "private_subnet_association" {
  for_each = { for subnet in var.subnets : subnet.name => subnet if subnet.type == "application" || subnet.type == "database" }

  subnet_id      = aws_subnet.subnets[each.key].id
  route_table_id = aws_route_table.private_rt.id
}

locals {
  # Get all public subnets
  public_subnets = [
    for subnet in aws_subnet.subnets :
    subnet if subnet.map_public_ip_on_launch
  ]

  # Ensure one subnet per AZ
  unique_az_public_subnets = [
    for az in distinct([for s in local.public_subnets : s.availability_zone]) :
    lookup({ for s in local.public_subnets : s.availability_zone => s }, az)
  ]
}

resource "aws_lb" "main" {
  name               = "my-load-balancer"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.lb_sg.id]

  # Use only one subnet per AZ
  subnets            = [for subnet in local.unique_az_public_subnets : subnet.id]

  tags = {
    Name = var.lb_name
  }
}
resource "aws_security_group" "lb_sg" {
  vpc_id = aws_vpc.my-vpc.id

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

  tags = {
    Name = var.sg_name
  }
}

# Security Groups
resource "aws_security_group" "rds_sg" {
  name        = "rds-sg"
  description = "Allow MySQL from EC2"
  vpc_id      = aws_vpc.my-vpc.id

  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    security_groups = [aws_security_group.ec2_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "rds-sg"
  }
}

resource "aws_security_group" "ec2_sg" {
  name        = "ec2-sg"
  description = "Allow HTTP & SSH from Jumpbox"
  vpc_id      = aws_vpc.my-vpc.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    security_groups = [aws_security_group.jump_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "ec2-sg"
  }
}

resource "aws_security_group" "jump_sg" {
  name        = "jump-sg"
  description = "Allow SSH from my IP"
  vpc_id      = aws_vpc.my-vpc.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["47.129.189.13/32"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "jumpbox-sg"
  }
}

# RDS MySQL Instance

resource "aws_db_subnet_group" "rds_subnet_group" {
  name = "rds-subnet-group"

  subnet_ids = [
    for key, subnet in aws_subnet.subnets :
    subnet.id
    if contains(split("-", subnet.tags["Name"]), "db")
  ]

  tags = {
    Name = "rds-subnet-group"
  }
}


resource "aws_db_instance" "wordpress_db" {
  identifier             = "wordpress-db"
  engine                 = "mysql"
  instance_class         = "db.t3.micro"
  allocated_storage      = 20
  username               = "admin"
  password               = "admin1234"
  db_name                = "wordpressdb"
  vpc_security_group_ids = [aws_security_group.rds_sg.id]
  db_subnet_group_name   = aws_db_subnet_group.rds_subnet_group.name
  skip_final_snapshot    = true
  publicly_accessible    = false
  multi_az               = false

  tags = {
    Name = "wordpress-rds"
  }
}

# Jump server EC2
resource "aws_instance" "jump_box" {
  ami                         = "ami-0e163898e0cc411f1" 
  instance_type               = "t2.micro"
  subnet_id                   = aws_subnet.subnets["lb-subnet-1"].id
  vpc_security_group_ids      = [aws_security_group.jump_sg.id]
  associate_public_ip_address = true
  key_name                    = "singapore-key"

  tags = {
    Name = "jumpbox"
  }
}

# EC2 for WordPress & AMI creation
resource "aws_instance" "wordpress" {
  ami                         = "ami-0e163898e0cc411f1"
  instance_type               = "t2.micro"
  subnet_id                   = aws_subnet.subnets["lb-subnet-1"].id
  vpc_security_group_ids      = [aws_security_group.ec2_sg.id]
  associate_public_ip_address = true
  key_name                    = "singapore-key"

  user_data = <<-EOF
            #!/bin/bash
            yum update -y

            # Remove old PHP versions if installed
            yum remove -y php*

            # Enable PHP 8.1
            amazon-linux-extras enable php8.1
            yum clean metadata

            # Install PHP 8.1 and required modules
            yum install -y php php-mysqlnd php-fpm php-gd php-xml php-mbstring php-json php-opcache httpd wget

            # Start and enable Apache
            systemctl start httpd
            systemctl enable httpd

            # Download and configure WordPress
            cd /var/www/html
            wget https://wordpress.org/latest.tar.gz
            tar -xzf latest.tar.gz
            cp -r wordpress/* .
            rm -rf wordpress latest.tar.gz
            cp wp-config-sample.php wp-config.php

            # Configure WordPress to connect to RDS
            sed -i 's/database_name_here/wordpressdb/' wp-config.php
            sed -i 's/username_here/admin/' wp-config.php
            sed -i 's/password_here/admin1234/' wp-config.php
            sed -i "s/localhost/${aws_db_instance.wordpress_db.address}/" wp-config.php

            # Restart Apache
            systemctl restart httpd
            EOF

  tags = {
    Name = "wordpress-ec2"
  }
}

resource "aws_ami_from_instance" "wordpress_image" {
  name               = "wordpress-ami"
  source_instance_id = aws_instance.wordpress.id
  depends_on         = [aws_instance.wordpress]
}
