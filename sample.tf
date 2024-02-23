variable "tags" {
  description = "AWS Tags"
  type = map(string)
}

variable "deployment_name" {
  description = "The deployment name"
  type        = string
}

data "aws_ssm_parameter" "vpc_id" {
  name = "/unity/account/network/vpc_id"
}

data "aws_ssm_parameter" "subnet_list" {
  name = "/unity/account/network/subnet_list"
}

locals {
  subnet_map = jsondecode(data.aws_ssm_parameter.subnet_list.value)
  subnet_ids = nonsensitive(local.subnet_map["private"])
  public_subnet_ids = nonsensitive(local.subnet_map["public"])
}

resource "aws_efs_file_system" "demo_config_efs" {
  creation_token = "${var.deployment_name}-demo-config"
  tags = {
    Service = "U-CS"
  }
}
resource "aws_security_group" "efs_sg" {
  name        = "${var.deployment_name}-efs-security-group"
  description = "Security group for EFS"
  vpc_id      = data.aws_ssm_parameter.vpc_id.value

  # Ingress rule to allow NFS
  ingress {
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    security_groups  = [aws_security_group.ecs_sg.id]
  }

  # Egress rule - allowing all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Service = "U-CS"
  }
}
resource "aws_efs_mount_target" "efs_mount_target" {
  for_each          = toset(local.subnet_ids)
  file_system_id     = aws_efs_file_system.demo_config_efs.id
  subnet_id         = each.value
  security_groups    = [aws_security_group.efs_sg.id]
}

resource "aws_efs_access_point" "demo_config_ap" {
  file_system_id = aws_efs_file_system.demo_config_efs.id

  posix_user {
    gid = 1000
    uid = 1000
  }

  root_directory {
    path = "/efs"
    creation_info {
      owner_gid   = 1000
      owner_uid   = 1000
      permissions = "0755"
    }
  }

  tags = {
    Name = "${var.deployment_name}-demo-config-ap"
    Service = "U-CS"
  }
}

#######################################
resource "aws_ecs_cluster" "demo_cluster" {
  name = "${var.deployment_name}-demo-cluster"
  tags = {
    Service = "U-CS"
  }
}

data "aws_iam_policy" "mcp_operator_policy" {
  name = "mcp-tenantOperator-AMI-APIG"
}

resource "aws_iam_role" "ecs_execution_role" {
  name = "${var.deployment_name}ecs_execution_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole",
        Effect = "Allow",
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      },
    ]
  })

  permissions_boundary = data.aws_iam_policy.mcp_operator_policy.arn
}

resource "aws_iam_role_policy_attachment" "ecs_execution_role_policy" {
  role       = aws_iam_role.ecs_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_ecs_task_definition" "demo" {
  family                   = "demo"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  execution_role_arn       = aws_iam_role.ecs_execution_role.arn
  memory                   = "512"
  cpu                      = "256"
  volume {
    name = "demo-config"

    efs_volume_configuration {
      file_system_id          = aws_efs_file_system.demo_config_efs.id
      root_directory          = "/"
      transit_encryption      = "ENABLED"
      transit_encryption_port = 2049
    }
  }

  container_definitions = jsonencode([{
    name  = "demo"
    image = "ghcr.io/unity-sds/unity-cs-infra:authtest"
    #environment = [
    #  {
    #    name = "ELB_DNS_NAME",
    #    value = var.demo_dns
    #  }
    #]
    portMappings = [
      {
        containerPort = 8888
        hostPort      = 8888
      }
    ]
    mountPoints = [
      {
        containerPath = "/etc/apache2/sites-enabled/"
        sourceVolume  = "demo-config"
      }
    ]
  }])
  tags = {
    Service = "U-CS"
  }
}

resource "aws_security_group" "ecs_sg" {
  name        = "${var.deployment_name}-ecs_service_sg"
  description = "Security group for ECS service"
  vpc_id      = data.aws_ssm_parameter.vpc_id.value

  // Inbound rules
  // Example: Allow HTTP and HTTPS
  ingress {
    from_port   = 8888
    to_port     = 8888
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  // Outbound rules
  // Example: Allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Service = "U-CS"
  }
}

# Update the ECS Service to use the Load Balancer
resource "aws_ecs_service" "demo_service" {
  name            = "demo-service"
  cluster         = aws_ecs_cluster.demo_cluster.id
  task_definition = aws_ecs_task_definition.demo.arn
  launch_type     = "FARGATE"
  desired_count   = 1

  load_balancer {
    target_group_arn = aws_lb_target_group.demo_tg.arn
    container_name   = "demo"
    container_port   = 8888
  }

  network_configuration {
    subnets         = local.subnet_ids
    security_groups = [aws_security_group.ecs_sg.id]
    #needed so it can pull images
    assign_public_ip = true
  }
  tags = {
    Service = "U-CS"
  }
  depends_on = [
    aws_lb_listener.demo_listener,
  ]
}


#####################################

# Create an Application Load Balancer (ALB)
resource "aws_lb" "demo_alb" {
  name               = "${var.deployment_name}-demo-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.ecs_sg.id]
  subnets            = local.public_subnet_ids
  enable_deletion_protection = false
  tags = {
    Service = "U-CS"
  }
}

# Create a Target Group for httpd
resource "aws_lb_target_group" "demo_tg" {
  name     = "${var.deployment_name}-demo-tg"
  port     = 8888
  protocol = "HTTP"
  vpc_id   = data.aws_ssm_parameter.vpc_id.value
  target_type = "ip"

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
  }
  tags = {
    Service = "U-CS"
  }
}

# Create a Listener for the ALB that forwards requests to the httpd Target Group
resource "aws_lb_listener" "demo_listener" {
  load_balancer_arn = aws_lb.demo_alb.arn
  port              = 8888
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.demo_tg.arn
  }
  tags = {
    Service = "U-CS"
  }
}


resource "aws_ssm_parameter" "demo_endpoint" {
  name = "/unity/cs/management/demo/loadbalancer-url"
  type = "String"
  value = "${aws_lb_listener.demo_listener.protocol}://${aws_lb.demo_alb.dns_name}:${aws_lb_listener.demo_listener.port}/management/ui"
  overwrite = true
}

#####################

variable "template" {
  default = <<EOT
<VirtualHost *:8080>
                  RewriteEngine on
                  ProxyPass /sample http://test-demo-alb-616613476.us-west-2.elb.amazonaws.com:8888/sample/hello.jsp
                  ProxyPassReverse /sample http://test-demo-alb-616613476.us-west-2.elb.amazonaws.com:8888/sample/hello.jsp
</VirtualHost>
EOT
}
resource "aws_lambda_invocation" "demoinvocation2" {
  function_name = "ZwUycV-unity-proxy-httpdproxymanagement"

  input = jsonencode({
    filename  = "example_filename1",
    template = var.template
  })

}

