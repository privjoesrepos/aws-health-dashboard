#!/bin/bash
set -e

AWS_REGION="us-east-1"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_URL="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"
IMAGE_NAME="sns-to-chat-alert"

IMAGE_TAG="v$(date +%Y%m%d-%H%M%S)"

echo "==> Logging into ECR..."
aws ecr get-login-password --region $AWS_REGION \
  | docker login --username AWS --password-stdin $ECR_URL

echo "==> Building image..."
docker build -t $IMAGE_NAME .

echo "==> Tagging image with unique tag: $IMAGE_TAG..."
docker tag $IMAGE_NAME:latest $ECR_URL/$IMAGE_NAME:$IMAGE_TAG

echo "==> Pushing to ECR..."
docker push $ECR_URL/$IMAGE_NAME:$IMAGE_TAG

echo "==> Generating Terraform plan with image tag: $IMAGE_TAG..."
terraform init -input=false
terraform plan -out=tfplan -var="image_tag=$IMAGE_TAG"

echo "==> Applying Terraform plan..."
terraform apply tfplan

echo "==> Done. Immutable image $IMAGE_TAG deployed to Lambda."
