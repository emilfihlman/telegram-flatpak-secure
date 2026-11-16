#!/usr/bin/env bash
# Desktop integration for the installed wrapper. Source from setup/checking.

tg_desktop_key() {
	awk -v wanted="$2" '
		{ sub(/\r$/, "") }
		/^\[/ { entry = ($0 == "[Desktop Entry]"); next }
		entry && index($0, "=") {
			key=$0; sub(/=.*/, "", key); gsub(/^[ \t]+|[ \t]+$/, "", key)
			if (key == wanted) { sub(/^[^=]*=/, ""); print; exit }
		}
	' "$1"
}

tg_desktop_quote() {
	local value=$1
	value=${value//\\/\\\\}
	value=${value//\"/\\\"}
	value=${value//\$/\\\$}
	value=${value//\`/\\\`}
	# Desktop Entry escaping is applied before Exec argument escaping.
	value=${value//\\/\\\\}
	value=${value//%/%%}
	printf '"%s"' "$value"
}

tg_desktop_owned() {
	[[ -f $1 ]] && [[ $(tg_desktop_key "$1" X-Telegram-Wrapper) == true ]]
}

tg_desktop_autostarts() {
	local file name command directory
	local -a directories=("$TG_AUTOSTART_DIR") configured=()
	local -A seen=()
	IFS=: read -r -a configured <<< "${XDG_CONFIG_DIRS:-/etc/xdg}"
	for directory in "${configured[@]}"; do
		[[ $directory != /* ]] || directories+=("$directory/autostart")
	done
	for directory in "${directories[@]}"; do
		for file in "$directory/"*.desktop; do
			[[ -f $file ]] || continue
			name=${file##*/}
			[[ ! ${seen[$name]+set} ]] || continue
			seen[$name]=1
			if [[ $name =~ ^(org\.telegram\.desktop(\._[[:xdigit:]]+)?|telegram-desktop|telegramdesktop|telegram)\.desktop$ ]]; then
				printf '%s\0' "$file"
				continue
			fi
			command=$(tg_desktop_key "$file" Exec) || return 1
			# Recognize explicit Telegram commands, not arbitrary substring matches.
			if [[ $command =~ ^(/[^[:space:]]*/)?(Telegram|telegram-desktop|telegram)([[:space:]]|$) ||
				$command =~ ^\"/[^\"]*/(Telegram|telegram-desktop|telegram)\"([[:space:]]|$) ||
				$command =~ ^(/usr/bin/)?flatpak[[:space:]]+run[[:space:]]+(--[^[:space:]]+[[:space:]]+)*org\.telegram\.desktop([[:space:]]|$) ]] ||
				tg_desktop_owned "$file"; then
				printf '%s\0' "$file"
			fi
		done
	done
}

tg_desktop_aliases() {
	local name directory
	local -a directories=("$TG_DATA") configured=()
	IFS=: read -r -a configured <<< "${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
	directories+=("${configured[@]}")
	for name in telegram.desktop telegram-desktop.desktop telegramdesktop.desktop; do
		for directory in "${directories[@]}"; do
			[[ $directory == /* && -f $directory/applications/$name ]] || continue
			printf '%s\0' "$directory/applications/$name"
			break
		done
	done
}

tg_desktop_approve() {
	local answer
	[[ -e $1 || -L $1 ]] || return 0
	tg_desktop_owned "$1" && return 0
	printf 'Replace this Telegram launcher with the wrapper: %q\n' "$1"
	read -r -p 'Replace it? [y/N]: ' answer || return 1
	if [[ ${answer,,} != y && ${answer,,} != yes ]]; then
		printf 'Launcher was not changed. Setup cannot route this entry through the wrapper.\n' >&2
		return 1
	fi
}

tg_desktop_prepare() {
	local stage=$1 file target command
	local -a autostarts=() aliases=()
	mkdir -p -- "$stage/desktop/autostart" "$stage/desktop/aliases" || return 1
	tg_desktop_approve "$TG_DESKTOP" || return 1
	# GIO checks the executable token before expanding %% field codes. Using
	# the script's native interpreter keeps percent signs in the path literal.
	command="/usr/bin/bash $(tg_desktop_quote "$TG_LAUNCHER")" || return 1
	cat > "$stage/desktop/main.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Telegram
Comment=Telegram Desktop
Exec=$command -- @@u %U @@
Icon=org.telegram.desktop
Terminal=false
DBusActivatable=false
Categories=Network;InstantMessaging;
MimeType=x-scheme-handler/tg;
X-Telegram-Wrapper=true
EOF
	mapfile -d '' -t aliases < <(tg_desktop_aliases)
	for file in "${aliases[@]}"; do
		target=${TG_DESKTOP%/*}/${file##*/}
		tg_desktop_approve "$target" || return 1
		cp -- "$stage/desktop/main.desktop" "$stage/desktop/aliases/${file##*/}" || return 1
		printf 'NoDisplay=true\n' >> "$stage/desktop/aliases/${file##*/}" || return 1
	done
	mapfile -d '' -t autostarts < <(tg_desktop_autostarts)
	for file in "${autostarts[@]}"; do
		tg_desktop_approve "$TG_AUTOSTART_DIR/${file##*/}" || return 1
		target=$stage/desktop/autostart/${file##*/}
		# Retain autostart conditions and disabled state. Only the launch route
		# changes; action groups cannot retain alternative executable routes.
		TG_DESKTOP_COMMAND="$command -autostart" awk '
			/^\[/ {
				entry = ($0 == "[Desktop Entry]")
				if (entry) {
					found=1; print
					print "Exec=" ENVIRON["TG_DESKTOP_COMMAND"]
					print "DBusActivatable=false"
					print "X-Telegram-Wrapper=true"
				}
				next
			}
			!entry { next }
			/^(Exec|TryExec|DBusActivatable|X-Telegram-Wrapper|Actions)[ \t]*=/ { next }
			{ print }
			END { if (!found) exit 1 }
		' "$file" > "$target" || return 1
	done
}

tg_desktop_apply() {
	local stage=$1 file
	tg_install_file "$stage/desktop/main.desktop" "$TG_DESKTOP" 644 || return 1
	for file in "$stage/desktop/aliases/"*.desktop; do
		[[ -f $file ]] || continue
		tg_install_file "$file" "${TG_DESKTOP%/*}/${file##*/}" 644 || return 1
	done
	for file in "$stage/desktop/autostart/"*.desktop; do
		[[ -f $file ]] || continue
		tg_install_file "$file" "$TG_AUTOSTART_DIR/${file##*/}" 644 || return 1
	done
	if [[ ${TG_LEGACY_DESKTOP:-} != "$TG_DESKTOP" ]] && tg_desktop_owned "${TG_LEGACY_DESKTOP:-}"; then
		rm -- "$TG_LEGACY_DESKTOP" || return 1
	fi
	update-desktop-database "${TG_DESKTOP%/*}" || return 1
	xdg-mime default org.telegram.desktop.desktop x-scheme-handler/tg || return 1
	[[ $(xdg-mime query default x-scheme-handler/tg) == org.telegram.desktop.desktop ]] || {
		printf 'Could not make the wrapper the default for tg: links.\n' >&2
		return 1
	}
}

tg_desktop_remove() {
	local file
	for file in "$TG_DESKTOP" "${TG_LEGACY_DESKTOP:-}" "$TG_AUTOSTART_DIR/"*.desktop \
		"${TG_DESKTOP%/*}/telegram.desktop" "${TG_DESKTOP%/*}/telegram-desktop.desktop" "${TG_DESKTOP%/*}/telegramdesktop.desktop"; do
		tg_desktop_owned "$file" || continue
		rm -- "$file" || return 1
	done
	if [[ -d ${TG_DESKTOP%/*} ]] && command -v update-desktop-database >/dev/null; then
		update-desktop-database "${TG_DESKTOP%/*}" || return 1
	fi
}

tg_desktop_check() {
	local file command result=0
	command="/usr/bin/bash $(tg_desktop_quote "$TG_LAUNCHER")" || return 1
	if ! tg_desktop_owned "$TG_DESKTOP" ||
		[[ $(tg_desktop_key "$TG_DESKTOP" Exec) != "$command -- @@u %U @@" ]] ||
		[[ $(tg_desktop_key "$TG_DESKTOP" DBusActivatable) != false ]]; then
		printf 'The Telegram menu launcher needs repair.\n'; result=1
	fi
	if [[ $(xdg-mime query default x-scheme-handler/tg) != org.telegram.desktop.desktop ]]; then
		printf 'The default tg: link handler needs repair.\n'; result=1
	fi
	while IFS= read -r -d '' file; do
		if ! tg_desktop_owned "$file" || [[ $(tg_desktop_key "$file" Exec) != "$command -- @@u %U @@" ]] ||
			[[ $(tg_desktop_key "$file" DBusActivatable) != false || $(tg_desktop_key "$file" NoDisplay) != true ]]; then
			printf 'An alternative Telegram menu entry needs repair: %q\n' "$file"; result=1
		fi
	done < <(tg_desktop_aliases)
	while IFS= read -r -d '' file; do
		if ! tg_desktop_owned "$file" || [[ $(tg_desktop_key "$file" Exec) != "$command -autostart" ]] ||
			[[ $(tg_desktop_key "$file" DBusActivatable) != false ]]; then
			printf 'Telegram autostart needs repair: %q\n' "$file"; result=1
		fi
	done < <(tg_desktop_autostarts)
	return "$result"
}
