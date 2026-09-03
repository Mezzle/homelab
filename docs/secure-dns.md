# Private secure DNS with AdGuard Home and Tailscale

Start with a resolver available only inside the `corgi-justice` tailnet:

```text
Apple device or browser
        |
        | https://dns.corgi-justice.ts.net/dns-query
        v
Tailscale Service `svc:dns`
        |
        +---- Raspberry Pi ---- primary AdGuard
        |
        +---- charm ----------- backup AdGuard
```

`dns.corgi-justice.ts.net` is the stable name for `svc:dns`. It is reachable
only by authorised tailnet members. Both hosts can advertise the service, so
the name does not belong to either machine and Tailscale can route around a
failed host.

MagicDNS and HTTPS certificates must be enabled for the tailnet. They are
enabled by default on current tailnets.

## 1. Allow reverse-proxied DoH in AdGuard

On both hosts, stop AdGuard and set this field in `AdGuardHome.yaml`:

```yaml
tls:
  allow_unencrypted_doh: true
```

Keep the other existing `tls` fields unchanged, then start AdGuard. The client
connection uses HTTPS. This setting permits HTTP only on the local hop between
Tailscale Serve and AdGuard.

## 2. Advertise the service from charm

The monitoring Compose stack publishes AdGuard as `127.0.0.1:3080` on `charm`.
The loopback binding is not reachable from the LAN or Internet.

Run on `charm`:

```bash
sudo tailscale set --accept-dns=false
sudo tailscale serve --service=svc:dns --https=443 127.0.0.1:3080
```

Approve the service host in the Tailscale admin console if prompted.

## 3. Advertise the same service from the Pi

Run the same service on the Pi, changing the backend port if its AdGuard HTTP
listener is not on port 80:

```bash
sudo tailscale set --accept-dns=false
sudo tailscale serve --service=svc:dns --https=443 127.0.0.1:80
```

`accept-dns=false` belongs on the DNS servers only. Normal clients should keep
accepting the tailnet DNS configuration.

Approve the Pi as another host for `svc:dns`.

## 4. Limit access with Tailscale policy

Grant access only to your tailnet members:

```json
{
  "grants": [
    {
      "src": ["autogroup:member"],
      "dst": ["svc:dns"],
      "ip": ["tcp:443"]
    }
  ]
}
```

Use your own user or group instead of `autogroup:member` if guests also belong
to the tailnet. AdGuard's admin login is reachable at the same hostname, so
keep AdGuard authentication enabled.

## 5. Test DNS and failover

From a Tailscale-connected client:

```bash
curl --fail-with-body \
  'https://dns.corgi-justice.ts.net/dns-query?name=example.com&type=A' \
  -H 'accept: application/dns-json'

kdig +https @dns.corgi-justice.ts.net example.com A
kdig +https @dns.corgi-justice.ts.net example.com AAAA
```

Test local A and AAAA records, DHCP hostnames, the router's search domain, and
PTR records against each AdGuard instance individually. Then stop the service
on each host in turn and repeat the DoH tests:

```bash
sudo tailscale serve --service=svc:dns --https=443 off
```

Returning a local IPv6 address does not make it reachable away from home.
Remote clients also need a Tailscale subnet route for the local IPv6 prefix.

## 6. Install on Apple devices

[`sites/start/public/profiles/tailscale.mobileconfig`](../sites/start/public/profiles/tailscale.mobileconfig) uses:

```text
https://dns.corgi-justice.ts.net/dns-query
```

The device must have Tailscale connected. Open the profile in Safari, then
approve it in **System Settings > General > Device Management** on macOS or
**Settings > General > VPN & Device Management** on iPhone and iPad.

For browsers that accept a custom DoH template, use the same URL. A browser
configured with another provider can bypass the system profile.

## Optional public deployment later

The `cloudflared` connector remains under the opt-in `public-doh` Compose
profile. A normal deployment does not start it. Do not enable this profile or
create `dns.mez.run` while the resolver is meant to remain tailnet-only.
