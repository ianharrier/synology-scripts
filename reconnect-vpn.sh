#!/usr/bin/env bash
#===============================================================================
#         FILE:  reconnect-vpn.sh
#
#  DESCRIPTION:  Reconnect a disconnected VPN session on Synology DSM
#      VERSION:  2.0.0
#      LICENSE:  MIT License
#
#    BASED ON:   https://github.com/ianharrier/synology-scripts (v1.6.1)
#                Original authors: Ian Harrier, Deac Karns, Michael Lake,
#                mchalandon, Branden R. Williams
#
#  EXIT CODES:  0 = connection is fine (or another instance is running)
#               1 = connection was down and was reconnected (SUCCESS_EXIT_CODE)
#               2 = reconnect failed
#               3 = configuration / environment error
#
#  Settings can be edited below or passed as environment variables, e.g.
#    VPN_PROFILE_NAME="Home VPN" ./reconnect-vpn.sh
#===============================================================================

#-------------------------------------------------------------------------------
#  User-customizable variables
#-------------------------------------------------------------------------------

# VPN_PROFILE_NAME : Exact "Profile Name" from DSM. Leave blank only if exactly
# one VPN profile exists.
VPN_PROFILE_NAME=${VPN_PROFILE_NAME:-}

# VPN_CHECK_METHOD : "dsm_status" | "gateway_ping" | "custom_ping"
# - dsm_status   : DSM reports the connection as up
# - gateway_ping : also ping the tunnel peer/gateway through the tunnel
# - custom_ping  : also ping CUSTOM_PING_ADDRESS through the tunnel
# Note: ping methods fail if ICMP is filtered, which causes reconnect loops.
VPN_CHECK_METHOD=${VPN_CHECK_METHOD:-dsm_status}

# CUSTOM_PING_ADDRESS : IP/hostname to ping when VPN_CHECK_METHOD=custom_ping.
# Prefer an IP address on the far side of the tunnel (avoids DNS dependence).
CUSTOM_PING_ADDRESS=${CUSTOM_PING_ADDRESS:-}

# TIMEOUT_SEC : Max seconds for the whole reconnect (kill + connect + wait).
# Blank = no timeout.
TIMEOUT_SEC=${TIMEOUT_SEC:-}

# KILL_WAIT_SEC : Seconds to wait after killing the old client.
KILL_WAIT_SEC=${KILL_WAIT_SEC:-20}

# CONNECT_WAIT_SEC : Max seconds to wait for the VPN to come up after connect.
CONNECT_WAIT_SEC=${CONNECT_WAIT_SEC:-60}

# SUCCESS_EXIT_CODE : Exit code after a successful reconnect. The default of 1
# makes DSM Task Scheduler send a notification when a reconnect happened.
# Set to 0 to treat a successful reconnect as a normal run.
SUCCESS_EXIT_CODE=${SUCCESS_EXIT_CODE:-1}

#-------------------------------------------------------------------------------
#  Helpers
#-------------------------------------------------------------------------------

LOCKFILE=/tmp/reconnect-vpn.lock
CONF_BASE=/usr/syno/etc/synovpnclient
SYNOVPNC=/usr/syno/bin/synovpnc

log() { printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$2"; }

# True if the file is root-owned and not group/world-writable.
file_is_safe() {
	local f=$1 owner perms
	[[ -e $f && -f $f && ! -L $f ]] || return 1
	owner=$(stat -c %u "$f" 2>/dev/null) || return 1
	perms=$(stat -c %A "$f" 2>/dev/null) || return 1
	[[ $owner == 0 && ${perms:5:1} != w && ${perms:8:1} != w ]]
}

# True if the directory is root-owned and not group/world-writable.
dir_is_safe() {
	local d=$1 owner perms
	[[ -d $d && ! -L $d ]] || return 1
	owner=$(stat -c %u "$d" 2>/dev/null) || return 1
	perms=$(stat -c %A "$d" 2>/dev/null) || return 1
	[[ $owner == 0 && ${perms:5:1} != w && ${perms:8:1} != w ]]
}

#-------------------------------------------------------------------------------
#  Environment checks
#-------------------------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
	log E "This script must run as root (the DSM VPN config is root-only). Exiting."
	exit 3
fi

if [[ ! -x $SYNOVPNC ]]; then
	log E "$SYNOVPNC not found. Is this a Synology DSM system? Exiting."
	exit 3
fi

if [[ ! -d $CONF_BASE || ! -r $CONF_BASE || -L $CONF_BASE ]]; then
	log E "Cannot safely read $CONF_BASE. Exiting."
	exit 3
fi

if ! dir_is_safe "$CONF_BASE"; then
	log E "$CONF_BASE must be root-owned and not group/world-writable. Exiting."
	exit 3
fi

SELF=${BASH_SOURCE[0]}
if ! file_is_safe "$SELF"; then
	log E "$SELF must be root-owned, a regular file, and not group/world-writable. Exiting."
	exit 3
fi

if [[ -e $LOCKFILE && ( -L $LOCKFILE || ! -f $LOCKFILE ) ]]; then
	log E "$LOCKFILE must not be a symlink or a non-regular file. Exiting."
	exit 3
fi

if [[ -e $CONF_BASE/vpnc_connecting && ( -L $CONF_BASE/vpnc_connecting || ! -f $CONF_BASE/vpnc_connecting ) ]]; then
	log E "$CONF_BASE/vpnc_connecting must not be a symlink or a non-regular file. Exiting."
	exit 3
fi

if ! file_is_safe "$SYNOVPNC"; then
	log E "$SYNOVPNC must be root-owned, a regular file, and not group/world-writable. Exiting."
	exit 3
fi

case $VPN_CHECK_METHOD in
	dsm_status|gateway_ping|custom_ping) ;;
	*) log E "Invalid VPN_CHECK_METHOD '$VPN_CHECK_METHOD'. Exiting."; exit 3 ;;
