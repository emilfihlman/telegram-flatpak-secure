#!/usr/bin/env bash
# Sourced by setup and the launcher; choices are saved by telegram-common.bash.

tg_media_valid_camera() {
	[[ $1 == by-id || $1 == by-path ]] &&
		[[ -n $2 && $2 != . && $2 != .. && $2 != */* && $2 != *$'\t'* && $2 != *$'\r'* && $2 != *$'\n'* && $2 =~ ^[[:print:]]+$ ]]
}

tg_media_video_node() {
	local node major
	node=$(readlink -e -- "$1") || return 1
	[[ $node =~ ^/dev/video[0-9]+$ && -c $node ]] || return 1
	major=$(stat -Lc '%t' -- "$node") || return 1
	[[ $major == 51 ]] || return 1
	printf '%s\n' "$node"
}

tg_media_camera_nodes() {
	local kind=$1 identity=$2 link suffix node
	tg_media_valid_camera "$kind" "$identity" || return 1
	for link in "/dev/v4l/$kind/$identity" "/dev/v4l/$kind/$identity"-video-index*; do
		[[ -L $link ]] || continue
		suffix=${link#"/dev/v4l/$kind/$identity"}
		[[ -z $suffix || $suffix =~ ^-video-index[0-9]+$ ]] || continue
		node=$(tg_media_video_node "$link") || continue
		printf '%s\n' "$node"
	done
}

tg_media_discover() {
	local index kind identity link node key label nodes
	local -A seen_nodes=() groups=()
	TG_MEDIA_KINDS=()
	TG_MEDIA_IDS=()
	TG_MEDIA_LABELS=()
	TG_MEDIA_NODES=()
	TG_MEDIA_SELECTED=()
	# Include disconnected configured cameras so removing one is always possible.
	for index in "${!TG_CAMERA_IDS[@]}"; do
		kind=${TG_CAMERA_KINDS[index]}
		identity=${TG_CAMERA_IDS[index]}
		tg_media_valid_camera "$kind" "$identity" || return 1
		key=$kind/$identity
		nodes=$(tg_media_camera_nodes "$kind" "$identity") || return 1
		TG_MEDIA_KINDS+=("$kind")
		TG_MEDIA_IDS+=("$identity")
		TG_MEDIA_LABELS+=("$identity")
		TG_MEDIA_NODES+=("${nodes//$'\n'/ }")
		TG_MEDIA_SELECTED+=(yes)
		groups[$key]=$index
		for node in $nodes; do seen_nodes[$node]=1; done
	done
	for kind in by-id by-path; do
		for link in "/dev/v4l/$kind/"*; do
			[[ -L $link ]] || continue
			node=$(tg_media_video_node "$link") || continue
			[[ ! ${seen_nodes[$node]+present} ]] || continue
			identity=${link##*/}
			if [[ $identity =~ ^(.*)-video-index[0-9]+$ ]]; then identity=${BASH_REMATCH[1]}; fi
			tg_media_valid_camera "$kind" "$identity" || continue
			key=$kind/$identity
			if [[ ${groups[$key]+present} ]]; then
				index=${groups[$key]}
				TG_MEDIA_NODES[index]+=" $node"
			else
				index=${#TG_MEDIA_IDS[@]}
				groups[$key]=$index
				TG_MEDIA_KINDS+=("$kind")
				TG_MEDIA_IDS+=("$identity")
				TG_MEDIA_LABELS+=("$identity")
				TG_MEDIA_NODES+=("$node")
				TG_MEDIA_SELECTED+=(no)
			fi
			seen_nodes[$node]=1
		done
	done
	for index in "${!TG_MEDIA_IDS[@]}"; do
		nodes=${TG_MEDIA_NODES[index]}
		node=${nodes%% *}
		label=${TG_MEDIA_IDS[index]}
		if [[ -n $node && -r /sys/class/video4linux/${node##*/}/name ]]; then
			IFS= read -r label < "/sys/class/video4linux/${node##*/}/name" || true
		fi
		TG_MEDIA_LABELS[index]=$(printf '%s' "$label" | LC_ALL=C tr '\000-\037\177' '?')
	done
}

tg_media_show() {
	local index mark state
	printf '\nCamera access: %s\n' "$TG_CAMERA_MODE"
	[[ $TG_CAMERA_MODE != all ]] || printf 'All cameras are allowed.\n'
	if (( ${#TG_MEDIA_IDS[@]} == 0 )); then
		printf 'No configured cameras or connected cameras with persistent identities.\n'
	fi
	for index in "${!TG_MEDIA_IDS[@]}"; do
		mark=' '
		[[ $TG_CAMERA_MODE == all || ( $TG_CAMERA_MODE == selected && ${TG_MEDIA_SELECTED[index]} == yes ) ]] && mark=x
		state=${TG_MEDIA_NODES[index]:-disconnected}
		printf '  %s. [%s] %s (%s)\n     %s/%s\n' "$((index + 1))" "$mark" "${TG_MEDIA_LABELS[index]}" "$state" "${TG_MEDIA_KINDS[index]}" "${TG_MEDIA_IDS[index]}"
	done
}

tg_media_choose() {
	local answer number index limit valid
	local -a words=() choices=()
	local -A seen=()
	tg_media_discover || return 1
	while true; do
		tg_media_show
		printf "Enter 'all', 'none', or the camera numbers to allow (space separated).\n"
		read -r -p 'Camera choice (Enter keeps current): ' answer || return 1
		answer=${answer#"${answer%%[![:space:]]*}"}
		answer=${answer%"${answer##*[![:space:]]}"}
		case ${answer,,} in
			'') break ;;
			all|none)
				TG_CAMERA_MODE=${answer,,}
				TG_CAMERA_KINDS=()
				TG_CAMERA_IDS=()
				break ;;
		esac
		read -r -a words <<< "${answer//,/ }"
		choices=()
		seen=()
		valid=yes
		limit=${#TG_MEDIA_IDS[@]}
		for number in "${words[@]}"; do
			if [[ ! $number =~ ^[1-9][0-9]*$ || ${#number} -gt ${#limit} ]] || (( number > limit )); then
				valid=no
				break
			fi
			index=$((number - 1))
			if [[ ! ${seen[$index]+present} ]]; then choices+=("$index"); seen[$index]=1; fi
		done
		if [[ $valid != yes ]] || (( ${#choices[@]} == 0 )); then
			printf 'Choose displayed camera numbers, all, or none.\n' >&2
			continue
		fi
		TG_CAMERA_MODE=selected
		TG_CAMERA_KINDS=()
		TG_CAMERA_IDS=()
		for index in "${choices[@]}"; do
			TG_CAMERA_KINDS+=("${TG_MEDIA_KINDS[index]}")
			TG_CAMERA_IDS+=("${TG_MEDIA_IDS[index]}")
		done
		break
	done
	while true; do
		read -r -p "Allow microphone input? [yes/no] (Enter keeps $TG_MICROPHONE): " answer || return 1
		case ${answer,,} in
			'') break ;;
			y|yes) TG_MICROPHONE=yes; break ;;
			n|no) TG_MICROPHONE=no; break ;;
			*) printf 'Enter yes or no.\n' >&2 ;;
		esac
	done
	printf 'Selected camera access: %s. Microphone input: %s. Audio playback remains available.\n' "$TG_CAMERA_MODE" "$TG_MICROPHONE"
}

tg_media_resolve() {
	local index node nodes
	local -A seen=()
	TG_CAMERA_NODES=()
	case $TG_CAMERA_MODE in
		none) return 0 ;;
		all)
			for node in /dev/video*; do
				node=$(tg_media_video_node "$node") || continue
				if [[ ! ${seen[$node]+present} ]]; then TG_CAMERA_NODES+=("$node"); seen[$node]=1; fi
			done
			;;
		selected)
			for index in "${!TG_CAMERA_IDS[@]}"; do
				nodes=$(tg_media_camera_nodes "${TG_CAMERA_KINDS[index]}" "${TG_CAMERA_IDS[index]}") || return 1
				if [[ -z $nodes ]]; then
					printf 'Configured camera disconnected: %s/%s\n' "${TG_CAMERA_KINDS[index]}" "${TG_CAMERA_IDS[index]}" >&2
				fi
				for node in $nodes; do
					if [[ ! ${seen[$node]+present} ]]; then TG_CAMERA_NODES+=("$node"); seen[$node]=1; fi
				done
			done
			;;
		*) return 1 ;;
	esac
}
