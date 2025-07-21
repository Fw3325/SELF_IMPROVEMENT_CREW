#!/bin/bash

set -e  # Exit on any error

# Configuration
APP_NAME="course_rec_demo"
CLUSTER_NAME="${APP_NAME}-cluster"
SERVICE_NAME="${APP_NAME}-service"
TASK_FAMILY="${APP_NAME}-task"
CONTAINER_NAME="${APP_NAME}-container"
LOG_GROUP="/ecs/${APP_NAME}"

echo "Starting ECS deployment for ${APP_NAME}"

# Get AWS account information
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=$(aws configure get region || echo "us-east-1")

echo "Account ID: $ACCOUNT_ID"
echo "Region: $REGION"

Step 1: Create ECR repository
echo "Creating ECR repository..."
aws ecr create-repository --repository-name $APP_NAME --region $REGION 2>/dev/null || echo "Repository already exists"

# Step 2: Build and push Docker image
echo "Building Docker image..."
docker build -t $APP_NAME .

echo "Tagging image for ECR..."
docker tag $APP_NAME:latest ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/$APP_NAME:latest

echo "Logging into ECR..."
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com

echo "Pushing image to ECR..."
docker push ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/$APP_NAME:latest


# Step 3: Create IAM role
echo "Creating IAM role..."
cat > trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ecs-tasks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

aws iam create-role --role-name ecsTaskExecutionRole --assume-role-policy-document file://trust-policy.json 2>/dev/null || echo "Role already exists"
aws iam attach-role-policy --role-name ecsTaskExecutionRole --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy

# Step 4: Create CloudWatch log group
echo "Creating CloudWatch log group..."
aws logs create-log-group --log-group-name $LOG_GROUP 2>/dev/null || echo "Log group already exists"

# Step 5: Create ECS cluster
echo "Creating ECS cluster..."
aws ecs create-cluster --cluster-name $CLUSTER_NAME 2>/dev/null || echo "Cluster already exists"

# Step 6: Set up networking
echo "Setting up networking..."
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query 'Vpcs[0].VpcId' --output text)
SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[*].SubnetId' --output text)
SUBNET_1=$(echo $SUBNET_IDS | cut -d' ' -f1)
SUBNET_2=$(echo $SUBNET_IDS | cut -d' ' -f2)

if [ -z "$SUBNET_1" ] || [ -z "$SUBNET_2" ]; then
    echo "Error: SUBNET_1 and SUBNET_2 environment variables must be set"
    exit 1
fi

# # Convert SUBNET_1 to array and get first subnet
# SUBNET_1_ARRAY=($SUBNET_1)
# SUBNET_1_FORMATTED="${SUBNET_1_ARRAY[0]}"

# # Convert SUBNET_2 to array and get second subnet (or first if they're the same)
# SUBNET_2_ARRAY=($SUBNET_2)
# if [ "${SUBNET_1_ARRAY[0]}" == "${SUBNET_2_ARRAY[0]}" ] && [ ${#SUBNET_2_ARRAY[@]} -gt 1 ]; then
#     # If both variables contain the same list, pick first and second from the list
#     SUBNET_2_FORMATTED="${SUBNET_2_ARRAY[1]}"
# else
#     # Otherwise, take the first from SUBNET_2
#     SUBNET_2_FORMATTED="${SUBNET_2_ARRAY[0]}"
# fi

# # Export the formatted variables
# export SUBNET_1="$SUBNET_1_FORMATTED"
# export SUBNET_2="$SUBNET_2_FORMATTED"


# Create security group
SECURITY_GROUP_ID=$(aws ec2 create-security-group \
  --group-name ecs-${APP_NAME}-sg \
  --description "Security group for ${APP_NAME} ECS tasks" \
  --vpc-id $VPC_ID \
  --query 'GroupId' --output text 2>/dev/null || aws ec2 describe-security-groups --filters "Name=group-name,Values=ecs-${APP_NAME}-sg" --query 'SecurityGroups[0].GroupId' --output text)

# Allow HTTP traffic
aws ec2 authorize-security-group-ingress \
  --group-id $SECURITY_GROUP_ID \
  --protocol tcp \
  --port 80 \
  --cidr 0.0.0.0/0 2>/dev/null || echo "HTTP rule already exists"

# Step 7: Create task definition
echo "Creating task definition..."
cat > task-definition.json << EOF
{
  "family": "${TASK_FAMILY}",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512",
  "executionRoleArn": "arn:aws:iam::${ACCOUNT_ID}:role/ecsTaskExecutionRole",
  "containerDefinitions": [
    {
      "name": "${CONTAINER_NAME}",
      "image": "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${APP_NAME}:latest",
      "portMappings": [
        {
          "containerPort": 80,
          "protocol": "tcp"
        }
      ],
      "essential": true,
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "${LOG_GROUP}",
          "awslogs-region": "${REGION}",
          "awslogs-stream-prefix": "ecs"
        }
      }
    }
  ]
}
EOF

# Wait for role propagation
echo "Waiting for IAM role propagation..."
sleep 30

aws ecs register-task-definition --cli-input-json file://task-definition.json

# Step 8: Create ECS service
echo "Creating ECS service..."
test = "subnet-0af57fe444a742c32"
aws ecs create-service \
  --cluster $CLUSTER_NAME \
  --service-name $SERVICE_NAME \
  --task-definition $TASK_FAMILY:1 \
  --desired-count 2 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=$test,securityGroups=[$SECURITY_GROUP_ID],assignPublicIp=ENABLED}"
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_1,$SUBNET_2],securityGroups=[$SECURITY_GROUP_ID],assignPublicIp=ENABLED}"

# Step 9: Wait for deployment and get public IPs
echo "Waiting for tasks to start..."
sleep 60

TASK_ARNS=$(aws ecs list-tasks --cluster $CLUSTER_NAME --service-name $SERVICE_NAME --query 'taskArns' --output text)

echo "Deployment complete!"
echo "Getting public IP addresses"

for TASK_ARN in $TASK_ARNS; do
  ENI_ID=$(aws ecs describe-tasks --cluster $CLUSTER_NAME --tasks $TASK_ARN --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value' --output text)
  if [ "$ENI_ID" != "None" ] && [ -n "$ENI_ID" ]; then
    PUBLIC_IP=$(aws ec2 describe-network-interfaces --network-interface-ids $ENI_ID --query 'NetworkInterfaces[0].Association.PublicIp' --output text)
    if [ "$PUBLIC_IP" != "None" ] && [ -n "$PUBLIC_IP" ]; then
      echo "Application available at: http://$PUBLIC_IP"
    fi
  fi
done


# Clean up temporary files
rm -f trust-policy.json task-definition.json

echo "Deployment script completed"