esac

if [[ $VPN_CHECK_METHOD == custom_ping && -z $CUSTOM_PING_ADDRESS ]]; then
	log E "VPN_CHECK_METHOD=custom_ping requires CUSTOM_PING_ADDRESS. Exiting."
	exit 3
fi

for v in KILL_WAIT_SEC CONNECT_WAIT_SEC SUCCESS_EXIT_CODE; do
	if ! [[ ${!v} =~ ^[0-9]+$ ]]; then
		log E "$v must be a non-negative integer. Exiting."
		exit 3
	fi
done
if [[ -n $TIMEOUT_SEC ]] && ! [[ $TIMEOUT_SEC =~ ^[0-9]+$ ]]; then
	log E "TIMEOUT_SEC must be a non-negative integer or blank. Exiting."
	exit 3
fi

#-------------------------------------------------------------------------------
#  Locking (prevents overlapping runs from killing each other's connection)
#-------------------------------------------------------------------------------

if command -v flock >/dev/null 2>&1; then
	exec 9>"$LOCKFILE"
	if ! flock -n 9; then
		log I "Another instance is already running. Exiting."
		exit 0
	fi
else
	log W "flock not available; running without a lock."
fi

#-------------------------------------------------------------------------------
#  Find the VPN profile (exact match, no regex)
#-------------------------------------------------------------------------------

