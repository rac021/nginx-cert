#!/usr/bin/env bash

# When the script is interrupted, kill all child processes
trap "exit"   INT TERM  # Trap interrupt (Ctrl+C) and terminate signals to exit the script
trap "kill 0" EXIT      # Kill all background jobs when the script exits

# Get the current directory of the script
CURRENT_PATH="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd $CURRENT_PATH  # Change to the directory of the script

#####################################################
# Sourcing the scripts for certificate management  ##
#####################################################

# Include utility scripts that provide various functions and configurations
source "./utils/nginx.sh"
source "./utils/helper.sh"
source "./utils/cron_setup.sh"
source "./utils/ssl_cert_toolkit.sh"
source "./cert_managers/cert_zerossl.sh"
source "./cert_managers/cert_lets_encrypt.sh"

#####################################################
#####################################################

# Set the environment variable for the renewal threshold
CERTME_RENEWAL_THRESHOLD_DAYS=${CERTME_RENEWAL_THRESHOLD_DAYS:-30}  # Default value of 30 days
CERTME_PROXY_PASS_PORT=${CERTME_PROXY_PASS_PORT:-8080}  # Default proxy port

CERTME_ENABLE=${CERTME_ENABLE:-false}

# Set the environment variable for the staging flag
CERTME_STAGING=${CERTME_STAGING:-true}  # Default value of true

# Check if staging is enabled and set the staging flag
STAGING_FLAG=""
if [[ "${CERTME_STAGING}" == "true" ]]; then
    STAGING_FLAG="--staging"
fi

# Check if force renewal is enabled
CERTME_FORCE_RENEW=${CERTME_FORCE_RENEW:-false}
FORCE_RENEW_FLAG=""
if [[ "${CERTME_FORCE_RENEW}" == "true" ]]; then
    FORCE_RENEW_FLAG="--force-renewal"
fi

# Set CERTME_CRON_SCHEDULE to run by default every day at 2am
CERTME_CRON_SCHEDULE="${CERTME_CRON_SCHEDULE:-0 2 * * *}"

## LOCAL VARIABLES 
PRIV_KEY_NAME="privkey.pem"           # Name of the private key file
FULL_CHAIN_NAME="fullchain.pem"       # Name of the full chain file
CHAIN_NAME="chain.pem"                # Name of the chain file
CSR_NAME="csr.pem"                    # Certificate Signing Request name
LE_ROOT_PATH="/etc/letsencrypt/live"  # Root path for Let's Encrypt certificates

###################################
###################################

# Function to renew the certificate
renew_certificate() {

    local cert_path="$LE_ROOT_PATH/${CERTME_DOMAINS}/$FULL_CHAIN_NAME"  # Path to the certificate 'fullchain.pem'

    # Check if the domain is an IP address
    if is_ip "${CERTME_DOMAINS}"; then
        # Check if ZeroSSL EAB (External Account Binding) variables are set and certificate should be renewed
        if [[ -n "${CERTME_ZEROSSL_API_KEY}" ]]; then
            print_message "🔔 ZeroSSL configuration detected for IP ${CERTME_DOMAINS}. Attempting ZeroSSL certificate issuance.."
            # Renew ZeroSSL certificate if needed
            if should_renew_certificate "$cert_path" "$CERTME_RENEWAL_THRESHOLD_DAYS"; then
                request_renew_zero_certificate  # Function to request renewal from ZeroSSL
            else
                echo "🔒 The ZeroSSL certificate for ${CERTME_DOMAINS} is valid for more than ${CERTME_RENEWAL_THRESHOLD_DAYS} days"
                echo "  No renewal needed."
                echo
            fi
            
        # Check if force renewal is enabled or if the certificate needs renewal
        elif [[ "${CERTME_FORCE_RENEW}" == "true" ]] || should_renew_certificate "$cert_path" "$CERTME_RENEWAL_THRESHOLD_DAYS"; then
            print_message "🌐 ${CERTME_DOMAINS} is an IP or localhost. Generating a self-signed certificate.."
            # Function to create self-signed certificate
            create_self_signed_certificate "${CERTME_DOMAINS}" "$LE_ROOT_PATH" "$PRIV_KEY_NAME" "$FULL_CHAIN_NAME"
        else
            print_message "🔒 The self-signed certificate for ${CERTME_DOMAINS} is valid for more than ${CERTME_RENEWAL_THRESHOLD_DAYS} days"
            echo "  No renewal needed."
        fi
    else
        # If the domain is not an IP, check if the certificate needs renewal
        if [[ "${CERTME_FORCE_RENEW}" == "true" ]] || should_renew_certificate "$cert_path" "$CERTME_RENEWAL_THRESHOLD_DAYS"; then
            print_message "🔔 The certificate for ${CERTME_DOMAINS} needs renewal."
            request_renew_letsencrypt_certificate  # Function to request renewal from Let's Encrypt
        else
            print_message "🔒 The certificate for ${CERTME_DOMAINS} is valid for more than ${CERTME_RENEWAL_THRESHOLD_DAYS} days."
            echo "  No renewal needed."
        fi
    fi
}

