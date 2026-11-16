#!/usr/bin/env bash
set -euo pipefail
umask 077

source_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=telegram-common.bash
source "$source_dir/telegram-common.bash"
# shellcheck source=telegram-media.bash
source "$source_dir/telegram-media.bash"
# shellcheck source=telegram-desktop.bash
source "$source_dir/telegram-desktop.bash"
# shellcheck source=telegram-check.bash
source "$source_dir/telegram-check.bash"

tg_profile_choose() {
	local answer default=1
	if [[ ! -d $TG_NATIVE_PROFILE/tdata ]]; then
		if [[ $TG_PROFILE == native ]]; then
			printf '\nThe saved native profile is missing: %s\n' "$TG_NATIVE_PROFILE"
			read -r -p 'Use the Flatpak profile instead? [Y/n]: ' answer || return 1
			[[ ${answer,,} != n && ${answer,,} != no ]] || return 1
		fi
		TG_PROFILE=flatpak
		printf '\nProfile: Flatpak.\n'
		return 0
	fi
	[[ $TG_PROFILE != native ]] || default=2
	if [[ ! -f $TG_CONFIG_FILE && ! -d $TG_HOME/.var/app/$TG_APP/data/TelegramDesktop/tdata ]]; then default=2; fi
	printf '\nTelegram profile (no files are copied or moved):\n'
	printf '1. Flatpak: %s\n2. Native: %s\n' "$TG_HOME/.var/app/$TG_APP/data/TelegramDesktop" "$TG_NATIVE_PROFILE"
	while true; do
		read -r -p "Choose [$default]: " answer || return 1
		case ${answer:-$default} in
			1) TG_PROFILE=flatpak; return 0 ;;
			2) TG_PROFILE=native; return 0 ;;
			*) printf 'Choose 1 or 2.\n' >&2 ;;
		esac
	done
}

tg_native_profile_available() {
	[[ $TG_PROFILE == native ]] || return 0
	local pid
	while IFS= read -r pid; do
		[[ -n $pid && -e /proc/$pid/exe ]] || continue
		if [[ ! -e /proc/$pid/root/.flatpak-info ]]; then
			tg_error 'Close native Telegram before using its profile, then run setup again.'
			return 1
		fi
	done < <(pgrep -u "$UID" -x Telegram || :)
}

