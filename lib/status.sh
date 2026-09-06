
check_mdm_status() {
	local data_mount="$1"
	local hosts="$data_mount/private/etc/hosts"
	local cfg="$data_mount/private/var/db/ConfigurationProfiles/Settings"
	local ldp="$data_mount/private/var/db/com.apple.xpc.launchd/disabled.plist"

	header "MDM Status Report"

	step "DEP markers ($cfg)"
	if [ -d "$cfg" ]; then
		for f in \
			.cloudConfigHasActivationRecord \
			.cloudConfigRecordFound \
			.cloudConfigRecordNotFound \
			.cloudConfigProfileInstalled \
			.cloudConfigTimerCheck; do
			if [ -f "$cfg/$f" ]; then
				echo -e "  ${GRN}$f${NC} — present"
			else
				echo -e "  ${YEL}$f${NC} — absent"
			fi
		done
	else
		warn "Settings directory not found"
	fi
	echo ""

	step "Blocked domains in hosts"
	if [ -f "$hosts" ]; then
		local matches
		matches=$(grep -iE 'iprofiles|enrollment|mdm|acmdm|albert|gdmf|configuration|xp\.apple|gs\.apple|tb\.apple' "$hosts" 2>/dev/null)
		if [ -n "$matches" ]; then
			echo "$matches" | while IFS= read -r line; do
				echo -e "  ${GRN}$line${NC}"
			done
		else
			echo -e "  ${YEL}(none)${NC}"
		fi
		local count; count=$(echo "$matches" | grep -c . 2>/dev/null || echo 0)
		echo -e "  ${CYAN}Total: $count of 13 expected domains blocked${NC}"
	else
		echo -e "  ${YEL}(hosts not found)${NC}"
	fi
	echo ""

	step "Enrollment daemon status"
	if [ -f "$ldp" ]; then
		/usr/libexec/PlistBuddy -c "Print" "$ldp" 2>/dev/null || echo -e "  ${YEL}(empty/corrupt)${NC}"
	else
		echo -e "  ${YEL}(no override)${NC}"
	fi
	echo ""

	step "Profiles enrollment status"
	if command -v profiles &>/dev/null; then
		profiles status -type enrollment 2>/dev/null \
			|| echo -e "  ${YEL}Cannot check (expected in Recovery)${NC}"
	else
		echo -e "  ${YEL}'profiles' not available${NC}"
	fi
	echo ""

	step "Backup status"
	if has_backup; then
		echo -e "  ${GRN}Backup exists:${NC} $(cat "$(_snapshot_root)/timestamp" 2>/dev/null || echo yes)"
	else
		echo -e "  ${YEL}No backup${NC}"
	fi
	echo ""

	if [ -f "$cfg/.cloudConfigRecordFound" ]; then
		local org
		org=$(plutil -convert xml1 -o - "$cfg/.cloudConfigRecordFound" 2>/dev/null \
			| grep -iA1 OrganizationName | tail -1 | sed -E 's/.*<string>(.*)<\/string>.*/\1/')
		[ -n "$org" ] && echo -e "${YEL}Active DEP record found — device assigned to: $org${NC}"
	else
		echo -e "${GRN}No active DEP record.${NC}"
	fi
}

