#!/usr/bin/env bash
#===============================================================================
#         FILE:  reconnect-vpn.sh
#
#  DESCRIPTION:  Reconnect a disconnected VPN session on Synology DSM
#    SOURCE(S):  https://community.synology.com/enu/forum/17/post/53791
#       README:  https://github.com/ianharrier/synology-scripts
#
#      AUTHORS:  Ian Harrier, Deac Karns, Michael Lake, mchalandon
#      VERSION:  1.5.0
#      LICENSE:  MIT License
#===============================================================================

#-------------------------------------------------------------------------------
#  User-customizable variables
#-------------------------------------------------------------------------------

# VPN_PROFILE_NAME : The VPN "Profile Name" (from DSM) you want to reconnect, in case multiple VPN profiles exist.
# - Note: Leaving this blank requires that only one VPN profile is configured in DSM.
VPN_PROFILE_NAME=

# VPN_CHECK_METHOD : How to check if the VPN connection is alive. Options:
# - "dsm_status" (default) : assume OK if Synology DSM reports the VPN connection is alive
# - "gateway_ping" : assume OK if the default gateway (i.e. VPN server) responds to ICMP ping
# - "custom_ping" : assume OK if CUSTOM_PING_ADDRESS (configured below) responds to ICMP ping
VPN_CHECK_METHOD=dsm_status

# CUSTOM_PING_ADDRESS : IP address or hostname to ping when VPN_CHECK_METHOD=custom_ping
CUSTOM_PING_ADDRESS=example.com

# NO_RECONNECT_SCRIPT : Run this script if a reconnection is not needed
NO_RECONNECT_SCRIPT=

# PRE_RECONNECT_SCRIPT : Run this script before a reconnection is attempted
PRE_RECONNECT_SCRIPT=

# POST_SUCCESS_SCRIPT : Run this script after a successful reconnection
POST_SUCCESS_SCRIPT=

# POST_FAILURE_SCRIPT : Run this script after a failed reconnection
POST_FAILURE_SCRIPT=

#-------------------------------------------------------------------------------
#  Process VPN config files
#-------------------------------------------------------------------------------

if [[ $VPN_PROFILE_NAME ]]; then
	echo "[I] Searching for '$VPN_PROFILE_NAME' in VPN configurations..."
fi