tg_setup_audio_runtime() {
	# Keep the desktop's PipeWire packages and services. Only selected-input
	# mode needs this private native broker when PulseAudio is not installed.
	[[ $TG_MICROPHONE_MODE == selected ]] || return 0
	! command -v pulseaudio >/dev/null || return 0
	local version dependency runtime=$TG_SETUP_WORK/programs/pulseaudio unpack=$TG_SETUP_WORK/audio-package
	local -a packages modules libraries
	tg_packages_update || return 1
	version=$(LC_ALL=C apt-cache policy pulseaudio | awk '/Candidate:/ { print $2; exit }') || return 1
	[[ -n $version && $version != '(none)' ]] || { tg_error 'No native PulseAudio broker package is available.'; return 1; }
	if tg_audio_runtime_owned "$TG_INSTALL_DIR/pulseaudio" && [[ -f $TG_INSTALL_DIR/pulseaudio/version && -f $TG_INSTALL_DIR/pulseaudio/dependencies && -x $TG_INSTALL_DIR/pulseaudio/bin/pulseaudio &&
		$(cat "$TG_INSTALL_DIR/pulseaudio/version") == "$version" ]]; then
		dependency=$(cat "$TG_INSTALL_DIR/pulseaudio/dependencies") || return 1
		sudo apt-get satisfy --no-remove --no-install-recommends -y "$dependency" || return 1
		cp -a --reflink=auto -- "$TG_INSTALL_DIR/pulseaudio" "$runtime" || return 1
		if (source "$TG_SETUP_WORK/programs/telegram-audio.bash"; tg_audio_supported); then return 0; fi
		# A broken disposable runtime must not be reused on every repair attempt.
		rm -rf -- "$runtime" || return 1
	fi
	printf '\nPreparing the private microphone broker...\n'
	(cd -- "$TG_SETUP_WORK" && apt-get download "pulseaudio=$version") || return 1
	packages=("$TG_SETUP_WORK"/pulseaudio_*.deb)
	[[ ${#packages[@]} == 1 && -f ${packages[0]} ]] || return 1
	dependency=$(dpkg-deb -f "${packages[0]}" Depends) || return 1
	sudo apt-get satisfy --no-remove --no-install-recommends -y "$dependency" || return 1
	dpkg-deb -x "${packages[0]}" "$unpack" || return 1
	modules=("$unpack"/usr/lib/pulse-*/modules)
	libraries=("$unpack"/usr/lib/*/pulseaudio/libpulsecore-*.so)
	[[ ${#modules[@]} == 1 && -d ${modules[0]} && ${#libraries[@]} == 1 && -f ${libraries[0]} ]] || return 1
	mkdir -p -- "$runtime/bin" "$runtime/lib" || return 1
	install -m 755 -- "$unpack/usr/bin/pulseaudio" "$runtime/bin/pulseaudio" || return 1
	cp -a -- "${modules[0]}" "$runtime/modules" || return 1
	install -m 644 -- "${libraries[0]}" "$runtime/lib/" || return 1
	printf '%s\n' "$version" > "$runtime/version" || return 1
	printf '%s\n' "$dependency" > "$runtime/dependencies" || return 1
	printf 'telegram-flatpak-secure\n' > "$runtime/owner" || return 1
	# Keep only the runtime used by the launcher, not package/config/service files.
	rm -rf -- "$unpack" "${packages[0]}"
}

tg_setup_stage() {
	local file
	mkdir -p -- "$TG_DATA"
	TG_SETUP_WORK=$(mktemp -d "$TG_DATA/.telegram-setup.XXXXXX")
	printf 'telegram-setup\n' > "$TG_SETUP_WORK/owner"
	mkdir -- "$TG_SETUP_WORK/programs"
	for file in telegram-common.bash telegram-media.bash telegram-audio.bash telegram-bwrap.bash telegram-run.bash; do
		[[ -r $source_dir/$file ]] || { tg_error "Missing $file."; return 1; }
		bash -n "$source_dir/$file" || return 1
		install -m 755 -- "$source_dir/$file" "$TG_SETUP_WORK/programs/$file" || return 1
	done
	tg_setup_audio_runtime || return 1
	(
		TG_CONFIG=$TG_SETUP_WORK/config/telegram-sandbox
		TG_CONFIG_FILE=$TG_CONFIG/settings
		tg_config_save
	) || return 1
	printf '%s\0' "$TG_SETUP_WORK/config/telegram-sandbox/settings" > "$TG_SETUP_WORK/programs/config-path"
	if [[ -e $TG_INSTALL_DIR || -L $TG_INSTALL_DIR ]]; then
		[[ -d $TG_INSTALL_DIR && ! -L $TG_INSTALL_DIR ]] || { tg_error "Not a wrapper directory: $TG_INSTALL_DIR"; return 1; }
		# Never discard files that are not part of this wrapper.
		for file in "$TG_INSTALL_DIR"/* "$TG_INSTALL_DIR"/.[!.]* "$TG_INSTALL_DIR"/..?*; do
			[[ -e $file || -L $file ]] || continue
			case ${file##*/} in
				pulseaudio)
					tg_audio_runtime_owned "$file" || { tg_error "Unexpected wrapper runtime: $file"; return 1; } ;;
				telegram-common.bash|telegram-media.bash|telegram-audio.bash|telegram-bwrap.bash|telegram-run.bash|config-path)
					[[ -f $file && ! -L $file ]] || { tg_error "Unexpected wrapper file: $file"; return 1; } ;;
				*) tg_error "Unrelated file in wrapper directory: $file"; return 1 ;;
			esac
		done
	fi
	tg_desktop_prepare "$TG_SETUP_WORK"
}

