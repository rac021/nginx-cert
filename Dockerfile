FROM nginx:1.27.2-alpine

# Install necessary packages
RUN apk add --no-cache certbot openssl bash

# Set the working directory
WORKDIR /opt

# Copy the script into the container
COPY scripts/nginx_certbot.sh ./
COPY scripts/renew.sh /usr/local/bin/renew
COPY config/nginx.conf /etc/nginx/nginx.conf

# Make the renew script executable
RUN chmod +x /usr/local/bin/renew

# Set the entrypoint
ENTRYPOINT ["/bin/bash", "-c", "./nginx_certbot.sh"]