# Function to request the first certificate
first_certificate() {
    # Check if CERTME_DOMAINS is an IP and if ZeroSSL variables are set
    if is_ip "${CERTME_DOMAINS}"; then
        if [[ -n "${CERTME_ZEROSSL_API_KEY}" ]]; then
            request_first_zero_certificate true  # Start HTTP server on port 80 for ZeroSSL
        else
            echo "⚠️ Missing ZeroSSL credentials. Generating a self-signed certificate for ${CERTME_DOMAINS}."
            # Function to create self-signed certificate
            create_self_signed_certificate "${CERTME_DOMAINS}" "$LE_ROOT_PATH" "$PRIV_KEY_NAME" "$FULL_CHAIN_NAME" 
        fi
    else
        # If CERTME_DOMAINS is not an IP, request the first certificate with Certbot
        request_first_letsencrypt_certificate  # Function to request first certificate from Let's Encrypt
    fi
}

#####################################################################
# Cert_Main function to handle certificate requests and renewals  ###
#####################################################################
main_certificate_manager() {

    local domain_dir="$LE_ROOT_PATH/${CERTME_DOMAINS}"  # Directory for the domain's certificates
    local cert_path="$domain_dir/$FULL_CHAIN_NAME"
    
    if [ ! -f "${cert_path}" ]; then
        echo "🗂️  Certificate '$FULL_CHAIN_NAME' not found in '$cert_path' for the domain ${CERTME_DOMAINS}. Generating the first certificate.."
        echo
        first_certificate  # Call to request the first certificate
    else
        echo "📄 Certificate ${CERTME_DOMAINS} already exists for ${CERTME_DOMAINS} in $cert_path. Checking renewal status.."
        echo
        renew_certificate  # Call to check and renew the certificate if needed
    fi
}

##############################################
# function to handle certificate renewals  ###
##############################################
renew_cert_main() {
    echo "🔄 Starting certificate renewal process.."
    main_certificate_manager  # Call to handle main certificate renewal logic
    reload_nginx              # Function to reload Nginx configuration
}

#######################################################
# function to handle the first certificate request  ###
#######################################################
first_cert_main() {
    print_message "🚀 Initiating first-time certificate setup.."
    main_certificate_manager  # Call to handle the first certificate setup
    start_nginx               # Function to start Nginx server
}
    
##############
## MAIN ######
##############
    
# Display user configuration summary
echo
echo "---------------------------------------------------------------"
echo "📋 Configuration Summary  :                                     "
echo "---------------------------------------------------------------"
echo " ENABLE           ( CERTME_ENABLE                 ) : ${CERTME_ENABLE}"      # Display if CertMe is enabled
echo " Domains          ( CERTME_DOMAINS                ) : ${CERTME_DOMAINS}"     # Display domains managed by CertMe
echo " Email            ( CERTME_EMAIL                  ) : ${CERTME_EMAIL}"       # Display email for CertMe notifications
echo " Staging Mode     ( CERTME_STAGING                ) : ${CERTME_STAGING}"     # Display staging mode status
echo " Force Renew      ( CERTME_FORCE_RENEW            ) : ${CERTME_FORCE_RENEW}" # Display if forced renewal is enabled
echo " Nginx Proxy Port ( CERTME_PROXY_PASS_PORT        ) : ${CERTME_PROXY_PASS_PORT}"        # Display the port used by the Nginx proxy
echo " Threshold Days   ( CERTME_RENEWAL_THRESHOLD_DAYS ) : ${CERTME_RENEWAL_THRESHOLD_DAYS}" # Display renewal threshold

# Display ZeroSSL configuration if environment variables are set
if [[ -n "${CERTME_ZEROSSL_API_KEY}" ]]; then
    echo "---------------------------------------------------------------"
    # Display ZeroSSL API key if set
    echo " ZERO SSL API     ( CERTME_ZEROSSL_API_KEY        ) : ${CERTME_ZEROSSL_API_KEY}" 
fi
echo "---------------------------------------------------------------"
echo

# If CERTME_ENABLE is not set to true, skip CertMe setup and start Nginx
if [[ "${CERTME_ENABLE}" != "true" ]]; then
    
    print_message "CERTME_ENABLE is not set to true. Skipping CertMe setup and starting Nginx."
    start_nginx  # Function to start the Nginx server

# Exit if CERTME_DOMAINS is empty and CERTME_ENABLE is set to true
elif [[ "${CERTME_ENABLE}" == "true" && -z "$CERTME_DOMAINS" ]]; then
    
    # Error message
    print_message "❌ CERTME_ENABLE is set to true but no CERTME_DOMAINS provided. Exiting." 
    exit 1  # Exit the script with error

# If no arguments are provided, set up cron job and initialize the first certificate
elif [ $# -eq 0 ]; then
    
    print_message "📝 Setting up cron job for automatic renewals."
    SCRIPT_NAME=$(basename "$0")  # Get the name of the current script
    configure_cron_job "$CERTME_CRON_SCHEDULE" "/opt/certme/${SCRIPT_NAME} renew >> /opt/certme/renew.info" 
    first_cert_main

else # Renew the certificate - Called by crontab
    
    print_message "🔄 Running renewal process..."
    renew_cert_main
fi
