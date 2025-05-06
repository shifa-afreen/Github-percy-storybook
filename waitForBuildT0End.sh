#!/bin/bash

# --- Configuration ---
API_URL='https://percy.io/api/v1/builds/40232012'
# !! Replace 'xxx' with your actual Authorization token !!
AUTH_TOKEN="$PERCY_TOKEN"
echo "Token : $PERCY_TOKEN"

# The jq filter to extract the state field
JQ_FILTER_STATE='.data.attributes.state'
# The jq filter to extract the total-comparisons-diff field
# Note: quotes are needed around "total-comparisons-diff" because of the hyphen
JQ_FILTER_DIFF='.data.attributes."total-comparisons-diff"'
# Polling interval in seconds
POLLING_INTERVAL_SECONDS=10
# Maximum number of attempts before giving up
MAX_ATTEMPTS=60 # e.g., 60 attempts * 10 seconds = 10 minutes timeout

# --- Script ---

# Set -e: Exit immediately if a command exits with a non-zero status.
# This helps catch errors if curl or jq fail fundamentally.
set -e

echo "Polling API for build state to become 'finished'..."
echo "API URL: $API_URL"
echo "Polling Interval: ${POLLING_INTERVAL_SECONDS}s"
echo "Maximum Attempts: $MAX_ATTEMPTS"

state=""      # Initialize the state variable
attempt=0     # Initialize attempt counter

# Loop while the state is NOT "finished" AND we haven't exceeded max attempts
while [ "$state" != "finished" ] && [ $attempt -lt $MAX_ATTEMPTS ]; do
    attempt=$((attempt + 1)) # Increment attempt counter

    echo "--- Attempt $attempt of $MAX_ATTEMPTS ---"

    # Use curl to call the API, pipe the response body to jq to get the state
    current_state=$(
      curl --silent --location "$API_URL" \
      -H "Authorization: Token token=$AUTH_TOKEN" \
      | jq -r "$JQ_FILTER_STATE" # Use the state filter
    )

    # Check if jq successfully extracted a non-empty state
    if [ -z "$current_state" ]; then
        echo "Warning: Failed to extract state or state is empty on attempt $attempt. Retrying..."
        # You might want to add a specific sleep here or break the loop on repeated errors
        state="" # Ensure state is not "finished" if extraction failed
    else
        state="$current_state" # Update the state variable
        echo "Current state: '$state'"
    fi

    # If the state is still not "finished" and we have more attempts left, wait
    if [ "$state" != "finished" ] && [ $attempt -lt $MAX_ATTEMPTS ]; then
        echo "State not 'finished'. Waiting ${POLLING_INTERVAL_SECONDS}s..."
        sleep "$POLLING_INTERVAL_SECONDS"
    fi

done # End of while loop

# --- Check the final result after the loop finishes ---

if [ "$state" = "finished" ]; then
    echo "Success: Build state is 'finished' after $attempt attempts."

    # --- NEW STEP: Extract and check total-comparisons-diff ---
    echo "Initiating final check: Extracting total-comparisons-diff..."

    # Make one more curl call to get the final complete JSON data
    # Pipe the response body to jq using the filter for the diff count
    comparisons_diff=$(
      curl --silent --location "$API_URL" \
      -H "Authorization: Token token=$AUTH_TOKEN" \
      | jq -r "$JQ_FILTER_DIFF" # Use the diff filter
    )

    # Basic validation: Check if the extracted value looks like a non-negative number
    # This prevents errors in the shell integer comparison below if extraction fails
    if ! [[ "$comparisons_diff" =~ ^[0-9]+$ ]]; then
        echo "Error: Failed to extract a valid non-negative number for total-comparisons-diff. Extracted: '$comparisons_diff'"
        exit 1 # Exit with failure status due to extraction/format error
    fi

    echo "Total comparisons diff found: $comparisons_diff"

    # Check if the diff is less than 10 using shell integer comparison (-lt)
    if [ "$comparisons_diff" -lt 10 ]; then
        echo "Validation successful: Total comparisons diff ($comparisons_diff) is less than 10."
        exit 0 # Exit with success status
    else
        echo "Validation failed: Total comparisons diff ($comparisons_diff) is NOT less than 10."
        exit 1 # Exit with failure status due to validation
    fi

else
    # This part handles the timeout if state never became 'finished'
    echo "Error: Build state did not become 'finished' within $MAX_ATTEMPTS attempts."
    echo "Final state after $MAX_ATTEMPTS attempts was: '$state'"
    exit 1 # Exit with failure status due to timeout
fi