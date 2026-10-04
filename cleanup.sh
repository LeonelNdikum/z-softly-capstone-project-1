#!/usr/bin/env bash
# =============================================================================
# cleanup.sh - Full cleanup for the ZSoftly Capstone Project 1
#
# Removes everything the project created, including the things that make a
# plain `terraform destroy` fail or leave resources behind:
#   - ECR images (a non-empty ECR repository cannot be destroyed)
#   - Leftover ECS, ALB, NAT, ENI, security group, subnet, route table,
#     internet gateway and VPC resources (found by name/tag)
#   - Elastic IP addresses
#   - IAM role, CloudWatch log group, ECS task definitions
#   - The S3 Terraform state bucket (all objects, versions, delete markers)
#
# Usage (run from the repository root):
#    chmod +x cleanup.sh
#   ./cleanup.sh --dry-run                  show what would be deleted
#   ./cleanup.sh                            interactive cleanup
#   ./cleanup.sh --yes                      no confirmation prompt
#
# Options:
#   --dry-run                  only print actions, delete nothing
#   --yes                      skip the confirmation prompt
#   --skip-terraform           do not run `terraform destroy` first
#   --keep-state-bucket        do not delete the S3 state bucket
#   --all-unassociated-eips    ALSO release every unassociated Elastic IP in the
#                              region (even ones not created by this project)
#
# WARNING: this is destructive and cannot be undone. The state bucket is
# deleted LAST, because Terraform needs it while destroying.
# =============================================================================

set -uo pipefail

# ----------------------------- Configuration ---------------------------------
PROJECT="${PROJECT:-zsoftly-capstone}"
REGION="${AWS_REGION:-eu-west-2}"
ECR_REPO="${ECR_REPO:-zsoftly-capstone-web}"
STATE_BUCKET="${STATE_BUCKET:-zsoftly-capstone-tfstate-32145}"
STATE_BUCKET_REGION="${STATE_BUCKET_REGION:-us-east-1}"
TF_DIR="${TF_DIR:-./terraform}"

DRY_RUN=false
ASSUME_YES=false
SKIP_TERRAFORM=false
KEEP_STATE_BUCKET=false
ALL_EIPS=false

for arg in "$@"; do
  case "$arg" in
    --dry-run)               DRY_RUN=true ;;
    --yes|-y)                ASSUME_YES=true ;;
    --skip-terraform)        SKIP_TERRAFORM=true ;;
    --keep-state-bucket)     KEEP_STATE_BUCKET=true ;;
    --all-unassociated-eips) ALL_EIPS=true ;;
    -h|--help)               sed -n '2,29p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

export AWS_DEFAULT_REGION="$REGION"

# ------------------------------- Helpers -------------------------------------
step() { echo; echo "==> $*"; }
info() { echo "    $*"; }
warn() { echo "    [warn] $*" >&2; }

run() {
  if $DRY_RUN; then
    echo "    [dry-run] $*"
    return 0
  fi
  "$@"
}

# Retry a command a few times (resources often need time to detach).
retry() {
  local attempts=$1; shift
  local n=1
  if $DRY_RUN; then echo "    [dry-run] $*"; return 0; fi
  until "$@" 2>/dev/null; do
    if (( n >= attempts )); then
      warn "gave up after $attempts attempts: $*"
      return 1
    fi
    n=$((n + 1))
    sleep 15
  done
}

# Print the value only when it is a real result (not empty / "None").
real() { [[ -n "${1:-}" && "$1" != "None" ]]; }

# ------------------------------ Preflight ------------------------------------
command -v aws >/dev/null 2>&1 || { echo "aws CLI not found"; exit 1; }

IDENTITY=$(aws sts get-caller-identity --query '[Account,Arn]' --output text 2>/dev/null) || {
  echo "AWS credentials not working. Run: aws sts get-caller-identity"
  exit 1
}
ACCOUNT_ID=$(echo "$IDENTITY" | awk '{print $1}')

echo "============================================================"
echo " ZSoftly Capstone cleanup"
echo "============================================================"
echo " AWS account : $ACCOUNT_ID"
echo " Region      : $REGION"
echo " Project     : $PROJECT"
echo " ECR repo    : $ECR_REPO"
echo " State bucket: $STATE_BUCKET ($STATE_BUCKET_REGION)"
$DRY_RUN && echo " Mode        : DRY RUN (nothing will be deleted)"
echo "============================================================"
echo " This will permanently delete the resources above."

