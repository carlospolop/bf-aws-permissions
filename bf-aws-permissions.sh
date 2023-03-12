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
verbose=0

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
    	start_string="SERVICES"
	end_string="SEE"
	point="o"
	in_range=false

	for line in $(aws help | col -b); do
		if [[ "$start_string" == *"$line"* ]]; then
			# Found the start string
			in_range=true
		elif [[ "$end_string" == *"$line"* ]]; then
			# Found the end string
			in_range=false
		fi

		if [[ $in_range == true ]] && [[ "$line" != *"$point"* ]] && echo "$line" | grep -qv "SERVICES"; then
			# We're in the target range, so echo the line
			echo $line
		fi
	done
}


# Get permissions for each service
get_commands_for_service() {
    service=$1
    
    # Set the start and end strings
    start_string="COMMANDS"
    end_string="SEE"

    # Set a flag to track if we're in the target range
    in_range=false
    for line in $(aws "$service" help | col -b); do
        #echo $line
        if [[ "$start_string" == *"$line"* ]]; then
            # Found the start string
            in_range=true
        elif [[ "$end_string" == *"$line"* ]]; then
            # Found the end string
            in_range=false
        fi

        if [ "$in_range" == true ] && [ "$line" ] && echo "$line" | grep -Eq "^list|^describe|^get"; then
            # We're in the target range, so echo the line
            echo $line
        fi
    done
}

# Test aws command
test_command() {
    service=$1
    command=$2

    echo -ne "Testing: aws --profile \"$profile\" $service $command                              \r"

    aws --cli-connect-timeout 20 --profile "$profile" "$service" "$command" >/dev/null 2>&1
    
    # for extended ouput use --> aws --cli-connect-timeout 20 --profile "$profile" "$service" "$command" 2>/dev/null
       
    if [ $? -eq 0 ]; then
        echo "[+] You have permissions to execute: aws --profile $profile $service $command"
    fi
}


# BFS through the AWS services and get-list-describe 
for service in $(get_aws_services); do
    for svc_command in $(get_commands_for_service "$service"); do
        test_command "$service" "$svc_command" &
    done
    wait
done
