# Define the name of the Cluster
if [ "$1" != "" ]; then
    CLUSTER_NAME="$1"
else
    echo "Please provide a Name for the Cluster"
    exit 1
fi
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