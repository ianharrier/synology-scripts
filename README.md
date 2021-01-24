# synology-scripts

Scripts for Synology DSM

## `reconnect-vpn.sh`

This script can be used as a workaround for Synology DSM's less-than-ideal reconnect behavior when a VPN connection is lost. The actual magic in this script was originally written by users on a [thread on the Synology Forum](https://forum.synology.com/enu/viewtopic.php?f=241&t=65444). This script just provides a user-friendly wrapper to their code. For more information, including installation instructions, refer to my [blog post](https://blog.harrier.us/reconnecting-a-failed-vpn-connection-on-synology-dsm-6/).

**As of version 1.1.0, extra customization options are included at the beginning of the script. Feel free to customize these to your liking.**

**As of version 1.2.0, the following exit codes are used:**

- `0`: reconnect not needed
- `1`: reconnect successful
- `2`: reconnect failed
- `3`: configuration error
