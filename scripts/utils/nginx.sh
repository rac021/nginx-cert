#!/bin/bash

start_nginx() {
    echo
    print_message "🚀 Starting Nginx server..."

    # Check if Nginx is already running
    if pgrep -x "nginx" > /dev/null; then
        print_message "⚠️ Nginx is already running."
        return 1
    fi

    # Start Nginx as the 'nginx' user directly
    if nginx -g 'daemon off;' ; then
        print_message "✅ Nginx server started successfully."
    else
        print_message "❌ Failed to start Nginx server."
        return 1
    fi
    echo
}

reload_nginx() {
    print_message "🔄 Reloading Nginx configuration..."

    # Reload Nginx configuration
    if nginx -s reload; then
        print_message "✅ Nginx configuration reloaded successfully."
    else
        print_message "❌ Failed to reload Nginx configuration."
        return 1
    fi
    echo
}
