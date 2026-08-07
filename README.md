# APOD-Script

Updates my macOS wallpapers every day using NASA's Astronomy Picture of the Day.
Images are matched or center-cropped to each display's aspect ratio. Connected
displays are detected at runtime, so the script also works with only the MacBook screen.

## Current wallpapers

![Wallpaper 1](https://raw.githubusercontent.com/yohanduartep/APOD-Script/refs/heads/main/001.jpg?v=1786105411228709000)
![Wallpaper 2](https://raw.githubusercontent.com/yohanduartep/APOD-Script/refs/heads/main/002.jpg?v=1786105411228709000)
![Wallpaper 3](https://raw.githubusercontent.com/yohanduartep/APOD-Script/refs/heads/main/003.jpg?v=1786105411228709000)
## Requirements

```bash
brew install imagemagick python
```

`nasa_apod.sh` starts the Python script used by the daily LaunchAgent. The NASA API
key and image paths are stored in `.env`.

Keep a display's current wallpaper while updating and publishing the others:

```bash
./nasa_apod.sh --skip "T24i-30"
```

Use `--skip` more than once to keep multiple displays unchanged.
