#!bin/bash

describe_cron_schedule() {

    local cron_schedule="$1"
    # Split cron schedule into its five fields
    local minute hour day month weekday
    minute=$(echo "$cron_schedule" | awk '{print $1}')
    hour=$(echo "$cron_schedule" | awk '{print $2}')
    day=$(echo "$cron_schedule" | awk '{print $3}')
    month=$(echo "$cron_schedule" | awk '{print $4}')
    weekday=$(echo "$cron_schedule" | awk '{print $5}')

    # Minute
    if [[ "$minute" == "*" ]]; then
        minute_desc="every minute"
    elif [[ "$minute" == "0" ]]; then
        minute_desc="at the start of the hour"
    else
        minute_desc="at minute $minute"
    fi

    # Hour
    if [[ "$hour" == "*" ]]; then
        hour_desc="of every hour"
    elif [[ "$hour" == "0" ]]; then
        hour_desc="at midnight"
    elif [[ "$hour" == "12" ]]; then
        hour_desc="at noon"
    else
        hour_desc="at $hour:00"
    fi

    # Day of month
    if [[ "$day" == "*" ]]; then
        day_desc="every day"
    else
        day_desc="on the $day"
    fi

    # Month
    if [[ "$month" == "*" ]]; then
        month_desc="of every month"
    else
        month_desc="of month $month"
    fi

    # Day of the week
    case "$weekday" in
        "*") weekday_desc="";;
        0|7) weekday_desc="on Sunday";;
        1) weekday_desc="on Monday";;
        2) weekday_desc="on Tuesday";;
        3) weekday_desc="on Wednesday";;
        4) weekday_desc="on Thursday";;
        5) weekday_desc="on Friday";;
        6) weekday_desc="on Saturday";;
        *) weekday_desc="";;
    esac

    # Combine all descriptions into a final message
    echo "Scheduled to run $minute_desc $hour_desc $day_desc $month_desc $weekday_desc."
}
