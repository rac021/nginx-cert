#!/bin/bash

################
### ZERO_SSL ###
################

# Function to request the first certificate with ZeroSSL API
request_first_zero_certificate() {

    local should_start_server="$1"  # Add parameter to control server start/stop

    echo "🔑 Requesting the certificate with ZeroSSL for IP ${CERTME_DOMAINS} ..."
    
    # Create directory if not exists
    mkdir -p "$LE_ROOT_PATH/${CERTME_DOMAINS}"

    # Generate SSL files
    if [ ! -f "$LE_ROOT_PATH/${CERTME_DOMAINS}/$CSR_NAME"  ]; then
         create_private_key_with_csr "${CERTME_DOMAINS}" "$LE_ROOT_PATH" "$CSR_NAME" "$PRIV_KEY_NAME"
    fi
    
    if [ ! -f "$LE_ROOT_PATH/${CERTME_DOMAINS}/$CSR_NAME"  ]; then
         echo "❌ Failed to generate [ $LE_ROOT_PATH/${CERTME_DOMAINS}/$CSR_NAME ] ! "
         exit 1
    fi
    if [ ! -f "$LE_ROOT_PATH/${CERTME_DOMAINS}/$PRIV_KEY_NAME" ]; then
         echo "❌ Failed to generate [ $LE_ROOT_PATH/${CERTME_DOMAINS}/$PRIV_KEY_NAME ] ! "
         exit 2
    fi
 
    # Draft certificate at ZeroSSL
    local response=$( curl -s -X POST "https://api.zerossl.com/certificates?access_key=${CERTME_ZEROSSL_API_KEY}" \
                              -d "certificate_domains=${CERTME_DOMAINS}" \
                              -d "certificate_validity_days=90"          \
                              --data-urlencode certificate_csr@$LE_ROOT_PATH/${CERTME_DOMAINS}/$CSR_NAME )
    echo
    echo "Response :"
    echo "$response"
    echo
    
    # Extract certificate ID from response
    local cert_id=$(echo "${response}" | jq -r '.id')
    if [ -z "$cert_id" ] || [ "$cert_id" == "null" ]; then
         echo "❌ Failed to request certificate: ${response}"
         return 1
    fi

    # Extract challenge details
    validation_url_http=$(echo "${response}" | jq -r '.validation.other_methods["'"${CERTME_DOMAINS}"'"].file_validation_url_http')
    validation_content=$(echo "${response}"  | jq -r '.validation.other_methods["'"${CERTME_DOMAINS}"'"].file_validation_content | join("\n")')

    echo
    echo "cert_id                    : ${cert_id}          "
    echo "Validation File URL (HTTP) : $validation_url_http"
    echo "Validation Content         : "
    echo "$validation_content          "
    echo
    
    # Ensure that the extracted information is not empty
    if [ -z "$validation_url_http" ] || [ -z "$validation_content" ]; then
         echo "❌ Validation data is missing in response!"
         return 1
    fi
    
    # Create validation file for HTTP challenge
    local validation_path="/var/www/html/.well-known/pki-validation"
    mkdir -p "$validation_path"
    echo "$validation_content" > "${validation_path}/${validation_url_http##*/}"
    
    # Start a restricted HTTP server if should_start_server is true
    local SERVER_PID
    if [ "$should_start_server" = true ]; then
        echo "🚀 Starting HTTP server on port 80 to serve the validation file..."
        python3 -m http.server 80 --directory "/var/www/html" --bind 0.0.0.0 &
        SERVER_PID=$!
    fi

    echo "⏳ Waiting for domain validation..."
    sleep 30  # Allow time for the validation file to propagate
    
    # Call Validation - Validate certificate at ZeroSSL
    echo
    echo "Call Validation :"
    curl -s -X POST "https://api.zerossl.com/certificates/${cert_id}/challenges?access_key=${CERTME_ZEROSSL_API_KEY}" \
            -d "validation_method=HTTP_CSR_HASH" 
    
    # Wait for cert to be issued
    sleep 30
        
    # Download certificate after validation
    local cert_response=$(curl -s -X GET "https://api.zerossl.com/certificates/${cert_id}/download/return?access_key=${CERTME_ZEROSSL_API_KEY}" \
                                  -H "Content-Type: application/x-www-form-urlencoded")

    echo 
    echo "Response : $cert_response"
    echo

    # Temporary paths for new certificates
    TEMP_FULL_CHAIN="${LE_ROOT_PATH}/${CERTME_DOMAINS}/temp_${FULL_CHAIN_NAME}"
    TEMP_CHAIN="${LE_ROOT_PATH}/${CERTME_DOMAINS}/temp_${CHAIN_NAME}"

    # Save the new certificate files to temporary locations
    echo "${cert_response}" | jq -r '.["certificate.crt"]' > "$TEMP_FULL_CHAIN"
    echo "${cert_response}" | jq -r '.["ca_bundle.crt"]'   > "$TEMP_CHAIN"

    # Check if both certificate files exist
    if [[ -f "$TEMP_FULL_CHAIN" && -f "$TEMP_CHAIN" ]]; then
         # Check if the new certificates were created successfully and are valid
         if openssl x509 -in "$TEMP_FULL_CHAIN" -noout && openssl x509 -in "$TEMP_CHAIN" -noout; then       
              echo "✅ Success ! Certificate successfully generated and installed"
              # Move the validated certificates to their final locations
              mv "$TEMP_FULL_CHAIN" "$LE_ROOT_PATH/${CERTME_DOMAINS}/$FULL_CHAIN_NAME"
              mv "$TEMP_CHAIN"      "$LE_ROOT_PATH/${CERTME_DOMAINS}/$CHAIN_NAME"
         else
              echo "❌ Error : Certificate files were not generated. Retaining existing certificates ( if available )"
              rm -rf "$TEMP_FULL_CHAIN" "$TEMP_CHAIN"
         fi
    else
         echo "❌ Error : Certificate files were not generated. Retaining existing certificates ( if available )"
         rm -rf "$TEMP_FULL_CHAIN" "$TEMP_CHAIN"  # Optionally remove temp files if they were created but invalid
    fi
    
    # Stop the HTTP server if it was started
    if [ "$should_start_server" = true ]; then
        echo "🛑 Stopping HTTP server..."
        kill "$SERVER_PID"
    fi

    # Clean up
    rm -f "${validation_path}/${validation_url_http##*/}"
}

# Function to renew an existing certificate with ZeroSSL API
request_renew_zero_certificate() {
    
    echo "Renewing the certificate with ZeroSSL for IP ${CERTME_DOMAINS} "
    
    # We'll just request a new certificate since ZeroSSL API doesn't have a specific renewal endpoint
    request_first_zero_certificate false # http server already started ( nginx on the port 80 )
}
