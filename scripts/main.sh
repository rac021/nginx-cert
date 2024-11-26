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
source "./cert_managers/zerossl.sh"
source "./cert_managers/lets_encrypt.sh"

#####################################################
#####################################################

# Set the environment variable for the renewal threshold
CERT_RENEWAL_THRESHOLD_DAYS=${CERT_RENEWAL_THRESHOLD_DAYS:-30}  # Default value of 30 days
CERT_PROXY_PASS_PORT=${CERT_PROXY_PASS_PORT:-8080}  # Default proxy port

CERT_ENABLE=${CERT_ENABLE:-false}

CERT_SELF_SIGNED_CERTIFICATE=${CERT_SELF_SIGNED_CERTIFICATE:-false}

# Set the environment variable for the staging flag
CERT_STAGING=${CERT_STAGING:-true}  # Default value of true

# Check if staging is enabled and set the staging flag
STAGING_FLAG=""
if [[ "${CERT_STAGING}" == "true" ]]; then
    STAGING_FLAG="--staging"
fi

# Check if force renewal is enabled
CERT_FORCE_RENEW=${CERT_FORCE_RENEW:-false}
FORCE_RENEW_FLAG=""
if [[ "${CERT_FORCE_RENEW}" == "true" ]]; then
    FORCE_RENEW_FLAG="--force-renewal"
fi

# Set CERT_CRON_SCHEDULE to run by default every day at 2am
CERT_CRON_SCHEDULE="${CERT_CRON_SCHEDULE:-0 2 * * *}"

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

    local cert_path="$LE_ROOT_PATH/${CERT_DOMAINS}/$FULL_CHAIN_NAME"  # Path to the certificate 'fullchain.pem'

    # Check if the domain is an IP address
    if is_ip "${CERT_DOMAINS}"; then
        # Check if ZeroSSL EAB (External Account Binding) variables are set and certificate should be renewed
        if [[ -n "${CERT_ZEROSSL_API_KEY}" ]]; then
            print_message "🔔 ZeroSSL configuration detected for IP ${CERT_DOMAINS}. Attempting ZeroSSL certificate issuance.."
            # Renew ZeroSSL certificate if needed
            if should_renew_certificate "$cert_path" "$CERT_RENEWAL_THRESHOLD_DAYS"; then
                request_renew_zero_certificate  # Function to request renewal from ZeroSSL
            else
                echo "🔒 The ZeroSSL certificate for ${CERT_DOMAINS} is valid for more than ${CERT_RENEWAL_THRESHOLD_DAYS} days"
                echo "   No renewal needed."
                echo
            fi
            
        # Check if force renewal is enabled or if the certificate needs renewal
        elif [[ "${CERT_FORCE_RENEW}" == "true" ]] || should_renew_certificate "$cert_path" "$CERT_RENEWAL_THRESHOLD_DAYS"; then
            print_message "🌐 ${CERT_DOMAINS} is an IP or localhost. Generating a self-signed certificate.."
            # Function to create self-signed certificate
            create_self_signed_certificate "${CERT_DOMAINS}" "$LE_ROOT_PATH" "$PRIV_KEY_NAME" "$FULL_CHAIN_NAME"
        else
            print_message "🔒 The self-signed certificate for ${CERT_DOMAINS} is valid for more than ${CERT_RENEWAL_THRESHOLD_DAYS} days"
            echo "   No renewal needed."
        fi
    else
        # If the domain is not an IP, check if the certificate needs renewal
        if [[ "${CERT_FORCE_RENEW}" == "true" ]] || should_renew_certificate "$cert_path" "$CERT_RENEWAL_THRESHOLD_DAYS"; then
            print_message "🔔 The certificate for ${CERT_DOMAINS} needs renewal."
            request_renew_letsencrypt_certificate  # Function to request renewal from Let's Encrypt
        else
            print_message "🔒 The certificate for ${CERT_DOMAINS} is valid for more than ${CERT_RENEWAL_THRESHOLD_DAYS} days."
            echo "   No renewal needed."
        fi
    fi
}

# Function to request the first certificate
first_certificate() {
    # Check if CERT_DOMAINS is an IP and if ZeroSSL variables are set
    if is_ip "${CERT_DOMAINS}"; then
        if [[ -n "${CERT_ZEROSSL_API_KEY}" ]]; then
            request_first_zero_certificate true  # Start HTTP server on port 80 for ZeroSSL
        else
            echo "⚠️ Missing ZeroSSL credentials. Generating a self-signed certificate for ${CERT_DOMAINS}."
            # Function to create self-signed certificate
            create_self_signed_certificate "${CERT_DOMAINS}" "$LE_ROOT_PATH" "$PRIV_KEY_NAME" "$FULL_CHAIN_NAME" 
        fi
    else
        # If CERT_DOMAINS is not an IP, request the first certificate with Certbot
        request_first_letsencrypt_certificate  # Function to request first certificate from Let's Encrypt
    fi
}

