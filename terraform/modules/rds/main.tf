variable "name_prefix" { type = string }
variable "vpc_id" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "db_instance_class" { type = string }
variable "db_name" { type = string }
variable "db_username" { type = string }
variable "allowed_security_group_id" { type = string }
variable "tags" { type = map(string) }

# Master password is generated and stored in Secrets Manager - it is never
# written into a .tf file or tfvars, and never appears in `terraform plan`
# output in plaintext (random_password marks it sensitive).
resource "random_password" "db" {
  length  = 20
  special = false
}

resource "aws_secretsmanager_secret" "db" {
  name = "${var.name_prefix}/db-credentials"
  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db.result
  })
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.name_prefix}-db-subnet-group"
  subnet_ids = var.private_subnet_ids
  tags       = var.tags
}

# Only allows traffic from the EKS cluster/node security group - the
# database has no route from the public internet at the network layer,
# on top of not having a public IP at all.
resource "aws_security_group" "db" {
  name        = "${var.name_prefix}-db-sg"
  description = "Allow Postgres access only from EKS nodes"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [var.allowed_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = var.tags
}

resource "aws_db_instance" "this" {
  identifier        = "${var.name_prefix}-db"
  engine            = "postgres"
  engine_version    = "16.3"
  instance_class    = var.db_instance_class
  allocated_storage = 20
  storage_encrypted = true

  db_name  = var.db_name
  username = var.db_username
  password = random_password.db.result

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]

  publicly_accessible = false   # <-- key requirement: no public exposure
  multi_az            = false   # set true for production
  skip_final_snapshot = true    # set false for production
  deletion_protection = false   # set true for production

  tags = var.tags
}

output "db_endpoint" { value = aws_db_instance.this.address }
output "db_secret_arn" { value = aws_secretsmanager_secret.db.arn }
