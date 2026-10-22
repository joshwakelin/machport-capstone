ids=$(aws ec2 describe-instances --filters "Name=tag:Project,Values=machport-capstone" "Name=instance-state-name,Values=running" --query 'Reservations[].Instances[].InstanceId' --output text)
if [ -z "$ids" ]; then echo "nothing to stop"; exit 0; fi
aws ec2 stop-instances --instance-ids ${=ids} > /dev/null && echo "stopping servers"