deep_status() {
	if [ "${1:-}" = "--json" ] || [ "${UNLEASH_JSON:-0}" = 1 ]; then
		deep_status_json
		return
	fi
	header "Deep MDM Audit"

	step "Installed Configuration Profiles"
	local profile_count=0
	if command -v profiles &>/dev/null; then
		profile_count=$(sudo profiles -C -output=xml 2>/dev/null | grep -c "ProfileDisplayName" || true)
		profile_count="${profile_count:-0}"
		profile_count=$(echo "$profile_count" | head -n 1 | tr -dc '0-9')
		profile_count="${profile_count:-0}"
		if [ "$profile_count" -gt 0 ]; then
			warn "$profile_count profile(s) installed:"
			sudo profiles -C -output=xml 2>/dev/null | grep -A1 "ProfileDisplayName" | grep "<string>" | sed 's/.*<string>\(.*\)<\/string>.*/  - \1/'
		else
			info "No configuration profiles installed"
		fi
	else
		warn "profiles command not available"
	fi
	echo ""

	step "MDM Enrollment State"
	local enroll_raw=""
	if command -v profiles &>/dev/null; then
		enroll_raw=$(sudo profiles status -type enrollment 2>/dev/null || echo "  Cannot determine")
		echo "$enroll_raw"
		# Terminate transient query processes spawned by profiles query so they don't linger
		sudo pkill -9 -fi "ManagedClient" 2>/dev/null || true
		sudo pkill -9 -fi "mdmclient" 2>/dev/null || true
		sleep 0.2
	fi
	echo ""

	step "MDM Identity Certificates (Keychain)"
	if command -v security &>/dev/null; then
		local mdm_certs
		mdm_certs=$(sudo security find-identity -p basic 2>/dev/null | grep -ci "mdm\|MDM\|Apple.*Push" || true)
		mdm_certs="${mdm_certs:-0}"
		mdm_certs=$(echo "$mdm_certs" | head -n 1 | tr -dc '0-9')
		mdm_certs="${mdm_certs:-0}"
		if [ "$mdm_certs" -gt 0 ]; then
			warn "$mdm_certs MDM-related certificate(s) found"
			sudo security find-identity -p basic 2>/dev/null | grep -i "mdm\|Apple.*Push"
		else
			info "No MDM certificates found in keychain"
		fi
	else
		warn "security command not available"
	fi
	echo ""

	step "MDM LaunchAgents (User)"
	local found=0
	for home in /Users/*/; do
		[ -d "$home/Library/LaunchAgents" ] || continue
		local user_agents
		user_agents=$(ls "$home/Library/LaunchAgents/" 2>/dev/null | grep -iE "mdm|enrollment|managed" || true)
		if [ -n "$user_agents" ]; then
			echo -e "  ${YEL}$(basename "$home"):${NC}"
			echo "$user_agents" | sed 's/^/    /'
			found=$((found + 1))
		fi
	done
	[ "$found" -eq 0 ] && info "No MDM LaunchAgents found in any user"
	echo ""

	step "MDM LaunchDaemons (System)"
	local sys_agents
	sys_agents=$(ls /Library/LaunchDaemons/ 2>/dev/null | grep -iE "mdm|enrollment|managed" || true)
	if [ -n "$sys_agents" ]; then
		echo "$sys_agents" | sed 's/^/  /'
	else
		info "No MDM LaunchDaemons found"
	fi
	echo ""

	step "Running MDM Processes"
	local procs third_party
	procs=$(ps aux 2>/dev/null | grep -iE "(ManagedClient\.app|/mdmclient|com\.apple\.ManagedClient)" | grep -v grep || true)
	third_party=$(ps aux 2>/dev/null | grep -iE "(jamf|AirWatch|Workspace\s*ONE|kandji|mosyle|simplemdm)" | grep -v grep || true)
	if [ -n "$third_party" ]; then
		warn "Active third-party MDM agent running:"
		echo "$third_party" | awk '{print "  " $11 " (PID " $2 ")"}'
	fi
	if [ -n "$procs" ]; then
		if echo "$enroll_raw" | grep -qiE "Enrolled via DEP:[[:space:]]*No" && echo "$enroll_raw" | grep -qiE "MDM enrollment:[[:space:]]*No" && [ "$profile_count" -eq 0 ]; then
			info "Apple system helper active in memory (transient query handler — not enrolled in MDM)"
			echo "$procs" | awk '{print "  " $11 " (PID " $2 ") [idle helper]"}'
		else
			warn "Active MDM process(es) running:"
			echo "$procs" | awk '{print "  " $11 " (PID " $2 ")"}'
		fi
	elif [ -z "$third_party" ]; then
		info "No MDM processes running"
	fi
	echo ""

	step "MDM Agent Binaries"
	for agent_bin in /usr/local/bin/jamf /usr/local/bin/jamfagent /opt/jamf/bin/jamf \
		/usr/local/bin/intune /usr/local/bin/microsoft-intune \
		/Applications/Jamf* /Applications/Microsoft\ Intune* /Applications/VMware\ Workspace*; do
		if [ -e "$agent_bin" ]; then
			warn "Agent binary found: $agent_bin"
		fi
	done
	info "Scan complete"
	echo ""

	step "Firewall Status"
	pf_status 2>/dev/null || info "pf firewall check skipped"

	step "Overall Assessment"
	local risk="LOW"
	[ "$profile_count" -gt 0 ] && risk="MEDIUM"

	# Escalate to HIGH only if third-party MDM agents are running,
	# or if configuration profiles/enrollment exist and MDM daemon is running
	if [ -n "$third_party" ]; then
		risk="HIGH"
	elif [ "$profile_count" -gt 0 ] || (echo "$enroll_raw" | grep -qiE "(Enrolled via DEP:[[:space:]]*Yes|MDM enrollment:[[:space:]]*Yes)"); then
		if [ -n "$procs" ]; then
			risk="HIGH"
		fi
	fi

	local cfg="/private/var/db/ConfigurationProfiles/Settings"
	if [ -f "$cfg/.cloudConfigRecordFound" ]; then
		local org=""
		org=$(plutil -convert xml1 -o - "$cfg/.cloudConfigRecordFound" 2>/dev/null \
			| grep -iA1 OrganizationName | tail -1 | sed -E 's/.*<string>(.*)<\/string>.*/\1/' || true)
		if [ -n "$org" ]; then
			risk="CRITICAL"
		elif ! plutil -p "$cfg/.cloudConfigRecordFound" 2>/dev/null | grep -q "CloudConfigFetchError"; then
			risk="CRITICAL"
		fi
	fi

	case "$risk" in
		LOW)
			echo -e "  ${GRN}Risk: $risk — Device appears clean${NC}"
			echo -e "  ${GRN}Suppressions active and no active MDM management detected.${NC}"
			;;
		MEDIUM)
			echo -e "  ${YEL}Risk: $risk — Residual configuration profiles detected${NC}"
			echo -e "  ${CYAN}Recommended Action:${NC}"
			echo -e "    ${YEL}sudo ./unleash harden${NC}    (Purges residual MDM profiles and stops background daemons)"
			;;
		HIGH)
			echo -e "  ${RED}Risk: $risk — Active MDM background management processes are running${NC}"
			echo -e "  ${CYAN}Recommended Action:${NC}"
			echo -e "    ${YEL}sudo ./unleash harden${NC}    (Terminates live MDM processes and suppresses daemons)"
			echo -e "    ${YEL}sudo ./unleash firewall${NC}  (Enables pf packet filter to drop all MDM traffic)"
			;;
		CRITICAL)
			echo -e "  ${RED}Risk: $risk — Active DEP cloud configuration record present${NC}"
			echo -e "  ${CYAN}Recommended Actions:${NC}"
			echo -e "    1. ${YEL}sudo ./unleash heal${NC}      (Resets DEP markers, updates /etc/hosts blocks, disables daemons)"
			echo -e "    2. ${YEL}sudo ./unleash harden${NC}    (Kills active MDM daemons & flushes system caches)"
			echo -e "    3. ${YEL}sudo ./unleash firewall${NC}  (Blocks outbound Apple MDM network endpoints)"
			echo -e "    4. ${YEL}sudo ./unleash persist${NC}   (Installs auto-heal LaunchDaemon on system boot)"
			echo -e "    ${MAG}Note: If wiping/reformatting, boot into Recovery and run './unleash recovery'.${NC}"
			;;
	esac
}

