import * as pulumi from "@pulumi/pulumi";
import * as cloudflare from "@pulumi/cloudflare";

const config = new pulumi.Config();
const accountId = config.require("accountId");
const zoneId = config.require("zoneId");
const zoneName = config.get("zoneName") ?? "mez.run";
const enablePublicDns = config.getBoolean("enablePublicDns") ?? false;
const enableStartSite = config.getBoolean("enableStartSite") ?? true;

const tunnelSecret = config.getSecret("tunnelSecret");

// The tunnel is deliberately opt-in until the public endpoint has been
// reviewed. The tunnel secret never appears in a plain Pulumi output.
const dohTunnel = enablePublicDns && tunnelSecret
  ? new cloudflare.ZeroTrustTunnelCloudflared("dohTunnel", {
      accountId,
      name: "mez-doh",
      configSrc: "cloudflare",
      tunnelSecret,
    })
  : undefined;

if (enablePublicDns && !dohTunnel) {
  throw new pulumi.RunError(
    "enablePublicDns=true requires the Pulumi secret tunnelSecret",
  );
}

if (dohTunnel && enablePublicDns) {
  new cloudflare.ZeroTrustTunnelCloudflaredConfig("dohTunnelConfig", {
    accountId,
    tunnelId: dohTunnel.id,
    config: {
      ingresses: [
        {
          hostname: "dns.mez.run",
          service: "http://adguard:80",
          originRequest: {
            connectTimeout: 10,
            keepAliveConnections: 100,
            keepAliveTimeout: 90,
          },
        },
        { service: "http_status:404" },
      ],
    },
  });

  new cloudflare.Record("dohHostname", {
    zoneId,
    name: "dns",
    type: "CNAME",
    content: pulumi.interpolate`${dohTunnel.id}.cfargotunnel.com`,
    proxied: true,
    ttl: 1,
  });

  // DoH supports GET as well as POST. Explicitly bypass cache for both forms.
  new cloudflare.Ruleset("dohCacheBypass", {
    zoneId,
    name: "DoH cache bypass",
    description: "Never cache DNS-over-HTTPS responses",
    kind: "zone",
    phase: "http_request_cache_settings",
    rules: [
      {
        action: "set_cache_settings",
        actionParameters: { cache: false },
        expression: `(http.host eq "dns.${zoneName}" and starts_with(http.request.uri.path, "/dns-query"))`,
        description: "Bypass cache for DoH",
        enabled: true,
      },
    ],
  });

  // Only the DoH path is useful on this hostname. Admin UI and every other
  // path are blocked before reaching the tunnel.
  new cloudflare.Ruleset("dohPathGuard", {
    zoneId,
    name: "DoH path guard",
    description: "Allow only the DNS-over-HTTPS endpoint",
    kind: "zone",
    phase: "http_request_firewall_custom",
    rules: [
      {
        action: "block",
        expression: `(http.host eq "dns.${zoneName}" and not starts_with(http.request.uri.path, "/dns-query"))`,
        description: "Block non-DoH paths",
        enabled: true,
      },
    ],
  });
}

if (enableStartSite) {
  const site = new cloudflare.PagesProject("startSite", {
    accountId,
    name: "homelab-start",
    productionBranch: "main",
  });

  new cloudflare.PagesDomain("startSiteDomain", {
    accountId,
    projectName: site.name,
    name: "start.mez.run",
  });

  new cloudflare.Record("startSiteDns", {
    zoneId,
    name: "start",
    type: "CNAME",
    content: site.subdomain,
    proxied: true,
    ttl: 1,
  });
}

export const publicDnsEnabled = enablePublicDns;
export const dohTunnelId = dohTunnel?.id;
export const dohHostname = enablePublicDns ? "dns.mez.run" : undefined;
export const setupHostname = enableStartSite ? "start.mez.run" : undefined;