tg_setup_commit() {
	local permission=no
	printf '%s\0' "$TG_CONFIG_FILE" > "$TG_SETUP_WORK/programs/config-path" || return 1
	[[ ! -d $TG_CONFIG_FILE ]] || return 1
	mkdir -p -- "$TG_CONFIG" || return 1
	TG_SETUP_SETTINGS_TEMP=$(mktemp "$TG_CONFIG/.telegram-settings.XXXXXX") || return 1
	install -m 600 -- "$TG_SETUP_WORK/config/telegram-sandbox/settings" "$TG_SETUP_SETTINGS_TEMP" || return 1
	TG_SETUP_SETTINGS_ID=$(stat -Lc '%d:%i' -- "$TG_SETUP_SETTINGS_TEMP") || return 1
	TG_SETUP_PROGRAM_ID=$(stat -Lc '%d:%i' -- "$TG_SETUP_WORK/programs") || return 1
	TG_SETUP_REPLACING=no
	[[ ! -d $TG_INSTALL_DIR ]] || TG_SETUP_REPLACING=yes
	[[ $TG_CAMERA_MODE != all ]] || permission=yes
	TG_SETUP_PERMISSION_CHANGED=yes
	flatpak permission-set devices camera "$TG_APP" "$permission" || return 1
	# Both directories share a filesystem. Exchange keeps the working copy intact
	# until all replacement files are ready; the staging directory is then removed.
	TG_SETUP_PENDING=yes
	printf '%s\n' "$TG_SETUP_SETTINGS_ID" > "$TG_SETUP_WORK/recovery-needed"
	if [[ $TG_SETUP_REPLACING == yes ]]; then
		mv --exchange --no-copy -T -- "$TG_SETUP_WORK/programs" "$TG_INSTALL_DIR" || return 1
	else
		mv --no-copy -T -- "$TG_SETUP_WORK/programs" "$TG_INSTALL_DIR" || return 1
	fi
	mv --no-copy -fT -- "$TG_SETUP_SETTINGS_TEMP" "$TG_CONFIG_FILE" || return 1
	TG_SETUP_PERMISSION_CHANGED=no
	TG_SETUP_PENDING=no
	rm -- "$TG_SETUP_WORK/recovery-needed"
	tg_desktop_apply "$TG_SETUP_WORK" || {
		tg_error 'The wrapper is installed, but desktop routing needs repair. Run setup and choose Check / repair.'
		return 1
	}
}

tg_setup_cleanup() {
	local status=$? permission=no
	# Inode identity establishes which atomic rename completed, even if a signal
	# arrived between a rename and the following shell assignment.
	if [[ ${TG_SETUP_PENDING:-no} == yes && $(stat -Lc '%d:%i' -- "$TG_INSTALL_DIR" 2>/dev/null) == "${TG_SETUP_PROGRAM_ID:-}" ]]; then
		if [[ $(stat -Lc '%d:%i' -- "$TG_CONFIG_FILE" 2>/dev/null) == "${TG_SETUP_SETTINGS_ID:-}" ]]; then
			TG_SETUP_PERMISSION_CHANGED=no
		elif [[ ${TG_SETUP_REPLACING:-no} == yes ]]; then
			mv --exchange --no-copy -T -- "$TG_SETUP_WORK/programs" "$TG_INSTALL_DIR" || {
				TG_SETUP_KEEP_WORK=yes
				printf 'Previous wrapper files were retained in %s/programs; file replacement needs repair.\n' "$TG_SETUP_WORK" >&2
			}
		else
			rm -rf -- "$TG_INSTALL_DIR"
		fi
	fi
	if [[ ${TG_SETUP_PERMISSION_CHANGED:-no} == yes ]]; then
		if [[ -n ${TG_SETUP_PREVIOUS_CAMERA_MODE:-} ]]; then
			[[ $TG_SETUP_PREVIOUS_CAMERA_MODE != all ]] || permission=yes
			flatpak permission-set devices camera "$TG_APP" "$permission" 2>/dev/null || printf 'Could not restore the previous camera permission. Run setup and choose Check / repair.\n' >&2
		else
			flatpak permission-remove devices camera "$TG_APP" 2>/dev/null || :
		fi
	fi
	[[ -z ${TG_SETUP_SETTINGS_TEMP:-} ]] || rm -f -- "$TG_SETUP_SETTINGS_TEMP"
	if [[ -n ${TG_SETUP_WORK:-} && ${TG_SETUP_KEEP_WORK:-no} != yes ]]; then rm -rf -- "$TG_SETUP_WORK"; fi
	return "$status"
}

tg_setup_clear_abandoned() {
	local directory file pending_id
	for directory in "$TG_DATA/.telegram-setup."*; do
		[[ -d $directory && ! -L $directory && -O $directory && -f $directory/owner && ! -L $directory/owner ]] || continue
		[[ $(cat -- "$directory/owner") == telegram-setup ]] || continue
		if [[ -e $directory/recovery-needed ]]; then
			IFS= read -r pending_id < "$directory/recovery-needed" || pending_id=
			if [[ -n $pending_id && $(stat -Lc '%d:%i' -- "$TG_CONFIG_FILE" 2>/dev/null) == "$pending_id" ]]; then
				rm -rf -- "$directory"
			else
				printf 'Interrupted replacement files were retained for review: %s\n' "$directory" >&2
			fi
		else
			rm -rf -- "$directory"
		fi
	done
	for file in "$TG_CONFIG/.telegram-settings."*; do
		[[ -f $file && ! -L $file && -O $file ]] || continue
		rm -- "$file"
	done
}

