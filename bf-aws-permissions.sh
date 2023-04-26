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
profile=""
region=""
verbose=""
service=""
debug=""
sleep_time="0.3"

HELP_MESSAGE="Usage: $0 [-p profile] [-v] [-s <service>]\n"\
"-p PROFILE: Specify the profile to use (required)\n"\
"-r REGION: Specify a region, if you have no clue use 'us-east-1' (required)\n"\
"-v for Verbose: Get the output of working commands\n"\
"-d for Debug: Get why some commands are failing\n"\
"-s SERVICE: Only BF this service\n"\
"-t SLEEP_TIME: Time to sleep between each BF attempt (default: 0.3)\n"\
"IMPORTANT: Set the region in the profile you want to test."

# Parse the command-line options
while getopts ":p:hvs:r:t:d" opt; do
  case ${opt} in
    h )
      echo -e "$HELP_MESSAGE"
      exit 0
      ;;
    p )
      profile=$OPTARG
      ;;
    r )
      region=$OPTARG
      ;;
    v )
      verbose="1"
      ;;
    d )
      debug="1"
      ;;
    s )
      service=$OPTARG
      ;;
    t )
      sleep_time=$OPTARG
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


if [ -z "$profile" ] || [ -z "$region" ]; then
    echo -e "${RED}Both profile and region are required.${RESET}"
    echo ""
    echo -e "$HELP_MESSAGE"
    exit 1
fi

if ! [ "$(command -v timeout)" ]; then
    echo -e "${RED}Command timeout not installed. It's required.${RESET}"
    echo ""
    exit 1
fi

# Some extra configs
file_path="/tmp/$profile-aws-permissions.txt"
rm $file_path 2>/dev/null
account_id=$(aws sts get-caller-identity --query 'Account' --output text --profile $profile --region $region)
if ! [ "$account_id" ]; then
  account_id="112233445566"
fi

##########################
###### QUERING IAM #######
##########################

caller_identity=$(aws --profile "$profile" --region $region sts get-caller-identity)

# Check if the current profile is a user or a role
if echo "$caller_identity" | grep -q "assumed-role"; then
  entity_type="role"
  entity_name=$(echo "$caller_identity" | jq -r '.Arn' | awk -F '/' '{print $2}')
else
  entity_type="user"
  entity_name=$(echo "$caller_identity" | jq -r '.Arn' | awk -F '/' '{print $NF}')
fi

echo -e "${YELLOW}Entity Type:${RESET} $entity_type"
echo -e "${YELLOW}Entity Name:${RESET} $entity_name"

# Get attached policies
echo -e "${YELLOW}Attached Policies${RESET}"
attached_policies=$(aws --profile "$profile" --region $region iam "list-attached-${entity_type}-policies" --"${entity_type}-name" "$entity_name" | jq -r '.AttachedPolicies[] | .PolicyName + " " + .PolicyArn')
echo "$attached_policies"
echo "====================="
echo ""

# Get policy documents for attached policies
printf "$attached_policies" | while read -r policy; do
  policy_name=$(echo "$policy" | cut -d ' ' -f1)
  policy_arn=$(echo "$policy" | cut -d ' ' -f2)
  version_id=$(aws --profile $profile --region $region iam get-policy --policy-arn $policy_arn | jq -r '.Policy.DefaultVersionId')
  policy_document=$(aws --profile "$profile" --region $region iam get-policy-version --policy-arn "$policy_arn" --version-id "$version_id")
  
  if [ $? -eq 0 ]; then
    echo -e "  ${GREEN}Policy Name:${RESET} $policy_name"
    echo -e "  ${GREEN}Policy Document:${RESET}"
    echo "$policy_document" | jq '.PolicyVersion.Document'
    echo "---------------------"
  fi
done
echo ""


# Get inline policies
echo -e "${YELLOW}Inline Policies${RESET}"
inline_policies=$(aws --profile "$profile" --region $region iam "list-${entity_type}-policies" --"${entity_type}-name" "$entity_name" | jq -r '.PolicyNames[]')
echo "$inline_policies"
echo "====================="
echo ""

# Get policy documents for inline policies
printf "$inline_policies" | while read -r policy; do
  policy_document=$(aws --profile "$profile" --region $region iam "get-${entity_type}-policy" --"${entity_type}-name" "$entity_name" --policy-name "$policy")
  if [ $? -eq 0 ]; then
    echo -e "  ${GREEN}Policy Name:${RESET} $policy"
    echo -e "  ${GREEN}Policy Document:${RESET}"
    echo "$policy_document" | jq '.PolicyDocument'
    echo "---------------------"
  fi
