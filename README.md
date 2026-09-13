# Helper scripts

Reusable server scripts. Deployment guides live in
[Usefull_Resources/VPN](https://github.com/phungvanquy/Usefull_Resources/tree/main/VPN).

| Script | Purpose | Installed command in the examples |
| --- | --- | --- |
| [UDP manager](relays/port-forwarding/udp-manager.sh) | UDP port forwarding for WireGuard, AmneziaWG, and other UDP services | `relay-udp-manager` |
| [TCP/UDP manager](relays/port-forwarding/tcp-udp-manager.sh) | Applies every mapping to both TCP and UDP | `relay-tcp-udp-manager` |
| [IPIP manager](ipip_tunnels_manager.sh) | IPIP tunnels with systemd persistence | `ipip-manager` |

## Quick relay setup

Run on the relay server. These commands need Bash, curl, sudo/root, and a Linux
host with iptables support. The forwarding managers install persistence tooling
through a supported package manager if needed and enable IPv4 forwarding. This
initialization runs even for `help` and `list`.

First prepare `port.conf` for UDP or `tcp-udp.conf` for TCP/UDP in your current
working directory, with one mapping per line:

```text
# Format: NAME|RELAY_PORT|DST_IP|DST_PORT
vpn-origin|51820|198.51.100.20|51820
vpn-backup|51822|198.51.100.20|51820
```

Edit the names, origin addresses, and ports for your servers. For a tunnel, use
the origin's tunnel address. Either manager accepts either filename or another
path; the manager determines the protocols.

**Import replaces the selected manager's existing mappings.** Include every
mapping you want to keep. For an existing installation, export a backup first
using the commands below.

### WireGuard / AmneziaWG (UDP)

```bash
curl -fL https://raw.githubusercontent.com/phungvanquy/helper-scripts/main/relays/port-forwarding/udp-manager.sh -o udp-manager.sh &&
sudo install -m 0755 udp-manager.sh /usr/local/sbin/relay-udp-manager &&
sudo /usr/local/sbin/relay-udp-manager import ./port.conf
```

### Both TCP and UDP

This manager creates rules for both protocols for every mapping.

```bash
curl -fL https://raw.githubusercontent.com/phungvanquy/helper-scripts/main/relays/port-forwarding/tcp-udp-manager.sh -o tcp-udp-manager.sh &&
sudo install -m 0755 tcp-udp-manager.sh /usr/local/sbin/relay-tcp-udp-manager &&
sudo /usr/local/sbin/relay-tcp-udp-manager import ./tcp-udp.conf
```

The commands above download the current `main` version. The
[deployment guide](https://github.com/phungvanquy/Usefull_Resources/blob/main/VPN/relays/port-forwarding/README.md)
provides downloads pinned to a checked revision.

The managers configure NAT rules. If the server's `FORWARD` chain or cloud
firewall restricts traffic, also allow the service traffic and replies. Configure
VPN clients with the relay's public address and relay port.

## Manage existing mappings

Export a backup, edit your configuration, and import it again:

```bash
sudo /usr/local/sbin/relay-udp-manager export /root/wg-forwards-backup.conf
nano ./port.conf
sudo /usr/local/sbin/relay-udp-manager import ./port.conf
sudo /usr/local/sbin/relay-udp-manager list
```

For both protocols, substitute `/usr/local/sbin/relay-tcp-udp-manager` and your
`tcp-udp.conf` file. Remove a line and import again to remove a mapping. UDP state lives
in `/etc/wg-forward/forwards.conf`; TCP/UDP state lives in
`/etc/port-forward/forwards.conf`. Installing the script does not replace these
files. `import` replaces the selected manager's mappings; export before importing
if you need to keep the current configuration.

Verify mappings and traffic on the relay:

```bash
sudo iptables -t nat -L PREROUTING -n -v --line-numbers
sudo iptables -t nat -L POSTROUTING -n -v --line-numbers
sudo iptables -L FORWARD -n -v --line-numbers
```

## IPIP tunnels

Install on both endpoints (requires systemd and kernel IPIP support):

```bash
curl -fL https://raw.githubusercontent.com/phungvanquy/helper-scripts/main/ipip_tunnels_manager.sh -o ipip-manager.sh &&
sudo bash ipip-manager.sh setup
```

Then follow the
[IPIP guide](https://github.com/phungvanquy/Usefull_Resources/blob/main/VPN/relays/tunnels/ipip/README.md)
to add both endpoints, allow IP protocol 4, and verify peer connectivity before
forwarding traffic through the tunnel.

## Maintenance

The forwarding scripts were copied without behavior changes from
Usefull_Resources commit `41dbdcb5a6d684b6a83472e302389ab979399980`. When updating them,
also update the matching copies and pinned download revision in its VPN guide.
