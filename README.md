# nginx-cert

## Description

This project handles the creation and renewal of SSL certificates using **Certbot**. It also configures an Nginx server, based on the **official Nginx Docker image**, to deploy the certificates. The project regularly checks whether a certificate needs renewal and takes the necessary actions as required.

## Features

-   Generates self-signed certificates for IP addresses and `localhost`.
-   Requests certificates via Certbot ( or REST for zeroSSL ) for specified domains.
-   Automatically renews certificates based on a defined threshold.

## Environment Variables

-   `CERT_ENABLE`: If set to `true`, the script will enable the Cert mode ( default value: `false` ).
-   `CERT_DOMAINS`: A comma-separated list of domains for which the certificate is requested.
-   `CERT_FORCE_RENEW`: If set to `true`, forces renewal of the certificate.
-   `CERT_STAGING`: If set to `true`, uses the staging environment for testing ( default value: `true` ).
-   `CERT_RENEWAL_THRESHOLD_DAYS`: The number of days before expiration to trigger renewal (default value: `30`).
-   `CERT_EMAIL`: The email address to use when requesting the certificate.
-   `CERT_SELF_SIGNED_CERTIFICATE`: When set to `true` and `CERT_ENABLE` is also `true`, a self-signed certificate will be generated ( default value: `false` ).
-   `CERT_PROXY_PASS_PORT`: The port used by the Nginx proxy (default value: `8080`).

## Example Nginx Configuration

Here's an example Nginx configuration (`nginx.conf`) to use with the Cert setup:

```
 worker_processes auto;  # Adjust based on the number of CPU cores

 events {
    worker_connections 1024; # Adjust based on your needs
 }

 http {
    
    # Server configuration
    server {    
        listen 80;
        listen [::]:80;
        server_name _;
     
        ## 1. Lets-Encrypt Configuration 
        location /.well-known/acme-challenge/ {
            proxy_pass http://127.0.0.1:8080;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }

        # 2. ZeroSSL ( for IPs Adresses )
        location /.well-known/pki-validation {
            alias /var/www/html/.well-known/;  
            allow all;
        }

        # Point 1 & 2 can be replaces by
        # Inclusion for specific Let’s Encrypt and zeroSll routes
        # include /etc/nginx/letsEncrypt_zeroSsl.conf ;

        # Redirection to HTTPS for all other traffic
        location / {
            # Example redirection to HTTPS for all other requests
            return 301 https://$host$request_uri;
        }
    }
    
    server {    
        
        listen 443 ssl;
        
        server_name openAdom;
        
        # SSL certificate
        ssl_certificate     /etc/letsencrypt/live/{DOMAIN_NAME}/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/{DOMAIN_NAME}/privkey.pem;
       
        location / {
            ....
        }
    }
}

```

## Using with Docker Compose

To use this setup with Docker Compose, you can define the environment variables in your `docker-compose.yml` file as follows:

```
`version: '3.8'

services:
  nginx:
    image: rac021/nginx-cert
    environment:
      - CERT_ENABLE=true
      - CERT_EMAIL=your-email@example.com
      - CERT_DOMAINS=example.com
      - CERT_PROXY_PASS_PORT=8080
      - CERT_FORCE_RENEW=true
      - CERT_STAGING=false
      - CERT_RENEWAL_THRESHOLD_DAYS=30
      - CERT_SELF_SIGNED_CERTIFICATE=false
    ports:
      - 80:80
      - 443:443
    volumes:
      - ./letsencrypt:/etc/letsencrypt
      - ./nginx.conf:/etc/nginx/nginx.conf:ro`
```
## Usage

1. ### With Docker command :

```
   docker run --rm \
              --name nginx-cert \
              -e CERT_EMAIL=your-email@example.com        \
              -e CERT_DOMAINS=example.com,www.example.com \
              -e CERT_SELF_SIGNED_CERTIFICATE=false \
              -e CERT_PROXY_PASS_PORT=8080          \
              -e CERT_RENEWAL_THRESHOLD_DAYS=30     \
              -e CERT_ENABLE=true      \
              -e CERT_FORCE_RENEW=true \
              -e CERT_STAGING=false    \
              -p 80:80   \
              -p 443:443 \
              rac021/nginx-cert
```

2. ### With Docker Compose :

  -  2.1 Build the Docker image :
  
```   
  `docker-compose build` 
```
   - 2.2 Start the services :
   
``` 
  `docker-compose up` 
```

3. It is also possible to manually trigger a renewal with the following command :

```
   docker exec nginx-cert renew
```
4. The script will automatically request certificates and set up Nginx. Ensure to adjust the domain names and email address accordingly.
