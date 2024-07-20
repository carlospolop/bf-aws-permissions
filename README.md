# Brute Force AWS Permissions

The script will first try to **enumerate your permissions querying the IAM service**, and then give you the options to brute force permissions.

The script `bf-aws-permissions.sh` will try to run all the `list*`, `describe*`, `get*` commands from all the aws services it can discover using the CLI and **indicate the ones that worked**.

This can have false negatives, but it's the **easiest approach to check want you can enumerate** without needing to code each possible action independently, and it won't have false positives:
- You might be able to run a command that needs another extra specific param and that will be a false negative (the tool is already testing with random params)
- You might be able to have permissions over not `list*`, `describe*`, `get*` commands and that will be a false negative

**Improvements TODO**
- *Some actions require specific ARNs from the account in 1 or more params, so generating a random ARN that fullfil the ARN regex and checking if the error says that the user doesn't have permission to that random data or that the data just doesn't exist but the user could have access could indicate access over the action*

## Quick start
```bash
# Remember to set the region in the profile
bash bf-aws-permissions.sh -p "<profile-name>" -r <region>
# BF only the 10 services most used according to GPT4
bash bf-aws-permissions.sh -p "<profile-name>" -r us-east-1 -s 's3|ec2|lambda|rds|sns|sqs|cloudwatch|cloudfront|iam|dynamodb'
# Skip initial checks and go straight to BF
bash bf-aws-permissions.sh -p "<profile-name>" -r us-east-1 -s 's3|ec2|lambda|rds|sns|sqs|cloudwatch|cloudfront|iam|dynamodb' -b

# For temp creds use:
aws configure set aws_session_token <token>
```

