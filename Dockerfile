FROM nginx:1.27.2-alpine

# Install necessary packages
RUN apk add --no-cache certbot openssl jq bash

# Set the working directory
RUN mkdir /opt/certme
WORKDIR   /opt/certme

# Copy the script into the container
COPY scripts/. .

# Commands
COPY bin/certme.sh /usr/local/bin/certme
COPY bin/renew.sh  /usr/local/bin/renew
# Make the renew script executable
RUN chmod +x /usr/local/bin/certme
RUN chmod +x /usr/local/bin/renew

COPY config/nginx.conf /etc/nginx/nginx.conf

# Set the entrypoint
ENTRYPOINT ["/bin/bash", "-c", "./main.sh"]
