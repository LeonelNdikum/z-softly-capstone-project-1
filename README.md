# ZSoftly AWS ECS Fargate Capstone

## Overview

A production-oriented AWS cloud project that deploys a **stateless containerized web application** using **Amazon ECS with AWS Fargate**.

The project demonstrates containerization, cloud networking, infrastructure as code, high availability, security, load balancing, DNS, and monitoring using AWS-native services.

All AWS infrastructure is provisioned using **Terraform with raw AWS resources**. No public Terraform modules are used.

---

## Architecture

                    Internet
                       │
                       ▼
                 Route 53 DNS
                       │
                       ▼
          Application Load Balancer
                Public Subnets
                 ┌─────┴─────┐
                 ▼           ▼
          ECS Fargate    ECS Fargate
             Task           Task
          Private AZ     Private AZ
                 └─────┬─────┘
                       │
                       ▼
                    Amazon ECR
                 Docker Image
```

### AWS Services

* Amazon VPC
* Amazon ECS
* AWS Fargate
* Amazon ECR
* Application Load Balancer
* Amazon Route 53
* AWS IAM
* Amazon CloudWatch
* AWS Certificate Manager
* Terraform

---

## Application

The application is a lightweight static web application served by **Nginx**.

It contains two pages:

* `/page1`
* `/page2`

The application is packaged as a Docker image and stored in Amazon ECR before being deployed to ECS Fargate.

---

## Project Structure

```text
zsoftly-capstone-project-1/
│
├── application/
│   ├── Dockerfile
│   ├── nginx.conf
│   ├── page1.html
│   └── page2.html
│
├── terraform/
│   └── AWS infrastructure
│
├── screenshots/
│   └── deployment evidence
│
├── .gitignore
└── README.md
```

---

## Key Objectives

### Containerization

* Build the web application with Docker.
* Use Nginx as the web server.
* Test the container locally.

### AWS Deployment

* Store the image in Amazon ECR.
* Deploy the application using ECS Fargate.
* Run multiple tasks across Availability Zones.
* Use an Application Load Balancer for public access.

### Networking & DNS

* Deploy ECS tasks in private subnets.
* Expose only the Application Load Balancer publicly.
* Use Route 53 for the application DNS name.
* Configure `/page1` and `/page2` routing.

### Infrastructure as Code

Terraform provisions the AWS infrastructure using raw resources.

Docker image building and ECR image pushing are intentionally performed outside Terraform, as required by the assignment.

---

## Security & Resilience

The architecture is designed around:

* Private ECS workloads
* Security groups with restricted traffic
* IAM least-privilege principles
* HTTPS using AWS Certificate Manager
* Application Load Balancer health checks
* Multiple ECS tasks
* Multiple Availability Zones
* Automatic ECS task replacement
* CloudWatch logging
* No credentials or private keys committed to GitHub

---

## Terraform Workflow

```bash
terraform init
terraform fmt
terraform validate
terraform plan
terraform apply
```

Infrastructure can be destroyed when no longer required:

```bash
terraform destroy
```

---

## Local Docker Testing

Build the application:

```bash
cd application
docker build -t zsoftly-nginx:latest .
```

Run it:

```bash
docker run -d \
  --name zsoftly-nginx \
  -p 8080:80 \
  zsoftly-nginx:latest
```

Test:

```bash
curl -I http://localhost:8080/page1.html
curl -I http://localhost:8080/page2.html
```

Expected result:

```text
HTTP/1.1 200 OK
```

---

## Testing & Evidence

The deployment will be validated through:

* Terraform validation and plan
* ECR image verification
* ECS service and task status
* ALB target health
* Route 53 DNS resolution
* `/page1` and `/page2` application testing
* CloudWatch logs
* AWS console screenshots

Deployment evidence will be stored in the `screenshots/` directory.

---

## Project Outcome

The final solution will provide a **secure, highly available and fault-tolerant containerized web application on AWS**, deployed through reproducible Terraform infrastructure and accessible through a Route 53 DNS name.

The project is designed to demonstrate practical cloud engineering skills across **AWS, Docker, ECS/Fargate, Terraform, networking, security and DevOps practices**.
