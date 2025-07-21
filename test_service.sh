#!/bin/bash

CLUSTER_NAME="course_rec_demo-cluster"
SERVICE_NAME="course_rec_demo-service"

echo "Activating ECS Service: $SERVICE_NAME"

# Check current status
echo "Checking current service status..."
SERVICE_STATUS=$(aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME --query 'services[0].status' --output text 2>/dev/null)
DESIRED_COUNT=$(aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME --query 'services[0].desiredCount' --output text 2>/dev/null)
RUNNING_COUNT=$(aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME --query 'services[0].runningCount' --output text 2>/dev/null)

echo "Service Status: $SERVICE_STATUS"
echo "Desired Tasks: $DESIRED_COUNT"
echo "Running Tasks: $RUNNING_COUNT"

if [ "$SERVICE_STATUS" = "INACTIVE" ]; then
    echo "Service is INACTIVE. This usually means it was deleted."
    echo "Recreating service..."
    
    # Get network configuration
    VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query 'Vpcs[0].VpcId' --output text)
    SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[*].SubnetId' --output text)
    SUBNET_1=$(echo $SUBNET_IDS | cut -d' ' -f1)
    SUBNET_2=$(echo $SUBNET_IDS | cut -d' ' -f2)
    
    # Get or create security group
    SECURITY_GROUP_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=ecs-course_rec_demo-sg" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
    
    if [ "$SECURITY_GROUP_ID" = "None" ] || [ -z "$SECURITY_GROUP_ID" ]; then
        echo "Creating security group..."
        SECURITY_GROUP_ID=$(aws ec2 create-security-group \
          --group-name ecs-course_rec_demo-sg \
          --description "Security group for course_rec_demo ECS tasks" \
          --vpc-id $VPC_ID \
          --query 'GroupId' --output text)
        
        # Allow HTTP traffic
        aws ec2 authorize-security-group-ingress \
          --group-id $SECURITY_GROUP_ID \
          --protocol tcp \
          --port 80 \
          --cidr 0.0.0.0/0
    fi
    
    # Create working task definition
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    REGION=$(aws configure get region)
    
    cat > temp-task-definition.json << EOF
{
  "family": "course_rec_demo-task",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512",
  "executionRoleArn": "arn:aws:iam::${ACCOUNT_ID}:role/ecsTaskExecutionRole",
  "containerDefinitions": [
    {
      "name": "course_rec_demo-container",
      "image": "nginx:alpine",
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
          "awslogs-group": "/ecs/course_rec_demo",
          "awslogs-region": "${REGION}",
          "awslogs-stream-prefix": "ecs"
        }
      }
    }
  ]
}
EOF

    # Register task definition
    echo "Registering task definition..."
    aws ecs register-task-definition --cli-input-json file://temp-task-definition.json
    
    # Create service
    echo "🚀 Creating service..."
    aws ecs create-service \
      --cluster $CLUSTER_NAME \
      --service-name $SERVICE_NAME \
      --task-definition course_rec_demo-task \
      --desired-count 1 \
      --launch-type FARGATE \
      --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_1,$SUBNET_2],securityGroups=[$SECURITY_GROUP_ID],assignPublicIp=ENABLED}"
    
    # Clean up
    rm -f temp-task-definition.json
    
elif [ "$SERVICE_STATUS" = "ACTIVE" ]; then
    if [ "$DESIRED_COUNT" = "0" ]; then
        echo "Service is ACTIVE but desired count is 0. Scaling up..."
        aws ecs update-service --cluster $CLUSTER_NAME --service $SERVICE_NAME --desired-count 1
    elif [ "$RUNNING_COUNT" = "0" ]; then
        echo "Service is ACTIVE but no tasks running. Forcing new deployment..."
        aws ecs update-service --cluster $CLUSTER_NAME --service $SERVICE_NAME --force-new-deployment
    else
        echo "Service is already ACTIVE and running!"
    fi
else
    echo "Unknown service status: $SERVICE_STATUS"
    echo "Recent service events:"
    aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME --query 'services[0].events[0:3].[createdAt,message]' --output table
fi

# Wait and monitor
echo ""
echo "Waiting for service to stabilize..."
sleep 30

# Check final status
echo ""
echo "Final Status Check:"
aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME --query 'services[0].[serviceName,status,runningCount,desiredCount]' --output table

# Get public IP if available
TASK_ARN=$(aws ecs list-tasks --cluster $CLUSTER_NAME --service-name $SERVICE_NAME --query 'taskArns[0]' --output text 2>/dev/null)
if [ "$TASK_ARN" != "None" ] && [ -n "$TASK_ARN" ]; then
    ENI_ID=$(aws ecs describe-tasks --cluster $CLUSTER_NAME --tasks $TASK_ARN --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value' --output text 2>/dev/null)
    if [ "$ENI_ID" != "None" ] && [ -n "$ENI_ID" ]; then
        PUBLIC_IP=$(aws ec2 describe-network-interfaces --network-interface-ids $ENI_ID --query 'NetworkInterfaces[0].Association.PublicIp' --output text 2>/dev/null)
        if [ "$PUBLIC_IP" != "None" ] && [ -n "$PUBLIC_IP" ]; then
            echo ""
            echo "Your service is available at: http://$PUBLIC_IP"
        fi
    fi
fi

echo ""
echo "Service activation complete!"
echo ""
echo "To monitor: aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME"
echo "To check logs: aws logs tail /ecs/course_rec_demo --follow"