#!/bin/bash

# Function to print messages in a box
print_message() {

    local message="$1"
    local length=${#message}
    local border_length=$((length + 2)) # Adding space for padding
    local border=$(printf '━%.0s' $(seq 1 $border_length))
    
    echo "╭${border}╮"
    echo "│$message │"
    echo "╰${border}╯"
}

# Function to check if the argument is an IP address (IPv4 only) or "localhost"
is_ip() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || [ "$1" = "localhost" ]
}