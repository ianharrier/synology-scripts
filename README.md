# synology-scripts

Scripts for Synology DSM

## `reconnect-vpn.sh`

This script can be used as a workaround for Synology DSM's less-than-ideal reconnect behavior when a VPN connection is lost. The actual magic in this script was originally written by users on a [thread on the Synology Forum](https://community.synology.com/enu/forum/17/post/53791). This script just provides a user-friendly wrapper to their code.

There were a number of goals in writing this script:

- Require no script modifications before putting into production
- Work with all VPN protocols (L2TP, PPTP, and OpenVPN)
- Run natively from DSM without needing backend console access
- Send email notifications when encountering warning or error conditions

This script was written for DSM 6.0.2, but from what I have seen, it will probably work on DSM 5.0 and high.

### Installation

Follow the official [Synology documentation](https://kb.synology.com/en-us/DSM/help/DSM/AdminCenter/system_taskscheduler) to create a scheduled task.

- Make sure the task runs as `root`.
- This script can run frequently (e.g. every 5 minutes).
- The **Send run details only when the script terminates abnormally** option is recommended. The script was written using different exit codes, allowing it to work well with this option.
- In the user-defined script box, you can either:
	- Paste the entire contents of the script itself.
	- Include the full path to the script (after uploading the script to some location on your device).

### Version History

- **1.1.0**: Extra customization options are included at the beginning of the script. Feel free to customize these to your liking.
- **1.2.0**: The following exit codes are used:
	- `0`: reconnect not needed
	- `1`: reconnect successful
	- `2`: reconnect failed
	- `3`: configuration error
- **1.3.0**: An option is added to allow pinging a custom IP address or hostname to validate VPN connectivity.
- **1.4.0**: An option is added to choose a specific VPN profile to reconnect, if multiple profiles exist. In this configuration, you could run multiple instances of this script, each targeting a specific VPN profile.
- **1.5.0**: Options are added to run external scripts at various points. Note that the scripts must be executable, and if there are spaces in the script paths, you must either escape the spaces (e.g. `NO_RECONNECT_SCRIPT=/volume1/Scripts/script\ with\ spaces.sh`) or wrap the script paths in quotes (e.g. `NO_RECONNECT_SCRIPT='/volume1/Scripts/script with spaces.sh'`). *Community-maintained scripts compatible with these features are included in the `reconnect-vpn.sh Community Scripts` directory.*
- **1.6.0**: An option is added to set a reconnect timeout, in the event the reconnect process hangs. This new option is currently considered experimental, as it is not well tested. Please feel free to open an issue if something doesn't work as expected.
