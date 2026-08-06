# APOD-Script

Updates my macOS wallpapers every day using NASA's Astronomy Picture of the Day.
Images that do not match a display's aspect ratio are discarded. Connected displays
are detected at runtime, so the script also works when I use only the MacBook screen.

The built-in display's wallpaper is published here:

![Current wallpaper](https://raw.githubusercontent.com/yohanduartep/APOD-Script/refs/heads/main/001.jpg?v=0)

## Requirements

```bash
brew install imagemagick jq
```

The NASA API key and image paths are stored in `.env`.