if ! $ASSUME_YES && ! $DRY_RUN; then
  read -r -p " Type 'delete' to continue: " answer
  [[ "$answer" == "delete" ]] || { echo "Aborted."; exit 1; }
fi

# ---------------------- 1. Empty ECR so destroy can work ---------------------
step "1/10 Emptying ECR repository '$ECR_REPO'"
if aws ecr describe-repositories --repository-names "$ECR_REPO" >/dev/null 2>&1; then
  DIGESTS=$(aws ecr list-images --repository-name "$ECR_REPO" \
    --query 'imageIds[].imageDigest' --output text 2>/dev/null | tr '\t' '\n' | sort -u)
  if [[ -z "$DIGESTS" ]]; then
    info "no images found"
  else
    for d in $DIGESTS; do
      info "deleting image $d"
      run aws ecr batch-delete-image --repository-name "$ECR_REPO" \
        --image-ids imageDigest="$d" >/dev/null
    done
  fi
else
  info "repository not found, skipping"
fi

# ---------------------------- 2. Terraform destroy ---------------------------
step "2/10 Running terraform destroy"
if $SKIP_TERRAFORM; then
  info "skipped (--skip-terraform)"
elif $DRY_RUN; then
  info "[dry-run] terraform destroy -auto-approve (in $TF_DIR)"
elif command -v terraform >/dev/null 2>&1 && [[ -d "$TF_DIR" ]]; then
  ( cd "$TF_DIR" && terraform init -input=false >/dev/null 2>&1; \
    terraform destroy -auto-approve -input=false ) \
    || warn "terraform destroy reported errors; the sweep below will remove leftovers"
else
  warn "terraform or $TF_DIR not found, skipping"
fi

# ------------------------------ 3. ECS ---------------------------------------
step "3/10 ECS service, cluster and task definitions"
CLUSTER="${PROJECT}-cluster"
if real "$(aws ecs describe-clusters --clusters "$CLUSTER" \
      --query 'clusters[?status==`ACTIVE`].clusterArn' --output text 2>/dev/null)"; then
  SERVICES=$(aws ecs list-services --cluster "$CLUSTER" --query 'serviceArns[]' --output text 2>/dev/null)
  for svc in $SERVICES; do
    info "deleting service $svc"
    run aws ecs delete-service --cluster "$CLUSTER" --service "$svc" --force >/dev/null
  done
  if [[ -n "$SERVICES" ]] && ! $DRY_RUN; then
    # shellcheck disable=SC2086
    aws ecs wait services-inactive --cluster "$CLUSTER" --services $SERVICES 2>/dev/null || true
  fi
  info "deleting cluster $CLUSTER"
  retry 5 aws ecs delete-cluster --cluster "$CLUSTER" >/dev/null
else
  info "cluster not found"
fi

TASK_DEFS=$(aws ecs list-task-definitions --family-prefix "${PROJECT}-task" \
  --status ACTIVE --query 'taskDefinitionArns[]' --output text 2>/dev/null)
for td in $TASK_DEFS; do
  info "deregistering $td"
  run aws ecs deregister-task-definition --task-definition "$td" >/dev/null
done
# Fully delete inactive revisions where the API supports it (ignore failures)
INACTIVE=$(aws ecs list-task-definitions --family-prefix "${PROJECT}-task" \
  --status INACTIVE --query 'taskDefinitionArns[]' --output text 2>/dev/null)
if [[ -n "$INACTIVE" || -n "$TASK_DEFS" ]] && ! $DRY_RUN; then
  # shellcheck disable=SC2086
  aws ecs delete-task-definitions --task-definitions $TASK_DEFS $INACTIVE >/dev/null 2>&1 || true
fi

