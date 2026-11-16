#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
source ./telegram-setup.bash
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
TG_APP=org.telegram.desktop
TG_PROGRAMS=$PWD
TG_HOME=$scratch/home
TG_DATA=$TG_HOME/.local/share
TG_CONFIG=$TG_HOME/.config/telegram-sandbox
TG_CONFIG_FILE=$TG_CONFIG/settings
TG_INSTALL_DIR=$TG_DATA/telegram-sandbox
TG_RUNTIME=$scratch/runtime
mkdir -p -- "$TG_RUNTIME" "$TG_INSTALL_DIR" "$TG_DATA/TelegramDesktop/tdata" "$TG_HOME/Downloads"
tg_config_defaults
TG_PULSE_SOCKET=$TG_RUNTIME/pulse/native
TG_CAMERA_MODE=none
TG_MICROPHONE_MODE=none
tg_config_save
for file in telegram-common.bash telegram-media.bash telegram-audio.bash telegram-bwrap.bash telegram-run.bash config-path; do
	printf '# old wrapper file\n' > "$TG_INSTALL_DIR/$file"
done
printf 'account\n' > "$TG_DATA/TelegramDesktop/tdata/preserved"
printf 'download\n' > "$TG_HOME/Downloads/preserved"
old_files=$(sha256sum "$TG_INSTALL_DIR/"*)
old_settings=$(sha256sum "$TG_CONFIG_FILE")
TG_SETUP_KEEP_WORK=no
flatpak() {
	printf '%s\n' "$*" >> "$scratch/flatpak-operations"
	return 90
}
tg_desktop_prepare() { :; }
tg_desktop_apply() { :; }
# Setup preserves native consent; it must not write permission-set during commit.
TG_CAMERA_MODE=all
# Atomic settings replacement can fail after directory exchange. Keep the old
# complete program directory and settings, and remove only temporary output.
tg_setup_stage
native_mv=$(type -P mv)
mv() {
	if [[ ${!#} == "$TG_CONFIG_FILE" ]]; then return 73; fi
	"$native_mv" "$@"
}
if tg_setup_commit; then exit 1; fi
tg_setup_cleanup
[[ $(sha256sum "$TG_INSTALL_DIR/"*) == "$old_files" ]]
[[ $(sha256sum "$TG_CONFIG_FILE") == "$old_settings" ]]
[[ ! -e $TG_SETUP_WORK ]]
unset -f mv
# A completed repeat setup applies new choices and leaves no old program copy.
tg_setup_stage
tg_setup_commit
tg_setup_cleanup
tg_config_load required
[[ $TG_CAMERA_MODE == all && $TG_MICROPHONE_MODE == none ]]
cmp -s telegram-run.bash "$TG_INSTALL_DIR/telegram-run.bash"
[[ ! -e $TG_SETUP_WORK ]]
[[ ! -e $scratch/flatpak-operations ]]
for file in telegram-consent.bash telegram-dbus-proxy.bash telegram-audio-broker.bash telegram-microphones.bash; do
	[[ -x $TG_INSTALL_DIR/$file ]]
	cmp -s "$file" "$TG_INSTALL_DIR/$file"
done
# A signal immediately after the atomic directory exchange follows the same
# cleanup path, preserving the previous complete wrapper and choices.
old_files=$(sha256sum "$TG_INSTALL_DIR/"*)
old_settings=$(sha256sum "$TG_CONFIG_FILE")
status=0
(
	trap 'tg_setup_cleanup' EXIT
	trap 'exit 143' TERM
	TG_CAMERA_MODE=none
	tg_setup_stage
	mv() {
		"$native_mv" "$@" || return
		if [[ $1 == --exchange ]]; then kill -TERM "$BASHPID"; fi
	}
	tg_setup_commit
) || status=$?
[[ $status == 143 ]]
[[ $(sha256sum "$TG_INSTALL_DIR/"*) == "$old_files" ]]
[[ $(sha256sum "$TG_CONFIG_FILE") == "$old_settings" ]]
# The previous private PulseAudio runtime is a recognized disposable upgrade.
mkdir -- "$TG_INSTALL_DIR/pulseaudio"
printf 'telegram-flatpak-secure\n' > "$TG_INSTALL_DIR/pulseaudio/owner"
printf 'old runtime\n' > "$TG_INSTALL_DIR/pulseaudio/disposable"
tg_setup_stage
tg_setup_commit
tg_setup_cleanup
[[ ! -e $TG_INSTALL_DIR/pulseaudio ]]
[[ ! -e $scratch/flatpak-operations ]]
# Refuse to discard unrelated content during directory replacement.
printf 'useful\n' > "$TG_INSTALL_DIR/unrelated"
if tg_setup_stage 2>/dev/null; then exit 1; fi
grep -Fxq useful "$TG_INSTALL_DIR/unrelated"
tg_setup_cleanup
rm -- "$TG_INSTALL_DIR/unrelated"
# Existing profiles are selectable in both directions, with Enter preserving it.
TG_PROFILE=flatpak
tg_profile_choose > /dev/null <<< 2
[[ $TG_PROFILE == native ]]
tg_profile_choose > /dev/null <<< ''
[[ $TG_PROFILE == native ]]
tg_profile_choose > /dev/null <<< 1
[[ $TG_PROFILE == flatpak ]]
[[ $(cat "$TG_DATA/TelegramDesktop/tdata/preserved") == account ]]
[[ $(cat "$TG_HOME/Downloads/preserved") == download ]]
# First install failure removes only its newly installed program tree.
rm -rf -- "$TG_INSTALL_DIR"
TG_CONFIG_FILE=$TG_CONFIG/fresh-settings
tg_setup_stage
mv() {
	if [[ ${!#} == "$TG_CONFIG_FILE" ]]; then return 73; fi
	"$native_mv" "$@"
}
if tg_setup_commit; then exit 1; fi
tg_setup_cleanup
[[ ! -e $TG_INSTALL_DIR && ! -e $TG_CONFIG_FILE ]]
unset -f mv
# Reclaim only recognized disposable staging; explicitly retained recovery
# work and unrelated directories must survive the next exclusive setup.
mkdir -- "$TG_DATA/.telegram-setup.abandoned" "$TG_DATA/.telegram-setup.recovery" "$TG_DATA/.telegram-setup.unrelated"
printf 'telegram-setup\n' > "$TG_DATA/.telegram-setup.abandoned/owner"
printf 'telegram-setup\n' > "$TG_DATA/.telegram-setup.recovery/owner"
: > "$TG_DATA/.telegram-setup.recovery/recovery-needed"
: > "$TG_CONFIG/.telegram-settings.abandoned"
tg_setup_clear_abandoned 2>/dev/null
[[ ! -e $TG_DATA/.telegram-setup.abandoned && -d $TG_DATA/.telegram-setup.recovery && -d $TG_DATA/.telegram-setup.unrelated ]]
[[ ! -e $TG_CONFIG/.telegram-settings.abandoned ]]
printf 'Telegram staged update, failure preservation and profile checks passed.\n'
