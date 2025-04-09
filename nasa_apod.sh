
API_KEY="INSER YOUR API KEY HERE"
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
IMAGE_PATH="FOLDER/apod.jpg"

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
    wget -q -O "$IMAGE_PATH" "$IMAGE_URL"
fi