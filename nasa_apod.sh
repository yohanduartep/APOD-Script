#!/bin/bash
API_KEY="API_HERE"
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
DAILY_PATH="/Pictures/apod.jpg"
RANDOM_PATH="/Pictures/randomapod.jpg"

START_DATE="1995-06-16"
END_DATE=$(date +%F)
start_ts=$(date -d "$START_DATE" +%s)
end_ts=$(date -d "$END_DATE" +%s)

is_daily_set="false"
is_random_set="false"

if ! ping -c 1 google.com &> /dev/null; then
    echo "No internet connection. Exiting."
    exit 1
fi

function checkSizes(){
    IMAGE_SIZE=$(identify -format "%wx%h" "$1")
    IMAGE_WIDTH=$(echo "$IMAGE_SIZE" | cut -d 'x' -f 1)
    IMAGE_HEIGHT=$(echo "$IMAGE_SIZE" | cut -d 'x' -f 2)

    if [ "$IMAGE_WIDTH" -lt 100 ] || [ "$IMAGE_HEIGHT" -lt 100 ]; then
        echo "Downloaded image is too small. Exiting."
        return 1
    fi

    if [ "$IMAGE_HEIGHT" -gt $((IMAGE_WIDTH * 125 / 100)) ]; then
        echo "Downloaded image is too tall. Exiting."
        return 1
    fi

    return 0
}

DAILY_JSON=$(curl -s "https://api.nasa.gov/planetary/apod?api_key=$API_KEY")
DAILY_URL=$(echo "$DAILY_JSON" | jq -r '.hdurl // .url')
if [[ "$DAILY_URL" == *youtube.com* || "$DAILY_URL" == *vimeo.com* ]]; then
    echo "Daily is video. Setting random image."
else
    wget -q -O "$DAILY_PATH" "$DAILY_URL"
    if checkSizes "$DAILY_PATH"; then
        is_daily_set="true"
    fi
fi

while [ "$is_random_set" = "false" ]; do
    while [ "$is_daily_set" = "false" ];  do
        random_ts=$(shuf -i $start_ts-$end_ts -n 1)
        random_date=$(date -d "@$random_ts" +%F)
        RANDOM_JSON=$(curl -s "https://api.nasa.gov/planetary/apod?api_key=$API_KEY&date=$random_date")
        RANDOM_URL=$(echo "$RANDOM_JSON" | jq -r '.hdurl // .url')
        if [[ "$RANDOM_URL" == *youtube.com* || "$RANDOM_URL" == *vimeo.com* ]]; then
            echo "Random is video. Trying again."       
            continue
        else
            wget -q -O "$DAILY_PATH" "$RANDOM_URL"
            if checkSizes "$DAILY_PATH"; then 
                is_daily_set="true"
            fi
        fi
    done

    random_ts=$(shuf -i $start_ts-$end_ts -n 1)
    random_date=$(date -d "@$random_ts" +%F)
    RANDOM_JSON=$(curl -s "https://api.nasa.gov/planetary/apod?api_key=$API_KEY&date=$random_date")
    RANDOM_URL=$(echo "$RANDOM_JSON" | jq -r '.hdurl // .url')
    if [[ "$RANDOM_URL" == *youtube.com* || "$RANDOM_URL" == *vimeo.com* ]]; then
        echo "Random is video. Trying again."       
    else
        wget -q -O "$RANDOM_PATH" "$RANDOM_URL"
        if checkSizes "$RANDOM_PATH"; then 
            is_random_set="true"
        fi
    fi
done

