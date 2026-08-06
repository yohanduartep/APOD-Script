#!/usr/bin/env bash

set -u

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

[ -f "$ENV_FILE" ] || { echo ".env not found: $ENV_FILE" >&2; exit 1; }

set -a
source "$ENV_FILE"
set +a

trim() { printf '%s' "$1" | tr -d '\r\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }

API_KEY="$(trim "${API_KEY:-}")"
DAILY_PATH="$(trim "${DAILY_PATH:-$HOME/Pictures/apod.jpg}")"
RANDOM_PATH="$(trim "${RANDOM_PATH:-$HOME/Pictures/randomapod.jpg}")"
MAX_ATTEMPTS="$(trim "${MAX_ATTEMPTS:-100}")"
ASPECT_TOLERANCE_PERCENT="$(trim "${ASPECT_TOLERANCE_PERCENT:-10}")"
MIN_WIDTH="$(trim "${MIN_WIDTH:-100}")"
MIN_HEIGHT="$(trim "${MIN_HEIGHT:-100}")"
USER_AGENT="${USER_AGENT:-apod-script/2.0}"
OUTPUT_DIR="$(trim "${OUTPUT_DIR:-$(dirname "$DAILY_PATH")}")"

[ -n "$API_KEY" ] || { echo "API_KEY not set" >&2; exit 1; }
for value in "$MAX_ATTEMPTS" "$ASPECT_TOLERANCE_PERCENT" "$MIN_WIDTH" "$MIN_HEIGHT"; do
    [[ "$value" =~ ^[0-9]+$ ]] || { echo "Numeric setting is invalid: $value" >&2; exit 1; }
done

for cmd in curl jq; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "Missing dependency: $cmd" >&2; exit 1; }
done

if command -v identify >/dev/null 2>&1; then
    IDENTIFY_CMD=(identify)
elif command -v magick >/dev/null 2>&1; then
    IDENTIFY_CMD=(magick identify)
else
    echo "Missing dependency: ImageMagick" >&2
    exit 1
fi

declare -a MONITOR_NAMES=()
declare -a MONITOR_DIMENSIONS=()

add_monitor() {
    local name="$1" size="$2"
    [[ "$size" =~ ^[0-9]+x[0-9]+$ ]] || return
    MONITOR_NAMES+=("$name")
    MONITOR_DIMENSIONS+=("$size")
}

