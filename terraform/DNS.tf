
# ============================================================
# DNS CONFIGURATION
# ============================================================
#
# DNS for leonels-projects.co.uk is managed by IONOS.
#
# The following DNS record is configured at IONOS:
#
#   www.leonels-projects.co.uk
#              |
#              | CNAME
#              v
#   AWS Application Load Balancer DNS name
#
# Route 53 is intentionally NOT used.
#
# Terraform manages the AWS infrastructure:
#   - VPC
#   - Subnets
#   - Internet Gateway
#   - NAT Gateway
#   - Security Groups
#   - Application Load Balancer
#   - Target Group
#   - ECS Cluster
#   - ECS Service
#   - ECS Task Definition
#   - CloudWatch Logs
#   - IAM
#   - ECR
#
# IONOS manages:
#   - leonels-projects.co.uk DNS
#   - www.leonels-projects.co.uk CNAME
#
# ============================================================

