ENV="tkg-eu"
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$ENV-vpc" \
--query "Vpcs[].VpcId" --output text)
SUBNETS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" | \
jq -r --arg subnet "$ENV-public-subnet" \
'.Subnets[] | select(.Tags[].Value | startswith($subnet)) | select(.Tags[].Key == "Name") | .SubnetId')
UUID="thisisauuid"
#
SARR=($SUBNETS)
for S in "${SARR[@]}"; do
    echo "hi frank $S"
    aws ec2 create-tags --resources "$S" \
      --tags Key="$UUID",Value=
done
read -p "Press enter to continue"
for S in "${SARR[@]}"; do
    echo "hi frank $S"
    aws ec2 delete-tags --resources "$S" \
      --tags Key="$UUID"
done
