# shellcheck shell=bash
# Honest uninstall: remove Unleash persist, pf anchors, hosts blocks we added,
# and launchd overrides we set. Does not restore DEP/ABM or original MDM state.

_uninstall_enrollment_labels() {
	# Must match suppress_daemons / harden (10 labels).
	printf '%s\n' \
		com.apple.ManagedClient \
		com.apple.ManagedClient.enroll \
		com.apple.ManagedClient.cloudConfiguration \
		com.apple.ManagedClientAgent \
		com.apple.ManagedClientAgent.agent \
		com.apple.mdmclient \
		com.apple.mdmclient.daemon \
		com.apple.mdmclient.daemon.runatboot \
		com.apple.mdmclient.agent \
		com.apple.activationd
}

_uninstall_mdm_domains() {
	# Must match _suppress_mdm_domains (14 names).
	printf '%s\n' \
		iprofiles.apple.com \
		deviceenrollment.apple.com \
		mdmenrollment.apple.com \
		acmdm.apple.com \
		axm-adm-mdm.apple.com \
		albert.apple.com \
		gdmf.apple.com \
		ax.init-content.apple.com \
		init-content.apple.com \
		configuration.apple.com \
		xp.apple.com \
		gs.apple.com \
		tb.apple.com \
		vpp.itunes.apple.com
}

_uninstall_root() {
	printf '%s' "${DATA_ROOT-}"
}

