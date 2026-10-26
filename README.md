# reconnect-vpn

Reconnect a dropped VPN client connection on Synology DSM.

DSM's built-in "reconnect when connection is lost" option does not always bring a
tunnel back. This script checks the connection on a schedule and, if the VPN is
down, kills the stale client and reconnects the profile.

This is a fork of [`ianharrier/synology-scripts`](https://github.com/ianharrier/synology-scripts)
(`reconnect-vpn.sh` v1.6.1), rewritten for robustness. See [Changes from upstream](#changes-from-upstream).

## Requirements

- Synology DSM with a VPN client profile (L2TP, OpenVPN or PPTP) created under
  **Control Panel > Network > Network Interface > Create > Create VPN profile**
- **Reconnect when the VPN connection is lost** enabled on that profile (the
  script refuses to act otherwise)
- Root privileges (DSM stores the VPN configuration in a root-only directory)

## Installation

1. Enable SSH on the NAS if it is currently disabled:
   - **Control Panel > Terminal & SNMP**
   - Enable **Enable SSH service**
   - If needed, also allow **Enable root account** or use a local admin account with
     suitable privileges for the shell session
2. Connect to the NAS over SSH:

   ```bash
   ssh root@<nas-ip>
   ```

   or, if your DSM setup requires a non-root admin account:

   ```bash
   ssh <admin-user>@<nas-ip>
   ```

3. Copy the script to a private location on the NAS, for example
   `/volume1/scripts/reconnect-vpn.sh`.
   - Use a dedicated script directory that is not writable by normal users.
   - Do not install it in a shared or world-writable location.
4. Make sure the script is owned by `root` and not writable by group or others:

   ```bash
   sudo chown root:root /volume1/scripts/reconnect-vpn.sh
   sudo chmod 700 /volume1/scripts/reconnect-vpn.sh
   ```

   The script intentionally refuses to run if it is not root-owned or is writable by
   non-root users, because it executes privileged DSM VPN commands as root.
5. Test it manually while the VPN is connected:

   ```bash
   sudo /volume1/scripts/reconnect-vpn.sh
   ```

   You should see `Reconnect is not needed.`
6. Disable SSH again after installation if you do not need it to stay enabled:
   - **Control Panel > Terminal & SNMP**
   - Disable **Enable SSH service**
   - This reduces the attack surface while keeping the scheduled script in place.
7. Schedule it with DSM Task Scheduler as the `root` user (see below).

## Configuration

Edit the variables at the top of the script, or pass them as environment
variables (environment values take precedence over the defaults in the file):

```bash
VPN_PROFILE_NAME="Home VPN" VPN_CHECK_METHOD=custom_ping CUSTOM_PING_ADDRESS=10.8.0.1 \
  /volume1/scripts/reconnect-vpn.sh
```

| Variable | Default | Description |
|---|---|---|
| `VPN_PROFILE_NAME` | *(blank)* | Exact profile name from DSM. Leave blank only if you have a single VPN profile. |
| `VPN_CHECK_METHOD` | `dsm_status` | `dsm_status`, `gateway_ping` or `custom_ping` (see below). |
| `CUSTOM_PING_ADDRESS` | *(blank)* | Address to ping when using `custom_ping`. Prefer an IP on the far side of the tunnel. |
| `TIMEOUT_SEC` | *(blank)* | Maximum seconds for the whole reconnect (kill, connect and wait). Blank disables the timeout. |
| `KILL_WAIT_SEC` | `20` | Seconds to wait after killing the old client. |
| `CONNECT_WAIT_SEC` | `60` | Maximum seconds to wait for the tunnel to come up after connecting. |
| `SUCCESS_EXIT_CODE` | `1` | Exit code after a successful reconnect. See [Exit codes](#exit-codes). |

### Check methods

- **`dsm_status`**: the connection is considered healthy if DSM reports an uptime
  for it. Lightweight, but a hung tunnel can still look connected.
- **`gateway_ping`**: additionally pings the tunnel peer (or a `via` gateway on the
  tunnel interface) through the tunnel. Works only if the gateway answers ICMP.
- **`custom_ping`**: additionally pings `CUSTOM_PING_ADDRESS` through the tunnel.
  Catches dead tunnels best, but if the target or a firewall drops ICMP the script
  will reconnect on every run.

## Scheduling with Task Scheduler

1. **Control Panel > Task Scheduler > Create > Scheduled Task > User-defined script**
2. **General**: user `root`, give it a name such as `Reconnect VPN`.
3. **Schedule**: run every 5 minutes (or as often as you like; overlapping runs are
   safe because the script uses a lock).
4. **Task Settings**: set the command to `/volume1/scripts/reconnect-vpn.sh`.
   Optionally enable **Send run details by email**.

By default a successful reconnect exits with code 1, which DSM treats as an
abnormal termination. If you enable **Send run details by email > Send run details
only when the script terminates abnormally**, you get a message whenever the VPN
had to be reconnected, and also when the reconnect failed (exit code 2) or the
script is misconfigured (exit code 3). Set `SUCCESS_EXIT_CODE=0` if you do not want
that notification.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | The connection is fine, or another instance is already running. |
| `1` | The connection was down and was reconnected (configurable with `SUCCESS_EXIT_CODE`). |
| `2` | The reconnect failed or timed out. |
| `3` | Configuration or environment error (not root, profile not found, reconnect disabled in DSM, invalid setting, and so on). |

Every log line is timestamped and prefixed with a level (`I`, `W`, `E`), so output
captured by Task Scheduler or redirected to a file is easy to read.

## Acting on the result

Earlier versions had hook scripts for the no-reconnect, pre-reconnect, post-success
and post-failure cases. They were removed to keep a root-run script free of
arbitrary command execution. If you need to run something afterwards, use a small
wrapper and the exit code:

```bash
#!/usr/bin/env bash
/volume1/scripts/reconnect-vpn.sh
case $? in
	1) /volume1/scripts/after-reconnect.sh ;;   # reconnected
	2) /volume1/scripts/after-failure.sh ;;     # failed
esac
```

Schedule the wrapper instead of the script, and apply the same ownership and
permissions to every file in the chain.

## How it works

1. Verifies it runs as root, that `synovpnc` exists and the DSM VPN configuration is
   readable, and that settings are valid.
2. Takes an `flock` on `/tmp/reconnect-vpn.lock`; if another run holds it, it exits
   quietly with code 0.
3. Reads the profiles from `/usr/syno/etc/synovpnclient/{l2tp,openvpn,pptp}/*client.conf`
   and selects the one whose name matches `VPN_PROFILE_NAME` exactly.
4. Checks the connection with the configured method. If healthy, exits 0.
5. Otherwise runs `synovpnc kill_client`, waits `KILL_WAIT_SEC`, writes the
   `vpnc_connecting` marker and runs `synovpnc connect`, then polls every 5 seconds
   (up to `CONNECT_WAIT_SEC`) until the tunnel is up.
6. On failure or timeout, removes the stale `vpnc_connecting` marker and exits 2.

## Changes from upstream

- Profile lookup is an exact name match, not a regex, so names containing spaces,
  hyphens, dots or similar characters work and `vpn` no longer matches `vpn2`.
- Profile names are no longer truncated at the first non-word character.
- Fixed the `[l|o|p]` character class and the unanchored protocol detection.
- Tunnel interface and gateway detection use exact address matching, and fail with a
  clear message instead of triggering a needless reconnect.
- `flock` locking prevents overlapping runs from killing each other's connection.
- Root and readable-config checks give clear errors instead of "0 VPN profiles".
- Connect and disconnect are polled instead of using fixed `sleep` guesses.
- `TIMEOUT_SEC` covers the whole reconnect, and a stale `vpnc_connecting` file is
  cleaned up after a failure.
- Pings send 3 packets, so one dropped packet does not cause a reconnect.
- Settings can be passed as environment variables and are validated.
- Log lines are timestamped.
- The `example.com` placeholder ping target was removed; `custom_ping` now requires
  an explicit address.
- **Removed:** `NO_RECONNECT_SCRIPT`, `PRE_RECONNECT_SCRIPT`, `POST_SUCCESS_SCRIPT` and
  `POST_FAILURE_SCRIPT`. See [Acting on the result](#acting-on-the-result).
- **Added:** `KILL_WAIT_SEC`, `CONNECT_WAIT_SEC` and `SUCCESS_EXIT_CODE`.

### Migrating from upstream

- Replace any hook variables with the wrapper approach above.
- If you use `custom_ping`, set `CUSTOM_PING_ADDRESS` explicitly.
- Set `VPN_PROFILE_NAME` to the exact profile name if you have multiple profiles.

## Limitations

- The script relies on undocumented DSM internals (`synovpnc`, the
  `vpnc_connecting` marker and the layout of the VPN client configuration). A DSM
  update can break it, so re-test after major updates.
- IPv4 only for the ping-based checks.
- If DSM's own reconnect option is also active, both can act on the same outage.
  The script requires that option to be enabled, so test how they interact on your
  setup.
- Ping-based checks depend on ICMP being allowed through the tunnel.

## Credits and license

Based on `reconnect-vpn.sh` from
[`ianharrier/synology-scripts`](https://github.com/ianharrier/synology-scripts) by
Ian Harrier, Deac Karns, Michael Lake, mchalandon and Branden R. Williams, which
was itself derived from a
[Synology community post](https://community.synology.com/enu/forum/17/post/53791).

Released under the MIT License. Keep the original `LICENSE` file, including the
upstream copyright notice, in your fork and add your own copyright line to it.
