#!/usr/bin/env bash
# Invoked by Flatpak through FLATPAK_DBUSPROXY inside its normal proxy bwrap.
# Keep that wrapper's /.flatpak-info identity, but remove the automatic grant
# to the Flatpak Spawn portal, which could recreate a sandbox outside our
# device/audio/consent supervisors. Ordinary desktop/document portals remain.
set -euo pipefail
export LC_ALL=C

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }

load_proxy_args() {
	local fd argument= total=0
	[[ $# == 1 && $1 =~ ^--args=([1-9][0-9]{0,8})$ ]] ||
		fail 'Unsupported Flatpak D-Bus proxy invocation; refusing to launch.'
	fd=${BASH_REMATCH[1]}
	(( fd >= 3 )) || fail 'Invalid Flatpak D-Bus proxy argument descriptor.'
	[[ -f /proc/self/fd/$fd ]] || fail 'Flatpak D-Bus proxy arguments are not a regular argument file.'
	proxy_args=()
	# Flatpak bundles proxy arguments as NUL-delimited strings in a sealed
	# memfd (or a regular temporary file). Never interpret them as shell code.
	while IFS= read -r -d '' argument; do
		[[ -n $argument && ${#argument} -le 65536 ]] || fail 'Invalid D-Bus proxy argument.'
		((total+=${#argument}+1))
		(( total <= 1048576 && ${#proxy_args[@]} < 8192 )) || fail 'Too many D-Bus proxy arguments.'
		proxy_args+=("$argument")
	done <&"$fd"
	[[ -z $argument ]] || fail 'Truncated Flatpak D-Bus proxy argument file.'
	exec {fd}<&-
}

check_policy_name() {
	local name=$1 base forbidden
	[[ $name =~ ^[A-Za-z_][A-Za-z0-9_-]*(\.[A-Za-z_][A-Za-z0-9_-]*)+(\.\*)?$ ]] ||
		fail "Unsupported D-Bus policy name: $name"
	# Positive proxy rules accumulate. A more specific missing/no-talk rule
	# cannot cancel a broader grant, so reject every such overlapping rule.
	for forbidden in org.freedesktop.portal.Flatpak org.freedesktop.Flatpak \
		org.freedesktop.systemd1 org.freedesktop.impl.portal.PermissionStore ca.desrt.dconf; do
		if [[ $name == *.\* ]]; then
			base=${name%.\*}
			[[ $forbidden != "$base" && $forbidden != "$base".* ]] ||
				fail "D-Bus policy would bypass device consent: $name"
		else
			[[ $name != "$forbidden" ]] || fail "D-Bus policy would bypass device consent: $name"
		fi
	done
}

rewrite_proxy_args() {
	local index=0 address socket argument name rule filtered groups=0 calls=0 broadcasts=0
	local count=${#proxy_args[@]}
	(( count > 4 )) || fail 'Incomplete Flatpak D-Bus proxy arguments.'
	[[ ${proxy_args[0]} =~ ^--fd=([1-9][0-9]{0,8})$ ]] ||
		fail 'Missing Flatpak D-Bus proxy lifetime descriptor.'
	(( BASH_REMATCH[1] >= 3 )) || fail 'Invalid Flatpak D-Bus proxy lifetime descriptor.'
	filtered_args=("${proxy_args[0]}")
	index=1
	while (( index < count )); do
		address=${proxy_args[$index]}
		((index+=1))
		(( index < count )) || fail 'Missing D-Bus proxy socket path.'
		socket=${proxy_args[$index]}
		((index+=1))
		# Debian's native buses use filesystem Unix sockets. An abstract or
		# network bus is reachable outside filesystem socket filtering.
		[[ $address == unix:path=* && $address != *';'* && $address != *',abstract='* &&
			$address != *$'\n'* && $address != *$'\r'* && $socket == /* &&
			$socket != *$'\n'* && $socket != *$'\r'* ]] ||
			fail 'Unsupported D-Bus address or proxy socket path.'
		filtered_args+=("$address" "$socket")
		filtered=0
		while (( index < count )) && [[ ${proxy_args[$index]} == -* ]]; do
			argument=${proxy_args[$index]}
			((index+=1))
			case $argument in
				--filter)
					# Flatpak adds this twice for the accessibility bus.
					if (( filtered == 0 )); then filtered_args+=("$argument"); fi
					((filtered+=1))
					;;
				--log|--sloppy-names)
					filtered_args+=("$argument") ;;
				'--call=org.freedesktop.portal.*=*')
					((calls+=1))
					filtered_args+=(
						'--call=org.freedesktop.portal.Desktop=*'
						'--call=org.freedesktop.portal.Documents=*'
					) ;;
				'--broadcast=org.freedesktop.portal.*=@/org/freedesktop/portal/*')
					((broadcasts+=1))
					filtered_args+=(
						'--broadcast=org.freedesktop.portal.Desktop=@/org/freedesktop/portal/*'
						'--broadcast=org.freedesktop.portal.Documents=@/org/freedesktop/portal/*'
					) ;;
				--see=*|--talk=*|--own=*)
					name=${argument#*=}
					check_policy_name "$name"
					filtered_args+=("$argument") ;;
				--call=*|--broadcast=*)
					rule=${argument#*=}
					[[ $rule == *=* ]] || fail 'Invalid D-Bus call/broadcast rule.'
					name=${rule%%=*}
					check_policy_name "$name"
					[[ -n ${rule#*=} ]] || fail 'Empty D-Bus call/broadcast rule.'
					filtered_args+=("$argument") ;;
				*) fail "Unsupported Flatpak D-Bus proxy option: $argument" ;;
			esac
		done
		(( filtered >= 1 )) || fail 'An unfiltered D-Bus proxy was requested.'
		((groups+=1))
	done
	(( groups >= 1 && calls == 1 && broadcasts == 1 )) ||
		fail 'Expected Flatpak portal policy was not found exactly once; refusing to launch.'
}

main() {
	[[ -x /usr/bin/xdg-dbus-proxy ]] || fail 'The native xdg-dbus-proxy executable is unavailable.'
	[[ -f /.flatpak-info ]] || fail "This helper must run inside Flatpak's D-Bus proxy wrapper."
	load_proxy_args "$@"
	rewrite_proxy_args
	exec /usr/bin/xdg-dbus-proxy "${filtered_args[@]}"
}

main "$@"
