#!/bin/bash

# --- Configuration ---
PERCY_BUILD_ID="$PERCY_BUILD_ID"
echo "Using PERCY_BUILD_ID: $PERCY_BUILD_ID"

API_URL="https://percy.io/api/v1/builds/${PERCY_BUILD_ID}"
echo "Using Percy API URL: $API_URL"

# !! Replace 'xxx' with your actual Authorization token !!
AUTH_TOKEN="$PERCY_TOKEN"
echo "Token : $PERCY_TOKEN"

# The jq filter to extract the state field
JQ_FILTER_STATE='.data.attributes.state'
# The jq filter to extract the total-comparisons-diff field
JQ_FILTER_DIFF='.data.attributes."total-comparisons-diff"'
# The jq filter to extract the total-comparisons-finished field
JQ_FILTER_FINISHED='.data.attributes."total-comparisons-finished"'
# Polling interval in seconds
POLLING_INTERVAL_SECONDS=10
# Maximum number of attempts before giving up
MAX_ATTEMPTS=60 # e.g., 60 attempts * 10 seconds = 10 minutes timeout
# Threshold percentage for failure
FAILURE_THRESHOLD_PERCENTAGE=50

# --- Script ---

# Set -e: Exit immediately if a command exits with a non-zero status.
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

    # --- NEW STEP: Extract total-comparisons-diff and total-comparisons-finished ---
    echo "Initiating final check: Extracting comparison metrics..."

    build_data=$(
      curl --silent --location "$API_URL" \
      -H "Authorization: Token token=$AUTH_TOKEN"
    )

    comparisons_diff=$(echo "$build_data" | jq -r "$JQ_FILTER_DIFF")
    comparisons_finished=$(echo "$build_data" | jq -r "$JQ_FILTER_FINISHED")

    # Basic validation: Check if the extracted values look like non-negative numbers
    if ! [[ "$comparisons_diff" =~ ^[0-9]+$ ]] || ! [[ "$comparisons_finished" =~ ^[0-9]+$ ]]; then
        echo "Error: Failed to extract valid non-negative numbers for comparisons. Diff: '$comparisons_diff', Finished: '$comparisons_finished'"
        exit 1 # Exit with failure status due to extraction/format error
    fi

    echo "Total comparisons diff found: $comparisons_diff"
    echo "Total comparisons finished: $comparisons_finished"

    # Calculate the percentage of difference
    if [ "$comparisons_finished" -gt 0 ]; then
        percentage_diff=$(echo "scale=2; ($comparisons_diff / $comparisons_finished) * 100" | bc)
        echo "Percentage of difference: $percentage_diff%"

        # Check if the percentage exceeds the threshold
        if (( $(echo "$percentage_diff" | bc -l) > $(echo "$FAILURE_THRESHOLD_PERCENTAGE" | bc -l) )); then
            echo "Validation failed: Percentage of difference ($percentage_diff%) exceeds the threshold ($FAILURE_THRESHOLD_PERCENTAGE%)."
            exit 1 # Exit with failure status due to validation
        else
            echo "Validation successful: Percentage of difference ($percentage_diff%) is within the threshold ($FAILURE_THRESHOLD_PERCENTAGE%)."
            exit 0 # Exit with success status
        fi
    else
        echo "Warning: Total comparisons finished is 0. Unable to calculate percentage difference. Proceeding with success."
        exit 0 # Exit with success status to avoid division by zero
    fi

else
    # This part handles the timeout if state never became 'finished'
    echo "Error: Build state did not become 'finished' within $MAX_ATTEMPTS attempts."
    echo "Final state after $MAX_ATTEMPTS attempts was: '$state'"
    exit 1 # Exit with failure status due to timeout
fi
