#!/usr/bin/env bash
# Check whether an ESP32 (or common USB-serial bridge) is connected.
# Usage: ./check_esp32.sh [-w]   (-w = watch until connected)

# Known USB vendor:product prefixes used by ESP32 boards
# 303a = Espressif (native USB), 10c4 = CP210x, 1a86 = CH340/CH9102, 0403 = FTDI
VENDORS="303a 10c4 1a86 0403"

check() {
  local found=0
  for d in /sys/bus/usb/devices/*/; do
    [ -f "$d/idVendor" ] || continue
    local vid pid name
    vid=$(cat "$d/idVendor"); pid=$(cat "$d/idProduct")
    name=$(cat "$d/product" 2>/dev/null)
    for v in $VENDORS; do
      if [ "$vid" = "$v" ]; then
        echo "USB device: $vid:$pid ${name:-unknown}"
        found=1
      fi
    done
  done

  local ports
  ports=$(ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null)
  if [ -n "$ports" ]; then
    echo "Serial ports:"
    echo "$ports" | sed 's/^/  /'
  fi

  if [ "$found" -eq 1 ] && [ -n "$ports" ]; then
    echo "✅ ESP32 is connected."
    [ -w "$(echo "$ports" | head -1)" ] || echo "⚠️  No write access to port (add user to 'dialout' group)."
    return 0
  elif [ "$found" -eq 1 ]; then
    echo "⚠️  USB device found but no serial port (driver missing?)."
    return 2
  else
    echo "❌ ESP32 not connected."
    return 1
  fi
}

if [ "$1" = "-w" ]; then
  echo "Waiting for ESP32 (Ctrl+C to stop)..."
  until check >/dev/null 2>&1; do sleep 1; done
  check
else
  check
fi