#####################################################################
# Cert_Main function to handle certificate requests and renewals  ###
#####################################################################
main_certificate_manager() {

    local domain_dir="$LE_ROOT_PATH/${CERT_DOMAINS}"  # Directory for the domain's certificates
    local cert_path="$domain_dir/$FULL_CHAIN_NAME"
    
    if [ ! -f "${cert_path}" ]; then
        echo "🗂️  Certificate '$FULL_CHAIN_NAME' not found in '$cert_path' for the domain ${CERT_DOMAINS}. Generating the first certificate.."
        echo
        first_certificate  # Call to request the first certificate
    else
        echo "📄 Certificate already exists for ${CERT_DOMAINS} in $cert_path. Checking renewal status.."
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
echo " ENABLE           ( CERT_ENABLE                  ) : ${CERT_ENABLE}"                  # Display if CertMe is enabled
echo " ENABLE S_S_C     ( CERT_SELF_SIGNED_CERTIFICATE ) : ${CERT_SELF_SIGNED_CERTIFICATE}" # Display if CERT_SELF_SIGNED_CERTIFICATE is enabled
echo " Domains          ( CERT_DOMAINS                 ) : ${CERT_DOMAINS}"                 # Display domains managed by CertMe
echo " Email            ( CERT_EMAIL                   ) : ${CERT_EMAIL}"                   # Display email for CertMe notifications
echo " Staging Mode     ( CERT_STAGING                 ) : ${CERT_STAGING}"                 # Display staging mode status
echo " Force Renew      ( CERT_FORCE_RENEW             ) : ${CERT_FORCE_RENEW}"             # Display if forced renewal is enabled
echo " Nginx Proxy Port ( CERT_PROXY_PASS_PORT         ) : ${CERT_PROXY_PASS_PORT}"         # Display the port used by the Nginx proxy
echo " Threshold Days   ( CERT_RENEWAL_THRESHOLD_DAYS  ) : ${CERT_RENEWAL_THRESHOLD_DAYS}"  # Display renewal threshold

# Display ZeroSSL configuration if environment variables are set
if [[ -n "${CERT_ZEROSSL_API_KEY}" ]]; then
    echo "---------------------------------------------------------------"
    # Display ZeroSSL API key if set
    echo " ZERO SSL API     ( CERT_ZEROSSL_API_KEY        ) : ${CERT_ZEROSSL_API_KEY}" 
fi
echo "---------------------------------------------------------------"
echo

# If CERT_ENABLE is not set to true, skip CertMe setup and start Nginx
if [[ "${CERT_ENABLE}" != "true" ]]; then
    
    print_message "CERT_ENABLE is not set to true. Skipping CertMe setup and starting Nginx."
    start_nginx  # Function to start the Nginx server

# Generate a self_signed_certificate if CERT_SELF_SIGNED_CERTIFICATE is set to true 
elif [[ "${CERT_ENABLE}" == "true" && "$CERT_SELF_SIGNED_CERTIFICATE" == "true" ]]; then
    
    if [ -z "$CERT_DOMAINS" ]; then
        CERT_DOMAINS="127.0.0.1"
    fi
    print_message "🌐 Generating a self-signed certificate for the domain : "
    create_self_signed_certificate "${CERT_DOMAINS}" "$LE_ROOT_PATH" "$PRIV_KEY_NAME" "$FULL_CHAIN_NAME"
    
# Exit if CERT_DOMAINS is empty and CERT_ENABLE is set to true
elif [[ "${CERT_ENABLE}" == "true" && -z "$CERT_DOMAINS" ]]; then
    
    # Error message
    print_message "❌ CERT_ENABLE is set to true but no CERT_DOMAINS provided. Exiting." 
    exit 1  # Exit the script with error

# If no arguments are provided, set up cron job and initialize the first certificate
elif [ $# -eq 0 ]; then
    
    print_message "📝 Setting up cron job for automatic renewals."
    SCRIPT_NAME=$(basename "$0")  # Get the name of the current script
    configure_cron_job "$CERT_CRON_SCHEDULE" "/opt/certme/${SCRIPT_NAME} renew >> /opt/certme/renew.info" 
    
    # Verify if the configuration file exists
    if [ -f /etc/nginx/letsEncrypt_zeroSsl.conf ]; then
        # If present, replace the default port ( 8080 ) with the value of $CERT_PROXY_PASS_PORT
        # This update is essential if letsEncrypt_zeroSsl.conf is included in nginx.conf
        sed -i "s/127.0.0.1:8080/127.0.0.1:$CERT_PROXY_PASS_PORT/" /etc/nginx/letsEncrypt_zeroSsl.conf
    fi

    first_cert_main

else # Renew the certificate - Called by crontab
    
    print_message "🔄 Running renewal process..."
    renew_cert_main
fi
