# Define the name of the Cluster
if [ "$1" != "" ]; then
    CLUSTER_NAME="$1"
else
    echo "Please provide a Name for the Cluster"
    exit 1
fi
# Define other required parameters that we can't get elsewhere.
# ENV is the domain name you gave to your TKG install
ENV="tkg-eu"
# SECURITY_GROUP is name of the security group that TKG created
# to allow port 8443 traffic, for a k8s cluster api
SECURITY_GROUP="pks_api_lb_security_group"
# Make sure we're logged into tkgi.
# Exit code from tkgi command will be 1 if not logged in.
tkgi clusters
if [ $? -gt 0 ]; then
    exit 1
fi
# Get the Id of the Security Group for the Load Balancer to use.
SG_ID=$(aws ec2 describe-security-groups \
--filters "Name=group-name,Values=$SECURITY_GROUP" \
--query "SecurityGroups[].GroupId" --output text)
# Get the id of the VPC that the Load Balancer will be placed in.
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$ENV-vpc" \
--query "Vpcs[].VpcId" --output text)
# Get the list of Subnets for the Load Balancer
# These are the 'public-subnets' that TKGI created
# and they belong to the VPC that TKGI also created.
SUBNETS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" | \
jq -r --arg subnet "$ENV-public-subnet" \
'.Subnets[] | select(.Tags[].Value | startswith($subnet)) | select(.Tags[].Key == "Name") | .SubnetId')
# Define the set of Listeners for the Load Bal.
# This allows is to be contact the k8s master nodes.
LSNR=$(jq -n --arg ptcl "TCP" --arg port "8443" \
'[{Protocol: $ptcl, LoadBalancerPort: $port|tonumber, 
InstanceProtocol: $ptcl, InstancePort: $port|tonumber}]')
# Create the Load Balancer, and get its DNS name
LBNAME=$(aws elb create-load-balancer --load-balancer-name "$CLUSTER_NAME" \
--security-groups $SG_ID \
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
# Add the cluster UUID as a Tag on the public subnets so that
# when we deploy k8s services (of Type=LoadBalancer), their LBs
# will use these public subnets.
TAG="kubernetes.io/cluster/service-instance_$UUID"
SARR=($SUBNETS)
for S in "${SARR[@]}"; do
    echo "subnet: $S, tag: $TAG"
    aws ec2 create-tags --resources "$S" \
      --tags Key="$TAG",Value=
done
# Get the Instance ID of all the VMs in the cluster
NODES=$(aws ec2 describe-instances --filters "Name=instance-state-name,Values=running" | \
jq -r --arg uuid "$DEPLOY_ID" '.Reservations[].Instances | select(.[].Tags[].Key == "deployment" and .[].Tags[].Value == $uuid) | .[].InstanceId')
# Add the cluster name as a tag to those VMs
aws ec2 create-tags --resources $NODES --tags "Key=Cluster,Value=$CLUSTER_NAME"
# Get the kubectl credentials for the new cluster
# (not required, just nice to have).
tkgi get-credentials $CLUSTER_NAME