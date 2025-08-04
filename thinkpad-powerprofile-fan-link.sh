#!/usr/bin/env bash
set -e
# -----------------------------------------------------------------------------
# ThinkPad Power-Profile-Fan Link Installer & Uninstaller
# Usage:
#   Install:   sudo ./thinkpad-power-profile-fan.sh install
#   Uninstall: sudo ./thinkpad-power-profile-fan.sh remove
# Detects tuned or power-profiles-daemon, configures event-driven hooks,
# and can revert all changes.
# -----------------------------------------------------------------------------

err(){ echo "Error $1: $2" >&2; exit "$1"; }
if [[ $EUID -ne 0 ]]; then err 1 "Run as root"; fi
ACTION=$1
[[ "$ACTION" =~ ^(install|remove)$ ]] || { echo "Usage: $0 install|remove"; exit 1; }

# Paths
MODCONF="/etc/modprobe.d/thinkpad_acpi.conf"
PPD_DIR="/etc/power-profiles.d"
TUNED_ETC="/etc/tuned"
PPD_SCRIPT="/usr/local/bin/power-profile-fan-ppd.sh"
TUNED_SCRIPT="/usr/local/bin/power-profile-fan-tuned.sh"
PPD_SERVICE="thinkpad-powerprofile-fan-ppd.service"
TUNED_SERVICE="thinkpad-powerprofile-fan-tuned.service"
PPD_PROFS=(power-saver balanced performance)
TUNED_BASES=(powersave "balanced-battery" throughput-performance)

remove_all(){
  for svc in "$PPD_SERVICE" "$TUNED_SERVICE"; do
    systemctl disable --now "$svc" 2>/dev/null || true
    rm -f "/etc/systemd/system/$svc"
  done
  systemctl daemon-reload
  rm -f "$PPD_SCRIPT" "$TUNED_SCRIPT"
  for prof in "${PPD_PROFS[@]}"; do
    rm -f "$PPD_DIR/$prof/00-set-fan.sh"
    rmdir --ignore-fail-on-non-empty "$PPD_DIR/$prof" 2>/dev/null || true
  done
  rmdir --ignore-fail-on-non-empty "$PPD_DIR" 2>/dev/null || true
  for base in "${TUNED_BASES[@]}"; do
    rm -rf "$TUNED_ETC/fan-$base"
  done
  rm -f "$MODCONF"
  modprobe -r thinkpad_acpi 2>/dev/null || true
  modprobe thinkpad_acpi || true
  echo "Cleanup complete."
  exit 0
}
[[ "$ACTION" == "remove" ]] && remove_all

# Detect package manager
if grep -qi ubuntu /etc/os-release; then
  PKG="apt install -y"
elif grep -qi fedora /etc/os-release; then
  PKG="dnf install -y"
else
  err 10 "Unsupported distro"
fi

# Detect power manager
if command -v powerprofilesctl &>/dev/null; then
  MANAGER="ppd"; echo "[*] Using power-profiles-daemon"
elif command -v tuned-adm &>/dev/null; then
  MANAGER="tuned"; echo "[*] Using tuned"
else
  echo "[*] Installing power-profiles-daemon..."
  $PKG power-profiles-daemon || err 11 "Failed install ppd"
  MANAGER="ppd"
fi

# Fan level mapping
declare -A fan_map=(
  [power-saver]="0"
  [balanced]="auto"
  [performance]="full-speed"
)
echo "Default levels: power-saver→0, balanced→auto, performance→full-speed"
read -rp "Customize levels? [y/N]: " R
if [[ "$R" =~ ^[Yy]$ ]]; then
  read -rp "power-saver level: " fan_map[power-saver]
  read -rp "balanced level:    " fan_map[balanced]
  read -rp "performance level: " fan_map[performance]
fi

# Enable manual fan control
mkdir -p /etc/modprobe.d
echo "options thinkpad_acpi experimental=1 fan_control=1" > "$MODCONF"
modprobe -r thinkpad_acpi 2>/dev/null || true
modprobe thinkpad_acpi experimental=1 fan_control=1 || err 21 "Failed reload module"
if [[ "$(cat /sys/module/thinkpad_acpi/parameters/fan_control)" != "Y" ]]; then
  err 22 "Manual fan_control not active"
