# ThinkPad Power Profile Fan Link
Creates a hook between the power profile that is currently active and the fan level (balanced-auto/performance-full speed) compatible with Fedora, Ubuntu and Arch based distros (only tested on Fedora with tuned so far) also compatible with both Tuned and Power-Profiles-Daemon.

> [!WARNING]
> This script is only meant for Thinkpads (with a single fan) since it requires the folder `/proc/acpi/ibm` and the file `fan` to exist inside it


## Usage
- Download the raw file `thinkpad-powerprofile-fan-link.sh`
- Either cd into the folder and run `chmod +x ./thinkpad-powerprofile-fan-link.sh` or right click on the file go to properties and enable "executable as program"
- run `sudo ./thinkpad-powerprofile-fan-link.sh install`

The script will prompt you in case you want to modify the hooks to the power profiles and the fan levels

> [!TIP]
> For fan level commands ensure the file `/etc/modprobe.d/thinkpad_acpi.conf` exists and contains `options thinkpad_acpi fan_control=1` either before (if you want to customize the fan levels) or after installation (the script will automatically check for the file, create it and edit it for you if it doesn't exist) once that file exists and the text inside it reflects as previously mentioned, the commands will appear on the file `/proc/acpi/ibm/fan` or you can run `cat /proc/acpi/fan | grep "Commmands:"`

>[!note]
> since this script was created with the help of chatgpt, you can upload it and ask for help troubleshooting, I will try to install more distros and try it with both PPD and tuned on each but can't promise since that'd take a LONG time

<!--## Troubleshooting


### Tuned

Run `journalctl -u thinkpad-powerprofile-fan-tuned.service -f` and check for `detected profile` it should say the name of the profile, in case it says `active_profile` (meaning it's using the name of the file instead of the text inside it)
To fix it, edit as follows:

run `cat /usr/local/bin/power-profile-fan-tuned.sh` and check for this lines:
```
if [[ -f /etc/tuned/active_profile ]]; then
  current=$(< /etc/tuned/active_profile)
  current=$(echo "$current" | tr -d '[:space:]')
```

if they exist either open the file with a GUI text editor or run `sudo nano /usr/local/bin/power-profile-fan-tuned.sh` and replace those lines with the following:

```
if [[ -f /etc/tuned/active_profile ]]; then
  read -r current < /etc/tuned/active_profile
  current="${current##*/}"           # remove path if any
  current="$(echo "$current" | tr -d '[:space:]')" # clean up
  [[ -z "$current" ]] && continue    # skip if empty
```

### power-profiles-daemon

do the same as Tuned but instead use `journalctl -u thinkpad-powerprofile-fan-ppd.service -f` and `/usr/local/bin/power-profile-fan-ppd.sh` -->
