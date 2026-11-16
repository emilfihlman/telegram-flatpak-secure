#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
# Exercise the actual argument parser without launching a bus or proxy daemon.
source <(sed '/^main "\$@"$/d' ./telegram-dbus-proxy.bash)
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT

parse_args() {
	local descriptor
	printf '%s\0' "$@" > "$scratch/arguments"
	exec {descriptor}< "$scratch/arguments"
	load_proxy_args "--args=$descriptor"
	rewrite_proxy_args
}

has_arg() {
	local argument
	for argument in "${filtered_args[@]}"; do
		[[ $argument != "$1" ]] || return 0
	done
	return 1
}

reject_args() {
	if (parse_args "$@") > "$scratch/stdout" 2> "$scratch/stderr"; then
		printf 'FAIL: unsafe D-Bus proxy arguments were accepted.\n' >&2
		exit 1
	fi
	grep -q '^Error:' "$scratch/stderr"
}

session=(--fd=9 unix:path=/run/user/1000/bus /run/user/1000/session-proxy
	--filter --own=org.telegram.desktop
	'--call=org.freedesktop.portal.*=*'
	'--broadcast=org.freedesktop.portal.*=@/org/freedesktop/portal/*')
parse_args "${session[@]}"
[[ ${filtered_args[0]} == --fd=9 ]]
has_arg --own=org.telegram.desktop
has_arg '--call=org.freedesktop.portal.Desktop=*'
has_arg '--call=org.freedesktop.portal.Documents=*'
has_arg '--broadcast=org.freedesktop.portal.Desktop=@/org/freedesktop/portal/*'
has_arg '--broadcast=org.freedesktop.portal.Documents=@/org/freedesktop/portal/*'
! has_arg '--call=org.freedesktop.portal.*=*'
! has_arg '--broadcast=org.freedesktop.portal.*=@/org/freedesktop/portal/*'

# Flatpak can repeat --filter in the accessibility bus group. Keep its policy
# and the common sync descriptor, while emitting only one filter per group.
parse_args "${session[@]}" \
	unix:path=/run/user/1000/at-spi/bus /run/user/1000/a11y-proxy \
	--filter --filter --sloppy-names --own=org.a11y.atspi.Registry \
	'--call=org.a11y.atspi.Registry=org.a11y.atspi.Registry.GetRegisteredEvents'
[[ ${filtered_args[0]} == --fd=9 ]]
has_arg unix:path=/run/user/1000/at-spi/bus
has_arg --own=org.a11y.atspi.Registry
has_arg '--call=org.a11y.atspi.Registry=org.a11y.atspi.Registry.GetRegisteredEvents'
filters=0
for argument in "${filtered_args[@]}"; do
	[[ $argument != --filter ]] || filters=$((filters + 1))
done
[[ $filters == 2 ]]

for grant in \
	'--talk=org.freedesktop.portal.Flatpak' \
	'--call=org.freedesktop.portal.Flatpak=org.freedesktop.portal.Flatpak.Spawn' \
	'--talk=org.freedesktop.portal.*' \
	'--own=org.freedesktop.*' \
	'--talk=org.freedesktop.impl.portal.PermissionStore' \
	'--call=org.freedesktop.impl.portal.PermissionStore=*' \
	'--talk=ca.desrt.dconf' \
	'--talk=ca.desrt.*'; do
	reject_args "${session[@]}" "$grant"
done
reject_args --fd=9 unix:path=/run/user/1000/bus /run/user/1000/session-proxy \
	'--call=org.freedesktop.portal.*=*' \
	'--broadcast=org.freedesktop.portal.*=@/org/freedesktop/portal/*'
reject_args --fd=9 unix:abstract=desktop-bus /run/user/1000/session-proxy "${session[@]:3}"
reject_args "${session[@]}" unix:path=/run/user/1000/other /run/user/1000/other-proxy --own=org.example.App

# A final unterminated argument must not be silently dropped.
if (
	printf '%s\0' "${session[@]}" > "$scratch/truncated"
	printf '%s' --talk=org.freedesktop.portal.Flatpak >> "$scratch/truncated"
	exec {descriptor}< "$scratch/truncated"
	load_proxy_args "--args=$descriptor"
) > "$scratch/stdout" 2> "$scratch/stderr"; then
	printf 'FAIL: truncated D-Bus proxy arguments were accepted.\n' >&2
	exit 1
fi
grep -q 'Truncated Flatpak D-Bus proxy argument file' "$scratch/stderr"
printf 'Telegram D-Bus proxy filtering and fail-closed argument checks passed.\n'
