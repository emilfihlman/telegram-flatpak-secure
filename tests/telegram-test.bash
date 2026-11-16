#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
source ./telegram-common.bash
source ./telegram-media.bash
source ./telegram-setup.bash
source ./telegram-bwrap.bash
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
TG_PROGRAMS=$PWD
TG_APP=org.telegram.desktop
TG_DATA=$scratch/data
TG_CONFIG=$scratch/config/telegram-sandbox
TG_CONFIG_FILE=$TG_CONFIG/settings
TG_INSTALL_DIR=$TG_DATA/telegram-sandbox
TG_RUNTIME=$scratch/runtime
TG_DESKTOP=$TG_DATA/applications/org.telegram.desktop.desktop
TG_LEGACY_DESKTOP=$TG_DATA/applications/legacy-telegram-secure.desktop
TG_AUTOSTART_DIR=$scratch/config/autostart
mkdir -p -- "$TG_RUNTIME"
tg_config_defaults
if tg_config_load required; then exit 1; fi
TG_CAMERA_MODE=selected
TG_CAMERA_KINDS=(by-id)
TG_CAMERA_IDS=('saved-camera')
TG_MICROPHONE=no
tg_config_save
first=$(stat -c '%i:%Y' "$TG_CONFIG_FILE")
tg_config_save
[[ $(stat -c '%i:%Y' "$TG_CONFIG_FILE") == "$first" ]]
TG_CAMERA_MODE=all
tg_config_load
[[ $TG_CAMERA_MODE == selected && $TG_MICROPHONE == no && ${TG_CAMERA_IDS[*]} == saved-camera ]]
# shellcheck disable=SC2016 # Malicious-looking configuration must stay literal.
printf 'unknown\t$(touch %s/executed)\n' "$scratch" >> "$TG_CONFIG_FILE"
if tg_config_load; then exit 1; fi
[[ ! -e $scratch/executed ]]
printf 'camera-mode\tnone\n' > "$TG_CONFIG_FILE"
if tg_config_load required; then exit 1; fi
tg_config_defaults
TG_RUNTIME=$scratch/runtime
TG_PULSE_SOCKET=$scratch/runtime/pulse/native
tg_config_save
# UI exposes disconnected saved entries, replacement, all/none and microphone.
TG_CAMERA_MODE=selected
TG_CAMERA_KINDS=(by-id)
TG_CAMERA_IDS=(disconnected-camera)
tg_media_choose > "$scratch/current" <<'CHOICES'

no
CHOICES
grep -q 'disconnected-camera' "$scratch/current"
[[ $TG_MICROPHONE == no && $TG_CAMERA_MODE == selected ]]
tg_media_choose > /dev/null <<'CHOICES'
all
yes
CHOICES
[[ $TG_CAMERA_MODE == all && $TG_MICROPHONE == yes && ${#TG_CAMERA_IDS[@]} == 0 ]]
tg_media_choose > /dev/null <<'CHOICES'
none
no
CHOICES
[[ $TG_CAMERA_MODE == none && $TG_MICROPHONE == no ]]
# Removing only wrapper-owned paths preserves Telegram account/download fixtures.
mkdir -p -- "$TG_DATA/TelegramDesktop/tdata" "$scratch/downloads" "$TG_INSTALL_DIR" "${TG_DESKTOP%/*}"
printf 'account\n' > "$TG_DATA/TelegramDesktop/tdata/preserved"
printf 'download\n' > "$scratch/downloads/preserved"
printf 'helper\n' > "$TG_INSTALL_DIR/telegram-run.bash"
printf '[Desktop Entry]\nType=Application\nName=Telegram\nExec=true\nX-Telegram-Wrapper=true\n' > "$TG_DESKTOP"
flatpak() { printf '%s\n' "$*" >> "$scratch/flatpak-operations"; }
tg_stop() { :; }
tg_remove > /dev/null
[[ ! -e $TG_CONFIG_FILE && ! -e $TG_DESKTOP && ! -e $TG_INSTALL_DIR/telegram-run.bash ]]
[[ -f $TG_DATA/TelegramDesktop/tdata/preserved && -f $scratch/downloads/preserved ]]
grep -q 'permission-remove devices camera org.telegram.desktop' "$scratch/flatpak-operations"
# Exercise the actual native metadata parser, including namespace roots.
: > "$scratch/app-info"
exec {metadata_fd}< "$scratch/app-info"
printf '%s\0' --setenv TELEGRAM_WRAPPER telegram-sandbox --ro-bind-data "$metadata_fd" /.flatpak-info > "$scratch/arguments"
exec {arguments_fd}< "$scratch/arguments"
for grant in 'org.freedesktop.Flatpak=talk' 'org.freedesktop.Flatpak.*=talk' 'org.freedesktop.systemd1.*=own' '*=talk'; do
	printf '[Application]\nname=org.telegram.desktop\n[Session Bus Policy]\n%s\n' "$grant" > "$scratch/app-info"
	if tg_bwrap_inspect --args "$arguments_fd" 2>/dev/null; then exit 1; fi
done
printf '[Application]\nname=org.telegram.desktop\n[Session Bus Policy]\norg.freedesktop.Notifications=talk\n' > "$scratch/app-info"
tg_bwrap_inspect --args "$arguments_fd"
[[ $TG_BWRAP_APP == yes ]]
exec {metadata_fd}<&-
exec {arguments_fd}<&-
printf 'Telegram config, repeat setup choices and cleanup checks passed.\n'
