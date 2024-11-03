#!/usr/bin/env bash

# When the script is interrupted, kill all child processes
trap "exit"   INT TERM
trap "kill 0" EXIT

# Set the environment variable for the renewal threshold
RENEWAL_THRESHOLD_DAYS=${RENEWAL_THRESHOLD_DAYS:-30}  # Default value of 30 days
NGINX_PROXY_PASS_PORT=${NGINX_PROXY_PASS_PORT:-8080}

# Set the environment variable for the staging flag
STAGING=${STAGING:-true}  # Default value of true

# Check if staging is enabled
STAGING_FLAG=""
if [[ "${STAGING}" == "true" ]]; then
    STAGING_FLAG="--staging"
fi

# Check if force renewal is enabled
FORCE_RENEW_FLAG=""
if [[ "${FORCE_RENEW}" == "true" ]]; then
    FORCE_RENEW_FLAG="--force-renewal"
fi

# Set CRON_SCHEDULE to run by default every day at 2am
CRON_SCHEDULE="${CRON_SCHEDULE:-0 2 * * *}"

# Function to print messages in a box
print_message() {
    local message="$1"
    local length=${#message}
    local border_length=$((length + 2)) # Adding space for padding
    local border=$(printf '━%.0s' $(seq 1 $border_length))
    
    echo "╭${border}╮"
    echo "│$message │"
    echo "╰${border}╯"
}

# Function to check if a certificate needs renewal
should_renew_cert() {
    local cert_path="$1"
    # Check if the certificate expires in less than RENEWAL_THRESHOLD_DAYS days
    if ! openssl x509 -noout -checkend $((RENEWAL_THRESHOLD_DAYS * 86400)) -in "${cert_path}"; then
        return 0  # The certificate should be renewed
    else
        return 1  # No need to renew
    fi
}

# Function to check if the argument is an IP address (IPv4 only) or "localhost"
is_ip() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || [ "$1" = "localhost" ]
}

# Function to generate a self-signed certificate
generate_self_signed_cert() {
    local domain="$1"
    print_message "Generating a self-signed certificate for ${domain}.."
    mkdir -p "/etc/letsencrypt/live/${domain}"
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
                -keyout "/etc/letsencrypt/live/${domain}/privkey.pem" \
                -out  "/etc/letsencrypt/live/${domain}/fullchain.pem" \
                -subj "/CN=${domain}"
}

####################
### LETS_ENCRYPT ###
####################

# Function to request a new certificate with Certbot
request_first_certbot_certificate() {
    print_message "/ Requesting a new certificate with Certbot..."
    echo
    certbot certonly --standalone               \
                     --email "${CERTBOT_EMAIL}" \
                     -d "${CERTBOT_DOMAINS}"    \
                     --agree-tos                \
                     ${STAGING_FLAG}            \
                     --non-interactive          \
                     --key-type ecdsa           \
                     --http-01-port 80          \
                     --preferred-challenges http
}

# Function to force renew the certificate with Certbot
request_renew_certbot_certificate() {
    echo "Attempting to renew certificate for ${CERTBOT_DOMAINS}..."
    echo
    pkill certbot
    sleep 1
    local attempt=1
    local max_attempts=3
    local success=false

    while (( attempt <= max_attempts )); do
        echo "🔄 Attempt ${attempt} of ${max_attempts}..."
        
        if certbot renew ${FORCE_RENEW_FLAG} --non-interactive ${STAGING_FLAG} --http-01-port $NGINX_PROXY_PASS_PORT 2>&1 | tee /dev/stderr; then
            print_message "✅ Certificate renewed successfully for ${CERTBOT_DOMAINS}."
            success=true
            break
        else
            echo "❌ Attempt ${attempt} failed. Retrying in 5 seconds..."
            ((attempt++))
            sleep 3
        fi
    done

    if ! $success; then
        print_message "❌ All renewal attempts failed for ${CERTBOT_DOMAINS}."
        echo "📝 Check the output above for details."
    fi

    pkill certbot
    rm -f /var/lib/letsencrypt/.certbot.lock 
}

################
### ZERO_SSL ###
################

# Function to generate CSR and private key
generate_ssl_files() {
    
    local domain=$1
    echo "📝 Generating private key and CSR for ${domain}..."
    
    # Create CSR and Private Key
    openssl req -new -newkey rsa:2048 -nodes \
                -out    "/etc/letsencrypt/live/${domain}/csr.pem"     \
                -keyout "/etc/letsencrypt/live/${domain}/privkey.pem" \
                -subj "/C=FR/ST=Paris/L=Paris/O=INRAE/OU=InfoSol/CN=${domain}" 
}

