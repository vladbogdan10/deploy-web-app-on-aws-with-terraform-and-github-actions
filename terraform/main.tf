module "vpc" {
  source  = "cloudposse/vpc/aws"
  version = "2.0.0"

  namespace = var.namespace
  stage     = var.stage
  name      = var.name

  ipv4_primary_cidr_block = "10.0.0.0/16"
}

module "subnets" {
  source  = "cloudposse/dynamic-subnets/aws"
  version = "2.0.4"

  namespace = var.namespace
  stage     = var.stage
  name      = var.name

  availability_zones  = ["eu-west-1a", "eu-west-1b", "eu-west-1c"] # change to your AZs
  vpc_id              = module.vpc.vpc_id
  igw_id              = [module.vpc.igw_id]
  ipv4_cidr_block     = [module.vpc.vpc_cidr_block]
  nat_gateway_enabled = true
  max_nats            = 1
}

module "alb" {
  source  = "cloudposse/alb/aws"
  version = "1.7.0"

  namespace = var.namespace
  stage     = var.stage
  name      = var.name

  access_logs_enabled   = false
  vpc_id                = module.vpc.vpc_id
  ip_address_type       = "ipv4"
  subnet_ids            = module.subnets.public_subnet_ids
  security_group_ids    = [module.vpc.vpc_default_security_group_id]
  # https_enabled         = true
  # certificate_arn       = aws_acm_certificate.cert.arn
  # http_redirect         = true
  health_check_interval = 60
}

resource "aws_ecs_cluster" "ecs_cluster" {
  name = "${var.namespace}-${var.stage}-${var.name}"
  tags = {
    Namespace = var.namespace
    Stage     = var.stage
    Name      = var.name
  }
}

module "ecr" {
  source  = "cloudposse/ecr/aws"
  version = "0.35.0"

  namespace = var.namespace
  stage     = var.stage
  name      = var.name

  max_image_count         = 100
  protected_tags          = ["latest"]
  image_tag_mutability    = "MUTABLE"
  enable_lifecycle_policy = true

  # Whether to delete the repository even if it contains images
  force_delete = true
}

module "cloudwatch_logs" {
  source  = "cloudposse/cloudwatch-logs/aws"
  version = "0.6.6"

  namespace = var.namespace
  stage     = var.stage
  name      = var.name

  retention_in_days = 7
}

module "container_definition" {
  source  = "cloudposse/ecs-container-definition/aws"
  version = "0.58.1"

  container_name   = "${var.namespace}-${var.stage}-${var.name}"
  container_image  = "${module.ecr.repository_url}:${var.image_tag}"
  container_memory = 512 # optional for FARGATE launch type
  container_cpu    = 256 # optional for FARGATE launch type
  essential        = true
  port_mappings    = var.container_port_mappings

  # The environment variables to pass to the container.
  environment = [
    {
      name  = "ENV_NAME"
      value = "ENV_VALUE"
    },
  ]

  # Pull secrets from AWS Parameter Store.
  # "name" is the name of the env var.
  # "valueFrom" is the name of the secret in PS.
  secrets = [
    # {
    #   name      = "SECRET_ENV_NAME"
    #   valueFrom = "SECRET_ENV_NAME"
    # },
  ]

  log_configuration = {
    logDriver = "awslogs"
    options = {
      "awslogs-region"        = var.region
      "awslogs-group"         = module.cloudwatch_logs.log_group_name
      "awslogs-stream-prefix" = var.name
    }
    secretOptions = null
  }
}

module "ecs_alb_service_task" {
  source  = "cloudposse/ecs-alb-service-task/aws"
  version = "0.66.4"

  namespace = var.namespace
  stage     = var.stage
  name      = var.name

  use_alb_security_group         = true
  alb_security_group             = module.alb.security_group_id
  container_definition_json      = module.container_definition.json_map_encoded_list
  ecs_cluster_arn                = aws_ecs_cluster.ecs_cluster.arn
  launch_type                    = "FARGATE"
  vpc_id                         = module.vpc.vpc_id
  security_group_ids             = [module.vpc.vpc_default_security_group_id]
  subnet_ids                     = module.subnets.private_subnet_ids # change to "module.subnets.public_subnet_ids" if "nat_gateway_enabled" is false
  ignore_changes_task_definition = false
  network_mode                   = "awsvpc"
  assign_public_ip               = false # change to true if "nat_gateway_enabled" is false
  propagate_tags                 = "TASK_DEFINITION"
  desired_count                  = var.desired_count
  task_memory                    = 512
  task_cpu                       = 256
  force_new_deployment           = true
  container_port                 = var.container_port_mappings[0].containerPort

  ecs_load_balancers = [{
    container_name   = "${var.namespace}-${var.stage}-${var.name}"
    container_port   = var.container_port_mappings[0].containerPort
    elb_name         = ""
    target_group_arn = module.alb.default_target_group_arn
  }]
}

resource "aws_iam_openid_connect_provider" "github_actions_oidc" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = [
    "sts.amazonaws.com",
  ]

  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1"
  ]

  tags = {
    Namespace = var.namespace
    Stage     = var.stage
    Name      = var.name
  }
}

resource "aws_iam_role" "github_actions_role" {
  name = "github_actions"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Federated = aws_iam_openid_connect_provider.github_actions_oidc.arn
        },
        Action = "sts:AssumeRoleWithWebIdentity",
        Condition = {
          StringLike = {
            "token.actions.githubusercontent.com:sub" : "repo:vladbogdan10/deploy-web-app-on-aws-with-terraform-and-github-actions:*"
          },
          StringEquals = {
            "token.actions.githubusercontent.com:aud" : "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  managed_policy_arns = ["arn:aws:iam::aws:policy/AdministratorAccess"]

  tags = {
    Namespace = var.namespace
    Stage     = var.stage
    Name      = var.name
  }
}
