# ==============================================
# Auntalma VPS Cloudflare Tunnel
# Routes web traffic to the auntalma/dropdrape origin server (103.21.131.100)
# via Cloudflare Tunnel, eliminating direct origin IP exposure.
#
# Serves:
#   - auntalma.com.au
#   - www.auntalma.com.au
#   - dropdrape.com.au
#   - www.dropdrape.com.au
# ==============================================

resource "random_bytes" "auntalma_tunnel_secret" {
  length = 32
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "auntalma_vps" {
  account_id = data.cloudflare_zone.haydenagencies.account_id
  name       = "auntalma-vps"
  secret     = random_bytes.auntalma_tunnel_secret.base64
  config_src = "cloudflare"
}

# ==============================================
# Tunnel Ingress Configuration (remotely managed)
# cloudflared on the VPS pulls this config automatically.
# ==============================================

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "auntalma_vps" {
  account_id = data.cloudflare_zone.haydenagencies.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.auntalma_vps.id

  config {
    ingress_rule {
      hostname = "auntalma.com.au"
      service  = "http://103.21.131.100:80"
    }
    ingress_rule {
      hostname = "www.auntalma.com.au"
      service  = "http://103.21.131.100:80"
    }
    ingress_rule {
      hostname = "dropdrape.com.au"
      service  = "http://103.21.131.100:80"
    }
    ingress_rule {
      hostname = "www.dropdrape.com.au"
      service  = "http://103.21.131.100:80"
    }
    # Catch-all
    ingress_rule {
      service = "http_status:404"
    }
  }
}

# ==============================================
# Outputs - needed for cloudflared install on VPS
# ==============================================

output "auntalma_tunnel_id" {
  value       = cloudflare_zero_trust_tunnel_cloudflared.auntalma_vps.id
  description = "Tunnel ID for cloudflared config on the auntalma VPS"
}

output "auntalma_tunnel_token" {
  value       = cloudflare_zero_trust_tunnel_cloudflared.auntalma_vps.tunnel_token
  description = "Tunnel token for cloudflared service install (contains credentials)"
  sensitive   = true
}
