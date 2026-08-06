#!/usr/bin/env python3

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import date
from pathlib import Path


API_URL = "https://api.nasa.gov/planetary/apod"
SCRIPT_DIR = Path(__file__).resolve().parent
MAX_DOWNLOAD_BYTES = 100 * 1024 * 1024


@dataclass(frozen=True)
class Config:
    api_key: str
    daily_path: Path
    random_path: Path
    output_dir: Path
    max_attempts: int
    tolerance: float
    min_width: int
    min_height: int
    user_agent: str


@dataclass(frozen=True)
class Monitor:
    name: str
    width: int
    height: int

    @property
    def size(self) -> str:
        return f"{self.width}x{self.height}"


@dataclass(frozen=True)
class Candidate:
    preview_url: str
    image_url: str


def load_env(path: Path) -> dict[str, str]:
    if not path.is_file():
        raise RuntimeError(f".env not found: {path}")
    values: dict[str, str] = {}
    for raw_line in path.read_text().splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip().strip("'\"")
    return values


def positive_int(values: dict[str, str], name: str, default: int) -> int:
    try:
        value = int(values.get(name, str(default)))
    except ValueError as error:
        raise RuntimeError(f"Invalid {name}") from error
    if value <= 0:
        raise RuntimeError(f"Invalid {name}")
    return value


def load_config() -> Config:
    values = load_env(SCRIPT_DIR / ".env")
    api_key = values.get("API_KEY", "").strip()
    if not api_key:
        raise RuntimeError("API_KEY not set")
    daily_path = expand_path(values.get("DAILY_PATH", str(Path.home() / "Pictures/apod.jpg")))
    random_path = expand_path(values.get("RANDOM_PATH", str(Path.home() / "Pictures/randomapod.jpg")))
    return Config(
        api_key=api_key,
        daily_path=daily_path,
        random_path=random_path,
        output_dir=expand_path(values.get("OUTPUT_DIR", str(daily_path.parent))),
        max_attempts=positive_int(values, "MAX_ATTEMPTS", 20),
        tolerance=float(values.get("ASPECT_TOLERANCE_PERCENT", "10")),
        min_width=positive_int(values, "MIN_WIDTH", 100),
        min_height=positive_int(values, "MIN_HEIGHT", 100),
        user_agent=values.get("USER_AGENT", "apod-script/3.0"),
    )


def expand_path(value: str) -> Path:
    return Path(os.path.expandvars(value)).expanduser()


def command_path(name: str) -> str:
    path = shutil.which(name)
    if not path:
        raise RuntimeError(f"Missing dependency: {name}")
    return path


def run(command: list[str], check: bool = True, timeout: int = 30) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, check=check, text=True, capture_output=True, timeout=timeout)


def detect_monitors() -> list[Monitor]:
    script = """ObjC.import('AppKit');
var values = $.NSScreen.screens.js.map(function(screen) {
    var frame = screen.frame;
    return screen.localizedName.js + '\\t' + Math.round(frame.size.width) + '\\t' + Math.round(frame.size.height);
});
values.join('\\n');"""
    result = run([command_path("osascript"), "-l", "JavaScript", "-e", script], check=False, timeout=15)
    monitors: list[Monitor] = []
    for line in result.stdout.splitlines():
        fields = line.split("\t")
        if len(fields) != 3:
            continue
        try:
            monitors.append(Monitor(fields[0], int(fields[1]), int(fields[2])))
        except ValueError:
            continue
    if not monitors:
        raise RuntimeError("No displays detected")
    monitors.sort(key=lambda monitor: not is_builtin(monitor.name))
    return monitors


def is_builtin(name: str) -> bool:
    return "Built-in" in name or "Color LCD" in name


def request_json(config: Config, parameters: dict[str, str | int]) -> object:
    url = f"{API_URL}?{urllib.parse.urlencode(parameters)}"
    request = urllib.request.Request(url, headers={"User-Agent": config.user_agent})
    last_error: Exception | None = None
    for attempt in range(2):
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.load(response)
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
            last_error = error
            if attempt == 0:
                time.sleep(1)
    raise RuntimeError(f"NASA request failed: {last_error}")


def download(url: str, destination: Path, config: Config) -> None:
    request = urllib.request.Request(url, headers={"User-Agent": config.user_agent})
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(f".{destination.name}.{time.time_ns()}.tmp")
    try:
        with urllib.request.urlopen(request, timeout=30) as response, temporary.open("wb") as output:
            content_length = response.headers.get("Content-Length")
            if content_length and content_length.isdigit() and int(content_length) > MAX_DOWNLOAD_BYTES:
                raise RuntimeError("Image exceeds 100 MB")
            downloaded = 0
            while chunk := response.read(1024 * 1024):
                downloaded += len(chunk)
                if downloaded > MAX_DOWNLOAD_BYTES:
                    raise RuntimeError("Image exceeds 100 MB")
                output.write(chunk)
        temporary.replace(destination)
        clear_quarantine(destination)
    except Exception:
        temporary.unlink(missing_ok=True)
        raise


