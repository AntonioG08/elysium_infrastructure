#!/usr/bin/env bash

# Elysium Infrastructure - AWS MFA Session
#
# Usage:
#   source scripts/aws-mfa-session.sh

# The script must be sourced to export variables into the current shell.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Error: source this script, instead of executing it."
    echo "Usage: source scripts/aws-mfa-session.sh"
    exit 1
fi 


##### LOAD THE '.env' FILE (CONFIG FILE)
# Locate the script and repository configuration.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../.env"

# Load local configuration.
if [[ ! -f "$CONFIG_FILE" || ! -r "$CONFIG_FILE" ]]; then
    echo "Error: configuration file is missing or unreadable: $CONFIG_FILE"
    return 1
fi


##### VALIDATIONS REGARDING THE '.env' FILE
# Validate that the '.env' (configuration file) is readable
if ! source "$CONFIG_FILE"; then
    echo "Error: unable to load configuration."
    return 1
fi

# Validate the aws profile name exists
if [[ -z "${AWS_PROFILE_NAME:-}" ]]; then
    echo "Error: AWS_PROFILE_NAME is missing or empty."
    return 1
fi

# Validate the MFA serial (arn) name exists
if [[ -z "${MFA_SERIAL:-}" ]]; then
    echo "Error: MFA_SERIAL is missing or empty."
    return 1
fi

# Validate the session duration is a positive integer
if [[ ! "${SESSION_DURATION:-}" =~ ^[0-9]+$ ]]; then
    echo "Error: SESSION_DURATION must be a positive integer."
    return 1
fi

# Validate the session duration is a valid number
if (( SESSION_DURATION < 900 || SESSION_DURATION > 129600 )); then
    echo "Error: SESSION_DURATION must be between 900 and 129600 seconds."
    return 1
fi

##### VALIDATE THE DEPENDENCIES
# Check required dependencies.
if ! command -v aws >/dev/null 2>&1; then
    echo "Error: AWS CLI is not installed or not in PATH."
    return 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: Python 3 is not installed or not in PATH."
    return 1
fi

##### MAIN LOGIC OF THE MFA PROCESS
# Request the user to enter the MFA code from his authenticator app
read -r -s -p "Enter your MFA code: " MFA_CODE
echo 

# Validate that the entered MFA code is strictly 6 digits
if [[ ! "$MFA_CODE" =~ ^[0-9]{6}$ ]]; then
    echo "Error: MFA code must contain exactly six digits."
    unset MFA_CODE
    return 1
fi 

# Request temporary credentials using the configured base profile.
# Remove environment credentials from this subprocess so an existing
# temporary session cannot accidentally be used to obtain the new one.
if ! SESSION_RESPONSE=$(
    env -u AWS_ACCESS_KEY_ID \
        -u AWS_SECRET_ACCESS_KEY \
        -u AWS_SESSION_TOKEN \
        aws sts get-session-token \
        --serial-number "$MFA_SERIAL" \
        --token-code "$MFA_CODE" \
        --profile "$AWS_PROFILE_NAME" \
        --duration-seconds "$SESSION_DURATION" \
        --output json
); then
    echo "Error: unable to obtain temporary AWS credentials."
    unset MFA_CODE SESSION_RESPONSE
    return 1
fi


unset MFA_CODE


##### CREDENTIALS EXTRACTION AND EXPORTING TO THE CONSOLE
# Parse and validate the response in one Python invocation.
CREDENTIAL_OUTPUT=$(printf '%s' "$SESSION_RESPONSE" | python3 -c '
import json
import sys

try:
    credentials = json.load(sys.stdin)["Credentials"]
    fields = [
        credentials["AccessKeyId"],
        credentials["SecretAccessKey"],
        credentials["SessionToken"],
        credentials["Expiration"],
    ]

    if not all(isinstance(value, str) and value for value in fields):
        raise ValueError("Missing or empty credential fields")

    print("\n".join(fields))

except (KeyError, TypeError, ValueError, json.JSONDecodeError):
    sys.exit(1)
') || {
    echo "Error: unable to parse or validate AWS credentials."
    unset SESSION_RESPONSE CREDENTIAL_OUTPUT
    return 1
}

# Unset the session response, as until this point, the information has been saved into the 
# Invidivual variables
unset SESSION_RESPONSE

# Split the validated response into individual values.
mapfile -t CREDENTIALS <<< "$CREDENTIAL_OUTPUT"
unset CREDENTIAL_OUTPUT

if (( ${#CREDENTIALS[@]} != 4 )); then
    echo "Error: unexpected credential response."
    unset CREDENTIALS
    return 1
fi

if [[ -z "${CREDENTIALS[0]}" ||
      -z "${CREDENTIALS[1]}" ||
      -z "${CREDENTIALS[2]}" ||
      -z "${CREDENTIALS[3]}" ]]; then
    echo "Error: one or more credential fields are empty."
    unset CREDENTIALS
    return 1
fi

# Export temporary credentials into the current shell.
export AWS_ACCESS_KEY_ID="${CREDENTIALS[0]}"
export AWS_SECRET_ACCESS_KEY="${CREDENTIALS[1]}"
export AWS_SESSION_TOKEN="${CREDENTIALS[2]}"

SESSION_EXPIRATION="${CREDENTIALS[3]}"
unset CREDENTIALS

echo "Temporary AWS credentials exported."
echo "Session expiration: ${SESSION_EXPIRATION}"
echo "Verifying AWS identity..."

# Unset the 3 temporary variables, as they have been exported as env variables
if ! aws sts get-caller-identity; then
    echo "Error: AWS identity verification failed."
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
    unset SESSION_EXPIRATION
    return 1
fi

echo "AWS MFA session is ready."