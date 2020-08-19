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
# Delete the Load Balancer
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
# Show the cluster status one last time before we go
tkgi cluster $CLUSTER_NAME