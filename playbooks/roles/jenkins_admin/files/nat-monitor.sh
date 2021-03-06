#!/bin/bash -x
# This script will monitor two NATs and route to a backup nat
# if the primary fails.
set -e

# Health Check variables
Num_Pings=3
Ping_Timeout=1
Wait_Between_Pings=2
Wait_for_Instance_Stop=60
Wait_for_Instance_Start=300
ID_UPDATE_INTERVAL=150

send_message() {
  message_file=/var/tmp/message-$$.json
  message_string=$1
  if [ -z $message_string ]; then
    message_string="Unknown error for $VPC_NAME NAT monitor"
  fi
  message_body=$2
  cat << EOF > $message_file
{"Subject":{"Data":"$message_string"},"Body":{"Text":{"Data": "$message_body"}}}
EOF

  echo `date` "-- $message_body"
  BASE_PROFILE=$AWS_DEFAULT_PROFILE
  export AWS_DEFAULT_PROFILE=$AWS_MAIL_PROFILE
  aws ses send-email --from $NAT_MONITOR_FROM_EMAIL --to $NAT_MONITOR_TO_EMAIL --message file://$message_file
  export AWS_DEFAULT_PROFILE=$BASE_PROFILE
}
trap send_message ERR SIGHUP SIGINT SIGTERM

# Determine the NAT instance private IP so we can ping the other NAT instance, take over
# its route, and reboot it.  Requires EC2 DescribeInstances, ReplaceRoute, and Start/RebootInstances
# permissions.  The following example EC2 Roles policy will authorize these commands:
# {
#  "Statement": [
#    {
#      "Action": [
#        "ec2:DescribeInstances",
#        "ec2:CreateRoute",
#        "ec2:ReplaceRoute",
#        "ec2:StartInstances",
#        "ec2:StopInstances"
#      ],
#      "Effect": "Allow",
#      "Resource": "*"
#    }
#  ]
# }

COUNTER=0

echo `date` "-- Running NAT monitor"
while [ . ]; do
  # Re check thi IDs and IPs periodically
  # This is useful in case the primary nat changes by some
  # other means than this script.
  if [ $COUNTER -eq 0 ]; then
    # NAT instance variables
    PRIMARY_NAT_ID=`aws ec2 describe-route-tables --filters Name=tag:aws:cloudformation:stack-name,Values=$VPC_NAME Name=tag:aws:cloudformation:logical-id,Values=PrivateRouteTable | jq '.RouteTables[].Routes[].InstanceId|strings' -r`
    BACKUP_NAT_ID=`aws ec2 describe-instances --filters Name=tag:aws:cloudformation:stack-name,Values=$VPC_NAME Name=tag:aws:cloudformation:logical-id,Values=NATDevice,BackupNATDevice | jq '.Reservations[].Instances[].InstanceId' -r | grep -v $PRIMARY_NAT_ID`
    NAT_RT_ID=`aws ec2 describe-route-tables --filters Name=tag:aws:cloudformation:stack-name,Values=$VPC_NAME Name=tag:aws:cloudformation:logical-id,Values=PrivateRouteTable | jq '.RouteTables[].RouteTableId' -r`
    
    # Get the primary NAT instance's IP
    PRIMARY_NAT_IP=`aws ec2 describe-instances --instance-ids $PRIMARY_NAT_ID | jq -r ".Reservations[].Instances[].PrivateIpAddress"`
    BACKUP_NAT_IP=`aws ec2 describe-instances --instance-ids $BACKUP_NAT_ID | jq -r ".Reservations[].Instances[].PrivateIpAddress"`

    let "COUNTER += 1"
    let "COUNTER %= $ID_UPDATE_INTERVAL"
  fi
  # Check the health of both instances.
  primary_pingresult=`ping -c $Num_Pings -W $Ping_Timeout $PRIMARY_NAT_IP| grep time= | wc -l`
  
  if [ "$primary_pingresult" == "0" ]; then
    backup_pingresult=`ping -c $Num_Pings -W $Ping_Timeout $BACKUP_NAT_IP| grep time= | wc -l`
    if [ "$backup_pingresult" == "0" ]; then
      send_message "Error monitoring NATs for $VPC_NAME."  "ERROR -- Both NATs($PRIMARY_NAT_ID and $BACKUP_NAT_ID) were unreachable."
    else #Backup nat is healthy.
      # Set HEALTHY variables to unhealthy (0)
      ROUTE_HEALTHY=0
      NAT_HEALTHY=0
      STOPPING_NAT=0
      while [ "$NAT_HEALTHY" == "0" ]; do
      # Primary NAT instance is unhealthy, loop while we try to fix it
        if [ "$ROUTE_HEALTHY" == "0" ]; then
          aws ec2 replace-route --route-table-id $NAT_RT_ID --destination-cidr-block 0.0.0.0/0 --instance-id $BACKUP_NAT_ID
          send_message " Primary $VPC_NAME NAT failed" "-- NAT($PRIMARY_NAT_ID) heartbeat failed, using $BACKUP_NAT_ID for $NAT_RT_ID default route"
          ROUTE_HEALTHY=1
        fi
        # Check NAT state to see if we should stop it or start it again
        NAT_STATE=`aws ec2 describe-instances --instance-ids $PRIMARY_NAT_ID | jq -r ".Reservations[].Instances[].State.Name"`
        if [ "$NAT_STATE" == "stopped" ]; then
          echo `date` "-- NAT($PRIMARY_NAT_ID) instance stopped, starting it back up"
          aws ec2 start-instances --instance-ids $PRIMARY_NAT_ID
          sleep $Wait_for_Instance_Start
        else
          if [ "$STOPPING_NAT" == "0" ]; then
            echo `date` "-- NAT($PRIMARY_NAT_ID) instance $NAT_STATE, attempting to stop for reboot"
            aws ec2 stop-instances --instance-ids $PRIMARY_NAT_ID
            STOPPING_NAT=1
          fi
          sleep $Wait_for_Instance_Stop
        fi
        unhealthy_nat_pingresult=`ping -c $Num_Pings -W $Ping_Timeout $PRIMARY_NAT_IP| grep time= | wc -l`
        if [ "$unhealthy_nat_pingresult" == "$Num_Pings" ]; then
          NAT_HEALTHY=1
        fi
      done
  
      # Backup nat was healthy so we switched to it.  It is now the primary.
      if [ "$ROUTE_HEALTHY" == "1" ]; then
        TEMP_NAT_ID=$PRIMARY_NAT_ID
        TEMP_NAT_IP=$PRIMARY_NAT_IP
  
        PRIMARY_NAT_ID=$BACKUP_NAT_ID
        PRIMARY_NAT_IP=$BACKUP_NAT_IP
  
        BACKUP_NAT_ID=$TEMP_NAT_ID
        BACKUP_NAT_IP=$TEMP_NAT_IP
      fi
    fi
  else
    echo `date` "-- PRIMARY NAT ($PRIMARY_NAT_ID $PRIMARY_NAT_IP) reports healthy to pings"
    sleep $Wait_Between_Pings
  fi
done