deep_status_json() {
	local json=""
	json="${json}{\n"
	json="${json}  \"version\": \"$VERSION\",\n"
	json="${json}  \"timestamp\": \"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\",\n"

	local profile_count=0
	if command -v profiles &>/dev/null; then
		profile_count=$(sudo profiles -C -output=xml 2>/dev/null | grep -c "ProfileDisplayName" || true)
		profile_count="${profile_count:-0}"
		profile_count=$(echo "$profile_count" | head -n 1 | tr -dc '0-9')
		profile_count="${profile_count:-0}"
	fi
	json="${json}  \"profile_count\": $profile_count,\n"

	local enroll_state="unknown"
	if command -v profiles &>/dev/null; then
		enroll_state=$(sudo profiles status -type enrollment 2>/dev/null | head -1 | xargs || echo "unknown")
		sudo pkill -9 -fi "ManagedClient" 2>/dev/null || true
		sudo pkill -9 -fi "mdmclient" 2>/dev/null || true
	fi
	enroll_state="${enroll_state//\"/\\\"}"
	json="${json}  \"enrollment_state\": \"${enroll_state}\",\n"

	local mdm_certs=0
	if command -v security &>/dev/null; then
		mdm_certs=$(sudo security find-identity -p basic 2>/dev/null | grep -ci "mdm\|MDM\|Apple.*Push" || true)
	fi
	json="${json}  \"mdm_certificates\": $mdm_certs,\n"

	local running_procs=0
	running_procs=$(ps aux 2>/dev/null | grep -iE "(jamf|AirWatch|Workspace\s*ONE|kandji|mosyle|simplemdm)" | grep -v grep | wc -l | tr -dc '0-9' || echo 0)
	if [ "$profile_count" -gt 0 ] || echo "$enroll_state" | grep -qi "Yes"; then
		local sys_procs
		sys_procs=$(ps aux 2>/dev/null | grep -iE "(ManagedClient\.app|/mdmclient|com\.apple\.ManagedClient)" | grep -v grep | wc -l | tr -dc '0-9' || echo 0)
		running_procs=$((running_procs + sys_procs))
	fi
	running_procs="${running_procs:-0}"
	json="${json}  \"running_mdm_processes\": $running_procs,\n"

	local risk="LOW"
	[ "$profile_count" -gt 0 ] && risk="MEDIUM"
	[ "$running_procs" -gt 0 ] && risk="HIGH"
	if [ -f "/private/var/db/ConfigurationProfiles/Settings/.cloudConfigRecordFound" ]; then
		local org=""
		org=$(plutil -convert xml1 -o - "/private/var/db/ConfigurationProfiles/Settings/.cloudConfigRecordFound" 2>/dev/null \
			| grep -iA1 OrganizationName | tail -1 | sed -E 's/.*<string>(.*)<\/string>.*/\1/' || true)
		if [ -n "$org" ] || ! plutil -p "/private/var/db/ConfigurationProfiles/Settings/.cloudConfigRecordFound" 2>/dev/null | grep -q "CloudConfigFetchError"; then
			risk="CRITICAL"
		fi
	fi
	json="${json}  \"risk_score\": \"${risk}\"\n"

	json="${json}}"
	echo -e "$json"
}
