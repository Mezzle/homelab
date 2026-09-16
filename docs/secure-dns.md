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
enabled by default on current tailnets. Tailscale Services require Tailscale
v1.86.0 or newer, an Owner/Admin/Network admin to define the service, and
tag-based identities on every service host. The current host bootstrap uses a
user identity, so do not run the commands below until you have planned the
tagged service-host reauthentication. A tagged device cannot also retain a
user identity.

## 1. Allow reverse-proxied DoH in AdGuard

On both hosts, stop AdGuard and set this current AdGuard Home field in
`AdGuardHome.yaml`:

```yaml
http:
  doh:
    insecure_enabled: true
```

Keep the other existing `http` and `tls` fields unchanged, then start AdGuard.
The client connection uses HTTPS. This setting permits HTTP only on the local
hop between Tailscale Serve and AdGuard. On a native Pi installation, bind the
AdGuard HTTP listener to loopback. On `charm`, the Compose mapping already binds
the backend to `127.0.0.1:3080`. Do not enable the optional public Cloudflare
connector while testing this private path.

## 2. Advertise the service from charm

The monitoring Compose stack publishes AdGuard as `127.0.0.1:3080` on `charm`.
The loopback binding is not reachable from the LAN or Internet.

Run on `charm`:

```bash
sudo tailscale set --accept-dns=false
sudo tailscale serve --service=svc:dns --https=443 127.0.0.1:3080
```

The command requires `charm` to be authenticated with a tag such as
`tag:dns-host`, not a user identity. Define `svc:dns`, add the service-host
tag, and approve the advertisement in the Tailscale admin console first.

## 3. Advertise the same service from the Pi

Run the same service on the Pi, changing the backend port if its AdGuard HTTP
listener is not on port 80:

```bash
sudo tailscale set --accept-dns=false
sudo tailscale serve --service=svc:dns --https=443 127.0.0.1:80
```

`accept-dns=false` belongs on the DNS servers only. Normal clients should keep
accepting the tailnet DNS configuration.

The Pi also needs a tagged identity and Tailscale v1.86.0 or newer. Approve it
as another host for `svc:dns`.

## 4. Limit access with Tailscale policy

Grant access only to your tailnet members. The service itself should be tagged
and its hosts should be auto-approved or approved manually:

```json
{
  "tagOwners": {
    "tag:dns-host": ["autogroup:admin"]
  },
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
