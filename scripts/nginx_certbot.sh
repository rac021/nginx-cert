#!/usr/bin/env bash

# When the script is interrupted, kill all child processes
trap "exit" INT TERM
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
    if certbot renew ${FORCE_RENEW_FLAG} --non-interactive ${STAGING_FLAG} --http-01-port $NGINX_PROXY_PASS_PORT 2>&1 | tee /dev/stderr; then
       print_message "✅ Certificate renewed successfully for ${CERTBOT_DOMAINS}."
    else
        print_message "❌ Certificate renewal failed for ${CERTBOT_DOMAINS}."
        echo "📝 Check the output above for details."
    fi
    pkill certbot
    rm -f /var/lib/letsencrypt/.certbot.lock 
}

# Function to renew the certificate
renew_certificate() {

    local cert_path="/etc/letsencrypt/live/${CERTBOT_DOMAINS}/fullchain.pem"
    
    if is_ip "${CERTBOT_DOMAINS}"; then
        # Check for self-signed certificate expiration before generating a new one
        if [[ "${FORCE_RENEW}" == "true" ]] || should_renew_cert "$cert_path"; then
            print_message "🌐 ${CERTBOT_DOMAINS} is an IP or localhost. Generating a self-signed certificate..."
            generate_self_signed_cert "${CERTBOT_DOMAINS}"
        else
            print_message "🔒 The self-signed certificate for ${CERTBOT_DOMAINS} is valid for more than ${RENEWAL_THRESHOLD_DAYS} days. No renewal needed."
        fi
    else
        if [[ "${FORCE_RENEW}" == "true" ]] || should_renew_cert "${cert_path}"; then
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
    local cron_job="* * * * * bash /opt/$SCRIPT_NAME renew >> /opt/renew.info"
    (crontab -l | grep -F "$cron_job") || (crontab -l; echo "$cron_job") | crontab -
    echo "🕒 Cron job configured to check certificate renewal every minute."
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
        if is_ip "${CERTBOT_DOMAINS}"; then
            generate_self_signed_cert "${CERTBOT_DOMAINS}"
        else
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
echo "---------------------------------------------"
echo

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
