# Brute Force AWS Permissions

The script `bf-aws-permissions.sh` will try to run all the `list*`, `describe*`, `get*` commands from all the aws services it can discover using the CLI and **indicate the ones that worked**.

This can have false negatives, but it's the **easiest approach to check want you can enumerate** without needing to code each possible action independently, and it won't have false positives:
- You might be able to run a command that needs another extra param and that will be a false negative
- You might be able to have permissions over not `list*`, `describe*`, `get*` commands and that will be a false negative

**Improvements TODO**
- *Some actions just require names or ARNs in 1 or more params, so putting random data it could be checked if the error says that the user doesn't have permission to that random data or that the data just doesn't exist but the user could have access* 

## Quick start
```bash
bash bf-aws-permissions.sh -p "<profile-name>"
# Remember to set the region in the profile
```