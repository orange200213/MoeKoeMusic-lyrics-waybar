#!/usr/bin/env python3
"""MoeKoe Music Waybar lyrics script with 1s JSON refresh cadence."""

import json
import re
import sys
import time

try:
    import websocket
except ImportError:
    print(
        json.dumps(
            {
                "text": "MoeKoe",
                "tooltip": "Missing dependency: websocket-client",
                "class": "error",
            },
            ensure_ascii=False,
        ),
        flush=True,
    )
    sys.exit(1)

WS_URL = "ws://127.0.0.1:6520"
RECONNECT_DELAY = 3
OUTPUT_INTERVAL = 1.0
POLL_INTERVAL = 0.2
IDLE_TEXT = "MoeKoe"
CONNECTING_TEXT = "MoeKoe"
DISCONNECTED_TEXT = "MoeKoe"

LINE_RE = re.compile(r"^\[(\d+),(\d+)\](.*)$", re.MULTILINE)


def json_output(text: str, tooltip: str, css_class: str) -> None:
    print(
        json.dumps(
            {"text": text, "tooltip": tooltip, "class": css_class},
            ensure_ascii=False,
        ),
        flush=True,
    )


def song_title(song: object) -> str:
    if not isinstance(song, dict):
        return ""
    for key in ("name", "songName", "title"):
        value = song.get(key)
        if isinstance(value, str):
            return value
    return ""


def song_artist(song: object) -> str:
    if not isinstance(song, dict):
        return ""
    for key in ("author", "artist", "singername", "singer", "artistName"):
        value = song.get(key)
        if isinstance(value, str):
            return value
    return ""


def build_tooltip(title: str, artist: str) -> str:
    if title and artist:
        return f"{title} - {artist}"
    if title:
        return title
    return artist


def extract_current_line(krc_text: str, current_time_sec: float) -> str:
    now_ms = current_time_sec * 1000
    for parts in LINE_RE.finditer(krc_text):
        start_ms = int(parts.group(1))
        end_ms = start_ms + int(parts.group(2))
        if start_ms <= now_ms <= end_ms:
            line = re.sub(r"<[^>]+>", "", parts.group(3))
            return line.replace("\r", "")
    return ""


def render_state(current_song_json: object, is_playing: bool, current_time: float, krc_text: str) -> None:
    title = song_title(current_song_json)
    artist = song_artist(current_song_json)
    tooltip = build_tooltip(title, artist)

    if not is_playing:
        if title:
            json_output(f"⏸ {title}", tooltip, "paused")
        else:
            json_output("⏸", tooltip, "paused")
        return

    line = extract_current_line(krc_text, current_time) if krc_text else ""

    if line:
        json_output(line, tooltip, "playing")
    elif title:
        json_output(title, tooltip, "playing")
    else:
        json_output(IDLE_TEXT, tooltip, "playing")


def main() -> None:
    current_song_json: object = {}
    is_playing = False
    current_time = 0.0
    krc_text = ""

    json_output(CONNECTING_TEXT, "Connecting to MoeKoe Music...", "connecting")

    while True:
        ws = None
        try:
            ws = websocket.create_connection(WS_URL, timeout=POLL_INTERVAL)
            ws.settimeout(POLL_INTERVAL)
            last_emit_monotonic = 0.0

            while True:
                try:
                    raw = ws.recv()
                except websocket.WebSocketTimeoutException:
                    raw = None
                except websocket.WebSocketConnectionClosedException:
                    break

                if raw:
                    try:
                        msg = json.loads(raw)
                    except Exception:
                        msg = None

                    if isinstance(msg, dict):
                        msg_type = msg.get("type")
                        if msg_type == "lyrics":
                            data = msg.get("data") or {}
                            lyrics_data = data.get("lyricsData", "")
                            krc_text = lyrics_data if isinstance(lyrics_data, str) else ""
                            current_time = float(data.get("currentTime") or 0)
                            maybe_song = data.get("currentSong")
                            if maybe_song is not None:
                                current_song_json = maybe_song
                        elif msg_type == "playerState":
                            data = msg.get("data") or {}
                            is_playing = bool(data.get("isPlaying", False))
                            current_time = float(data.get("currentTime") or 0)

                now_monotonic = time.monotonic()
                if last_emit_monotonic == 0.0:
                    render_state(current_song_json, is_playing, current_time, krc_text)
                    last_emit_monotonic = now_monotonic
                    continue

                if now_monotonic - last_emit_monotonic >= OUTPUT_INTERVAL:
                    if is_playing:
                        current_time += now_monotonic - last_emit_monotonic
                    render_state(current_song_json, is_playing, current_time, krc_text)
                    last_emit_monotonic = now_monotonic
        except Exception:
            pass
        finally:
            if ws is not None:
                try:
                    ws.close()
                except Exception:
                    pass

        json_output(
            DISCONNECTED_TEXT,
            "MoeKoe Music not running or API mode is off",
            "disconnected",
        )
        time.sleep(RECONNECT_DELAY)


if __name__ == "__main__":
    main()
