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

# DISPLAY_HARDWARE_ALERTS : Cause the Synology to beep and flash lights when 
# the VPN is interrupted. Options:
# - "false" (default) : do not beep or change lights
# - "true" : beep and change status light based on connection status:
#   - Interrupted: Single long beep and solid orange status light
#   - Reconnecting: blinking orange status light
#   - Reconnected: Single short beep and solid green status light
DISPLAY_HARDWARE_ALERTS=false

# STATUS_OFFLINE_INDICATOR_FILE : Create a file in the filesystem when VPN is 
# interrupted and will be deleted once VPN reconnects. Options:
# - commented (default) : do not create an indicator file
# - "/full/path/to/file" : full filesystem path of file to create
#STATUS_OFFLINE_INDICATOR_FILE="/volume1/Share/__WARNING - VPN IS OFFLINE"

# TRANSMISSION_SERVICE_CHECK : This is set if you are running Transmission as a
# Docker container. This will pause the Transmission container when running in
# the event the VPN connection is not connected and resume the container when
# the VPN connection is retored. Options:
# - "false" (default) : This will DISABLE this feature
# - "true" : This will ENABLE this feature
TRANSMISSION_CONTAINER_CHECK=false

# TRANSMISSION_CONTAINER_NAME : This is the name of the docker container which
# is running Transmission (e.g. the value when you run it:
#   e.g. : docker run --name YOUR_CONTAINER_NAME ...
# This will pause the Transmission container when running in the event the VPN
# connection is not connected and resume the container when the VPN connection
# is retored. Options:
# - "" (default) : this will DISABLE this feature along even if
#   TRANSMISSION_SERVICE_CHECK is set to "true" above (You MUST set this value)
# - "YOUR_CONTAINER_NAME" : the name of the Transmission container
TRANSMISSION_CONTAINER_NAME="transmission"

# TRANSMISSION_SERVICE_CHECK : This is set if you are running Transmission as
# a native service for Synology and not within a Docker container. This will
# hard-disable the Transmission Synology service when running in the event the
# VPN connection is not connected and hard-enable the container when the VPN
# connection is retored.  Options:
# - "false" (default) : this will DISABLE this feature
# - "true" : This will stop the Transmission process when the VPN connection is
#   not connected and resume the process when the VPN connection is
#   restored.
TRANSMISSION_SERVICE_CHECK=false

# TRANSMISSION_SERVICE_NAME : This is the service name that the Synology service
# tool uses to recognize the Transmission service by that it will start and
# stop. You can find the name of your Transmission service by doing the
# following and inspecting the JSON value for the service name:
#   e.g. : cat /usr/syno/etc/synoservice.d/pkgctl-transmission.cf
# Options:
# - "pkgctl-transmission" (default) : the default name of the Synology service
#   name as it comes from the Synology Community packages
# Note : You will likely not need to change this value
TRANSMISSION_SERVICE_NAME="pkgctl-transmission"

#-------------------------------------------------------------------------------
#  Process VPN config files
#-------------------------------------------------------------------------------

# Make sure we're executing as root (required to get VPN information from synovpnc)
if [[ ${UID} -ne 0 ]]; then
	echo "[E] This script must be run as root."
	exit 3
fi

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

DOCKER_COMMAND=$(command -v docker)
PROFILE_ID=$(echo $CONFIG | cut -d "[" -f2 | cut -d "]" -f1)
PROFILE_NAME=$(echo "$CONFIG" | grep -oP "conf_name=+\K\w+")
PROFILE_RECONNECT=$(echo "$CONFIG" | grep -oP "reconnect=+\K\w+")
PROFILE_ID=$(echo $CONFIGS_ALL | cut -d "[" -f2 | cut -d "]" -f1)
PROFILE_NAME=$(echo "$CONFIGS_ALL" | grep -oP "conf_name=+\K\w+")
PROFILE_RECONNECT=$(echo "$CONFIGS_ALL" | grep -oP "reconnect=+\K\w+")
TRANSMISSION_SERVICE_STATUS=$(/usr/syno/sbin/synoservice --status $TRANSMISSION_SERVICE_NAME | grep -oP "\[$TRANSMISSION_SERVICE_NAME\] is .*\." | sed -r "s/\[$TRANSMISSION_SERVICE_NAME\] is (.*)\./\1/g")
VPN_OFFLINE_FLAG_FILE="/tmp/reconnect-vpn-offline"

