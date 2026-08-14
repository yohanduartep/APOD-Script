# APOD-Script

Updates my macOS wallpapers every day using NASA's Astronomy Picture of the Day.
Images are matched to each display's aspect ratio when possible, then stretched to fill
the screen without cropping. Connected displays are detected at runtime, so the script
also works with only the MacBook screen.

If no suitable online image is found within the configured attempts, the script chooses
a random local image from the APOD dataset's `acceptable-landscape` or
`acceptable-portrait` category according to the display orientation.

## Current wallpapers

![Wallpaper 1](https://raw.githubusercontent.com/yohanduartep/APOD-Script/refs/heads/main/001.jpg?v=1786710096514052000)
![Wallpaper 2](https://raw.githubusercontent.com/yohanduartep/APOD-Script/refs/heads/main/002.jpg?v=1786710096514052000)
![Wallpaper 3](https://raw.githubusercontent.com/yohanduartep/APOD-Script/refs/heads/main/003.jpg?v=1786710096514052000)

## Requirements

```bash
brew install imagemagick python
```

`nasa_apod.sh` starts the Python script used by the daily LaunchAgent. The NASA API
key and image paths are stored in `.env`.

The dataset categories default to the sibling `APOD-Dataset/categories` directory. Set
`DATASET_CATEGORIES` in `.env` only if that directory moves elsewhere.

Keep a display's current wallpaper while updating and publishing the others:

```bash
./nasa_apod.sh --skip "T24i-30"
```

Use `--skip` more than once to keep multiple displays unchanged.

Replace today's APOD with monitor-matched random images:

```bash
./nasa_apod.sh --random
```

`--random` can be combined with `--skip`:

```bash
./nasa_apod.sh --random --skip "T24i-30"
```