done
echo ""


if [ "$entity_type" == "user" ]; then
  # Get the groups the user belongs to
  groups=$(aws --profile "$profile" --region $region iam list-groups-for-user --user-name "$entity_name" | jq -r '.Groups[].GroupName')
  echo -e "${YELLOW}Groups${RESET}"
  echo "$groups"


  # Get the policies attached to the groups
  printf "$groups" | while read -r group; do
    echo -e "  ${GREEN}Group:${RESET} $group"
    group_attached_policies=$(aws --profile "$profile" --region $region iam list-attached-group-policies --group-name "$group" | jq -r '.AttachedPolicies[] | .PolicyName + " " + .PolicyArn')
    echo -e "  ${YELLOW}Attached Policies:${RESET}"
    echo "$group_attached_policies"

    # Get policy documents for attached group policies
    printf "$group_attached_policies" | while read -r policy; do
      policy_name=$(echo "$policy" | cut -d ' ' -f1)
      policy_arn=$(echo "$policy" | cut -d ' ' -f2)
      policy_document=$(aws --profile "$profile" --region $region iam get-policy-version --policy-arn "$policy_arn" --version-id "$(aws --profile "$profile" --region $region iam get-policy --policy-arn "$policy_arn" | jq -r '.Policy.DefaultVersionId')")
      if [ $? -eq 0 ]; then
        echo -e "    ${GREEN}Policy Name:${RESET} $policy_name"
        echo -e "    ${GREEN}Policy Document:${RESET}"
        echo "$policy_document" | jq '.PolicyVersion.Document'
        echo "---------------------"
      fi
    done

    # Get inline policies of the groups
    group_inline_policies=$(aws --profile "$profile" --region $region iam list-group-policies --group-name "$group" | jq -r '.PolicyNames[]')
    echo -e "${YELLOW}Inline Policies:${RESET}"
    echo "$group_inline_policies"

    # Get policy documents for inline group policies
    for policy in $group_inline_policies; do
      policy_document=$(aws --profile "$profile" --region $region iam get-group-policy --group-name "$group" --policy-name "$policy")
      if [ $? -eq 0 ]; then
        echo "${GREEN}Policy Name:${RESET} $policy"
        echo "${GREEN}Policy Document:${RESET}"
        echo "$policy_document" | jq '.PolicyDocument'
        echo "---------------------"
      fi
    done
  done
fi

echo ""


# Check for simulate permissions
echo -e "${YELLOW}Checking for simulate permissions...${RESET}"

CURRENT_ARN=$(aws --profile "$profile" --region $region sts get-caller-identity --query "Arn" --output text)