if [[ $(echo "$CONFIG" | grep '\[l') ]]; then
	PROFILE_PROTOCOL="l2tp"
elif [[ $(echo "$CONFIG" | grep '\[o') ]]; then
	PROFILE_PROTOCOL="openvpn"
elif [[ $(echo "$CONFIG" | grep '\[p') ]]; then
	PROFILE_PROTOCOL="pptp"
fi

#-------------------------------------------------------------------------------
#  Function definitions
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
		clear_connection_error_indicator
		return 0
	else
		create_connection_error_indicator
		return 1
	fi
}

function create_connection_error_indicator() {
	if [[ $DISPLAY_HARDWARE_ALERTS = "true" ]]; then
		echo ":" > /dev/ttyS1  # solid orange status light
	fi
	# only do these if an 'offline' status flag has not been created by previous instances of this script
	if [ ! -f "$VPN_OFFLINE_FLAG_FILE" ]; then
		touch "$VPN_OFFLINE_FLAG_FILE"

		if [ ! -z "$STATUS_OFFLINE_INDICATOR_FILE" ] && [ -d $(dirname "$STATUS_OFFLINE_INDICATOR_FILE") ] && [ ! -f "$STATUS_OFFLINE_INDICATOR_FILE" ]; then
			touch "$STATUS_OFFLINE_INDICATOR_FILE"
		fi

		if [[ $DISPLAY_HARDWARE_ALERTS = "true" ]]; then
			echo "3" > /dev/ttyS1  # long beep
		fi
	fi
}

function clear_connection_error_indicator() {
	if [ -f "$VPN_OFFLINE_FLAG_FILE" ]; then
		rm -f "$VPN_OFFLINE_FLAG_FILE"

		if [[ $DISPLAY_HARDWARE_ALERTS = "true" ]]; then
			echo "28" > /dev/ttyS1  # short beep + solid green status light
		fi
	fi
	if [ ! -z "$STATUS_OFFLINE_INDICATOR_FILE" ] && [ -f "$STATUS_OFFLINE_INDICATOR_FILE" ]; then
		rm -f "$STATUS_OFFLINE_INDICATOR_FILE"
	fi
}

function change_transmission_container_state() {
	local DOCKER_COMMAND_RESULT=""
	local DOCKER_CONTAINER_STATUS=""
	local PAUSE_UNPAUSE="${1:=pause}"

	if [[ "$TRANSMISSION_CONTAINER_CHECK" != "true" ]] && [ -z "$TRANSMISSION_CONTAINER_NAME" ]; then
		# We will skip and return 0 here because the Transmission container name
		# is empty or unset disabling this feature
		echo "[I] Skipping Transmission Docker container check..."
		return 0
	fi

	if [ -x "$DOCKER_COMMAND" ]; then
		DOCKER_CONTAINER_STATUS=$(docker container inspect --format='{{.State.Status}}' $TRANSMISSION_CONTAINER_NAME)
		if [ $DOCKER_CONTAINER_STATUS == "running" ] && [ $PAUSE_UNPAUSE == "unpause" ]; then
			echo "[I] Skipping unpause of Transmission Docker container since it is already running."
			return 0
		elif [[ $DOCKER_CONTAINER_STATUS =~ ^(paused|stopped)$ ]] && [ $PAUSE_UNPAUSE == "pause" ]; then
			echo "[I] Skipping pause of Transmission Docker container since it is already paused."
			return 0
		fi

		DOCKER_COMMAND_RESULT=$(docker $PAUSE_UNPAUSE $TRANSMISSION_CONTAINER_NAME)
	else
		echo "[W] Docker command was not found."
		return 1
	fi

	if [ ! -z "$DOCKER_COMMAND_RESULT" ] && [ "$DOCKER_COMMAND_RESULT" == "$TRANSMISSION_CONTAINER_NAME" ]; then
		echo "[I] Successfully able to $PAUSE_UNPAUSE the Transmission Docker container."
		return 0
	fi

	echo "[W] Something went wrong trying to $PAUSE_UNPAUSE the Transmission Docker container: $DOCKER_COMMAND_RESULT."
	return 1
}

