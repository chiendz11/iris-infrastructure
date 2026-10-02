resource "aws_security_group" "rds" {
  name_prefix = "${local.name}-rds-"
  description = "PostgreSQL access from EKS worker nodes"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "PostgreSQL from EKS nodes"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_db_subnet_group" "mlflow" {
  name       = local.name
  subnet_ids = module.vpc.private_subnets
}

resource "aws_db_instance" "mlflow" {
  identifier                  = "${local.name}-mlflow"
  engine                      = "postgres"
  engine_version              = "16"
  instance_class              = var.db_instance_class
  allocated_storage           = 20
  max_allocated_storage       = var.db_max_allocated_storage
  storage_type                = "gp3"
  storage_encrypted           = true
  multi_az                    = var.db_multi_az
  db_name                     = var.db_name
  username                    = var.db_username
  manage_master_user_password = true
  port                        = 5432
  db_subnet_group_name        = aws_db_subnet_group.mlflow.name
  vpc_security_group_ids      = [aws_security_group.rds.id]
  publicly_accessible         = false

  backup_retention_period   = var.db_backup_retention_days
  deletion_protection       = var.environment == "prod"
  skip_final_snapshot       = var.environment != "prod"
  final_snapshot_identifier = var.environment == "prod" ? "${local.name}-final" : null

  auto_minor_version_upgrade = true
  apply_immediately          = var.environment != "prod"
}