# ------------------------------ 4. ALB ---------------------------------------
step "4/10 Load balancer and target group"
ALB_ARN=$(aws elbv2 describe-load-balancers --names "${PROJECT}-alb" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || true)
if real "$ALB_ARN"; then
  for l in $(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" \
        --query 'Listeners[].ListenerArn' --output text 2>/dev/null); do
    info "deleting listener $l"
    run aws elbv2 delete-listener --listener-arn "$l"
  done
  info "deleting load balancer ${PROJECT}-alb"
  run aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN"
  $DRY_RUN || aws elbv2 wait load-balancers-deleted --load-balancer-arns "$ALB_ARN" 2>/dev/null || true
else
  info "load balancer not found"
fi

TG_ARN=$(aws elbv2 describe-target-groups --names "${PROJECT}-tg" \
  --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || true)
if real "$TG_ARN"; then
  info "deleting target group ${PROJECT}-tg"
  retry 5 aws elbv2 delete-target-group --target-group-arn "$TG_ARN"
else
  info "target group not found"
fi

# ------------------------------ 5. NAT + EIP ---------------------------------
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=${PROJECT}-vpc" \
  --query 'Vpcs[0].VpcId' --output text 2>/dev/null || true)

step "5/10 NAT gateway and Elastic IPs"
if real "$VPC_ID"; then
  NAT_IDS=$(aws ec2 describe-nat-gateways \
    --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available,pending" \
    --query 'NatGateways[].NatGatewayId' --output text 2>/dev/null)
  for nat in $NAT_IDS; do
    info "deleting NAT gateway $nat"
    run aws ec2 delete-nat-gateway --nat-gateway-id "$nat" >/dev/null
  done
  if [[ -n "$NAT_IDS" ]] && ! $DRY_RUN; then
    info "waiting for NAT gateway(s) to be deleted (can take a few minutes)"
    for _ in $(seq 1 40); do
      PENDING=$(aws ec2 describe-nat-gateways \
        --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available,pending,deleting" \
        --query 'NatGateways[].NatGatewayId' --output text 2>/dev/null)
      [[ -z "$PENDING" ]] && break
      sleep 10
    done
  fi
else
  info "VPC not found (already deleted?)"
fi

# Elastic IPs created by this project (tagged by Terraform)
EIPS=$(aws ec2 describe-addresses \
  --filters "Name=tag:Name,Values=${PROJECT}-nat-eip" \
  --query 'Addresses[].AllocationId' --output text 2>/dev/null)
for eip in $EIPS; do
  info "releasing Elastic IP $eip"
  retry 5 aws ec2 release-address --allocation-id "$eip"
done
[[ -z "$EIPS" ]] && info "no project-tagged Elastic IPs found"

if $ALL_EIPS; then
  step "5b/10 Releasing ALL unassociated Elastic IPs in $REGION"
  OTHER=$(aws ec2 describe-addresses \
    --query 'Addresses[?AssociationId==`null`].[AllocationId,PublicIp]' --output text 2>/dev/null)
  if [[ -z "$OTHER" ]]; then
    info "none found"
  else
    echo "$OTHER" | sed 's/^/    /'
    PROCEED=true
    if ! $ASSUME_YES && ! $DRY_RUN; then
      read -r -p "    Release the Elastic IPs listed above? (yes/no): " a
      [[ "$a" == "yes" ]] || PROCEED=false
    fi
    if $PROCEED; then
      echo "$OTHER" | awk '{print $1}' | while read -r id; do
        info "releasing $id"
        run aws ec2 release-address --allocation-id "$id"
      done
    else
      info "skipped"
    fi
  fi
fi

# ------------------------------ 6. VPC network -------------------------------
step "6/10 VPC networking (ENIs, security groups, subnets, routes, IGW, VPC)"
if real "$VPC_ID"; then
  # Leftover network interfaces (released slowly by ECS/ALB)
  for eni in $(aws ec2 describe-network-interfaces \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=status,Values=available" \
        --query 'NetworkInterfaces[].NetworkInterfaceId' --output text 2>/dev/null); do
    info "deleting network interface $eni"
    run aws ec2 delete-network-interface --network-interface-id "$eni"
  done

  # Security groups (two passes: the ECS group references the ALB group)
  for pass in 1 2 3; do
    for sg in $(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" \
          --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text 2>/dev/null); do
      info "deleting security group $sg (pass $pass)"
      run aws ec2 delete-security-group --group-id "$sg" 2>/dev/null || true
    done
    $DRY_RUN && break
    sleep 5
  done

  # Route table associations, then subnets
  for rt in $(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" \
        --query 'RouteTables[].RouteTableId' --output text 2>/dev/null); do
    for assoc in $(aws ec2 describe-route-tables --route-table-ids "$rt" \
          --query 'RouteTables[0].Associations[?Main==`false`].RouteTableAssociationId' \
          --output text 2>/dev/null); do
      info "disassociating $assoc"
      run aws ec2 disassociate-route-table --association-id "$assoc"
    done
  done

  for subnet in $(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" \
        --query 'Subnets[].SubnetId' --output text 2>/dev/null); do
    info "deleting subnet $subnet"
    retry 5 aws ec2 delete-subnet --subnet-id "$subnet"
  done

  # Non-main route tables
  for rt in $(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" \
        --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' --output text 2>/dev/null); do
    info "deleting route table $rt"
    run aws ec2 delete-route-table --route-table-id "$rt"
  done

  # Internet gateway
  for igw in $(aws ec2 describe-internet-gateways \
        --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
        --query 'InternetGateways[].InternetGatewayId' --output text 2>/dev/null); do
    info "detaching and deleting internet gateway $igw"
    run aws ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$VPC_ID"
    run aws ec2 delete-internet-gateway --internet-gateway-id "$igw"
  done

  info "deleting VPC $VPC_ID"
  retry 5 aws ec2 delete-vpc --vpc-id "$VPC_ID"
else
  info "VPC already gone"
fi

# ------------------------------ 7. IAM ---------------------------------------
step "7/10 IAM execution role"
ROLE="${PROJECT}-ecs-task-execution-role"
if aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  for pol in $(aws iam list-attached-role-policies --role-name "$ROLE" \
        --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
    info "detaching $pol"
    run aws iam detach-role-policy --role-name "$ROLE" --policy-arn "$pol"
  done
  for inline in $(aws iam list-role-policies --role-name "$ROLE" \
        --query 'PolicyNames[]' --output text 2>/dev/null); do
    run aws iam delete-role-policy --role-name "$ROLE" --policy-name "$inline"
  done
  info "deleting role $ROLE"
  run aws iam delete-role --role-name "$ROLE"
else
  info "role not found"
fi

# ------------------------------ 8. Logs --------------------------------------
step "8/10 CloudWatch log group"
LOG_GROUP="/ecs/${PROJECT}"
if real "$(aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" \
      --query "logGroups[?logGroupName=='$LOG_GROUP'].logGroupName" --output text 2>/dev/null)"; then
  info "deleting $LOG_GROUP"
  run aws logs delete-log-group --log-group-name "$LOG_GROUP"
else
  info "log group not found"
fi

# ------------------------------ 9. ECR ---------------------------------------
step "9/10 ECR repository"
if aws ecr describe-repositories --repository-names "$ECR_REPO" >/dev/null 2>&1; then
  info "deleting repository $ECR_REPO (with any remaining images)"
  run aws ecr delete-repository --repository-name "$ECR_REPO" --force >/dev/null
else
  info "repository already gone"
fi

# ------------------------------ 10. S3 state ---------------------------------
step "10/10 S3 Terraform state bucket"
if $KEEP_STATE_BUCKET; then
  info "skipped (--keep-state-bucket)"
elif aws s3api head-bucket --bucket "$STATE_BUCKET" --region "$STATE_BUCKET_REGION" 2>/dev/null; then
  info "deleting all object versions and delete markers in s3://$STATE_BUCKET"
  for kind in Versions DeleteMarkers; do
    while true; do
      ITEMS=$(aws s3api list-object-versions --bucket "$STATE_BUCKET" --region "$STATE_BUCKET_REGION" \
        --max-items 500 --query "${kind}[].[Key,VersionId]" --output text 2>/dev/null)
      if [[ -z "$ITEMS" || "$ITEMS" == "None" ]]; then break; fi
      if $DRY_RUN; then echo "$ITEMS" | sed 's/^/    [dry-run] delete /'; break; fi
      echo "$ITEMS" | while IFS=$'\t' read -r key vid; do
        aws s3api delete-object --bucket "$STATE_BUCKET" --region "$STATE_BUCKET_REGION" \
          --key "$key" --version-id "$vid" >/dev/null
      done
    done
  done
  info "deleting bucket $STATE_BUCKET"
  run aws s3api delete-bucket --bucket "$STATE_BUCKET" --region "$STATE_BUCKET_REGION"
else
  info "bucket not found or not accessible"
fi

# ------------------------------ Summary --------------------------------------
echo
echo "============================================================"
if $DRY_RUN; then
  echo " Dry run finished. Nothing was deleted."
else
  echo " Cleanup finished. Verify nothing is left (and nothing is billing):"
fi
echo "============================================================"
cat <<EOF
  aws ec2 describe-nat-gateways --region $REGION --filter Name=state,Values=available,pending
  aws ec2 describe-addresses --region $REGION
  aws elbv2 describe-load-balancers --region $REGION
  aws ecs list-clusters --region $REGION
  aws ecr describe-repositories --region $REGION
  aws s3 ls
EOF
