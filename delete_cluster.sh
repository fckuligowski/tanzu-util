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
# Delete the k8s cluster, well, start the process.
# This command doesn't change its return value based on if
# the user hit y/n. So we can't conditionally delete the
# load balancer, or not, based on the user's choice. 
# So, we just always delete them both (--non-interactive).
tkgi delete-cluster "$CLUSTER_NAME" --non-interactive
# Delete the Load Balancer
aws elb delete-load-balancer --load-balancer-name "$CLUSTER_NAME"
# Show the cluster status one last time before we go
tkgi cluster $CLUSTER_NAME