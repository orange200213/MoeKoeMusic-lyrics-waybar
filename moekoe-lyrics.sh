#!/usr/bin/env bash

set -u

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

WS_URL="${WS_URL:-ws://127.0.0.1:6520}"
RECONNECT_DELAY="${RECONNECT_DELAY:-3}"
OUTPUT_INTERVAL="${OUTPUT_INTERVAL:-1}"
POLL_INTERVAL="${POLL_INTERVAL:-0.2}"
IDLE_TEXT="${IDLE_TEXT:-MoeKoe}"
CONNECTING_TEXT="${CONNECTING_TEXT:-MoeKoe}"
DISCONNECTED_TEXT="${DISCONNECTED_TEXT:-MoeKoe}"

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "{\"text\":\"MoeKoe\",\"tooltip\":\"Missing dependency: $1\",\"class\":\"error\"}"
        exit 1
    fi
}

require_cmd websocat
require_cmd jq
require_cmd awk

json_output() {
    local text="$1"
    local tooltip="$2"
    local css_class="$3"

    jq -cn \
        --arg text "$text" \
        --arg tooltip "$tooltip" \
        --arg class "$css_class" \
        '{text: $text, tooltip: $tooltip, class: $class}'
}

song_title() {
    jq -r 'if type == "object" then (.name // .songName // .title // "") else "" end'
}

song_artist() {
    jq -r 'if type == "object" then (.author // .artist // .singername // .singer // .artistName // "") else "" end'
}

build_tooltip() {
    local title="$1"
    local artist="$2"

    if [[ -n "$title" && -n "$artist" ]]; then
        echo "$title - $artist"
    elif [[ -n "$title" ]]; then
        echo "$title"
    else
        echo "$artist"
    fi
}

extract_current_line() {
    local krc_text="$1"
    local current_time_sec="$2"

    awk -v now_sec="$current_time_sec" '
        BEGIN {
            now_ms = now_sec * 1000;
        }

        match($0, /^\[([0-9]+),([0-9]+)\](.*)$/, parts) {
            start_ms = parts[1] + 0;
            end_ms = start_ms + (parts[2] + 0);

            if (now_ms >= start_ms && now_ms <= end_ms) {
                line = parts[3];
                gsub(/<[^>]+>/, "", line);
                gsub(/\r/, "", line);
                print line;
                exit;
            }
        }
    ' <<< "$krc_text"
}

render_state() {
    local current_song_json="$1"
    local is_playing="$2"
    local current_time="$3"
    local krc_text="$4"

    local title artist tooltip line
    title="$(song_title <<< "$current_song_json")"
    artist="$(song_artist <<< "$current_song_json")"
    tooltip="$(build_tooltip "$title" "$artist")"

    if [[ "$is_playing" != "true" ]]; then
        if [[ -n "$title" ]]; then
            json_output "⏸ $title" "$tooltip" "paused"
        else
            json_output "⏸" "$tooltip" "paused"
        fi
        return
    fi

    if [[ -n "$krc_text" ]]; then
        line="$(extract_current_line "$krc_text" "$current_time")"
    else
        line=""
    fi

    if [[ -n "$line" ]]; then
        json_output "$line" "$tooltip" "playing"
    elif [[ -n "$title" ]]; then
        json_output "$title" "$tooltip" "playing"
    else
        json_output "$IDLE_TEXT" "$tooltip" "playing"
    fi
}

main() {
    local current_song_json='{}'
    local is_playing='false'
    local current_time='0'
    local krc_text=''
    local raw msg_type data maybe_song ws_fd ws_pid
    local output_interval_sec now_epoch last_emit_epoch delta_sec

    output_interval_sec="${OUTPUT_INTERVAL%%.*}"
    if [[ -z "$output_interval_sec" || "$output_interval_sec" -lt 1 ]]; then
        output_interval_sec=1
    fi

    json_output "$CONNECTING_TEXT" "Connecting to MoeKoe Music..." "connecting"

    while true; do
        coproc WS_CONN { websocat -t "$WS_URL" 2>/dev/null; }
        ws_fd="${WS_CONN[0]}"
        ws_pid="${WS_CONN_PID:-}"

        if [[ -z "$ws_pid" ]]; then
            json_output "$DISCONNECTED_TEXT" "MoeKoe Music not running or API mode is off" "disconnected"
            sleep "$RECONNECT_DELAY"
            continue
        fi

        last_emit_epoch=0

        while true; do
            if IFS= read -r -t "$POLL_INTERVAL" -u "$ws_fd" raw; then
                msg_type="$(jq -r '.type // empty' <<< "$raw" 2>/dev/null)"
                if [[ -n "$msg_type" ]]; then
                    case "$msg_type" in
                        lyrics)
                            data="$(jq -c '.data // {}' <<< "$raw" 2>/dev/null)"
                            krc_text="$(jq -r '(.lyricsData // "") | if type == "string" then . else "" end' <<< "$data" 2>/dev/null)"
                            current_time="$(jq -r '(.currentTime // 0)' <<< "$data" 2>/dev/null)"
                            maybe_song="$(jq -c '.currentSong // empty' <<< "$data" 2>/dev/null)"
                            if [[ -n "$maybe_song" && "$maybe_song" != "null" ]]; then
                                current_song_json="$maybe_song"
                            fi
                            ;;
                        playerState)
                            data="$(jq -c '.data // {}' <<< "$raw" 2>/dev/null)"
                            is_playing="$(jq -r 'if (.isPlaying // false) then "true" else "false" end' <<< "$data" 2>/dev/null)"
                            current_time="$(jq -r '(.currentTime // 0)' <<< "$data" 2>/dev/null)"
                            ;;
                    esac
                fi
            else
                kill -0 "$ws_pid" 2>/dev/null || break
            fi

            now_epoch="$(date +%s)"
            if (( last_emit_epoch == 0 )); then
                render_state "$current_song_json" "$is_playing" "$current_time" "$krc_text"
                last_emit_epoch="$now_epoch"
                continue
            fi

            if (( now_epoch - last_emit_epoch >= output_interval_sec )); then
                if [[ "$is_playing" == "true" ]]; then
                    delta_sec=$(( now_epoch - last_emit_epoch ))
                    current_time="$(awk -v t="$current_time" -v d="$delta_sec" 'BEGIN { printf "%.3f", t + d }')"
                fi
                render_state "$current_song_json" "$is_playing" "$current_time" "$krc_text"
                last_emit_epoch="$now_epoch"
            fi
        done

        wait "$ws_pid" 2>/dev/null

        json_output "$DISCONNECTED_TEXT" "MoeKoe Music not running or API mode is off" "disconnected"
        sleep "$RECONNECT_DELAY"
    done
}

main "$@"