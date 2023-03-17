#!/bin/bash

# ANSI escape codes for colors
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
MAGENTA="\033[35m"
CYAN="\033[36m"
RESET="\033[0m"

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
verbose=""
service=""

HELP_MESSAGE="Usage: $0 [-p profile] [-v] [-s <service>]\n"\
"-v for Verbose: Get the output of working commands\n"\
"-s SERVICE: Only BF this service\n"\
"IMPORTANT: Set the region in the profile you want to test."

# Parse the command-line options
while getopts ":p:hvs:" opt; do
  case ${opt} in
    h )
      echo -e "$HELP_MESSAGE"
      exit 0
      ;;
    p )
      profile=$OPTARG
      ;;
    v )
      verbose="1"
      ;;
    s )
      service=$OPTARG
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

file_path="/tmp/$profile-aws-permissions.txt"
rm $file_path 2>/dev/null
account_id=$(aws sts get-caller-identity --query 'Account' --output text --profile $profile)
if ! [ "$account_id" ]; then
  account_id="112233445566"
fi


# Read the file line by line
get_aws_services(){
  # Set the start and end strings
  start_string="SERVICES"
	end_string="SEE"
	point="o"
	in_range=false

	for line in $(aws help | col -b); do
		if echo "$line" | grep -a -q "$start_string"; then
			# Found the start string
			in_range=true
		elif echo "$line" | grep -a -q "$end_string"; then
			# Found the end string
			in_range=false
		fi

		if [[ $in_range == true ]] && [[ "$line" != *"$point"* ]] && echo "$line" | grep -aqv "SERVICES"; then
      # We're in the target range, so echo the line
      
      if [ "$service" ]; then
        if echo "$line" | grep -qEi "$service"; then
          echo $line
        fi
      
      else
        echo $line
      fi
			
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
        if echo "$line" | grep -a -q "$start_string"; then
            # Found the start string
            in_range=true
        elif echo "$line" | grep -a -q "$end_string"; then
            # Found the end string
            in_range=false
        fi

        if [ "$in_range" == true ] && [ "$line" ] && echo "$line" | grep -Eq "^list|^describe|^get"; then
            # We're in the target range, so echo the line
            echo $line
        fi
    done
}

trim_string_to_fit_line() {
  input_string="$1"
  terminal_width=$(tput cols)

  if [ ${#input_string} -gt $terminal_width ]; then
    truncated_string="${input_string:0:$terminal_width}"
  else
    truncated_string="$input_string"
  fi

  echo -n "$truncated_string"
}

test_command_param(){
  service=$1
  command=$2
  extra=$3

  output=$(timeout 20 aws --cli-connect-timeout 19 --profile $profile $service $command $extra 2>&1)

  if echo "$output" | grep -qi 'only alphanumeric characters'; then
    echo -n "only alphanumeric characters"
  fi
}

test_command() {
  service=$1
  command=$2
  extra=$3

  echo -ne "\033[2K\r" # Clean previous echo
  testing_cmd=$(trim_string_to_fit_line "Testing: aws --profile $profile $service $command $extra")
  echo -ne "$testing_cmd\r"

  output=$(timeout 20 aws --cli-connect-timeout 19 --profile $profile $service $command $extra 2>&1)

  if [ $? -eq 0 ]; then
    echo -e "${YELLOW}[+]${RESET} You have permissions for: ${GREEN}$service $command ${BLUE}(aws --profile $profile $service $command $extra)${RESET}"
    echo "$service $command" >> $file_path
    if [ "$verbose" ]; then
      echo "$output"
    fi
  
  # Check if 1 argument is required
  elif echo "$output" | grep -q 'arguments are required'; then
    required_arg=$(echo "$output" | grep -E -o 'arguments are required: [^[:space:],]+' | awk '{print $NF}')
    
    if [ "$required_arg" ]; then
      name_string="OrganizationAccountAccessRole"
      arn_string="arn:aws:iam::$account_id:role/OrganizationAccountAccessRole"
      extra_test="$extra $required_arg $arn_string"
      
      test_cp=$(test_command_param "$service" "$command" "$extra_test")
      if [ "$test_cp" == "only alphanumeric characters" ]; then
        extra="$extra $required_arg $name_string"
      else
        extra="$extra $required_arg $arn_string"
      fi

      test_command "$service" "$command" "$extra"
    fi
  
  elif echo "$output" | grep -iq 'AccessDenied'; then
    return
  
  # If NoSuchEntity, you have permissions
  elif echo "$output" | grep -qi 'NoSuchEntity'; then
    echo -e "${YELLOW}[+]${RESET} You have permissions for: ${GREEN}$service $command ${BLUE}(aws --profile $profile $service $command $extra)${RESET}"
    echo "$service $command (might)" >> $file_path
    if [ "$verbose" ]; then
      echo "$output"
    fi
  
  # In AWS, both AccessDenied and AccessDeniedException represent errors that occur when the user or the role associated with the user doesn't have the necessary permissions to perform the requested operation.
  # The difference is that the first one is generated by XML-Based APIs and the second one is generated by JSON-Based APIs.
  # THEREFORE THIS IS NOT USEFUL
  #elif echo "$output" | grep -qi 'AccessDeniedException'; then
  #  echo -e "${YELLOW}[+]${RESET} You migh have permissions for: ${GREEN}$service $command ${BLUE}(aws --profile $profile $service $command $extra)${RESET}"
  #  echo "$service $command (might)" >> $file_path
  #  if [ "$verbose" ]; then
  #    echo "$output"
  #  fi
  fi
}


# BFS through the AWS services and get-list-describe 
for service in $(get_aws_services); do
    for svc_command in $(get_commands_for_service "$service"); do
        test_command "$service" "$svc_command" &
        sleep 0.2
    done
done

echo -ne "\033[2K\r"
echo ""
echo -e "${YELLOW}[+]${GREEN} Summary of permissions in ${CYAN}$file_path${RESET}"
echo "