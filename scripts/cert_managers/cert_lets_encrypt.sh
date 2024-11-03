#!/bin/bash

####################
### LETS_ENCRYPT ###
####################

# Function to request a new certificate with Certbot
request_first_letsencrypt_certificate() {
    print_message "/ Requesting a new certificate with Certbot/Standalone on port 80 ..."
    echo
    certbot certonly --standalone               \
                     --email "${CERTME_EMAIL}"  \
                     -d "${CERTME_DOMAINS}"     \
                     --agree-tos                \
                     ${STAGING_FLAG}            \
                     --non-interactive          \
                     --key-type ecdsa           \
                     --http-01-port 80          \
                     --preferred-challenges http
}

# Function to force renew the certificate with Certbot
request_renew_letsencrypt_certificate() {
    echo "Attempting to renew certificate for ${CERTME_DOMAINS}..."
    echo
    pkill certbot
    sleep 1
    local attempt=1
    local max_attempts=3
    local success=false

    while (( attempt <= max_attempts )); do
        echo "🔄 Attempt ${attempt} of ${max_attempts}..."
        
        if certbot renew ${FORCE_RENEW_FLAG} --non-interactive ${STAGING_FLAG} --http-01-port $CERTME_PROXY_PASS_PORT 2>&1 | tee /dev/stderr; then
            print_message "✅ Certificate renewed successfully for ${CERTME_DOMAINS}."
            success=true
            break
        else
            echo "❌ Attempt ${attempt} failed. Retrying in 5 seconds..."
            ((attempt++))
            sleep 3
        fi
    done

    if ! $success; then
        print_message "❌ All renewal attempts failed for ${CERTME_DOMAINS}."
        echo "📝 Check the output above for details."
    fi

    pkill certbot
    rm -f /var/lib/letsencrypt/.certbot.lock 
}
