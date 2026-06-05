#!/bin/sh
set -eu

PORT="${1:-5555}"
USB_WAIT_SECONDS="${USB_WAIT_SECONDS:-60}"

log() {
  printf '%s\n' "$*"
}

fail() {
  log "FAIL: $*"
  exit 1
}

case "$PORT" in
  ''|*[!0-9]*) fail "PORT must be numeric." ;;
esac
if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
  fail "PORT must be between 1 and 65535."
fi

command -v adb >/dev/null 2>&1 || fail "adb is required but was not found on PATH."

cleanup() {
  if [ -n "${usb_serial:-}" ]; then
    adb -s "$usb_serial" usb >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

diagnose_network_path() {
  log "Diagnostics:"
  log "  adb devices:"
  adb devices -l 2>&1 | sed 's/^/    /' || true

  if [ -n "${usb_serial:-}" ]; then
    log "  phone route:"
    adb -s "$usb_serial" shell ip route 2>&1 | sed 's/^/    /' || true
    log "  phone tcp adb port:"
    adb -s "$usb_serial" shell getprop service.adb.tcp.port 2>&1 | sed 's/^/    /' || true
    log "  phone port listeners:"
    adb -s "$usb_serial" shell "ss -ltnp 2>/dev/null | grep ':[0-9]*$PORT' || netstat -an 2>/dev/null | grep ':[0-9]*$PORT' || true" 2>&1 | sed 's/^/    /' || true
    if [ -n "${local_ip:-}" ]; then
      log "  phone-to-Mac ping:"
      adb -s "$usb_serial" shell ping -c 2 -W 1 "$local_ip" 2>&1 | sed 's/^/    /' || true
    fi
  fi

  if [ -n "${wifi_ip:-}" ]; then
    log "  Mac route to phone:"
    route -n get "$wifi_ip" 2>&1 | sed 's/^/    /' || true
    log "  Mac ARP entry for phone:"
    arp -n "$wifi_ip" 2>&1 | sed 's/^/    /' || true
    log "  Mac-to-phone ping:"
    ping -c 2 -W 1000 "$wifi_ip" 2>&1 | sed 's/^/    /' || true
    log "  Mac TCP probe to phone adb port:"
    nc -vz -G 2 "$wifi_ip" "$PORT" 2>&1 | sed 's/^/    /' || true
  fi
}

deadline=$(( $(date +%s) + USB_WAIT_SECONDS ))
usb_serial=""
adb_out=""
while [ "$(date +%s)" -le "$deadline" ]; do
  adb_out="$(adb devices -l)"
  usb_serial="$(printf '%s\n' "$adb_out" | awk '/ device / && /usb:/ { print $1; exit }')"
  if [ -n "$usb_serial" ]; then
    break
  fi
  log "Waiting for an authorized USB Android device... ($USB_WAIT_SECONDS second timeout)"
  sleep 2
done

if [ -z "$usb_serial" ]; then
  log "$adb_out"
  fail "No authorized USB Android device is visible to adb."
fi

log "USB device: $usb_serial"

route_out="$(adb -s "$usb_serial" shell ip route)"
wifi_ip="$(printf '%s\n' "$route_out" | awk '/wlan/ && / src / { for (i=1; i<=NF; i++) if ($i == "src") { print $(i+1); exit } }')"

if [ -z "$wifi_ip" ]; then
  log "$route_out"
  fail "Could not find a wlan source IP on the phone."
fi

target="$wifi_ip:$PORT"
log "Wi-Fi target: $target"

route_iface="$(route -n get "$wifi_ip" 2>/dev/null | awk '/interface:/ { print $2; exit }')"
case "$route_iface" in
  ''|*[!A-Za-z0-9._-]*) local_ip="" ;;
  *) local_ip="$(ipconfig getifaddr "$route_iface" 2>/dev/null || true)" ;;
esac
if [ -n "$local_ip" ]; then
  log "Priming phone-to-Mac route: phone ping $local_ip"
  adb -s "$usb_serial" shell ping -c 1 -W 1 "$local_ip" >/dev/null 2>&1 || true
fi

log "Enabling adb tcpip $PORT"
tcpip_out="$(adb -s "$usb_serial" tcpip "$PORT" 2>&1 || true)"
log "$tcpip_out"
printf '%s\n' "$tcpip_out" | grep -Eiq 'restarting in TCP mode port|already in TCP mode' || fail "adb tcpip did not report success."

connected=0
attempt=1
while [ "$attempt" -le 15 ]; do
  if [ -n "$local_ip" ]; then
    adb -s "$usb_serial" shell ping -c 1 -W 1 "$local_ip" >/dev/null 2>&1 || true
  fi
  connect_out="$(adb connect "$target" 2>&1 || true)"
  log "connect attempt $attempt: $connect_out"
  if printf '%s\n' "$connect_out" | grep -Eiq 'connected to|already connected to'; then
    connected=1
    break
  fi
  sleep 1
  attempt=$((attempt + 1))
done

if [ "$connected" -ne 1 ]; then
  diagnose_network_path
  fail "Could not connect to $target over Wi-Fi."
fi

ready=0
attempt=1
while [ "$attempt" -le 15 ]; do
  if [ -n "$local_ip" ]; then
    adb -s "$usb_serial" shell ping -c 1 -W 1 "$local_ip" >/dev/null 2>&1 || true
  fi
  shell_out="$(adb -s "$target" shell echo wifi-adb-ok 2>&1 || true)"
  log "shell attempt $attempt: $shell_out"
  if printf '%s\n' "$shell_out" | grep -q 'wifi-adb-ok'; then
    ready=1
    break
  fi
  sleep 1
  attempt=$((attempt + 1))
done

if [ "$ready" -ne 1 ]; then
  diagnose_network_path
  fail "Wi-Fi adb target did not execute shell command."
fi

log "PASS: USB-to-Wi-Fi adb handoff is established."
log "Now unplug the USB cable. This verifier will check that $target remains online for 15 seconds."

end=$(( $(date +%s) + 15 ))
while [ "$(date +%s)" -lt "$end" ]; do
  devices="$(adb devices -l)"
  if ! printf '%s\n' "$devices" | grep -q "^$target[[:space:]]*device"; then
    log "$devices"
    diagnose_network_path
    fail "Wi-Fi adb target disappeared after cable removal."
  fi
  sleep 1
done

log "PASS: Wi-Fi adb target stayed online after cable-removal window."