function check_transmission_synology_service() {
	TRANSMISSION_SERVICE_STATUS=$(/usr/syno/sbin/synoservice --status $TRANSMISSION_SERVICE_NAME | grep -oP "\[$TRANSMISSION_SERVICE_NAME\] is .*\." | sed -r "s/\[$TRANSMISSION_SERVICE_NAME\] is (.*)\./\1/g")

	if [[ "$TRANSMISSION_SERVICE_CHECK" != "true" ]]; then
		# We return a non-zero value because technically the service should not be
		# checked if the service check isn't set to "true"
		return 2
	fi

	if [ -z "$TRANSMISSION_SERVICE_STATUS" ] || [[ ! "$TRANSMISSION_SERVICE_STATUS" =~ .*(start|stop).* ]]; then
		echo "[W] Transmission Synology service \"$TRANSMISSION_SERVICE_NAME\" not found with a start or stop status."
		return 1
	fi

	echo "[I] Transmission Synology service \"$TRANSMISSION_SERVICE_NAME\" found with status \"$TRANSMISSION_SERVICE_STATUS\"."
	return 0
}

function change_transmission_service_state() {
	local SERVICE_COMMAND_RESULT=1
	local START_STOP="${1:=stop}"

	local DISABLE_ENABLE="hard-disable"
	if [ $START_STOP == "start" ]; then
		DISABLE_ENABLE="hard-enable"
	fi

	if [ $TRANSMISSION_SERVICE_CHECK != "true" ]; then
		# We will skip and return 0 here because the Transmission service check is 
		# set to something other than "true"
		echo "[I] Skipping Transmission Synology service check..."
		return 0
	fi

	if [ "$TRANSMISSION_SERVICE_STATUS" != "$START_STOP" ] && check_transmission_synology_service; then
		/usr/syno/sbin/synoservice --$DISABLE_ENABLE $TRANSMISSION_SERVICE_NAME
		SERVICE_COMMAND_RESULT=$?
		if [ $SERVICE_COMMAND_RESULT ]; then
			echo "[I] Successfully able to $START_STOP the Transmission Synology service."
			return 0
		fi
	fi

	return $SERVICE_COMMAND_RESULT
}

#-------------------------------------------------------------------------------
#  Check VPN and reconnect if needed
#-------------------------------------------------------------------------------

if check_vpn_connection; then
	echo "[I] Reconnect is not needed. Exiting..."
	exit 0
fi

if [[ $PROFILE_RECONNECT != "yes" ]]; then
	PROFILE_NAME="${PROFILE_NAME:=$VPN_PROFILE_NAME}"
	echo "[W] Reconnect is disabled. Please enable reconnect for for the \"$PROFILE_NAME\" VPN profile. Exiting..."
	exit 3
fi

echo "[I] Attempting to reconnect..."
if [[ $DISPLAY_HARDWARE_ALERTS = "true" ]]; then
	echo ";" > /dev/ttyS1  # blinking orange status light
fi
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

EXIT_CODE=0
if check_vpn_connection; then
	echo "[I] VPN successfully reconnected."
	if ! (change_transmission_container_state unpause); then
		echo "[W] Unable to unpause the Transmission Docker container."
	fi

	if [ "$TRANSMISSION_SERVICE_STATUS" != "start" ]; then
		if ! (change_transmission_service_state start); then
			echo "[W] Unable to start the Transmission Synology service."
		fi
	else
		echo "[I] Skipping start of Transmission Synology service since it is already started."
	fi
else
	echo "[E] VPN failed to reconnect."
	if ! (change_transmission_container_state pause); then
		echo "[E] Unable to pause the Transmission Docker container."
		EXIT_CODE=3
	fi

	if [ "$TRANSMISSION_SERVICE_STATUS" != "stop" ]; then
		if ! (change_transmission_service_state stop); then
			echo "[E] Unable to stop the Transmission Synology service."
			EXIT_CODE=3
		fi
	else
		echo "[I] Skipping stop of Transmission Synology service since it is already stopped."
		if [ $EXIT_CODE -gt 0 ]; then
			exit $EXIT_CODE
		fi
	fi
fi

echo "Exiting..."
exit $EXIT_CODE
