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
direct_bf=""

HELP_MESSAGE="Usage: $0 -p profile -r region [-v] [-s <service>]\n"\
"-p PROFILE: Specify the profile to use (required)\n"\
"-r REGION: Specify a region, if you have no clue use 'us-east-1' (required)\n"\
"-v for Verbose: Get the output of working commands\n"\
"-d for Debug: Get why some commands are failing\n"\
"-s SERVICE: Only BF this service\n"\
"-t SLEEP_TIME: Time to sleep between each BF attempt (default: 0.3)\n"\
"-b: Skip initial checks and go straight to brute-forcing\n"

# Parse the command-line options
while getopts ":p:hvs:r:t:db" opt; do
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
    b )
      direct_bf="1"
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




if ! [ "$direct_bf" ]; then
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
      --action-names iam:SimulatePrincipalPolicy \
      --region $region --profile $profile

    
  if [ $? -eq 0 ]; then
    echo -e "${GREEN}You have simulate permissions!${RESET} Check: ${BLUE}https://github.com/carlospolop/bf-aws-perms-simulate${RESET}"
  else
    echo -e "${RED}You don't have simulate permissions!${RESET}"
  fi
  echo ""
  echo ""


  # Check for Brute Forcing
  read -p "Do you want to continue with brute-forcing? (Y/n): " user_choice
  if [[ "$user_choice" =~ ^[Nn]$ ]]; then
      echo "Aborting brute-forcing."
      exit 0
  fi
fi


##########################
#### TRANSFORM COMMAND ###
##########################
transform_command() {
  echo $1 | \
  sed 's/accessanalizer/access-analyzer/g' | \
  sed 's/amp:/aps:/g' | \
  sed 's/apigateway:Get.*/apigateway:GET/g' | \
  sed 's/apigatewayv2:Get.*/apigateway:GET/g' | \
  sed 's/appintegrations:/app-integrations:/g' | \
  sed 's/application-insights:/applicationinsights:/g' | \
  sed 's/athena:ListApplicationDpuSizes/athena:ListApplicationDPUSizes/g' | \
  sed 's/chime-.*:/chime:/g' | \
  sed 's/cloudcontrol:/cloudformation:/g' | \
  sed 's/cloudfront:ListDistributionsByWebAclId/cloudfront:ListDistributionsByWebACLId/g' | \
  sed 's/cloudhsmv2:/cloudhsm:/g' | \
  sed 's/codeguruprofiler:/codeguru-profiler:/g' | \
  sed 's/comprehendmedical:ListIcd10CmInferenceJobs/comprehendmedical:ListICD10CMInferenceJobs/g' | \
  sed 's/comprehendmedical:ListPhiDetectionJobs/comprehendmedical:ListPHIDetectionJobs/g' | \
  sed 's/comprehendmedical:ListSnomedctInferenceJobs/comprehendmedical:ListSNOMEDCTInferenceJobs/g' | \
  sed 's/configservice:/config:/g' | \
  sed 's/connectcampaigns:/connect-campaigns:/g' | \
  sed 's/connectcases:/cases:/g' | \
  sed 's/customer-profiles:/profile:/g' | \
  sed 's/deploy:/codeploy:/g' | \
  sed 's/detective:ListOrganizationAdminAccounts/detective:ListOrganizationAdminAccount/g' | \
  sed 's/docdb:/rds:/g' | \
  sed 's/dynamodbstreams:/dynamodb:/g' | \
  sed 's/ecr:GetLoginPassword/ecr:GetAuthorizationToken/g' | \
  sed 's/efs:/elasticfilesystem:/g' | \
  sed 's/elb:/elasticloadbalancing:/g' | \
  sed 's/elbv2/elasticloadbalancing:/g' | \
  sed 's/emr:/elasticmapreduce:/g' | \
  sed 's/frauddetector:GetKmsEncryptionKey/frauddetector:GetKMSEncryptionKey/g' | \
  sed 's/gamelift:DescribeEc2InstanceLimits/gamelift:DescribeEC2InstanceLimits/g' | \
  sed 's/glue:GetMlTransforms/glue:GetMLTransforms/g' | \
  sed 's/glue:ListMlTransforms/glue:ListMLTransforms/g' | \
  sed 's/greengrassv2:/greengrass:/g' | \
  sed 's/healthlake:ListFhirDatastores/healthlake:ListFHIRDatastores/g' | \
  sed 's/iam:ListMfaDevices/iam:ListMFADevices/g' | \
  sed 's/iam:ListOpenIdConnectProviders/iam:ListOpenIDConnectProviders/g' | \
  sed 's/iam:ListSamlProviders/iam:ListSAMLProviders/g' | \
  sed 's/iam:ListSshPublicKeys/iam:ListSSHPublicKeys/g' | \
  sed 's/iam:ListVirtualMfaDevices/iam:ListVirtualMFADevices/g' | \
  sed 's/iot:ListCaCertificates/iot:ListCACertificates/g' | \
  sed 's/iot:ListOtaUpdates/iot:ListOTAUpdates/g' | \
  sed 's/iot-data:/iot:/g' | \
  sed 's/iotsecuretunneling:/iot:/g' | \
  sed 's/ivs-realtime:/ivs:/g' | \
  sed 's/kinesis-video-archived-media:/kinesisvideo:/g' | \
  sed 's/kinesis-video-signaling:/kinesisvideo:/g' | \
  sed 's/kinesisanalyticsv2:/kinesisanalytics:/g' | \
  sed 's/lakeformation:ListLfTags/lakeformation:ListLFTags/g' | \
  sed 's/lex-models:/lex:/g' | \
  sed 's/lexv2-models:/lex:/g' | \
  sed 's/lightsail:GetContainerApiMetadata/lightsail:GetContainerAPIMetadata/g' | \
  sed 's/location:/geo:/g' | \
  sed 's/marketplace-entitlement:/aws-marketplace:/g' | \
  sed 's/migration-hub-refactor-spaces:/refactor-spaces:/g' | \
  sed 's/migrationhub-config:/mgh:/g' | \
  sed 's/migrationhuborchestrator:/migrationhub-orchestrator:/g' | \
  sed 's/migrationhubstrategy:/migrationhub-strategy:/g' | \
  sed 's/mwaa:/airflow:/g' | \
  sed 's/neptune:/rds:/g' | \
  sed 's/network-firewall:ListTlsInspectionConfigurations/network-firewall:ListTLSInspectionConfigurations/g' | \
  sed 's/opensearch:/es:/g' | \
  sed 's/opensearchserverless:/aoss:/g' | \
  sed 's/organizations:ListAwsServiceAccessForOrganization/organizations:ListAWSServiceAccessForOrganization/g' | \
  sed 's/pinpoint:/mobiletargeting:/g' | \
  sed 's/pinpoint-email:/ses:/g' | \
  sed 's/pinpoint-sms-voice-v2:/sms-voice:/g' | \
  sed 's/privatenetworks:/private-networks:/g' | \
  sed 's/Db/DB/g' | \
  sed 's/resourcegroupstaggingapi:/tag:/g' | \
  sed 's/s3outposts:/s3-outposts:/g' | \
  sed 's/sagemaker:ListAutoMlJobs/sagemaker:ListAutoMLJobs/g' | \
  sed 's/sagemaker:ListCandidatesForAutoMlJob/sagemaker:ListCandidatesForAutoMLJob/g' | \
  sed 's/service-quotas:/servicequotas:/g' | \
  sed 's/servicecatalog:GetAwsOrganizationsAccessStatus/servicecatalog:GetAWSOrganizationsAccessStatus/g' | \
  sed 's/servicecatalog-appregistry:/servicecatalog:/g' | \
  sed 's/sesv2:/ses:/g' | \
  sed 's/sns:GetSmsAttributes/sns:GetSMSAttributes/g' | \
  sed 's/sns:GetSmsSandboxAccountStatus/sns:GetSMSSandboxAccountStatus/g' | \
  sed 's/sns:ListSmsSandboxPhoneNumbers/sns:ListSMSSandboxPhoneNumbers/g' | \
  sed 's/sso-admin:/sso:/g' | \
  sed 's/stepfunctions:/states:/g' | \
  sed 's/support-app:/supportapp:/g' | \
  sed 's/timestream-query:/timestream:/g' | \
  sed 's/timestream-write:/timestream:/g' | \
  sed 's/voice-id:/voiceid:/g' | \
  sed 's/waf:ListIpSets/waf:ListIPSets/g' | \
  sed 's/waf:ListWebAcls/waf:ListWebACLs/g' | \
  sed 's/waf-regional:ListIpSets/waf-regional:ListIPSets/g' | \
  sed 's/waf-regional:ListWebAcls/waf-regional:ListWebACLs/g' | \
  sed 's/keyspaces:ListKeyspaces/cassandra:Select/g' | \
  sed 's/keyspaces:ListTables/cassandra:Select/g' | \
  sed 's/s3api:ListBuckets/s3:ListAllMyBuckets/g' | \
  grep -v "configure:"
}

