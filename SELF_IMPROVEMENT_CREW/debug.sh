#!/bin/bash

APP_NAME="course_rec_demo"
CLUSTER_NAME="${APP_NAME}-cluster"
SERVICE_NAME="${APP_NAME}-service"

echo "Debugging ECS deployment for ${APP_NAME}"

# Check service status
echo "Checking service status..."
RUNNING_COUNT=$(aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME --query 'services[0].runningCount' --output text)
DESIRED_COUNT=$(aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME --query 'services[0].desiredCount' --output text)
echo "Running tasks: $RUNNING_COUNT / $DESIRED_COUNT"

# Get task details
echo "Getting task details..."
TASK_ARN=$(aws ecs list-tasks --cluster $CLUSTER_NAME --service-name $SERVICE_NAME --query 'taskArns[0]' --output text)

if [ "$TASK_ARN" == "None" ] || [ -z "$TASK_ARN" ]; then
    echo "No tasks found! Service might be failing to start."
    echo "Checking service events..."
    aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME --query 'services[0].events[0:5]'
    exit 1
fi

echo "Task ARN: $TASK_ARN"

# Check task status
TASK_STATUS=$(aws ecs describe-tasks --cluster $CLUSTER_NAME --tasks $TASK_ARN --query 'tasks[0].lastStatus' --output text)
echo "Task Status: $TASK_STATUS"

# Check container status
echo "Checking container status..."
aws ecs describe-tasks --cluster $CLUSTER_NAME --tasks $TASK_ARN --query 'tasks[0].containers[0].{name:name,status:lastStatus,reason:reason}'

# Get network details
echo "Getting network details..."
ENI_ID=$(aws ecs describe-tasks --cluster $CLUSTER_NAME --tasks $TASK_ARN --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value' --output text)
echo "ENI ID: $ENI_ID"

if [ "$ENI_ID" != "None" ] && [ -n "$ENI_ID" ]; then
    PUBLIC_IP=$(aws ec2 describe-network-interfaces --network-interface-ids $ENI_ID --query 'NetworkInterfaces[0].Association.PublicIp' --output text)
    PRIVATE_IP=$(aws ec2 describe-network-interfaces --network-interface-ids $ENI_ID --query 'NetworkInterfaces[0].PrivateIpAddress' --output text)
    
    echo "Public IP: $PUBLIC_IP"
    echo "Private IP: $PRIVATE_IP"
    
    # Check security group
    SG_ID=$(aws ec2 describe-network-interfaces --network-interface-ids $ENI_ID --query 'NetworkInterfaces[0].Groups[0].GroupId' --output text)
    echo "Security Group: $SG_ID"
    
    echo "Security Group Rules:"
    aws ec2 describe-security-groups --group-ids $SG_ID --query 'SecurityGroups[0].IpPermissions'
else
    echo "No network interface found"
fi

# Check logs (macOS compatible)
echo "Recent application logs:"
START_TIME=$(python3 -c "import time; print(int((time.time() - 300) * 1000))" 2>/dev/null || echo $(date -v-5M +%s)000)
aws logs filter-log-events --log-group-name /ecs/$APP_NAME --start-time $START_TIME --query 'events[*].message' --output text 2>/dev/null | tail -10 || echo "No logs found or log group doesn't exist"

# Check for stopped tasks with error details
echo "Checking for task failures:"
aws ecs describe-tasks --cluster $CLUSTER_NAME --tasks $TASK_ARN --query 'tasks[0].{status:lastStatus,reason:stoppedReason,containers:containers[0].{status:lastStatus,reason:reason,exitCode:exitCode}}'

# Check service events
echo "Recent service events:"
aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME --query 'services[0].events[0:5].[createdAt,message]' --output table

# Check task execution role
echo "Checking task execution role:"
aws iam get-role --role-name ecsTaskExecutionRole --query 'Role.RoleName' 2>/dev/null && echo "Role exists" || echo "Role missing"

# Check task definition
echo "Current task definition ports:"
aws ecs describe-task-definition --task-definition $APP_NAME-task --query 'taskDefinition.containerDefinitions[0].portMappings'

# Test connectivity
if [ "$PUBLIC_IP" != "None" ] && [ -n "$PUBLIC_IP" ]; then
    echo "Testing connectivity..."
    
    # Test common ports
    for port in 80 3000 5000 8000 8080; do
        echo "Testing port $port..."
        timeout 5 bash -c "echo >/dev/tcp/$PUBLIC_IP/$port" 2>/dev/null && echo "Port $port is open" || echo "Port $port is closed"
    done
    
    # Try HTTP request on port 80
    echo "Testing HTTP on port 80..."
    curl -s --connect-timeout 5 http://$PUBLIC_IP/ && echo "HTTP response received" || echo "No HTTP response"
    
    echo ""
    echo "Try these URLs:"
    echo "   http://$PUBLIC_IP"
    echo "   http://$PUBLIC_IP:3000"
    echo "   http://$PUBLIC_IP:5000"
    echo "   http://$PUBLIC_IP:8000"
fi
