#!/usr/bin/env bash
#===============================================================================
#         FILE:  reconnect-vpn.sh
#
#  DESCRIPTION:  Reconnect a disconnected VPN session on Synology DSM
#    SOURCE(S):  https://forum.synology.com/enu/viewtopic.php?f=241&t=65444
#
#       AUTHOR:  Ian Harrier
#      VERSION:  1.0.0
#      LICENSE:  MIT License
#===============================================================================

#-------------------------------------------------------------------------------
#  Pull in VPN config files
#-------------------------------------------------------------------------------

if [[ -f /usr/syno/etc/synovpnclient/l2tp/l2tpclient.conf ]]; then
	L2TP_CONFIG=$(cat /usr/syno/etc/synovpnclient/l2tp/l2tpclient.conf)
else
 	L2TP_CONFIG=""
fi

if [[ -f /usr/syno/etc/synovpnclient/openvpn/ovpnclient.conf ]]; then
 	OPENVPN_CONFIG=$(cat /usr/syno/etc/synovpnclient/openvpn/ovpnclient.conf)
else
 	OPENVPN_CONFIG=""
fi

if [[ -f /usr/syno/etc/synovpnclient/pptp/pptpclient.conf ]]; then
 	PPTP_CONFIG=$(cat /usr/syno/etc/synovpnclient/pptp/pptpclient.conf)
else
 	PPTP_CONFIG=""
fi

#-------------------------------------------------------------------------------
#  Process config files
#-------------------------------------------------------------------------------

# Concatenate the config files
CONFIGS_ALL="$L2TP_CONFIG $OPENVPN_CONFIG $PPTP_CONFIG"

# How many VPN profiles are there?
CONFIGS_QTY=$(echo "$CONFIGS_ALL" | grep -e '\[l' -e '\[o' -e '\[p' | wc -l)

# Only proceed if there is 1 VPN profile
if [[ $CONFIGS_QTY -eq 1 ]]; then
 	echo "[I] There is 1 VPN profile. Continuing..."
elif [[ $CONFIGS_QTY -gt 1 ]]; then
 	echo "[E] There are $CONFIGS_QTY VPN profiles. This script supports only 1 VPN profile. Exiting..."
 	exit 1
else
 	echo "[W] There are 0 VPN profiles. Please create a VPN profile. Exiting..."
 	exit 1
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

if [[ $(/usr/syno/bin/synovpnc get_conn | grep Uptime) ]]; then
 	echo "[I] VPN is already connected. Exiting..."
 	exit 0
fi

if [[ $PROFILE_RECONNECT != "yes" ]]; then
 	echo "[W] VPN is not connected, but reconnect is disabled. Please enable reconnect for for the \"$PROFILE_NAME\" VPN profile. Exiting..."
 	exit 1
else
 	echo "[W] VPN is not connected. Attempting to reconnect..."
fi

#-------------------------------------------------------------------------------
#  Reconnect the VPN connection
#-------------------------------------------------------------------------------

echo conf_id=$PROFILE_ID > /usr/syno/etc/synovpnclient/vpnc_connecting
echo conf_name=$PROFILE_NAME >> /usr/syno/etc/synovpnclient/vpnc_connecting
echo proto=$PROFILE_PROTOCOL >> /usr/syno/etc/synovpnclient/vpnc_connecting
/usr/syno/bin/synovpnc reconnect --protocol=$PROFILE_PROTOCOL --name=$PROFILE_NAME --retry=1 --interval=30

#-------------------------------------------------------------------------------
#  Re-check the VPN connection
#-------------------------------------------------------------------------------

if [[ $(/usr/syno/bin/synovpnc get_conn | grep Uptime) ]]; then
 	echo "[I] VPN successfully reconnected. Exiting..."
 	exit 1
else
 	echo "[E] VPN failed to reconnect. Exiting..."
 	exit 1
fi
