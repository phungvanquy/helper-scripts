# Helper scripts

Reusable server scripts. Deployment guides live in
[Usefull_Resources/VPN](https://github.com/phungvanquy/Usefull_Resources/tree/main/VPN).

| Script | Purpose | Installed command in the examples |
| --- | --- | --- |
| [UDP manager](relays/port-forwarding/udp-manager.sh) | UDP port forwarding for WireGuard, AmneziaWG, and other UDP services | `vpn-relay-udp` |
| [TCP/UDP manager](relays/port-forwarding/tcp-udp-manager.sh) | Applies every mapping to both TCP and UDP | `vpn-relay-tcp-udp` |
| [IPIP manager](ipip_tunnels_manager.sh) | IPIP tunnels with systemd persistence | `ipip-manager` |

## Quick relay setup

Run on the relay server. These commands need Bash, curl, sudo/root, and a Linux
host with iptables support. The forwarding managers install persistence tooling
through a supported package manager if needed and enable IPv4 forwarding. This
initialization runs even for `help` and `list`.

Replace `198.51.100.20` with your origin's address and adjust the ports before
running. For a tunnel, use the origin's tunnel address. The arguments after `add`
are `NAME RELAY_PORT ORIGIN_IP ORIGIN_PORT`.

### WireGuard / AmneziaWG (UDP)

```bash
curl -fL https://raw.githubusercontent.com/phungvanquy/helper-scripts/main/relays/port-forwarding/udp-manager.sh -o udp-manager.sh &&
sudo install -m 0755 udp-manager.sh /usr/local/sbin/vpn-relay-udp &&
sudo /usr/local/sbin/vpn-relay-udp add vpn-origin 51820 198.51.100.20 51820
```

### Both TCP and UDP

This manager creates rules for both protocols for every mapping.

```bash
curl -fL https://raw.githubusercontent.com/phungvanquy/helper-scripts/main/relays/port-forwarding/tcp-udp-manager.sh -o tcp-udp-manager.sh &&
sudo install -m 0755 tcp-udp-manager.sh /usr/local/sbin/vpn-relay-tcp-udp &&
sudo /usr/local/sbin/vpn-relay-tcp-udp add proxy-origin 443 198.51.100.20 443
```

The commands above download the current `main` version. The
[deployment guide](https://github.com/phungvanquy/Usefull_Resources/blob/main/VPN/relays/port-forwarding/README.md)
provides downloads pinned to a checked revision.

The managers configure NAT rules. If the server's `FORWARD` chain or cloud
firewall restricts traffic, also allow the service traffic and replies. Configure
VPN clients with the relay's public address and relay port.

## Manage existing mappings

```bash
sudo /usr/local/sbin/vpn-relay-udp list
sudo /usr/local/sbin/vpn-relay-udp update vpn-origin 51820 198.51.100.20 51821
sudo /usr/local/sbin/vpn-relay-udp export /root/wg-forwards-backup.conf
sudo /usr/local/sbin/vpn-relay-udp remove vpn-origin
```

For both protocols, substitute `/usr/local/sbin/vpn-relay-tcp-udp`. UDP state lives
in `/etc/wg-forward/forwards.conf`; TCP/UDP state lives in
`/etc/port-forward/forwards.conf`. Installing the script does not replace these
files. `import` replaces the selected manager's mappings; export before importing
if you need to keep the current configuration. Repeating `add` with an existing
name is rejected; use `update` to change it.

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
