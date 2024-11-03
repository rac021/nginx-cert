FROM nginx:1.27.2-alpine-slim

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
# Make the certme & renew scripts executable
RUN chmod +x /usr/local/bin/certme
RUN chmod +x /usr/local/bin/renew

# Copy default nginx config
COPY config/. /etc/nginx/

# Create log and cache directories 
# with the right permissions
RUN mkdir -p /var/log/nginx /var/cache/nginx
# Set permissions for nginx log and cache directories
RUN chown -R nginx:nginx /opt/certme      && \
    chmod -R 755 /opt/certme              && \
    chown -R nginx:nginx /var/cache/nginx && \
    chown -R nginx:nginx /var/log/nginx   && \
    chown -R nginx:nginx /etc/nginx/conf.d
RUN touch /var/run/nginx.pid && \
    chown -R nginx:nginx /var/run/nginx.pid

# Switch to the nginx user to run Nginx
USER nginx

# Set the entrypoint
ENTRYPOINT ["/bin/bash", "-c", "./main.sh"]