if echo $CURRENT_ARN | grep -q "assumed-role"; then
  CURRENT_ARN=${CURRENT_ARN//:sts::/:iam::}
  CURRENT_ARN=${CURRENT_ARN//:assumed-role/:role}
  CURRENT_ARN=${CURRENT_ARN%/*}
fi

echo "Current arn: $CURRENT_ARN"

aws iam simulate-principal-policy --profile "$profile" --region $region \
    --policy-source-arn "$CURRENT_ARN" \
    --action-names codecommit:SimulatePrincipalPolicy
  
if [ $? -eq 0 ]; then
  echo -e "${GREEN}You have simulate permissions!${RESET} Check: ${BLUE}https://github.com/carlospolop/bf-aws-perms-simulate${RESET}"
else
  echo -e "${RED}You don't have simulate permissions!${RESET}"
fi
echo ""
echo ""


# Check for Brute Forcing
read -p "Do you want to continue with brute-forcing? (y/N): " user_choice
if [[ ! "$user_choice" =~ ^[Yy]$ ]]; then
    echo "Aborting brute-forcing."
    exit 0
fi

##########################
##### BRUTE FORCING ######
##########################

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

  output=$(timeout 20 aws --cli-connect-timeout 19 --profile $profile --region $region $service $command $extra 2>&1)

  if echo "$output" | grep -qi 'only alphanumeric characters'; then
    echo -n "only alphanumeric characters"
  fi
}

test_command() {
  service=$1
  command=$2
  extra=$3

  echo -ne "\033[2K\r" # Clean previous echo
  testing_cmd=$(trim_string_to_fit_line "Testing: aws --profile $profile --region $region $service $command $extra")
  echo -ne "$testing_cmd\r"

  output=$(timeout 20 aws --cli-connect-timeout 19 --profile $profile --region $region $service $command $extra 2>&1)

  if [ $? -eq 0 ]; then

    echo -e "\033[2K\r${YELLOW}[+]${RESET} You have permissions for: ${GREEN}$service $command ${BLUE}(aws --profile $profile --region $region $service $command $extra)${RESET}"
    echo "$service $command" >> $file_path
    if [ "$verbose" ]; then
      echo "$output"
    fi
  
  elif echo "$output" | grep -Eq "ValidationException|ValidationError"; then
    if [ "$debug" ]; then
      echo -e "\033[2K\r${RED}[-] (Name Validation Error) Could not check:${RESET} aws --profile $profile --region $region $service $command $extra"
    fi
    return
  
  elif echo "$output" | grep -Eq "InvalidArnException|InvalidRequestException|InvalidParameterValueException|InvalidARNFault|Invalid ARN|InvalidIpamScopeId.Malformed|InvalidParameterException|invalid literal for"; then
    if [ "$debug" ]; then
      echo -e "\033[2K\r${RED}[-] (Invalid Resource) Could not check:${RESET} aws --profile $profile --region $region $service $command $extra"
    fi
    return
  
  elif echo "$output" | grep -Eq "Could not connect to the endpoint URL"; then
    if [ "$debug" ]; then
      echo -e "\033[2K\r${RED}[-] (Could Not Connect To URL) Could not check:${RESET} aws --profile $profile --region $region $service $command $extra"
    fi
    return
  
  elif echo "$output" | grep -Eq "Unknown options|MissingParameter|InvalidInputException|error: argument"; then
    if [ "$debug" ]; then
      echo -e "\033[2K\r${RED}[-] Options weren't properly generated:${RESET} aws --profile $profile --region $region $service $command $extra"
    fi
    return

  # Check if 1 argument is required
  elif echo "$output" | grep -q 'arguments are required'; then
    required_arg=$(echo "$output" | grep -E -o 'arguments are required: [^[:space:],]+' | awk '{print $NF}')
    
    if [ "$required_arg" ]; then
      name_string="OrganizationAccountAccessRole"
      arn_string="arn:aws:iam::$account_id:role/OrganizationAccountAccessRole"
      extra_test="$extra $required_arg $name_string"
      
      test_cp=$(test_command_param "$service" "$command" "$extra_test")
      if echo "$test_cp" | grep -Eq "ValidationException|ValidationError|InvalidArnException|InvalidRequestException|InvalidParameterValueException|InvalidARNFault|Invalid ARN|InvalidIpamScopeId.Malformed|InvalidParameterException|invalid literal for"; then
        extra="$extra $required_arg $arn_string"
      else
        extra="$extra $required_arg $name_string"
      fi

      test_command "$service" "$command" "$extra"
    fi
  
  elif echo "$output" | grep -iEq 'AccessDenied|ForbiddenException|UnauthorizedOperation|UnsupportedCommandException|AuthorizationException'; then
    return
  
  # If NoSuchEntity, you have permissions
  elif echo "$output" | grep -qi 'NoSuchEntity|ResourceNotFoundException|NotFoundException'; then
    echo -e "\033[2K\r${YELLOW}[+]${RESET} You have permissions for: ${GREEN}$service $command ${BLUE}(aws --profile $profile --region $region $service $command $extra)${RESET}"
    echo "$service $command" >> $file_path
    if [ "$verbose" ]; then
      echo "$output"
    fi
  
  # In AWS, both AccessDenied and AccessDeniedException represent errors that occur when the user or the role associated with the user doesn't have the necessary permissions to perform the requested operation.
  # The difference is that the first one is generated by XML-Based APIs and the second one is generated by JSON-Based APIs.
  # THEREFORE THIS IS NOT USEFUL
  #elif echo "$output" | grep -qi 'AccessDeniedException'; then
  #  echo -e "${YELLOW}[+]${RESET} You migh have permissions for: ${GREEN}$service $command ${BLUE}(aws --profile $profile --region $region $service $command $extra)${RESET}"
  #  echo "$service $command (might)" >> $file_path
  #  if [ "$verbose" ]; then
  #    echo "$output"
  #  fi

  else
    if [ "$debug" ]; then
      echo -e "\033[2K\r${RED}[-] Could not check${RESET} aws --profile $profile --region $region $service $command $extra"
    fi
    return
  fi
}


# BFS through the AWS services and get-list-describe 
for service in $(get_aws_services); do
    for svc_command in $(get_commands_for_service "$service"); do
        test_command "$service" "$svc_command" &
        sleep $sleep_time
    done
done

wait
echo -ne "\033[2K\r"
echo ""
echo -e "${YELLOW}[+]${GREEN} Summary of permissions in ${CYAN}$file_path${RESET}"
echo ""