main() {
	(( EUID != 0 )) || { tg_error 'Run ./telegram-setup.bash as your desktop user, without sudo.'; return 1; }
	[[ -t 0 ]] || { tg_error 'Run ./telegram-setup.bash in a terminal.'; return 1; }
	tg_paths
	local desktop_runtime=${XDG_RUNTIME_DIR:-/run/user/$UID} setup_lock
	[[ -d $desktop_runtime && -O $desktop_runtime ]] || { tg_error 'Your desktop runtime directory is unavailable.'; return 1; }
	exec {setup_lock}> "$desktop_runtime/telegram-setup.lock"
	flock -n "$setup_lock" || { tg_error 'Another Telegram setup is running.'; return 1; }
	tg_setup_clear_abandoned
	TG_SETUP_WORK=
	TG_SETUP_KEEP_WORK=no
	TG_SETUP_PERMISSION_CHANGED=no
	TG_SETUP_PENDING=no
	TG_SETUP_SETTINGS_TEMP=
	TG_SETUP_PREVIOUS_CAMERA_MODE=
	trap 'tg_setup_cleanup' EXIT
	trap 'exit 129' HUP
	trap 'exit 130' INT
	trap 'exit 143' TERM
	if ! tg_config_load new; then
		tg_config_defaults
		printf 'Saved wrapper settings are invalid. Configure them again or remove the wrapper.\n'
	elif [[ -f $TG_CONFIG_FILE ]]; then
		TG_SETUP_PREVIOUS_CAMERA_MODE=$TG_CAMERA_MODE
	fi
	local action=1 answer socket origin
	printf 'Telegram setup\n'
	if [[ -d $TG_INSTALL_DIR || -f $TG_CONFIG_FILE ]]; then
		printf '\n1. Update Telegram or change settings\n2. Check / repair\n3. Remove wrapper\n'
		read -r -p 'Choose [1]: ' action
		case ${action:-1} in
			1) ;;
			2)
				if tg_check; then return 0; fi
				read -r -p 'Update the wrapper and configure repairs now? [Y/n]: ' answer || return 1
				[[ ${answer,,} != n && ${answer,,} != no ]] || return 1
				tg_check_repair_user_overrides || return 1 ;;
			3) tg_remove; return ;;
			*) return 0 ;;
		esac
	fi
	tg_desktop_session || {
		tg_error 'Open a terminal in your graphical desktop session.'; return 1;
	}
	TG_RUNTIME=$desktop_runtime
	tg_dependencies
	tg_profile_choose
	tg_media_choose
	tg_dependencies
	tg_native_profile_available
	printf '\nChecking desktop access...\n'
	socket=$(LC_ALL=C pactl info | sed -n 's/^Server String: //p')
	socket=${socket#unix:}
	if ! tg_plain_path "$socket" || [[ ! -S $socket || ! -O $socket ]]; then
		tg_error 'A local desktop audio socket is required.'; return 1
	fi
	TG_PULSE_SOCKET=$socket
	tg_policy_args
	flatpak run "${TG_FLATPAK_ARGS[@]}" --help >/dev/null
	bwrap --unshare-user --bind / / --dev /dev -- /usr/bin/true
	printf '\nInstalling/updating Telegram...\n'
	flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
	tg_remote_check
	local -a install_args=(--user --or-update -y)
	if origin=$(flatpak info --user --show-origin "$TG_APP" stable 2>/dev/null) && [[ $origin != flathub ]]; then
		printf 'Reinstalling Telegram from Flathub; account data is retained.\n'
		install_args+=(--reinstall)
	fi
	flatpak install "${install_args[@]}" flathub "$TG_APP//stable"
	tg_origin_check
	flatpak make-current --user "$TG_APP" stable
	tg_setup_stage
	printf '\nChecking the replacement sandbox...\n'
	(TG_INSTALL_DIR=$TG_SETUP_WORK/programs; tg_check_probe) || {
		tg_error 'The replacement sandbox failed verification. The installed wrapper and saved choices were retained.'
		return 1
	}
	tg_stop
	tg_setup_commit
	if ! tg_desktop_check; then
		tg_error 'Desktop routing needs repair. Run setup and choose Check / repair.'
		return 1
	fi
	printf '\nTelegram is ready. Launch Telegram from the application menu.\n'
	read -r -p 'Start Telegram now? [Y/n]: ' answer
	if [[ ${answer,,} != n && ${answer,,} != no ]]; then
		nohup setsid --wait "$TG_LAUNCHER" -- {setup_lock}>&- >> "$TG_RUNTIME/telegram-sandbox.log" 2>&1 < /dev/null &
	fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
