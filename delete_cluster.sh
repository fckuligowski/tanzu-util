# Define the name of the Cluster
if [ "$1" != "" ]; then
    CLUSTER_NAME="$1"
else
    echo "Please provide a Name for the Cluster"
    exit 1
fi
# Make sure we're logged into tkgi.
# Exit code from tkgi command will be 1 if not logged in.
tkgi cluster $CLUSTER_NAME
if [ $? -gt 0 ]; then
    exit 1
fi
# Capture the UUID so we can use it later to remove Tags
UUID=$(tkgi cluster $CLUSTER_NAME --details | grep -oP "UUID:\s*\K(\S*)")
# Delete the k8s cluster, well, start the process.
# This command doesn't change its return value based on if
# the user hit y/n. So we can't conditionally delete the
# load balancer, or not, based on the user's choice. 
# So, we just always delete them both (--non-interactive).
tkgi delete-cluster "$CLUSTER_NAME" --non-interactive
# Wait for the Cluster to finish provisioning
echo "Waiting for cluster to delete"
STATUS="in progress"
while [ "$STATUS" == "in progress" ]; do
  sleep 30
  CLFOUND=$(tkgi clusters | grep $CLUSTER_NAME)
  if [ "$1" != "" ]; then
    STATUS=$(tkgi cluster $CLUSTER_NAME | grep -oP 'Last Action State:\s*\K(.*)')
    echo "$STATUS - `date`"
  else
    echo "$CLUSTER_NAME has been deleted"
  fi
done
# Delete the Load Balancer
echo "Deleting cluster Load Balancer - $CLUSTER_NAME"
aws elb delete-load-balancer --load-balancer-name "$CLUSTER_NAME"
# Remove any Tags for this cluster from the public subnets.
# That tag is used when k8s services of Type=Loadbalancer are deployed.
TAG="kubernetes.io/cluster/service-instance_$UUID"
ENV="tkg-eu"
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$ENV-vpc" \
--query "Vpcs[].VpcId" --output text)
SUBNETS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" | \
jq -r --arg subnet "$ENV-public-subnet" \
'.Subnets[] | select(.Tags[].Value | startswith($subnet)) | select(.Tags[].Key == "Name") | .SubnetId')
SARR=($SUBNETS)
for S in "${SARR[@]}"; do
    aws ec2 delete-tags --resources "$S" \
      --tags Key="$TAG"
done
# Remove any Load Balancers that were setup for k8s Services running
# from this delete cluster. We know what these are because they have
# a tag matching the cluster UUID.
ALLLOADBALS=$(aws elb describe-load-balancers | \
jq -r '.LoadBalancerDescriptions[] | .LoadBalancerName')
LBARR=($ALLLOADBALS)
for LB in "${LBARR[@]}"; do
    LBNAME=$(aws elb describe-tags --load-balancer-names $LB | \
    jq -r --arg tag "$TAG" '.TagDescriptions[] | select(.Tags[].Key == $tag) | .LoadBalancerName')
    if [ ! -z "$LBNAME" ]; then
        echo "deleting Load Balancer $LBNAME"
        aws elb delete-load-balancer --load-balancer-name "$LBNAME"
    fi
done
#
# Delete any EBS volumes that were dynamically provisioned.
#
EBS_ALL=$(aws ec2 describe-volumes --filters "Name=tag:Name,Values=$CLUSTER_NAME*" | \
jq -r '.Volumes[] | select(.Tags[].Key == "Name") | .VolumeId' | sort)
EBS_ARR=($EBS_ALL)
for EBS in "${EBS_ARR[@]}"; do 
    echo "Deleting EBS Volume $EBS"
    aws ec2 delete-volume --volume-id $EBS
done
# Show the cluster status one last time before we go
echo "Delete complete - $CLUSTER_NAME"