# Function to request the first certificate with ZeroSSL API
request_first_zero_certificate() {

    echo "🔑 Requesting the certificate with ZeroSSL for IP ${CERTBOT_DOMAINS}..."
    
    # Create directory if not exists
    mkdir -p "/etc/letsencrypt/live/${CERTBOT_DOMAINS}"
    
    # Generate SSL files
    if [ ! -f "/etc/letsencrypt/live/${CERTBOT_DOMAINS}/csr.pem"  ]; then
         generate_ssl_files "${CERTBOT_DOMAINS}"
    fi
    
    if [ ! -f "/etc/letsencrypt/live/${CERTBOT_DOMAINS}/csr.pem"  ]; then
         echo "❌ Failed to generate [ /etc/letsencrypt/live/${CERTBOT_DOMAINS}/csr.pem ] ! "
         exit 1
    fi
    if [ ! -f "/etc/letsencrypt/live/${CERTBOT_DOMAINS}/privkey.pem" ]; then
         echo "❌ Failed to generate [ /etc/letsencrypt/live/${CERTBOT_DOMAINS}/privkey.pem ] ! "
         exit 2
    fi
 
    # Draft certificate at ZeroSSL
    local response=$( curl -s -X POST "https://api.zerossl.com/certificates?access_key=${ZEROSSL_API_KEY}" \
                              -d "certificate_domains=${CERTBOT_DOMAINS}" \
                              -d "certificate_validity_days=90" \
                              --data-urlencode certificate_csr@/etc/letsencrypt/live/${CERTBOT_DOMAINS}/csr.pem )
    echo
    echo "Response..."
    echo "$response"
    echo
    
    # Extract certificate ID from response
    local cert_id=$(echo "${response}" | jq -r '.id')
    if [ -z "$cert_id" ] || [ "$cert_id" == "null" ]; then
         echo "❌ Failed to request certificate: ${response}"
         return 1
    fi

    # Extract challenge details
    validation_url_http=$(echo "${response}" | jq -r '.validation.other_methods["'"${CERTBOT_DOMAINS}"'"].file_validation_url_http')
    validation_content=$(echo "${response}"  | jq -r '.validation.other_methods["'"${CERTBOT_DOMAINS}"'"].file_validation_content | join("\n")')

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
    
    # Start a restricted HTTP server to serve the validation file
    echo "🚀 Starting HTTP server on port 80 to serve the validation file..."
    python3 -m http.server 80 --directory "/var/www/html" --bind 0.0.0.0 &
    SERVER_PID=$!

    echo "⏳ Waiting for domain validation..."
    sleep 30  # Allow time for the validation file to propagate
    
    # Call Validation - Validate certificate at ZeroSSL
    echo
    echo "Call Validation.."
    curl -s -X POST "https://api.zerossl.com/certificates/${cert_id}/challenges?access_key=${ZEROSSL_API_KEY}" \
            -d "validation_method=HTTP_CSR_HASH" 
    
    # Wait for cert to be issued
    sleep 30
        
    # Download certificate after validation
    local cert_files=$(curl -s -X GET "https://api.zerossl.com/certificates/${cert_id}/download/return?access_key=${ZEROSSL_API_KEY}" \
                               -H "Content-Type: application/x-www-form-urlencoded")

    echo 
    echo "cert_files == $cert_files"
    echo

    # Save certificate files
    echo "${cert_files}" | jq -r '.["certificate.crt"]' > "/etc/letsencrypt/live/${CERTBOT_DOMAINS}/fullchain.pem"
    echo "${cert_files}" | jq -r '.["ca_bundle.crt"]'   > "/etc/letsencrypt/live/${CERTBOT_DOMAINS}/chain.pem"

    # Stop the HTTP server
    echo "🛑 Stopping HTTP server..."
    kill "$SERVER_PID"
    
    # Clean up
    rm -f "${validation_path}/${validation_url_http##*/}"

    
    # Check if the files were created successfully
    if [ -f "/etc/letsencrypt/live/${CERTBOT_DOMAINS}/fullchain.pem" ] && [ -f "/etc/letsencrypt/live/${CERTBOT_DOMAINS}/chain.pem" ]; then
         echo "✅ Success ! Certificate successfully generated and installed"
    else
         echo "❌ Error : Certificate files were not generated."
    fi
}

# Function to renew an existing certificate with ZeroSSL API
request_renew_zero_certificate() {
    
    echo "🔑 Renewing the certificate with ZeroSSL for IP ${CERTBOT_DOMAINS}..."
    # We'll just request a new certificate since ZeroSSL API doesn't have a specific renewal endpoint
    request_first_zero_certificate
}