capitalize(){
  local input=$1
  # Split the input based on hyphen (-)
  IFS='-' read -r -a parts <<< "$input"

  # Initialize output variable
  output=""

  # Loop over each part
  for part in "${parts[@]}"; do
    # Capitalize the first character and append the rest of the string
    capitalized="${part^}"
    # Append the capitalized part back with a hyphen
    if [ -z "$output" ]; then
      output="$capitalized"
    else
      output="$output-$capitalized"
    fi
  done

  echo -n "$output"
}

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

		if [[ $in_range == true ]] && echo -n "$line" | grep -qvE "^${point}$" && echo "$line" | grep -aqv "SERVICES"; then
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
    capitalized_command=$(capitalize "$command")
    permission_command=$(echo -n "$capitalized_command" | tr -d '-')
    # Construct the permission with service and formatted command
    permission="${service}:$permission_command"
    permission=$(transform_command "$permission")

    echo -e "\033[2K\r${YELLOW}[+]${RESET} You can: ${GREEN}$service $command ${BLUE}(aws --profile $profile --region $region $service $command $extra)${RESET} (${YELLOW}$permission${RESET})"
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
    # Capitalize command and after "-"
    capitalized_command=$(capitalize "$command")
    permission_command=$(echo -n "$capitalized_command" | tr -d '-')
    # Construct the permission with service and formatted command
    permission="${service}:$permission_command"
    permission=$(transform_command "$permission")

    echo -e "\033[2K\r${YELLOW}[+]${RESET} You can: ${GREEN}$service $command ${BLUE}(aws --profile $profile --region $region $service $command $extra)${RESET}($permission)"
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
echo -e "${YELLOW}Now try the tool https://github.com/carlospolop/aws-Perms2ManagedPolicies to guess even more permissions you might have${RESET}"
