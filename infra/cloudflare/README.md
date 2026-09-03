# Cloudflare infrastructure

This Pulumi project owns the Cloudflare side of the optional public DNS
deployment and the `start.mez.run` Pages project. It does not deploy
`cloudflared` to the homelab hosts or copy secrets into Docker `.env` files.

The public endpoint is disabled by default. Configure a Pulumi backend, install
dependencies, and set the secret before enabling it:

```bash
npm install
pulumi stack init dev
pulumi config set accountId <account-id>
pulumi config set zoneId <zone-id>
pulumi config set zoneName mez.run
pulumi config set --secret tunnelSecret <base64-32-byte-secret>
pulumi config set enablePublicDns true
pulumi preview
pulumi up
```

The Cloudflare API token needs account tunnel-edit, zone DNS-edit, and zone
ruleset-edit permissions. `start.mez.run` is created as a Pages custom domain;
deploy the contents of `sites/start` from CI or Wrangler after the project
exists.

The tunnel route intentionally has a catch-all 404 rule, cache bypass for
`/dns-query*`, and a firewall rule blocking non-DoH paths. Rate limiting should
be added once the Cloudflare plan and desired query budget are known.
