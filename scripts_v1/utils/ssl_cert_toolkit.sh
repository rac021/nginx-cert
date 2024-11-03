#!/bin/bash

# Function to generate a self-signed certificate
create_self_signed_certificate() {

    local domain="$1"
    local le_root_path="$2"
    local priv_key_name="$3"
    local full_chain_name="$4"

    print_message "📝 Generating a self-signed certificate for ${domain}"
    echo "   - Generating the private key pem in : ${le_root_path}/${domain}/${priv_key_name}"
    echo "   - Generating the fullchain   pem in : ${le_root_path}/${domain}/${full_chain_name}"
    
    mkdir -p "${le_root_path}/${domain}"
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
                -keyout "${le_root_path}/${domain}/${priv_key_name}"   \
                -out    "${le_root_path}/${domain}/${full_chain_name}" \
                -subj   "/CN=${domain}"
    chmod -R 666 $le_root_path
}

# Function to generate CSR and private key
create_private_key_with_csr() {

    local domain="$1"
    local le_root_path="$2"
    local csr_name="$3"
    local priv_key_name="$4"

    # Check if both certificate files are present
    if [[ -f "${le_root_path}/${domain}/${priv_key_name}" && 
          -f "${le_root_path}/${domain}/${FULL_CHAIN_NAME}" ]]; then
        echo "Certificate files located in '${le_root_path}/${domain}'. Creating a backup copy at '${le_root_path}/${domain}_copy'."
        cp -r "${le_root_path}/${domain}"  "${le_root_path}/${domain}_copy"
    fi

    echo "📝 Generating private key and CSR for ${domain}"
    echo "   - Generating the private key in : ${le_root_path}/${domain}/${priv_key_name}"
    echo "   - Generating the csr pem in     : ${le_root_path}/${domain}/${csr_name}"
    
    # Create CSR and Private Key
    openssl req -new -newkey rsa:2048 -nodes \
                -keyout "${le_root_path}/${domain}/${priv_key_name}" \
                -out    "${le_root_path}/${domain}/${csr_name}"      \
                -subj   "/C=FR/ST=Paris/L=Paris/O=INRAE/OU=InfoSol/CN=${domain}"
    chmod -R 666 $le_root_path
}

# Function to check if a certificate needs renewal
should_renew_certificate() {

    local cert_path="$1"
    local renewal_threshold_days="$2"

    # Check if the certificate expires in less than CERTME_RENEWAL_THRESHOLD_DAYS days
    if ! openssl x509 -noout -checkend $((renewal_threshold_days * 86400)) -in "${cert_path}"; then
        return 0  # The certificate should be renewed
    else
        return 1  # No need to renew
    fi
}