fi
[[ -d /proc/acpi/ibm && $(grep -c commands /proc/acpi/ibm/fan) -gt 0 ]] || err 30 "Fan interface missing"
echo "[✓] Manual fan control enabled"

# PPd setup
setup_ppd(){
  mkdir -p "$PPD_DIR"
  for prof in "${PPD_PROFS[@]}"; do
    lvl="${fan_map[$prof]}"
    mkdir -p "$PPD_DIR/$prof"
    cat > "$PPD_DIR/$prof/00-set-fan.sh" <<EOF
#!/usr/bin/env bash
echo "level $lvl" > /proc/acpi/ibm/fan
EOF
    chmod +x "$PPD_DIR/$prof/00-set-fan.sh"
  done
  cat > "$PPD_SCRIPT" <<'EOF'
#!/usr/bin/env bash
dbus-monitor --system \
  "type='signal',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged',path='/org/freedesktop/PowerProfiles'" | \
while read -r _ _ iface _ msg; do
  [[ "$iface" != "org.freedesktop.PowerProfiles" ]] && continue
  echo "$msg" | grep -q ActiveProfile || continue
  prof=$(powerprofilesctl get)
  case "$prof" in
    power-saver) lvl=0;;
    balanced)    lvl=auto;;
    performance) lvl=full-speed;;
    *)           lvl=auto;;
  esac
  echo "level $lvl" > /proc/acpi/ibm/fan
done
EOF
  chmod +x "$PPD_SCRIPT"
  cat > /etc/systemd/system/$PPD_SERVICE <<EOF
[Unit]
Description=ThinkPad Power-Profile-Fan Link (ppd listener)
After=dbus.service

[Service]
ExecStart=$PPD_SCRIPT
Restart=always

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now $PPD_SERVICE || true
  echo "Installed service: $PPD_SERVICE"
}

# Tuned setup
setup_tuned(){
  for base in "${TUNED_BASES[@]}"; do
    case "$base" in
      powersave) key="power-saver";;
      balanced-battery) key="balanced";;
      throughput-performance) key="performance";;
    esac
    lvl="${fan_map[$key]}"
    prof_dir="$TUNED_ETC/fan-$base"
    mkdir -p "$prof_dir"
    cp -r /usr/lib/tuned/$base/* "$prof_dir/" 2>/dev/null || true
    cat > "$prof_dir/fan.sh" <<EOT
#!/usr/bin/env bash
echo "level $lvl" > /proc/acpi/ibm/fan
EOT
    chmod +x "$prof_dir/fan.sh"
    cat > "$prof_dir/tuned.conf" <<EOT
[main]
include=$base

[scripts]
script=$prof_dir/fan.sh
EOT
  done
  systemctl restart tuned

  cat > "$TUNED_SCRIPT" <<'EOT'
#!/usr/bin/env bash
set -e

map_profile_to_level(){
  case "$1" in
    powersave) echo "0" ;;
    balanced-battery) echo "auto" ;;
    throughput-performance) echo "full-speed" ;;
    *) echo "auto" ;;
  esac
}

watch_profile(){
  last=""
  while true; do
    if [[ -f /etc/tuned/active_profile ]]; then
      current=$(< /etc/tuned/active_profile)
      current=${current//[[:space:]]/}
      if [[ "$current" != "$last" && -n "$current" ]]; then
        lvl=$(map_profile_to_level "$current")
        echo "Detected tuned profile: $current → Fan level: $lvl"
        echo "level $lvl" > /proc/acpi/ibm/fan 2>/dev/null || true
        last="$current"
      fi
    fi
    sleep 3
done
}

watch_profile
EOT
  chmod +x "$TUNED_SCRIPT"
  cat > /etc/systemd/system/$TUNED_SERVICE <<EOF
[Unit]
Description=ThinkPad Power-Profile-Fan Link (tuned monitor)
After=multi-user.target

[Service]
ExecStart=$TUNED_SCRIPT
Restart=always

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now $TUNED_SERVICE || true
  echo "Installed service: $TUNED_SERVICE"
}

# Execute setup and display
if [[ "$MANAGER" == "ppd" ]]; then
  setup_ppd
else
  setup_tuned
fi

echo "[INSTALL COMPLETE]"

