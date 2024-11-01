# nginx-certbot

## Description

This project handles the creation and renewal of SSL certificates using **Certbot**. It also configures an Nginx server, based on the **official Nginx Docker image**, to deploy the certificates. The project regularly checks whether a certificate needs renewal and takes the necessary actions as required.

## Features

-   Generates self-signed certificates for IP addresses and `localhost`.
-   Requests certificates via Certbot for specified domains.
-   Automatically renews certificates based on a defined threshold.

## Environment Variables

-   `CERTBOT_EMAIL`: The email address to use when requesting the certificate.
-   `CERTBOT_DOMAINS`: A comma-separated list of domains for which the certificate is requested.
-   `NGINX_PROXY_PASS_PORT`: The port used by the Nginx proxy (default value: `8080`).
-   `RENEWAL_THRESHOLD_DAYS`: The number of days before expiration to trigger renewal (default value: `30`).
-   `RUN_CERTBOT`: If set to `true`, the script executes the Certbot mode.
-   `FORCE_RENEW`: If set to `true`, forces renewal of the certificate.
-   `STAGING`: If set to `true`, uses the staging environment for testing ( default value: `true` ).

## Example Nginx Configuration

Here's an example Nginx configuration (`nginx.conf`) to use with the Certbot setup:

```
 http {
    
    # Server configuration
    server {    
        listen 80;
        listen [::]:80;
        server_name _;
     
        ## Lets-Encrypt Configuration 
        location /.well-known/acme-challenge/ {
            proxy_pass http://127.0.0.1:8080;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }   

        # Redirection to HTTPS for all other traffic
        location / {
            # Example redirection to HTTPS for all other requests
            return 301 https://$host$request_uri;
        }
    }
    
    server {    
        listen 443 ssl;
        server_name openadom;
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
    build:
      context: .
      dockerfile: Dockerfile
    environment:
      - RUN_CERTBOT=true
      - CERTBOT_EMAIL=your-email@example.com
      - CERTBOT_DOMAINS=example.com
      - NGINX_PROXY_PASS_PORT=8080
      - FORCE_RENEW=true
      - STAGING=false
      - RENEWAL_THRESHOLD_DAYS=30
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
              --name nginx-certbot \
              -e CERTBOT_EMAIL=your-email@example.com        \
              -e CERTBOT_DOMAINS=example.com,www.example.com \
              -e NGINX_PROXY_PASS_PORT=8080 \
              -e RENEWAL_THRESHOLD_DAYS=30  \
              -e RUN_CERTBOT=true \
              -e FORCE_RENEW=true \
              -e STAGING=false    \
              -p 80:80   \
              -p 443:443 \
              nginx-certbot
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
   docker exec nginx-certbot renew
```
4. The script will automatically request certificates and set up Nginx. Ensure to adjust the domain names and email address accordingly.
