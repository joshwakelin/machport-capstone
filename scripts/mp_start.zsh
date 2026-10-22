ids=$(aws ec2 describe-instances --filters "Name=tag:Project,Values=machport-capstone" "Name=instance-state-name,Values=stopped" --query 'Reservations[].Instances[].InstanceId' --output text)
if [ -z "$ids" ]; then echo "nothing to start"; exit 0; fi
aws ec2 start-instances --instance-ids ${=ids} > /dev/null && echo "starting servers, wait 2-5 minutes"
