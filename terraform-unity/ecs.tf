resource "aws_ecs_cluster" "demo_cluster" {
  name = "${var.deployment_name}-demo-cluster"
  tags = {
    Service = "U-CS"
  }
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
    environment = [
      {
        name = "VPC_ID",
        value = data.aws_ssm_parameter.vpc_id.value
      }
    ]
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