# Function to renew the certificate
renew_certificate() {
    
    local cert_path="/etc/letsencrypt/live/${CERTBOT_DOMAINS}/fullchain.pem"

    if is_ip "${CERTBOT_DOMAINS}"; then
        # Check if ZeroSSL EAB variables are set and certificate should be renewed
        if [[ -n "${ZEROSSL_API_KEY}" ]]; then
            print_message "🔔 ZeroSSL configuration detected for IP ${CERTBOT_DOMAINS}. Attempting ZeroSSL certificate issuance.."
            if should_renew_cert "$cert_path"; then
               request_renew_zero_certificate
            else
              echo "🔒 The ZeroSSL certificate for ${CERTBOT_DOMAINS} is valid for more than ${RENEWAL_THRESHOLD_DAYS} days. No renewal needed."
              echo
            fi
            
        elif [[ "${FORCE_RENEW}" == "true" ]] || should_renew_cert "$cert_path"; then
            print_message "🌐 ${CERTBOT_DOMAINS} is an IP or localhost. Generating a self-signed certificate.."
            generate_self_signed_cert "${CERTBOT_DOMAINS}"
        else
            print_message "🔒 The self-signed certificate for ${CERTBOT_DOMAINS} is valid for more than ${RENEWAL_THRESHOLD_DAYS} days. No renewal needed."
        fi
    else
        if [[ "${FORCE_RENEW}" == "true" ]] || should_renew_cert "$cert_path"; then
            print_message "🔔 The certificate for ${CERTBOT_DOMAINS} needs renewal."
            request_renew_certbot_certificate
        else
            print_message "🔒 The certificate for ${CERTBOT_DOMAINS} is valid for more than ${RENEWAL_THRESHOLD_DAYS} days. No renewal needed."
        fi
    fi
}

start_nginx() {
    echo
    print_message "🚀 Starting Nginx server.."
    echo
    nginx -g "daemon off;"
}

reload_nginx() {
    print_message "🔄 Reloading Nginx configuration..."
    nginx -s reload
    echo
}

# Function to configure a cron job that runs renew_cert_main every minute
configure_cron_job() {
    SCRIPT_NAME=$(basename "$0")
    local cron_job="$CRON_SCHEDULE bash /opt/$SCRIPT_NAME renew >> /opt/renew.info"
    (crontab -l | grep -F "$cron_job") || (crontab -l; echo "$cron_job") | crontab -
    echo "🕒 Cron job configured to check certificate renewal : $CRON_SCHEDULE"
    echo
    crond start
}

#####################################################################
# Cert_Main function to handle certificate requests and renewals  ###
#####################################################################

gen_cert() {
    local domain_dir="/etc/letsencrypt/live/${CERTBOT_DOMAINS}"

    if [ ! -d "${domain_dir}" ]; then
        echo "🗂️  Directory for ${CERTBOT_DOMAINS} does not exist. Generating the first certificate.."
        echo

        # Vérifier si CERTBOT_DOMAINS est une IP et que les variables ZeroSSL sont définies
        if is_ip "${CERTBOT_DOMAINS}"; then
            if [[ -n "${ZEROSSL_API_KEY}" ]]; then
                request_first_zero_certificate
            else
                echo "⚠️ Missing ZeroSSL credentials. Generating a self-signed certificate for ${CERTBOT_DOMAINS}."
                generate_self_signed_cert "${CERTBOT_DOMAINS}"
            fi
        else
            # Si CERTBOT_DOMAINS n'est pas une IP, demander le premier certificat avec Certbot
            request_first_certbot_certificate
        fi
    else
        echo "📄 Certificate directory exists for ${CERTBOT_DOMAINS}. Checking renewal status.."
        echo
        renew_certificate
    fi
}


###########################################################################
# Renew_Cert_Main function to handle certificate requests and renewals  ###
###########################################################################
renew_cert_main() {
    echo "🔄 Starting certificate renewal process.."
    gen_cert
    reload_nginx
}

##############################
# First_Cert_Main function ###
##############################
first_cert_main() {
    print_message "🚀 Initiating first-time certificate setup.."
    gen_cert
    start_nginx
}
    
##############
## MAIN ######
##############
    
# Display user configuration summary
echo
echo "---------------------------------------------"
echo "📋 Configuration Summary  :                   "
echo "---------------------------------------------"
echo " Email for Certbot       : ${CERTBOT_EMAIL}"
echo " Domains for Certbot     : ${CERTBOT_DOMAINS}"
echo " Nginx Proxy Pass Port   : ${NGINX_PROXY_PASS_PORT}"
echo " Renewal Threshold Days  : ${RENEWAL_THRESHOLD_DAYS}"
echo " Force Renew             : ${FORCE_RENEW}"
echo " Staging Mode            : ${STAGING}"

# Display ZeroSSL configuration if environment variables are set
if [[ -n "${ZEROSSL_API_KEY}" ]]; then
    echo "---------------------------------------------"
    echo " ZEROSSL_API_KEY         : ${ZEROSSL_API_KEY}"
fi
echo "---------------------------------------------"
echo

if [[ -z "$CERTBOT_DOMAINS" ]]; then
    print_message "❌ No CERTBOT_DOMAINS provided. Empty variable 'CERTBOT_DOMAINS' !"
    echo
    exit 1
fi

# Check if RUN_CERTBOT is set to true; if not, execute command and exit
if [[ "${RUN_CERTBOT}" != "true" ]]; then
    print_message "RUN_CERTBOT is not set to true. Skipping Certbot setup."
    start_nginx
# Check if any argument was passed to the script
elif [ $# -eq 0 ]; then    
    print_message "📝 Setting up cron job for automatic renewals."
    configure_cron_job
    first_cert_main
else
    print_message "🔄 Running renewal process..."
    renew_cert_main
fi