# Get the VPN config file(s)
CONFIG=$(cat /usr/syno/etc/synovpnclient/{l2tp,openvpn,pptp}/*client.conf 2>/dev/null | grep -Poz "\[[l|o|p]\d+\][^\[]+$VPN_PROFILE_NAME[^\[]+" | tr -d '\0')

# How many VPN profiles are there?
PROFILE_QTY=$(echo "$CONFIG" | grep -E '^\[' | wc -l)

# Only proceed if there is 1 VPN profile
if [[ $PROFILE_QTY -gt 1 ]]; then
	echo "[E] There are $PROFILE_QTY VPN profiles. Please configure VPN_PROFILE_NAME. Exiting..."
	exit 3
elif [[ $PROFILE_QTY -eq 0 ]]; then
	echo "[W] There are 0 VPN profiles. Please create a VPN profile. Exiting..."
	exit 3
fi

#-------------------------------------------------------------------------------
#  Set variables
#-------------------------------------------------------------------------------

PROFILE_ID=$(echo $CONFIG | cut -d "[" -f2 | cut -d "]" -f1)
PROFILE_NAME=$(echo "$CONFIG" | grep -oP "conf_name=+\K\w+")
PROFILE_RECONNECT=$(echo "$CONFIG" | grep -oP "reconnect=+\K\w+")

if [[ $(echo "$CONFIG" | grep '\[l') ]]; then
	PROFILE_PROTOCOL="l2tp"
elif [[ $(echo "$CONFIG" | grep '\[o') ]]; then
	PROFILE_PROTOCOL="openvpn"
elif [[ $(echo "$CONFIG" | grep '\[p') ]]; then
	PROFILE_PROTOCOL="pptp"
fi

#-------------------------------------------------------------------------------
#  Check the VPN connection
#-------------------------------------------------------------------------------

function check_dsm_status() {
	if [[ $(/usr/syno/bin/synovpnc get_conn | grep Uptime) ]]; then
		echo "[I] Synology DSM reports VPN is connected."
		return 0
	else
		echo "[W] Synology DSM reports VPN is not connected."
		return 1
	fi
}

function check_ping() {
	local CLIENT_IP=$(/usr/syno/bin/synovpnc get_conn | grep "Client IP" | awk '{ print $4 }')
	local TUNNEL_INTERFACE=$(ip addr | grep $CLIENT_IP | awk 'END{ print $NF }')
	if [[ $VPN_CHECK_METHOD = "gateway_ping" ]]; then
		local PING_ADDRESS=$(ip route | grep $TUNNEL_INTERFACE | grep -oE '([0-9]+\.){3}[0-9]+ dev' | awk '{ print $1 }' | head -n 1)
		echo "[I] Pinging VPN gateway address $PING_ADDRESS."
	else
		local PING_ADDRESS=$CUSTOM_PING_ADDRESS
		echo "[I] Pinging custom address $PING_ADDRESS."
	fi
	if ping -c 1 -i 1 -w 15 -I $TUNNEL_INTERFACE $PING_ADDRESS > /dev/null 2>&1; then
		echo "[I] The address $PING_ADDRESS responded to ping."
		return 0
	else
		echo "[W] The address $PING_ADDRESS did not respond to ping."
		return 1
	fi
}

function check_vpn_connection() {
	local CONNECTION_STATUS=disconnected
	if [[ $VPN_CHECK_METHOD = *_ping ]]; then
		check_dsm_status && check_ping && CONNECTION_STATUS=connected
	else
		check_dsm_status && CONNECTION_STATUS=connected
	fi
	if [[ $CONNECTION_STATUS = "connected" ]]; then
		return 0
	else
		return 1
	fi
}

if check_vpn_connection; then
	if [[ -x $NO_RECONNECT_SCRIPT ]]; then
		echo "[I] Reconnect is not needed. Running no-reconnect script \"$NO_RECONNECT_SCRIPT\", then exiting..."
		"$NO_RECONNECT_SCRIPT"
	else
		echo "[I] Reconnect is not needed. Exiting..."
	fi
	exit 0
fi

#-------------------------------------------------------------------------------
#  Reconnect the VPN connection
#-------------------------------------------------------------------------------

if [[ $PROFILE_RECONNECT != "yes" ]]; then
	echo "[W] Reconnect is disabled. Please enable reconnect for for the \"$PROFILE_NAME\" VPN profile. Exiting..."
	exit 3
fi

if [[ -x $PRE_RECONNECT_SCRIPT ]]; then
	echo "[I] Running pre-reconnect script \"$PRE_RECONNECT_SCRIPT\"..."
	"$PRE_RECONNECT_SCRIPT"
fi

echo "[I] Attempting to reconnect..."
/usr/syno/bin/synovpnc kill_client
sleep 20
cat > /usr/syno/etc/synovpnclient/vpnc_connecting <<EOF
conf_id=$PROFILE_ID
conf_name=$PROFILE_NAME
proto=$PROFILE_PROTOCOL
EOF
/usr/syno/bin/synovpnc connect --id=$PROFILE_ID
sleep 20

#-------------------------------------------------------------------------------
#  Re-check the VPN connection
#-------------------------------------------------------------------------------

if check_vpn_connection; then
	if [[ -x $POST_SUCCESS_SCRIPT ]]; then
		echo "[I] VPN successfully reconnected. Running post-success script \"$POST_SUCCESS_SCRIPT\", then exiting..."
		"$POST_SUCCESS_SCRIPT"
	else
		echo "[I] VPN successfully reconnected. Exiting..."
	fi
	exit 1
else
	if [[ -x $POST_FAILURE_SCRIPT ]]; then
		echo "[I] VPN failed to reconnect. Running post-failure script \"$POST_FAILURE_SCRIPT\", then exiting..."
		"$POST_FAILURE_SCRIPT"
	else
		echo "[E] VPN failed to reconnect. Exiting..."
	fi
	exit 2
fi
