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
TG_MICROPHONE_MODE=none
tg_config_save
first=$(stat -c '%i:%Y' "$TG_CONFIG_FILE")
tg_config_save
[[ $(stat -c '%i:%Y' "$TG_CONFIG_FILE") == "$first" ]]
TG_CAMERA_MODE=all
tg_config_load
[[ $TG_CAMERA_MODE == selected && $TG_MICROPHONE_MODE == none && ${TG_CAMERA_IDS[*]} == saved-camera ]]
TG_MICROPHONE_MODE=selected
TG_MICROPHONE_IDS=(alsa_input.usb-Desk:mic input-monitor)
tg_config_save
tg_config_load
[[ $TG_MICROPHONE_MODE == selected && ${TG_MICROPHONE_IDS[*]} == 'alsa_input.usb-Desk:mic input-monitor' ]]
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
cp -- "$TG_CONFIG_FILE" "$scratch/default-settings"
# Old yes/no settings retain their meaning and are saved in the new format.
for legacy in yes no; do
	sed "s/^microphone-mode.*/microphone\t$legacy/" "$scratch/default-settings" > "$TG_CONFIG_FILE"
	tg_config_load
	if [[ $legacy == yes ]]; then expected=all; else expected=none; fi
	[[ $TG_MICROPHONE_MODE == "$expected" && ${#TG_MICROPHONE_IDS[@]} == 0 ]]
	tg_config_save
	grep -qx $'microphone-mode\t'"$expected" "$TG_CONFIG_FILE"
done
# Invalid selections and mixed legacy/new settings fail closed.
for invalid in $'microphone\talsa_input.usb-Desk:mic' $'microphone\tno' $'microphone-mode\tall'; do
	cp -- "$scratch/default-settings" "$TG_CONFIG_FILE"
	printf '%s\n' "$invalid" >> "$TG_CONFIG_FILE"
	if tg_config_load; then exit 1; fi
done
for invalid in '' $'microphone\t42' $'microphone\t42mic' $'microphone\tinput.monitor' $'microphone\tyes' $'microphone\tinput with spaces' $'microphone\tinput"; injected=true' $'microphone\tinput\\escaped' $'microphone\tinput\textra' $'microphone\tinput\nmicrophone\tinput'; do
	sed 's/^microphone-mode.*/microphone-mode\tselected/' "$scratch/default-settings" > "$TG_CONFIG_FILE"
	printf '%s\n' "$invalid" >> "$TG_CONFIG_FILE"
	if tg_config_load; then exit 1; fi
done
sed 's/^microphone-mode.*/microphone\tyes/' "$scratch/default-settings" > "$TG_CONFIG_FILE"
printf 'microphone\tno\n' >> "$TG_CONFIG_FILE"
if tg_config_load; then exit 1; fi
tg_config_defaults
TG_RUNTIME=$scratch/runtime
TG_PULSE_SOCKET=$scratch/runtime/pulse/native
# The source name is stable; numeric source indexes and monitor naming are not.
cat > "$scratch/sources" <<'SOURCES'
Source #91
	Name: alsa_input.usb-Desk:mic
	Description: Desk microphone
	Monitor of Sink: n/a
Source #92
	Name: input-monitor
	Description: A real microphone named monitor
	Monitor of Sink: n/a
Source #93
	Name: not-named-monitor
	Description: Playback monitor
	Monitor of Sink: 7
Source #94
	Name: unknown-kind
	Description: Missing authoritative monitor field
Source #95
	Name: 123
	Description: Numeric index cannot be a saved identity
	Monitor of Sink: n/a
Source #96
	Name: bad";injected=true
	Description: Invalid configuration syntax
	Monitor of Sink: n/a
Source #98
	Name: safe-prefix	invalid-suffix
	Description: A delimiter in a source name must not shorten its identity
	Monitor of Sink: n/a
SOURCES
printf 'Source #97\n\tName: safe-mic\n\tDescription: Control\033[31m label\n\tMonitor of Sink: n/a\n' >> "$scratch/sources"
tg_microphone_sources() {
	printf '%s\n' "$*" >> "$scratch/pactl-operations"
	[[ -z $* || $* == "--server=unix:$TG_PULSE_SOCKET" ]] || return 1
	cat -- "$scratch/sources"
}
TG_MICROPHONE_MODE=selected
TG_MICROPHONE_IDS=(disconnected-microphone)
tg_microphones_discover "$TG_PULSE_SOCKET" 2> "$scratch/discovery-errors"
[[ ${TG_MICROPHONES_IDS[*]} == 'disconnected-microphone alsa_input.usb-Desk:mic input-monitor safe-mic' ]]
[[ ${TG_MICROPHONES_CONNECTED[*]} == 'no yes yes yes' && ${TG_MICROPHONES_SELECTED[*]} == 'yes no no no' ]]
[[ ${TG_MICROPHONES_LABELS[3]} == 'Control?[31m label' ]]
grep -qx -- "--server=unix:$TG_PULSE_SOCKET" "$scratch/pactl-operations"
# UI exposes disconnected saved entries, replacement, all/none and microphone.
TG_CAMERA_MODE=selected
TG_CAMERA_KINDS=(by-id)
TG_CAMERA_IDS=(disconnected-camera)
tg_media_choose > "$scratch/current" 2>/dev/null <<'CHOICES'


CHOICES
grep -q 'disconnected-camera' "$scratch/current"
grep -q 'disconnected-microphone (disconnected)' "$scratch/current"
[[ $TG_MICROPHONE_MODE == selected && ${TG_MICROPHONE_IDS[*]} == disconnected-microphone && $TG_CAMERA_MODE == selected ]]
tg_media_choose > /dev/null 2>/dev/null <<'CHOICES'
all
2,3 2
CHOICES
[[ $TG_CAMERA_MODE == all && $TG_MICROPHONE_MODE == selected && ${TG_MICROPHONE_IDS[*]} == 'alsa_input.usb-Desk:mic input-monitor' && ${#TG_CAMERA_IDS[@]} == 0 ]]
tg_media_choose > /dev/null 2>/dev/null <<'CHOICES'
none
none
CHOICES
[[ $TG_CAMERA_MODE == none && $TG_MICROPHONE_MODE == none && ${#TG_MICROPHONE_IDS[@]} == 0 ]]
tg_media_choose > /dev/null 2>/dev/null <<'CHOICES'

all
CHOICES
[[ $TG_MICROPHONE_MODE == all && ${#TG_MICROPHONE_IDS[@]} == 0 ]]
tg_microphones_choose > /dev/null 2> "$scratch/choice-errors" <<'CHOICES'
0
999999999999999999999999999999999
01
1;touch invalid
1
CHOICES
[[ $TG_MICROPHONE_MODE == selected && ${TG_MICROPHONE_IDS[*]} == alsa_input.usb-Desk:mic ]]
[[ $(grep -c '^Choose displayed microphone numbers' "$scratch/choice-errors") == 4 ]]
unset -f tg_microphone_sources
tg_config_save
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
[[ ! -e $scratch/flatpak-operations ]]
# Exercise the actual native metadata parser, including namespace roots.
: > "$scratch/app-info"
exec {metadata_fd}< "$scratch/app-info"
printf '%s\0' --setenv TELEGRAM_WRAPPER telegram-sandbox \
	--setenv TELEGRAM_MICROPHONE_CONSENT no --setenv TELEGRAM_CAMERA_CONSENT no \
	--ro-bind-data "$metadata_fd" /.flatpak-info > "$scratch/arguments"
exec {arguments_fd}< "$scratch/arguments"
for grant in 'org.freedesktop.Flatpak=talk' 'org.freedesktop.Flatpak.*=talk' 'org.freedesktop.systemd1.*=own' '*=talk'; do
	printf '[Application]\nname=org.telegram.desktop\n[Session Bus Policy]\n%s\n' "$grant" > "$scratch/app-info"
	if tg_bwrap_inspect --args "$arguments_fd" 2>/dev/null; then exit 1; fi
done
printf '[Application]\nname=org.telegram.desktop\n[Session Bus Policy]\norg.freedesktop.Notifications=talk\n' > "$scratch/app-info"
# A marked Telegram sandbox needs two explicit native yes/no values. Partial,
# missing, ask and malformed metadata cannot silently grant either device.
for microphone in yes no; do
	for camera in yes no; do
		printf '%s\0' --setenv TELEGRAM_WRAPPER telegram-sandbox \
			--setenv TELEGRAM_MICROPHONE_CONSENT "$microphone" --setenv TELEGRAM_CAMERA_CONSENT "$camera" \
			--ro-bind-data "$metadata_fd" /.flatpak-info > "$scratch/arguments"
		tg_bwrap_inspect --args "$arguments_fd"
		[[ $TG_BWRAP_APP == yes && $TG_BWRAP_MICROPHONE_CONSENT == "$microphone" && $TG_BWRAP_CAMERA_CONSENT == "$camera" ]]
	done
done
for missing in both microphone camera; do
	arguments=(--setenv TELEGRAM_WRAPPER telegram-sandbox --ro-bind-data "$metadata_fd" /.flatpak-info)
	[[ $missing == both || $missing == microphone ]] || arguments+=(--setenv TELEGRAM_MICROPHONE_CONSENT yes)
	[[ $missing == both || $missing == camera ]] || arguments+=(--setenv TELEGRAM_CAMERA_CONSENT yes)
	printf '%s\0' "${arguments[@]}" > "$scratch/arguments"
	if tg_bwrap_inspect --args "$arguments_fd" 2> "$scratch/consent-error"; then exit 1; fi
	grep -q 'consent is missing or invalid' "$scratch/consent-error"
done
for device in MICROPHONE CAMERA; do
	for invalid in '' ask true YES 'yes no'; do
		printf '%s\0' --setenv TELEGRAM_WRAPPER telegram-sandbox \
			--setenv TELEGRAM_MICROPHONE_CONSENT yes --setenv TELEGRAM_CAMERA_CONSENT yes \
			--setenv "TELEGRAM_${device}_CONSENT" "$invalid" \
			--ro-bind-data "$metadata_fd" /.flatpak-info > "$scratch/arguments"
		if tg_bwrap_inspect --args "$arguments_fd" 2> "$scratch/consent-error"; then exit 1; fi
		grep -q 'consent is missing or invalid' "$scratch/consent-error"
	done
done
exec {metadata_fd}<&-
exec {arguments_fd}<&-
printf 'Telegram config, repeat setup choices and cleanup checks passed.\n'