shopt -s nullglob
CONF_FILES=("$CONF_BASE"/{l2tp,openvpn,pptp}/*client.conf)
shopt -u nullglob

if [[ ${#CONF_FILES[@]} -eq 0 ]]; then
	log W "No VPN client config files found under $CONF_BASE. Create a VPN profile. Exiting."
	exit 3
fi

for cf in "${CONF_FILES[@]}"; do
	if [[ -L $cf || ! -f $cf || ! -r $cf ]]; then
		log E "Unsafe VPN config file '$cf'. Exiting."
		exit 3
	fi
	if ! file_is_safe "$cf"; then
		log E "VPN config file '$cf' must be root-owned and not group/world-writable. Exiting."
		exit 3
	fi
done

# Output: <id>	<name>	<reconnect>
PARSED=$(awk '
	function emit() {
		if (id ~ /^[lop][0-9]+$/ && name != "") printf "%s\t%s\t%s\n", id, name, reconn
		id = ""; name = ""; reconn = ""
	}
	FNR == 1 { emit() }
	{ sub(/\r$/, "") }
	/^\[/ { emit(); id = $0; sub(/^\[/, "", id); sub(/\].*$/, "", id); next }
	/^conf_name=/ { name = substr($0, 11); next }
	/^reconnect=/ { reconn = substr($0, 11); next }
	END { emit() }
' "${CONF_FILES[@]}")

MATCHES=()
while IFS=$'\t' read -r p_id p_name p_reconn; do
	[[ -n $p_id ]] || continue
	if [[ -z $VPN_PROFILE_NAME || $p_name == "$VPN_PROFILE_NAME" ]]; then
		MATCHES+=("$p_id"$'\t'"$p_name"$'\t'"$p_reconn")
	fi
done <<< "$PARSED"

if [[ ${#MATCHES[@]} -gt 1 ]]; then
	log E "${#MATCHES[@]} VPN profiles match. Set VPN_PROFILE_NAME to the exact profile name. Exiting."
	exit 3
elif [[ ${#MATCHES[@]} -eq 0 ]]; then
	if [[ -n $VPN_PROFILE_NAME ]]; then
		log W "No VPN profile named '$VPN_PROFILE_NAME' found. Exiting."
	else
		log W "No VPN profiles found. Create a VPN profile. Exiting."
	fi
	exit 3
fi

IFS=$'\t' read -r PROFILE_ID PROFILE_NAME PROFILE_RECONNECT <<< "${MATCHES[0]}"

case ${PROFILE_ID:0:1} in
	l) PROFILE_PROTOCOL=l2tp ;;
	o) PROFILE_PROTOCOL=openvpn ;;
	p) PROFILE_PROTOCOL=pptp ;;
esac

log I "Using VPN profile '$PROFILE_NAME' ($PROFILE_PROTOCOL, id $PROFILE_ID)."

#-------------------------------------------------------------------------------
#  Check the VPN connection
#-------------------------------------------------------------------------------

check_dsm_status() {
	if "$SYNOVPNC" get_conn 2>/dev/null | grep -q Uptime; then
		log I "Synology DSM reports VPN is connected."
		return 0
	fi
	log W "Synology DSM reports VPN is not connected."
	return 1
}

check_ping() {
	local client_ip iface ping_addr
	client_ip=$("$SYNOVPNC" get_conn 2>/dev/null | awk '/Client IP/ { print $NF; exit }')
	if [[ -z $client_ip ]]; then
		log W "Could not determine the VPN client IP."
		return 1
	fi

	# Exact IP match against local addresses (handles "10.8.0.2/24" and p2p form)
	iface=$(ip -o -4 addr show | awk -v ip="$client_ip" '{ split($4, a, "/"); if (a[1] == ip) { print $2; exit } }')
	if [[ -z $iface ]]; then
		log W "Could not determine the tunnel interface for $client_ip."
		return 1
	fi

	if [[ $VPN_CHECK_METHOD == gateway_ping ]]; then
		# Prefer the point-to-point peer address, then a "via" gateway on the interface
		ping_addr=$(ip -o -4 addr show dev "$iface" | awk '{ for (i = 1; i < NF; i++) if ($i == "peer") { split($(i+1), a, "/"); print a[1]; exit } }')
		if [[ -z $ping_addr ]]; then
			ping_addr=$(ip -4 route show dev "$iface" | awk '{ for (i = 1; i < NF; i++) if ($i == "via") { print $(i+1); exit } }')
		fi
		if [[ -z $ping_addr ]]; then
			log W "Could not determine the gateway on $iface. Use custom_ping instead."
			return 1
		fi
		log I "Pinging VPN gateway $ping_addr via $iface."
	else
		ping_addr=$CUSTOM_PING_ADDRESS
		log I "Pinging custom address $ping_addr via $iface."
	fi

	if ping -c 3 -w 15 -I "$iface" "$ping_addr" >/dev/null 2>&1; then
		log I "$ping_addr responded to ping."
		return 0
	fi
	log W "$ping_addr did not respond to ping."
	return 1
}

check_vpn_connection() {
	check_dsm_status || return 1
	if [[ $VPN_CHECK_METHOD == *_ping ]]; then
		check_ping || return 1
	fi
	return 0
}

if check_vpn_connection; then
	log I "Reconnect is not needed. Exiting."
	exit 0
fi

#-------------------------------------------------------------------------------
#  Reconnect the VPN connection
#-------------------------------------------------------------------------------

if [[ $PROFILE_RECONNECT != yes ]]; then
	log W "Reconnect is disabled for the '$PROFILE_NAME' profile. Enable it in DSM. Exiting."
	exit 3
fi

do_reconnect() {
	log I "Attempting to reconnect."
	"$SYNOVPNC" kill_client 9>&-   # close the lock fd so a daemon cannot inherit it
	sleep "$KILL_WAIT_SEC"

	printf 'conf_id=%s\nconf_name=%s\nproto=%s\n' \
		"$PROFILE_ID" "$PROFILE_NAME" "$PROFILE_PROTOCOL" \
		> "$CONF_BASE/vpnc_connecting"

	"$SYNOVPNC" connect --id="$PROFILE_ID" 9>&-

	# Poll instead of sleeping a fixed time
	local waited=0
	while (( waited < CONNECT_WAIT_SEC )); do
		if check_vpn_connection >/dev/null 2>&1; then
			return 0
		fi
		sleep 5
		(( waited += 5 ))
	done
	return 1
}

if [[ -n $TIMEOUT_SEC ]] && command -v timeout >/dev/null 2>&1; then
	# Run the whole reconnect (kill + connect + wait) under the timeout
	export -f do_reconnect check_vpn_connection check_dsm_status check_ping log
	export SYNOVPNC CONF_BASE PROFILE_ID PROFILE_NAME PROFILE_PROTOCOL \
		KILL_WAIT_SEC CONNECT_WAIT_SEC VPN_CHECK_METHOD CUSTOM_PING_ADDRESS
	timeout "$TIMEOUT_SEC" bash -c do_reconnect
else
	[[ -n $TIMEOUT_SEC ]] && log W "timeout command not found; running without timeout."
	do_reconnect
fi
RECONNECT_RC=$?

#-------------------------------------------------------------------------------
#  Final check
#-------------------------------------------------------------------------------

if [[ $RECONNECT_RC -eq 0 ]] && check_vpn_connection; then
	log I "VPN successfully reconnected. Exiting."
	exit "$SUCCESS_EXIT_CODE"
fi

# Don't leave a stale "connecting" marker behind after a failure/timeout
rm -f "$CONF_BASE/vpnc_connecting"
log E "VPN failed to reconnect. Exiting."
exit 2
