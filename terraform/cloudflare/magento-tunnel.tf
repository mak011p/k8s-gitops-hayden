# ==============================================
# Magento VPS Cloudflare Tunnel
# Routes web traffic to the Magento origin server (103.21.130.236)
# via Cloudflare Tunnel, eliminating direct origin IP exposure.
#
# Replaces manual A records for:
#   - haydenagencies.com.au
#   - www.haydenagencies.com.au
#   - staging.haydenagencies.com.au
#   - cdn.haydenagencies.com.au
#   - dev.haydenagencies.com.au
# ==============================================

resource "random_bytes" "magento_tunnel_secret" {
  length = 32
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "magento_vps" {
  account_id = data.cloudflare_zone.haydenagencies.account_id
  name       = "magento-vps"
  secret     = random_bytes.magento_tunnel_secret.base64
  config_src = "cloudflare"
}

# ==============================================
# Tunnel Ingress Configuration (remotely managed)
# cloudflared on the VPS pulls this config automatically.
# ==============================================

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "magento_vps" {
  account_id = data.cloudflare_zone.haydenagencies.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.magento_vps.id

  config {
    ingress_rule {
      hostname = var.domain
      service  = "https://localhost:443"
      origin_request {
        no_tls_verify = true
      }
    }
    ingress_rule {
      hostname = "www.${var.domain}"
      service  = "https://localhost:443"
      origin_request {
        no_tls_verify = true
      }
    }
    ingress_rule {
      hostname = "staging.${var.domain}"
      service  = "https://localhost:443"
      origin_request {
        no_tls_verify = true
      }
    }
    ingress_rule {
      hostname = "cdn.${var.domain}"
      service  = "https://localhost:443"
      origin_request {
        no_tls_verify = true
      }
    }
    ingress_rule {
      hostname = "dev.${var.domain}"
      service  = "https://localhost:443"
      origin_request {
        no_tls_verify = true
      }
    }
    # Catch-all
    ingress_rule {
      service = "http_status:404"
    }
  }
}

# ==============================================
# DNS Records - Magento VPS via Tunnel
# These replace the manual A records pointing to 103.21.130.236.
#
# CUTOVER PLAN:
# 1. Ensure cloudflared is running and connected on the VPS
# 2. terraform apply — creates CNAME records
# 3. Manually delete old A records via API (they aren't in TF state)
# 4. Verify all sites load correctly
#
# The old A records (not managed by TF) must be deleted manually:
#   Record IDs (from Cloudflare API):
#   - haydenagencies.com.au       (A) id=508c6507ed22a2fae7b65a86f3a294f9
#   - staging.haydenagencies.com.au (A) id=3de35f23c0452ea44b2916bf0a1b7560
#   - cdn.haydenagencies.com.au   (A) id=5be22cc1b0ca1fb25c846466133a814a
#   - dev.haydenagencies.com.au   (A) id=00d7ce036db3e8ce0d743d6ddb41d4cc
#   - www.haydenagencies.com.au   (CNAME) id=c4c4a1617c3e4f3439811e7a99964431
# ==============================================

resource "cloudflare_record" "magento_root" {
  zone_id = local.haydenagencies_zone_id
  name    = "@"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.magento_vps.cname}"
  type    = "CNAME"
  proxied = true
  ttl     = 1
  comment = "Magento VPS via Cloudflare Tunnel"
}

resource "cloudflare_record" "magento_www" {
  zone_id = local.haydenagencies_zone_id
  name    = "www"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.magento_vps.cname}"
  type    = "CNAME"
  proxied = true
  ttl     = 1
  comment = "Magento VPS www via Cloudflare Tunnel"
}

resource "cloudflare_record" "magento_staging" {
  zone_id = local.haydenagencies_zone_id
  name    = "staging"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.magento_vps.cname}"
  type    = "CNAME"
  proxied = true
  ttl     = 1
  comment = "Magento staging via Cloudflare Tunnel"
}

resource "cloudflare_record" "magento_cdn" {
  zone_id = local.haydenagencies_zone_id
  name    = "cdn"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.magento_vps.cname}"
  type    = "CNAME"
  proxied = true
  ttl     = 1
  comment = "Magento CDN via Cloudflare Tunnel"
}

resource "cloudflare_record" "magento_dev" {
  zone_id = local.haydenagencies_zone_id
  name    = "dev"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.magento_vps.cname}"
  type    = "CNAME"
  proxied = true
  ttl     = 1
  comment = "Magento dev via Cloudflare Tunnel"
}

# ==============================================
# Outputs - needed for cloudflared install on VPS
# ==============================================

output "magento_tunnel_id" {
  value       = cloudflare_zero_trust_tunnel_cloudflared.magento_vps.id
  description = "Tunnel ID for cloudflared config on the Magento VPS"
}

output "magento_tunnel_token" {
  value       = cloudflare_zero_trust_tunnel_cloudflared.magento_vps.tunnel_token
  description = "Tunnel token for cloudflared service install (contains credentials)"
  sensitive   = true
}
