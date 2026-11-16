#!/usr/bin/env bash
# Shared setup for integration workers that supply an isolated native session
# bus/PermissionStore, staged helpers/config, and synthetic audio devices.

tg_audio_test_load() {
	local test_runtime=${TG_TEST_RUNTIME:-} programs=${TG_TEST_PROGRAMS:-}
	if [[ -z $test_runtime || -z $programs || -z ${TG_TEST_PULSE_SOCKET:-} ]]; then
		printf 'UNAVAILABLE: set TG_TEST_RUNTIME, TG_TEST_PROGRAMS and TG_TEST_PULSE_SOCKET to a private native-consent/audio fixture.\n' >&2
		return 77
	fi
	[[ $test_runtime == /* && $programs == "$test_runtime/"* && -r $programs/config-path && -S $test_runtime/bus ]] || {
		printf 'Use staged helpers and a private native session bus inside TG_TEST_RUNTIME.\n' >&2
		return 1
	}
	source "$programs/telegram-common.bash"
	tg_paths
	tg_config_load required || return 1
	[[ $TG_CONFIG_FILE == "$test_runtime/"* && $TG_RUNTIME == "$test_runtime" && $TG_PULSE_SOCKET == "$TG_TEST_PULSE_SOCKET" ]] || {
		printf 'The test must not edit desktop settings: stage its config inside TG_TEST_RUNTIME.\n' >&2
		return 1
	}
	TG_HOME=$test_runtime/home
	[[ -d $TG_HOME && -O $TG_HOME ]] || return 1
	export HOME=$TG_HOME XDG_RUNTIME_DIR=$TG_RUNTIME DBUS_SESSION_BUS_ADDRESS=unix:path=$TG_RUNTIME/bus
	TG_NATIVE_CONSENT=$("$programs/telegram-consent.bash" snapshot) || return 1
	source "$programs/telegram-media.bash"
	source "$programs/telegram-audio.bash"
}
