#!/usr/bin/env bash
#===============================================================================
#         FILE:  reconnect-vpn.sh
#
#  DESCRIPTION:  Reconnect a disconnected VPN session on Synology DSM
#    SOURCE(S):  https://community.synology.com/enu/forum/17/post/53791
#       README:  https://github.com/ianharrier/synology-scripts
#
#      AUTHORS:  Ian Harrier, Deac Karns, Michael Lake, mchalandon
#      VERSION:  1.4.0
#      LICENSE:  MIT License
#===============================================================================

#-------------------------------------------------------------------------------
#  User-customizable variables
#-------------------------------------------------------------------------------

# PROFILE_NAME : The VPN "Profile Name" (from DSM) you want to reconnect, in case multiple VPN profiles exist.
# - Note: Leaving this blank will assume only one VPN profile is configured.
PROFILE_NAME=""

# VPN_CHECK_METHOD : How to check if the VPN connection is alive. Options:
# - "dsm_status" (default) : assume OK if Synology DSM reports the VPN connection is alive
# - "gateway_ping" : assume OK if the default gateway (i.e. VPN server) responds to ICMP ping
# - "custom_ping" : assume OK if CUSTOM_PING_ADDRESS (configured below) responds to ICMP ping
VPN_CHECK_METHOD=dsm_status

# CUSTOM_PING_ADDRESS : IP address or hostname to ping when VPN_CHECK_METHOD=custom_ping
CUSTOM_PING_ADDRESS=example.com

#-------------------------------------------------------------------------------
#  Process VPN config files
#-------------------------------------------------------------------------------

# Get the VPN config files
CONFIGS_ALL=$(cat /usr/syno/etc/synovpnclient/{l2tp,openvpn,pptp}/*client.conf 2>/dev/null)

if [ -n "$VPN_IDENTIFIER" ]; then
  echo "[I] Searching $VPN_IDENTIFIER in VPN configurations..."
  CONFIGS_ALL=$(echo "$CONFIGS_ALL" | grep -Poz '\[[l|o|p]\d*\][^\[]*'$VPN_IDENTIFIER'[^\[]*')
fi

# How many VPN profiles are there?
CONFIGS_QTY=$(echo "$CONFIGS_ALL" | grep -e '\[l' -e '\[o' -e '\[p' | wc -l)

# Only proceed if there is 1 VPN profile
if [[ $CONFIGS_QTY -eq 1 ]]; then
	echo "[I] 1 VPN profile found. Continuing..."
elif [[ $CONFIGS_QTY -gt 1 ]]; then
	echo "[E] $CONFIGS_QTY VPN profiles found. This script supports only 1 VPN profile. Exiting..."
	exit 3
else
	echo "[W] 0 VPN profiles found. Please create a VPN profile. Exiting..."
	exit 3
fi

#-------------------------------------------------------------------------------
#  Set variables
#-------------------------------------------------------------------------------

PROFILE_ID=$(echo $CONFIGS_ALL | cut -d "[" -f2 | cut -d "]" -f1)
PROFILE_NAME=$(echo "$CONFIGS_ALL" | grep -oP "conf_name=+\K\w+")
PROFILE_RECONNECT=$(echo "$CONFIGS_ALL" | grep -oP "reconnect=+\K\w+")

if [[ $(echo "$CONFIGS_ALL" | grep '\[l') ]]; then
	PROFILE_PROTOCOL="l2tp"
elif [[ $(echo "$CONFIGS_ALL" | grep '\[o') ]]; then
	PROFILE_PROTOCOL="openvpn"
elif [[ $(echo "$CONFIGS_ALL" | grep '\[p') ]]; then
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
	local TUNNEL_INTERFACE=$(ip addr | grep $CLIENT_IP | awk '{ print $NF }')
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
	echo "[I] Reconnect is not needed. Exiting..."
	exit 0
fi

#-------------------------------------------------------------------------------
#  Reconnect the VPN connection
#-------------------------------------------------------------------------------

if [[ $PROFILE_RECONNECT != "yes" ]]; then
	echo "[W] Reconnect is disabled. Please enable reconnect for for the \"$PROFILE_NAME\" VPN profile. Exiting..."
	exit 3
fi

echo "[I] Attempting to reconnect..."
/usr/syno/bin/synovpnc kill_client
sleep 20
echo conf_id=$PROFILE_ID > /usr/syno/etc/synovpnclient/vpnc_connecting
echo conf_name=$PROFILE_NAME >> /usr/syno/etc/synovpnclient/vpnc_connecting
echo proto=$PROFILE_PROTOCOL >> /usr/syno/etc/synovpnclient/vpnc_connecting
/usr/syno/bin/synovpnc connect --id=$PROFILE_ID
sleep 20

#-------------------------------------------------------------------------------
#  Re-check the VPN connection
#-------------------------------------------------------------------------------

if check_vpn_connection; then
	echo "[I] VPN successfully reconnected. Exiting..."
	exit 1
else
	echo "[E] VPN failed to reconnect. Exiting..."
	exit 2
fi
