#!/bin/bash

# Define a function to handle the SIGINT signal (CTRL+C)
function handle_sigint {
  # Kill all child processes
  pkill -P $$
  # Exit the script with a non-zero status code
  exit 1
}

# Set the SIGINT signal (CTRL+C) to trigger the handle_sigint function
trap handle_sigint SIGINT


# Set default values for the options
profile="default"

HELP_MESSAGE="Usage: $0 [-p profile] \n"\
"Set the region in the profile you want to test."

# Parse the command-line options
while getopts ":p:h" opt; do
  case ${opt} in
    h )
      echo -e "$HELP_MESSAGE"
      exit 0
      ;;
    p )
      profile=$OPTARG
      ;;
    \? )
      echo "Invalid option: -$OPTARG" 1>&2
      echo -e "$HELP_MESSAGE"
      exit 1
      ;;
    : )
      echo "Option -$OPTARG requires an argument" 1>&2
      echo -e "$HELP_MESSAGE"
      exit 1
      ;;
  esac
done



# Read the file line by line
get_aws_services(){
    # Set the start and end strings
    start_string="AVAILABLE SERVICES"
    end_string="SEE ALSO"

    # Set a flag to track if we're in the target range
    in_range=false

    aws help | while read line; do
        if [[ "$line" == *"$start_string"* ]]; then
            # Found the start string
            in_range=true
        elif [[ "$line" == *"$end_string"* ]]; then
            # Found the end string
            in_range=false
        fi

        if [ "$in_range" == true ] && [ "$line" ] && echo "$line" | grep -qv "AVAILABLE SERVICES"; then
            # We're in the target range, so echo the line
            echo "$line" | awk '{print $2}'
        fi
    done
}


# Get permissions for each service
get_commands_for_service() {
    service=$1
    
    # Set the start and end strings
    start_string="AVAILABLE COMMANDS"
    end_string="SEE ALSO"

    # Set a flag to track if we're in the target range
    in_range=false

    aws "$service" help | while read line; do
        if [[ "$line" == *"$start_string"* ]]; then
            # Found the start string
            in_range=true
        elif [[ "$line" == *"$end_string"* ]]; then
            # Found the end string
            in_range=false
        fi

        if [ "$in_range" == true ] && [ "$line" ] && echo "$line" | awk '{print $2}' | grep -Eq "^list|^describe|^get"; then
            # We're in the target range, so echo the line
            echo $line | awk '{print $2}' | sort -u
        fi
    done
}

test_command() {
    service=$1
    command=$2

    echo -ne "Testing: aws --profile \"$profile\" $service $command                              \r"

    aws --cli-connect-timeout 20 --profile "$profile" "$service" "$command" >/dev/null 2>&1

    if [ $? -eq 0 ]; then
        echo ""
        echo "[+] You have permissions to execute: aws --profile $profile $service $command"
        echo ""
    fi
}


# BFS through the AWS services and get-list-describe 
for service in $(get_aws_services); do
    for svc_command in $(get_commands_for_service "$service"); do
        test_command "$service" "$svc_command" &
    done
    wait
done
