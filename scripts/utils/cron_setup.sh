#!/bin/bash

# Function to configure a cron job that runs renew_cert_main every ...
configure_cron_job() {
    local cron_schedule="$1"
    local cron_command="$2"    
    local cron_job="${cron_schedule} bash ${cron_command}"

    (crontab -l | grep -F "$cron_job") || (crontab -l; echo "$cron_job") | crontab -
    echo "🕒 Cron job configured to check certificate renewal : ${cron_job}"
    echo
    crond start
}