_uninstall_need_root() {
	case "${DATA_ROOT:-}" in
		""|"/") return 0 ;;
		/Volumes/*|/System/*) return 0 ;;
	esac
	return 1
}

do_uninstall() {
	header "Unleash uninstall"

	if _uninstall_need_root; then
		if ! type is_root >/dev/null 2>&1 || ! is_root; then
			error_exit "ERROR E_NOT_ROOT: uninstall needs root. Persist plists and pf anchors are root-owned. Next: sudo ./unleash uninstall"
		fi
	fi

	local root
	root=$(_uninstall_root)
	local launchctl="${LAUNCHCTL:-/bin/launchctl}"
	local pb="${PLISTBUDDY:-/usr/libexec/PlistBuddy}"
	local pfctl="${PFCTL:-/sbin/pfctl}"
	local live=0
	if [ -z "$root" ] || [ "$root" = "/" ]; then
		live=1
	fi

	begin "Removing heal LaunchDaemon"
	local plist="${root}/Library/LaunchDaemons/com.unleash.heal.plist"
	local sentinel="${root}/Library/LaunchDaemons/${PERSIST_SENTINEL:-.unleash-persist-installed}"
	if [ "$live" = 1 ] && [ -x "$launchctl" ]; then
		"$launchctl" bootout system/com.unleash.heal >/dev/null 2>&1 || \
			"$launchctl" unload "$plist" >/dev/null 2>&1 || true
	fi
	if [ -f "$plist" ] || [ -f "$sentinel" ]; then
		rm -f "$plist" "$sentinel"
		end_ok
	else
		info "Heal LaunchDaemon not installed"
	fi

	begin "Removing leftover monitor LaunchDaemon"
	plist="${root}/Library/LaunchDaemons/com.unleash.monitor.plist"
	if [ "$live" = 1 ] && [ -x "$launchctl" ]; then
		"$launchctl" bootout system/com.unleash.monitor >/dev/null 2>&1 || \
			"$launchctl" unload "$plist" >/dev/null 2>&1 || true
	fi
	if [ -f "$plist" ]; then
		rm -f "$plist"
		end_ok
	else
		info "Monitor LaunchDaemon not installed"
	fi

	begin "Removing persist copy"
	local unleash_dir="${root}/Library/Unleash"
	if [ -d "$unleash_dir" ]; then
		rm -rf "$unleash_dir"
		end_ok
	else
		info "No /Library/Unleash copy"
	fi

	begin "Cleaning pf anchors"
	local a anchor_name
	for a in \
		"${root}/private/etc/pf.anchors/com.unleash/mdm" \
		"${root}/etc/pf.anchors/com.unleash/mdm" \
		"${root}/private/etc/pf.anchors/com.unleash.selective" \
		"${root}/etc/pf.anchors/com.unleash.selective" \
		"${root}/private/etc/pf.anchors/com.unleash/vpn-kill" \
		"${root}/etc/pf.anchors/com.unleash/vpn-kill" \
		"${root}/private/etc/pf.anchors/com.unleash.apns" \
		"${root}/etc/pf.anchors/com.unleash.apns"; do
		[ -f "$a" ] && rm -f "$a"
	done
	rmdir "${root}/private/etc/pf.anchors/com.unleash" 2>/dev/null || true
	rmdir "${root}/etc/pf.anchors/com.unleash" 2>/dev/null || true
	if [ "$live" = 1 ] && [ -x "$pfctl" ]; then
		for anchor_name in "com.unleash/mdm" "com.unleash.selective" "com.unleash/vpn-kill" "com.unleash.apns"; do
			"$pfctl" -a "$anchor_name" -F all 2>/dev/null || true
		done
	fi
	local pf_conf
	for pf_conf in "${root}/private/etc/pf.conf" "${root}/etc/pf.conf"; do
		if [ -f "$pf_conf" ]; then
			sed -i '' '/# Added by unleash/d' "$pf_conf" 2>/dev/null || true
			sed -i '' '/# UNLEASH_/d' "$pf_conf" 2>/dev/null || true
			sed -i '' '/com\.unleash/d' "$pf_conf" 2>/dev/null || true
		fi
	done
	if [ "$live" = 1 ] && [ -x "$pfctl" ]; then
		"$pfctl" -f /etc/pf.conf 2>/dev/null || true
	fi
	end_ok

	# D18: fake rc hook is not a macOS update path.
	begin "Removing post-update rc hook"
	rm -f "${root}/private/etc/rc.unleash-update.local" \
		"${root}/etc/rc.unleash-update.local"
	end_ok

	begin "Cleaning hosts entries we added"
	local hosts d
	for hosts in "${root}/private/etc/hosts" "${root}/etc/hosts"; do
		[ -f "$hosts" ] || continue
		sed -i '' '/# Added by unleash/d' "$hosts" 2>/dev/null || true
		while IFS= read -r d || [ -n "$d" ]; do
			[ -n "$d" ] || continue
			sed -i '' "/[[:space:]]$d/d" "$hosts" 2>/dev/null || true
			sed -i '' "/::.*$d/d" "$hosts" 2>/dev/null || true
		done <<EOF
$(_uninstall_mdm_domains)
EOF
	done
	end_ok

	begin "Removing launchd overrides we set"
	local ldp="${root}/private/var/db/com.apple.xpc.launchd/disabled.plist"
	[ -f "$ldp" ] || ldp="${root}/var/db/com.apple.xpc.launchd/disabled.plist"
	local label
	if [ -f "$ldp" ] && [ -x "$pb" ]; then
		while IFS= read -r label || [ -n "$label" ]; do
			[ -n "$label" ] || continue
			"$pb" -c "Delete :$label" "$ldp" 2>/dev/null || true
		done <<EOF
$(_uninstall_enrollment_labels)
EOF
		end_ok
	else
		info "No launchd disabled.plist"
	fi

	begin "Removing backup directory"
	local backup="${BACKUP_DIR:-${SCRIPT_DIR:-$(cd "$(dirname "$0")" && pwd)}}/.unleash-backup"
	if [ -d "$backup" ]; then
		rm -rf "$backup"
		end_ok
	elif [ -d ".unleash-backup" ]; then
		rm -rf ".unleash-backup"
		end_ok
	else
		info "No backup directory"
	fi

	begin "Removing config file"
	if [ -f "${HOME:-}/.unleash.conf" ]; then
		rm -f "$HOME/.unleash.conf"
		end_ok
	else
		info "No ~/.unleash.conf"
	fi

	begin "Stopping leftover monitor pidfile"
	local pidfile="/tmp/unleash-monitor.pid"
	if [ -f "$pidfile" ]; then
		kill "$(cat "$pidfile")" 2>/dev/null || true
		rm -f "$pidfile"
		end_ok
	else
		info "No monitor pidfile"
	fi

	echo ""
	success "Uninstall finished"
	info "Removed Unleash persist, pf anchors, hosts blocks we added, and launchd overrides we set."
	info "This does not restore DEP/ABM enrollment or original MDM state."
	info "The unleash script itself was not removed."
	info "Next: reboot, or restore a snapshot with ./unleash restore --snapshot ID"
}
