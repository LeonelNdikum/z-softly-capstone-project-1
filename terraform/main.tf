terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }

  backend "s3" {
    bucket       = "zsoftly-capstone-tfstate-258124"       # <-- your S3 bucket name (must already exist)
    key          = "capstone-project-1/terraform.tfstate" # <-- path/filename within the bucket
    region       = "us-east-1"                            # <-- region the bucket lives in
    encrypt      = true                                   # encrypts the state file at rest
    use_lockfile = true                                   # native S3 locking (Terraform 1.10+)
  }
}

provider "aws" {
  region = var.aws_region
}

resource "aws_ecr_repository" "app" {
  name                 = "zsoftly-capstone-web"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}
