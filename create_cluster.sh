# Define the name of the Cluster
if [ "$1" != "" ]; then
    CLUSTER_NAME="$1"
else
    echo "Please provide a Name for the Cluster"
    exit 1
fi
# Define other required parameters that we can't get elsewhere.
SECURITY_GROUPS="sg-07cbaa667bdf55352"
VPC_ID="vpc-021f9d9b667b7ab68"
# Make sure we're logged into tkgi.
# Exit code from tkgi command will be 1 if not logged in.
tkgi clusters
if [ $? -gt 0 ]; then
    exit 1
fi
# Get the list of Subnets for the Load Balancer
# These are the 'public-subnets' that TKGI created
# and they belong to the VPC that TKGI also created.
SUBNETS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" | \
jq -r '.Subnets[] | select(.Tags[].Value | startswith("tkg-public-subnet")) | select(.Tags[].Key == "Name") | .SubnetId')
# Define the set of Listeners for the Load Bal.
# This allows is to be contact the k8s master nodes.
LSNR=$(jq -n --arg ptcl "TCP" --arg port "8443" \
'[{Protocol: $ptcl, LoadBalancerPort: $port|tonumber, 
InstanceProtocol: $ptcl, InstancePort: $port|tonumber}]')
# Create the Load Balancer, and get its DNS name
LBNAME=$(aws elb create-load-balancer --load-balancer-name "$CLUSTER_NAME" \
--security-groups $SECURITY_GROUPS \
--subnets $SUBNETS \
--listeners "$LSNR" \
--query "DNSName" --output text)
echo "Load Balancer: $LBNAME"
# Create the k8s cluster, and get its UUID, so that we can
# add the master node to the LB
UUID=$(tkgi create-cluster $CLUSTER_NAME \
--external-hostname $LBNAME \
--plan small \
--tags name:$CLUSTER_NAME | grep -oP 'UUID:\s*\K(\S*)')
echo "Cluster UUID: $UUID"
# Wait for the Cluster to finish provisioning
echo "Waiting for cluster to deploy"
STATUS="in progress"
while [ "$STATUS" == "in progress" ]; do
  sleep 30
  STATUS=$(tkgi cluster $CLUSTER_NAME | grep -oP 'Last Action State:\s*\K(.*)')
  echo "$STATUS - `date`"
done
# Get the Instance Id of the Master node VMs
DEPLOY_ID="service-instance_$UUID"
INSTANCE_ID=$(aws ec2 describe-instances | \
jq -r --arg uuid "$DEPLOY_ID" '.Reservations[].Instances | select(.[].Tags[].Key == "deployment" and .[].Tags[].Value == $uuid) |   select(.[].Tags[].Key == "instance_group" and .[].Tags[].Value == "master") | .[].InstanceId' | \
sort | uniq)
# Add the Instance to the Load Bal
aws elb register-instances-with-load-balancer \
--load-balancer-name $CLUSTER_NAME --instances $INSTANCE_ID
# Get the kubectl credentials for the new cluster
# (not required, just nice to have).
tkgi get-credentials $CLUSTER_NAME
# Get the Instance ID of all the VMs in the cluster
NODES=$(aws ec2 describe-instances --filters "Name=instance-state-name,Values=running" | \
jq -r --arg uuid "$DEPLOY_ID" '.Reservations[].Instances | select(.[].Tags[].Key == "deployment" and .[].Tags[].Value == $uuid) | .[].InstanceId')
# Add the cluster name as a tag to those VMs
aws ec2 create-tags --resources $NODES --tags "Key=Cluster,Value=$CLUSTER_NAME"