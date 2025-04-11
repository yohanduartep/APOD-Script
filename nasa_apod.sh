#!/bin/bash
API_KEY="API"
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
IMAGE_PATH="Pictures/apod.jpg"
IMAGE_OLDPATH="Pictures/apod_old.jpg"
IMAGE_TEMPPATH="Pictures/apod_temp.jpg"

#Only starts if there is conenection to the internet
if ! ping -c 1 google.com &> /dev/null; then
    echo "No internet connection. Exiting."
    exit 1
fi

#Only runs if image is older than 24 hours
if [ -f "$IMAGE_PATH" ]; then
    if [ "$(find "$IMAGE_PATH" -mmin -1440)" ]; then
        echo "Image is less than 24 hours old. Exiting."
        exit 0
    fi
fi

# Fetch APOD data
JSON_DATA=$(curl -s "https://api.nasa.gov/planetary/apod?api_key=$API_KEY")
# Extract image URL
MEDIA_URL=$(echo "$JSON_DATA" | jq -r '.hdurl // .url')

# Check if URL is an image
if [[ "$MEDIA_URL" == *youtube.com* || "$MEDIA_URL" == *vimeo.com* ]]; then
    exit 0
else
    IMAGE_URL="$MEDIA_URL"
    wget -q -O "$IMAGE_TEMPPATH" "$IMAGE_URL"
fi

# Check if the image downloaded has a valid size (image proportion should be at least 1:1 and height should not be more than 1.25x the width)

IMAGE_SIZE=$(identify -format "%wx%h" "$IMAGE_TEMPPATH")
IMAGE_WIDTH=$(echo "$IMAGE_SIZE" | cut -d 'x' -f 1)
IMAGE_HEIGHT=$(echo "$IMAGE_SIZE" | cut -d 'x' -f 2)

if [ "$IMAGE_WIDTH" -lt 100 ] || [ "$IMAGE_HEIGHT" -lt 100 ]; then
    echo "Downloaded image is too small. Exiting."
    exit 1
fi

if [ "$IMAGE_HEIGHT" -gt $((IMAGE_WIDTH * 125 / 100)) ]; then
    echo "Downloaded image is too tall. Exiting."
    exit 1
fi

# Move the temporary image to the final location
mv "$IMAGE_PATH" "$IMAGE_OLDPATH"
mv "$IMAGE_TEMPPATH" "$IMAGE_PATH"