detect_monitors() {
    local name width height transform size index=1

    if [ "$(uname)" = "Darwin" ]; then
        while IFS=$'\t' read -r name width height; do
            add_monitor "$name" "${width}x${height}"
            index=$((index + 1))
        done < <(osascript -l JavaScript -e '
ObjC.import("AppKit");
var sizes = $.NSScreen.screens.js.map(function (screen) {
    var frame = screen.frame;
    return screen.localizedName.js + "\t" + Math.round(frame.size.width) + "\t" + Math.round(frame.size.height);
});
sizes.join("\n");' 2>/dev/null)
    fi

    if [ "${#MONITOR_DIMENSIONS[@]}" -eq 0 ] && [ "$(uname)" = "Darwin" ] && command -v system_profiler >/dev/null 2>&1; then
        index=1
        while read -r width height; do
            add_monitor "display-$index" "${width}x${height}"
            index=$((index + 1))
        done < <(system_profiler SPDisplaysDataType 2>/dev/null | sed -nE 's/^[[:space:]]*Resolution: ([0-9]+) x ([0-9]+).*/\1 \2/p')
    fi

    [ "${#MONITOR_DIMENSIONS[@]}" -gt 0 ] || { echo "No displays detected" >&2; exit 1; }
}

detect_monitors

for ((i = 0; i < ${#MONITOR_NAMES[@]}; i++)); do
    if [[ "${MONITOR_NAMES[$i]}" == *"Built-in"* ]] || [[ "${MONITOR_NAMES[$i]}" == *"Color LCD"* ]]; then
        if [ "$i" -ne 0 ]; then
            name=${MONITOR_NAMES[0]}
            size=${MONITOR_DIMENSIONS[0]}
            MONITOR_NAMES[0]=${MONITOR_NAMES[$i]}
            MONITOR_DIMENSIONS[0]=${MONITOR_DIMENSIONS[$i]}
            MONITOR_NAMES[$i]=$name
            MONITOR_DIMENSIONS[$i]=$size
        fi
        break
    fi
done

mkdir -p "$OUTPUT_DIR" "$(dirname "$DAILY_PATH")" "$(dirname "$RANDOM_PATH")"

API_CURL=(-fsS --retry 1 --retry-all-errors --retry-delay 1 --connect-timeout 10 --max-time 30 -A "$USER_AGENT")
IMG_CURL=(-LfsS --connect-timeout 8 --max-time 30 -A "$USER_AGENT")

check_image() {
    local file="$1" monitor_size="$2" size width height monitor_width monitor_height difference baseline
    [ -s "$file" ] || return 1
    size=$("${IDENTIFY_CMD[@]}" -format "%w %h" "${file}[0]" 2>/dev/null) || return 1
    read -r width height <<< "$size"
    IFS=x read -r monitor_width monitor_height <<< "$monitor_size"
    [ "$width" -ge "$MIN_WIDTH" ] && [ "$height" -ge "$MIN_HEIGHT" ] || return 1

    difference=$((width * monitor_height - height * monitor_width))
    [ "$difference" -ge 0 ] || difference=$((-difference))
    baseline=$((height * monitor_width))
    [ $((difference * 100)) -le $((baseline * ASPECT_TOLERANCE_PERCENT)) ]
}

apod_url() {
    local date_value="$1" json
    if [ -n "$date_value" ]; then
        json=$(curl "${API_CURL[@]}" --get "https://api.nasa.gov/planetary/apod" \
            --data-urlencode "api_key=$API_KEY" --data-urlencode "date=$date_value") || return 1
    else
        json=$(curl "${API_CURL[@]}" --get "https://api.nasa.gov/planetary/apod" \
            --data-urlencode "api_key=$API_KEY") || return 1
    fi
    jq -er 'select(.media_type == "image") | (.hdurl // .url) | select(length > 0)' <<< "$json" 2>/dev/null
}

declare -a RANDOM_PREVIEW_URLS=()
declare -a RANDOM_IMAGE_URLS=()
RANDOM_INDEX=0
LAST_IMAGE_ATTEMPTS=0

load_random_urls() {
    local json preview_url image_url
    RANDOM_PREVIEW_URLS=()
    RANDOM_IMAGE_URLS=()
    RANDOM_INDEX=0
    json=$(curl "${API_CURL[@]}" --get "https://api.nasa.gov/planetary/apod" \
        --data-urlencode "api_key=$API_KEY" \
        --data-urlencode "count=20") || return 1
    while IFS=$'\t' read -r preview_url image_url; do
        if [[ "$preview_url" =~ ^https?://[^[:space:]]+$ ]] && [[ "$image_url" =~ ^https?://[^[:space:]]+$ ]]; then
            RANDOM_PREVIEW_URLS+=("$preview_url")
            RANDOM_IMAGE_URLS+=("$image_url")
        fi
    done < <(jq -r '.[] | select(.media_type == "image" and (.url | length > 0)) | [.url, (.hdurl // .url)] | @tsv' <<< "$json" 2>/dev/null)
    [ "${#RANDOM_PREVIEW_URLS[@]}" -gt 0 ]
}

download_image() {
    local url="$1" path="$2" monitor_size="$3" tmp="${path}.tmp"
    rm -f "$tmp"
    curl "${IMG_CURL[@]}" -o "$tmp" "$url" || { rm -f "$tmp"; return 1; }
    check_image "$tmp" "$monitor_size" || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$path"
}

preview_matches() {
    local url="$1" monitor_size="$2" tmp result
    tmp=$(mktemp "${TMPDIR:-/tmp}/apod-preview.XXXXXX") || return 1
    curl "${IMG_CURL[@]}" -o "$tmp" "$url" || { rm -f "$tmp"; return 1; }
    check_image "$tmp" "$monitor_size"
    result=$?
    rm -f "$tmp"
    return "$result"
}

set_random_image() {
    local path="$1" monitor_size="$2" preview_url image_url attempt=0 batch_failures=0
    while [ "$attempt" -lt "$MAX_ATTEMPTS" ]; do
        if [ "$RANDOM_INDEX" -ge "${#RANDOM_PREVIEW_URLS[@]}" ]; then
            if ! load_random_urls; then
                batch_failures=$((batch_failures + 1))
                if [ "$batch_failures" -ge 5 ]; then
                    LAST_IMAGE_ATTEMPTS=$attempt
                    return 1
                fi
                continue
            fi
            batch_failures=0
        fi
        preview_url=${RANDOM_PREVIEW_URLS[$RANDOM_INDEX]}
        image_url=${RANDOM_IMAGE_URLS[$RANDOM_INDEX]}
        RANDOM_INDEX=$((RANDOM_INDEX + 1))
        attempt=$((attempt + 1))
        if preview_matches "$preview_url" "$monitor_size" && download_image "$image_url" "$path" "$monitor_size"; then
            LAST_IMAGE_ATTEMPTS=$attempt
            return 0
        fi
    done
    LAST_IMAGE_ATTEMPTS=$attempt
    return 1
}

wallpaper_path() {
    local index="$1"
    case "$index" in
        0) printf '%s\n' "$DAILY_PATH" ;;
        *) printf '%s/apod-%d.jpg\n' "$OUTPUT_DIR" "$((index + 1))" ;;
    esac
}

declare -a WALLPAPERS=()
MAC_WALLPAPER=""
daily_url=""
daily_url=$(apod_url "") || true

for ((i = 0; i < ${#MONITOR_DIMENSIONS[@]}; i++)); do
    path=$(wallpaper_path "$i")
    size=${MONITOR_DIMENSIONS[$i]}
    if [ "$i" -eq 0 ] && [ -n "$daily_url" ] && download_image "$daily_url" "$path" "$size"; then
        :
    elif [ "$i" -eq 0 ]; then
        path="$RANDOM_PATH"
        if ! set_random_image "$path" "$size"; then
            echo "Failed to find a daily fallback for ${MONITOR_NAMES[$i]} ($size) after $LAST_IMAGE_ATTEMPTS image attempts" >&2
            exit 1
        fi
    elif ! set_random_image "$path" "$size"; then
        echo "Failed to find a suitable image for ${MONITOR_NAMES[$i]} ($size) after $LAST_IMAGE_ATTEMPTS image attempts" >&2
        exit 1
    fi
    WALLPAPERS+=("$path")
    if [[ "${MONITOR_NAMES[$i]}" == *"Built-in"* ]] || [[ "${MONITOR_NAMES[$i]}" == *"Color LCD"* ]]; then
        MAC_WALLPAPER="$path"
    fi
    echo "${MONITOR_NAMES[$i]} ($size): $path"
done

[ -n "$MAC_WALLPAPER" ] || MAC_WALLPAPER="${WALLPAPERS[0]}"

declare -a WALLPAPER_ASSIGNMENTS=()
for ((i = 0; i < ${#WALLPAPERS[@]}; i++)); do
    WALLPAPER_ASSIGNMENTS+=("${MONITOR_NAMES[$i]}" "${WALLPAPERS[$i]}")
done

osascript \
    -e 'on run assignments' \
    -e 'tell application "System Events"' \
    -e 'repeat with assignmentIndex from 1 to count of assignments by 2' \
    -e 'set targetDisplay to contents of item assignmentIndex of assignments' \
    -e 'set targetPicture to contents of item (assignmentIndex + 1) of assignments' \
    -e 'repeat with currentDesktop in desktops' \
    -e 'if display name of currentDesktop is targetDisplay then set picture of currentDesktop to POSIX file targetPicture' \
    -e 'end repeat' \
    -e 'end repeat' \
    -e 'end tell' \
    -e 'end run' \
    -- "${WALLPAPER_ASSIGNMENTS[@]}"

command -v git >/dev/null 2>&1 || { echo "Missing dependency: git" >&2; exit 1; }
git -C "$SCRIPT_DIR" fetch origin main || { echo "git fetch failed" >&2; exit 1; }
unpublished=$(git -C "$SCRIPT_DIR" diff --name-only origin/main..HEAD)
while IFS= read -r unpublished_file; do
    case "$unpublished_file" in
        ""|001.jpg|README.md) ;;
        *) echo "Local branch has unpushed commits" >&2; exit 1 ;;
    esac
done <<< "$unpublished"
cp "$MAC_WALLPAPER" "$SCRIPT_DIR/001.jpg"
version=$(date +%s)
perl -0pi -e "s#001\\.jpg\\?v=[0-9]+#001.jpg?v=$version#" "$SCRIPT_DIR/README.md"
if ! git -C "$SCRIPT_DIR" diff HEAD --quiet -- 001.jpg README.md; then
    git -C "$SCRIPT_DIR" commit --only -m "Update wallpaper $(date +%F)" -- 001.jpg README.md
    git -C "$SCRIPT_DIR" push origin HEAD:main
fi

echo "Done: created ${#WALLPAPERS[@]} monitor-matched wallpaper(s)"