def clear_quarantine(path: Path) -> None:
    subprocess.run(
        [command_path("xattr"), "-d", "com.apple.quarantine", str(path)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )


def identify_command() -> list[str]:
    magick = shutil.which("magick")
    if magick:
        return [magick, "identify"]
    identify = shutil.which("identify")
    if identify:
        return [identify]
    raise RuntimeError("Missing dependency: ImageMagick")


def image_dimensions(path: Path, identify: list[str]) -> tuple[int, int]:
    result = run([*identify, "-format", "%w %h", f"{path}[0]"])
    width, height = result.stdout.split()[:2]
    return int(width), int(height)


def image_matches(path: Path, monitor: Monitor, config: Config, identify: list[str]) -> bool:
    difference = aspect_difference(path, monitor, config, identify)
    return difference is not None and difference <= config.tolerance


def aspect_difference(
    path: Path, monitor: Monitor, config: Config, identify: list[str]
) -> float | None:
    try:
        width, height = image_dimensions(path, identify)
    except (OSError, ValueError, subprocess.SubprocessError):
        return None
    if width < config.min_width or height < config.min_height:
        return None
    if (width >= height) != (monitor.width >= monitor.height):
        return None
    image_ratio = width / height
    monitor_ratio = monitor.width / monitor.height
    return abs(image_ratio / monitor_ratio - 1) * 100


class CandidatePool:
    def __init__(self, config: Config):
        self.config = config
        self.candidates: list[Candidate] = []
        self.index = 0

    def load_batch(self) -> None:
        response = request_json(self.config, {"api_key": self.config.api_key, "count": 20})
        if not isinstance(response, list):
            raise RuntimeError("Unexpected NASA response")
        candidates: list[Candidate] = []
        for item in response:
            if not isinstance(item, dict) or item.get("media_type") != "image":
                continue
            preview = item.get("url")
            image = item.get("hdurl") or preview
            if valid_url(preview) and valid_url(image):
                candidates.append(Candidate(preview, image))
        if not candidates:
            raise RuntimeError("NASA returned no images")
        self.candidates = candidates
        self.index = 0

    def next(self) -> Candidate:
        if self.index >= len(self.candidates):
            self.load_batch()
        candidate = self.candidates[self.index]
        self.index += 1
        return candidate


def valid_url(value: object) -> bool:
    if not isinstance(value, str) or any(character.isspace() for character in value):
        return False
    return urllib.parse.urlparse(value).scheme in {"http", "https"}


def preview_difference(
    candidate: Candidate, monitor: Monitor, config: Config, identify: list[str]
) -> float | None:
    descriptor, name = tempfile.mkstemp(prefix="apod-preview-")
    os.close(descriptor)
    path = Path(name)
    try:
        download(candidate.preview_url, path, config)
        return aspect_difference(path, monitor, config, identify)
    except (OSError, RuntimeError, urllib.error.URLError, TimeoutError):
        return None
    finally:
        path.unlink(missing_ok=True)


def random_wallpaper(
    destination: Path,
    monitor: Monitor,
    config: Config,
    identify: list[str],
    pool: CandidatePool,
) -> int:
    attempts = 0
    batch_failures = 0
    best_candidate: Candidate | None = None
    best_difference = float("inf")
    while attempts < config.max_attempts:
        try:
            candidate = pool.next()
            batch_failures = 0
        except RuntimeError:
            batch_failures += 1
            if batch_failures >= 5:
                break
            continue
        attempts += 1
        difference = preview_difference(candidate, monitor, config, identify)
        if difference is None:
            continue
        if difference < best_difference:
            best_candidate = candidate
            best_difference = difference
        if difference > config.tolerance:
            continue
        try:
            download(candidate.image_url, destination, config)
        except (OSError, RuntimeError, urllib.error.URLError, TimeoutError):
            continue
        if image_matches(destination, monitor, config, identify):
            return attempts
        destination.unlink(missing_ok=True)
    if best_candidate is not None:
        try:
            download(best_candidate.image_url, destination, config)
            crop_to_monitor(destination, monitor, identify)
            if image_matches(destination, monitor, config, identify):
                return attempts
        except (OSError, RuntimeError, subprocess.SubprocessError, urllib.error.URLError, TimeoutError):
            destination.unlink(missing_ok=True)
    raise RuntimeError(f"Failed to find a suitable image for {monitor.name} ({monitor.size}) after {attempts} image attempts")


def crop_to_monitor(path: Path, monitor: Monitor, identify: list[str]) -> None:
    width, height = image_dimensions(path, identify)
    target_ratio = monitor.width / monitor.height
    if width / height > target_ratio:
        crop_width = round(height * target_ratio)
        crop_height = height
    else:
        crop_width = width
        crop_height = round(width / target_ratio)
    temporary = path.with_name(f".{path.name}.{time.time_ns()}.crop.jpg")
    magick = command_path("magick")
    try:
        subprocess.run(
            [magick, str(path), "-gravity", "center", "-crop", f"{crop_width}x{crop_height}+0+0", "+repage", str(temporary)],
            check=True,
            capture_output=True,
            timeout=60,
        )
        temporary.replace(path)
        clear_quarantine(path)
    except Exception:
        temporary.unlink(missing_ok=True)
        raise


def daily_url(config: Config) -> str | None:
    try:
        response = request_json(config, {"api_key": config.api_key})
    except RuntimeError:
        return None
    if not isinstance(response, dict) or response.get("media_type") != "image":
        return None
    value = response.get("hdurl") or response.get("url")
    return value if valid_url(value) else None


def acquire_wallpapers(
    config: Config, monitors: list[Monitor], identify: list[str], skipped: set[str]
) -> tuple[list[Monitor], list[Path], int]:
    config.output_dir.mkdir(parents=True, exist_ok=True)
    pool = CandidatePool(config)
    completed_monitors: list[Monitor] = []
    wallpapers: list[Path] = []
    failures = 0
    today = daily_url(config) if monitors[0].name not in skipped else None
    for index, monitor in enumerate(monitors):
        if monitor.name in skipped:
            print(f"Skipped {monitor.name} ({monitor.size})")
            continue
        try:
            if index == 0:
                destination = config.daily_path
                matched = False
                if today:
                    try:
                        download(today, destination, config)
                        matched = image_matches(destination, monitor, config, identify)
                    except (OSError, RuntimeError, urllib.error.URLError, TimeoutError):
                        matched = False
                if not matched:
                    destination = config.random_path
                    random_wallpaper(destination, monitor, config, identify, pool)
            else:
                destination = config.output_dir / f"apod-{index + 1}.jpg"
                random_wallpaper(destination, monitor, config, identify, pool)
            completed_monitors.append(monitor)
            wallpapers.append(destination)
            print(f"{monitor.name} ({monitor.size}): {destination}")
        except RuntimeError as error:
            failures += 1
            print(error, file=sys.stderr)
    if not wallpapers and failures:
        raise RuntimeError("No wallpapers were created")
    return completed_monitors, wallpapers, failures


def apply_wallpapers(monitors: list[Monitor], wallpapers: list[Path]) -> int:
    cache = Path.home() / "Library/Caches/APOD-Script"
    cache.mkdir(parents=True, exist_ok=True)
    run_id = time.time_ns()
    failures = 0
    applied_count = 0
    for index, (monitor, wallpaper) in enumerate(zip(monitors, wallpapers, strict=True), start=1):
        cached = cache / f"{run_id}-{index}{wallpaper.suffix or '.jpg'}"
        shutil.copy2(wallpaper, cached)
        clear_quarantine(cached)
        name_literal = json.dumps(monitor.name)
        path_literal = json.dumps(str(cached))
        script = f"""ObjC.import('AppKit');
var name = {name_literal};
var path = {path_literal};
var screens = $.NSScreen.screens.js.filter(function(screen) {{ return screen.localizedName.js === name; }});
if (screens.length !== 1) throw new Error('Display not found: ' + name);
var screen = screens[0];
var workspace = $.NSWorkspace.sharedWorkspace;
var url = $.NSURL.fileURLWithPath(path);
var options = workspace.desktopImageOptionsForScreen(screen);
var error = Ref();
var success = workspace.setDesktopImageURLForScreenOptionsError(url, screen, options, error);
if (!success) throw new Error(error[0] ? error[0].localizedDescription.js : 'Wallpaper update failed');
var appliedPath = workspace.desktopImageURLForScreen(screen).path.js;
if (appliedPath !== path) throw new Error('Wallpaper update was not retained for ' + name);"""
        applied = False
        last_error = "unknown error"
        for attempt in range(3):
            result = run(
                [command_path("osascript"), "-l", "JavaScript", "-e", script],
                check=False,
                timeout=15,
            )
            if result.returncode == 0:
                applied = True
                applied_count += 1
                break
            last_error = result.stderr.strip() or f"exit status {result.returncode}"
            if attempt < 2:
                time.sleep(1)
        if not applied:
            failures += 1
            print(f"Failed to apply wallpaper for {monitor.name}: {last_error}", file=sys.stderr)
    if applied_count:
        subprocess.run(
            [command_path("killall"), "WallpaperAgent"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
    return failures


def git(*arguments: str, capture: bool = False) -> str:
    result = subprocess.run(
        [command_path("git"), "-C", str(SCRIPT_DIR), *arguments],
        check=True,
        text=True,
        capture_output=capture,
    )
    return result.stdout.strip() if capture else ""


def active_wallpapers(monitors: list[Monitor]) -> list[Path]:
    script = """ObjC.import('AppKit');
var workspace = $.NSWorkspace.sharedWorkspace;
$.NSScreen.screens.js.map(function(screen) {
    var url = workspace.desktopImageURLForScreen(screen);
    return screen.localizedName.js + '\\t' + (url ? url.path.js : '');
}).join('\\n');"""
    result = run([command_path("osascript"), "-l", "JavaScript", "-e", script], timeout=15)
    paths: dict[str, Path] = {}
    for line in result.stdout.splitlines():
        name, separator, value = line.partition("\t")
        if separator and value:
            paths[name] = Path(value)
    wallpapers: list[Path] = []
    for monitor in monitors:
        path = paths.get(monitor.name)
        if path is None or not path.is_file():
            raise RuntimeError(f"Active wallpaper not found for {monitor.name}")
        wallpapers.append(path)
    return wallpapers


def clean_cache(active: list[Path]) -> None:
    cache = Path.home() / "Library/Caches/APOD-Script"
    preserved = {path.resolve() for path in active}
    cutoff = time.time() - 7 * 24 * 60 * 60
    for path in cache.glob("*.jpg"):
        if path.resolve() not in preserved and path.stat().st_mtime < cutoff:
            path.unlink()


def publish(wallpapers: list[Path]) -> None:
    working_tree = git("status", "--porcelain", "--untracked-files=all", capture=True).splitlines()
    if working_tree:
        print("Wallpaper not published: repository has uncommitted changes", file=sys.stderr)
        return
    git("fetch", "origin", "main")
    unpublished = git("diff", "--name-only", "origin/main..HEAD", capture=True).splitlines()
    if any(path != "README.md" and not re.fullmatch(r"\d{3}\.jpg", path) for path in unpublished):
        raise RuntimeError("Local branch has unpushed commits")
    published: list[Path] = []
    for index, wallpaper in enumerate(wallpapers, start=1):
        destination = SCRIPT_DIR / f"{index:03}.jpg"
        shutil.copy2(wallpaper, destination)
        destination.chmod(0o644)
        published.append(destination)
    tracked = git("ls-files", capture=True).splitlines()
    stale = [SCRIPT_DIR / path for path in tracked if re.fullmatch(r"\d{3}\.jpg", path) and SCRIPT_DIR / path not in published]
    for path in stale:
        path.unlink(missing_ok=True)
    readme = SCRIPT_DIR / "README.md"
    content = readme.read_text()
    version = time.time_ns()
    images = "\n".join(
        f"![Wallpaper {index}](https://raw.githubusercontent.com/yohanduartep/APOD-Script/refs/heads/main/{path.name}?v={version})"
        for index, path in enumerate(published, start=1)
    )
    section = f"## Current wallpapers\n\n{images}\n"
    updated = re.sub(r"## Current wallpapers\n.*?(?=\n## )", section.rstrip(), content, flags=re.DOTALL)
    readme.write_text(updated)
    managed = ["README.md", *[path.name for path in published], *[path.name for path in stale]]
    git("add", "--all", "--", *managed)
    changed = subprocess.run([command_path("git"), "-C", str(SCRIPT_DIR), "diff", "--cached", "--quiet"]).returncode
    if changed:
        git("commit", "-m", f"Update wallpapers {date.today().isoformat()}", "--", *managed)
        git("push", "origin", "HEAD:main")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--skip", action="append", default=[], metavar="DISPLAY")
    return parser.parse_args()


def main() -> int:
    try:
        arguments = parse_args()
        config = load_config()
        monitors = detect_monitors()
        monitor_names = {monitor.name for monitor in monitors}
        unknown = set(arguments.skip) - monitor_names
        if unknown:
            raise RuntimeError(f"Unknown display: {', '.join(sorted(unknown))}")
        identify = identify_command()
        completed_monitors, wallpapers, failures = acquire_wallpapers(
            config, monitors, identify, set(arguments.skip)
        )
        application_failures = apply_wallpapers(completed_monitors, wallpapers)
        failures += application_failures
        active = active_wallpapers(monitors)
        publish(active)
        clean_cache(active)
        print(f"Done: created {len(wallpapers)} monitor-matched wallpaper(s), {failures} failed")
        return 1 if failures else 0
    except (RuntimeError, OSError, subprocess.SubprocessError, urllib.error.URLError) as error:
        print(error, file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
