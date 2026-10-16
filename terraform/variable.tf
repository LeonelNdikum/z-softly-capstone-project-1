variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "eu-west-2"
}

variable "project_name" {
  description = "Project name"
  type        = string
  default     = "zsoftly-capstone"
}

variable "vpc_cidr" {
  description = "VPC CIDR"
  type        = string
  default     = "10.0.0.0/16"
}

variable "image_tag" {
  description = "Container image tag deployed by the ECS task definition"
  type        = string
  default     = "v1"
}

variable "ecr_repository_name" {
  description = "ECR repository that stores the application image"
  type        = string
  default     = "zsoftly-capstone-web"
}
