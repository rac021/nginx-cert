#!/bin/bash

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
