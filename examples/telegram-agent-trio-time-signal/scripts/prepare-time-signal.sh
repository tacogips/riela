#!/usr/bin/env sh
set -eu

scheduled_at="${1:-}"
time_zone="${2:-}"

if [ -z "$scheduled_at" ]; then
  echo "scheduledAt is required" >&2
  exit 1
fi

if [ -z "$time_zone" ]; then
  echo "timezone is required" >&2
  exit 1
fi

case "$time_zone" in
  /*|*..*|*\\*)
    echo "invalid timezone: $time_zone" >&2
    exit 1
    ;;
esac
if [ ! -f "/usr/share/zoneinfo/$time_zone" ]; then
  echo "invalid timezone: $time_zone" >&2
  exit 1
fi

interval_minutes="${RIELA_TIME_SIGNAL_INTERVAL_MINUTES:-5}"
case "$interval_minutes" in
  ''|*[!0-9]*)
    echo "RIELA_TIME_SIGNAL_INTERVAL_MINUTES must be a positive integer" >&2
    exit 1
    ;;
esac
if [ "$interval_minutes" -le 0 ]; then
  echo "RIELA_TIME_SIGNAL_INTERVAL_MINUTES must be a positive integer" >&2
  exit 1
fi

normalized_utc=$(printf '%s\n' "$scheduled_at" | sed -E 's/\.[0-9]+Z$/Z/')
bsd_offset_utc=$(printf '%s\n' "$scheduled_at" | sed -E 's/\.[0-9]+([+-][0-9]{2}):?([0-9]{2})$/\1\2/; s/([+-][0-9]{2}):([0-9]{2})$/\1\2/')
fraction_digits=$(printf '%s\n' "$scheduled_at" | sed -nE 's/.*T[0-9]{2}:[0-9]{2}:[0-9]{2}\.([0-9]+)(Z|[+-][0-9]{2}:?[0-9]{2})$/\1/p')
fraction_millis=$(printf '%.3s' "${fraction_digits}000")

if epoch=$(date -u -d "$scheduled_at" '+%s' 2>/dev/null); then
  local_parts=$(TZ="$time_zone" date -d "@$epoch" '+%Y %m %d %H %M %S' 2>/dev/null) || {
    echo "failed to read local time for timezone $time_zone" >&2
    exit 1
  }
  scheduled_output=$(date -u -d "@$epoch" "+%Y-%m-%dT%H:%M:%S.${fraction_millis}Z" 2>/dev/null) || {
    echo "failed to normalize scheduledAt" >&2
    exit 1
  }
elif epoch=$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$normalized_utc" '+%s' 2>/dev/null); then
  local_parts=$(TZ="$time_zone" date -r "$epoch" '+%Y %m %d %H %M %S' 2>/dev/null) || {
    echo "failed to read local time for timezone $time_zone" >&2
    exit 1
  }
  scheduled_output=$(date -u -r "$epoch" "+%Y-%m-%dT%H:%M:%S.${fraction_millis}Z" 2>/dev/null) || {
    echo "failed to normalize scheduledAt" >&2
    exit 1
  }
elif epoch=$(date -j -u -f '%Y-%m-%dT%H:%M:%S%z' "$bsd_offset_utc" '+%s' 2>/dev/null); then
  local_parts=$(TZ="$time_zone" date -r "$epoch" '+%Y %m %d %H %M %S' 2>/dev/null) || {
    echo "failed to read local time for timezone $time_zone" >&2
    exit 1
  }
  scheduled_output=$(date -u -r "$epoch" "+%Y-%m-%dT%H:%M:%S.${fraction_millis}Z" 2>/dev/null) || {
    echo "failed to normalize scheduledAt" >&2
    exit 1
  }
else
  echo "scheduledAt must be an ISO timestamp: $scheduled_at" >&2
  exit 1
fi

set -- $local_parts
year="$1"
month="$2"
day="$3"
hour="$4"
minute="$5"
second="$6"

minute_number=$(printf '%s\n' "$minute" | sed 's/^0*//')
second_number=$(printf '%s\n' "$second" | sed 's/^0*//')
minute_number="${minute_number:-0}"
second_number="${second_number:-0}"
should_announce=false
reply_text=""
local_time="$year-$month-$day $hour:$minute"

if [ "$second_number" -eq 0 ] && [ $((minute_number % interval_minutes)) -eq 0 ]; then
  should_announce=true
  reply_text="時報です。$time_zone の現在時刻は $local_time です。"
fi

escaped_reply=$(printf '%s' "$reply_text" | sed 's/\\/\\\\/g; s/"/\\"/g')
escaped_timezone=$(printf '%s' "$time_zone" | sed 's/\\/\\\\/g; s/"/\\"/g')

printf '{"when":{"always":true,"should_announce":%s},"payload":{"shouldAnnounce":%s,"scheduledAt":"%s","timezone":"%s","intervalMinutes":%s,"localTime":"%s","replyText":"%s"}}\n' \
  "$should_announce" \
  "$should_announce" \
  "$scheduled_output" \
  "$escaped_timezone" \
  "$interval_minutes" \
  "$local_time" \
  "$escaped_reply"
