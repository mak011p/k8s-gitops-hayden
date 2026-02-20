# ==============================================
# haydenagencies.com.au - Primary Business Domain
# Zone ID: 012445366374fc5a3f865cc809e459e0
# ==============================================

locals {
  haydenagencies_zone_id = data.cloudflare_zone.haydenagencies.id
  odoo_webhook_hostname  = "odoo-webhook.${var.domain}"
  tunnel_id              = "116ee772-e4a7-45e3-a401-522d76f1138c"
}

# ==============================================
# DNS Records - Cloudflare Tunnel
# ==============================================

resource "cloudflare_record" "tunnel_ingress" {
  zone_id = local.haydenagencies_zone_id
  name    = "ingress"
  content = "${local.tunnel_id}.cfargotunnel.com"
  type    = "CNAME"
  proxied = true
  ttl     = 1 # Auto when proxied
  comment = "Cloudflare Tunnel ingress for cluster services"
}

# ==============================================
# IP Lists (WAF)
# ==============================================

resource "cloudflare_list" "whitelisted_ips" {
  account_id  = data.cloudflare_zone.haydenagencies.account_id
  name        = "whitelisted_ips"
  description = "IPs that bypass rate limiting and WAF challenges"
  kind        = "ip"

  item {
    value {
      ip = "119.18.0.248"
    }
    comment = "Rival - Justin"
  }

  item {
    value {
      ip = "144.6.92.244"
    }
    comment = "Hayden"
  }

  item {
    value {
      ip = "121.200.5.240"
    }
    comment = "Thomas home IP"
  }
}

# ==============================================
# Access Applications and Policies
# ==============================================

resource "cloudflare_access_application" "kubernetes_cluster_access" {
  zone_id                    = local.haydenagencies_zone_id
  app_launcher_visible       = true
  auto_redirect_to_identity  = false
  domain                     = var.kubernetes_cluster_api
  enable_binding_cookie      = false
  http_only_cookie_attribute = false
  name                       = "Kubernetes Cluster Access"
  session_duration           = var.session_duration
  skip_interstitial          = true
  type                       = "self_hosted"
  cors_headers {
    allow_all_methods = true
    allow_all_origins = true
    allowed_methods   = ["CONNECT", "TRACE", "GET", "HEAD", "POST", "PATCH", "PUT", "OPTIONS", "DELETE"]
  }
}

resource "cloudflare_access_policy" "kubernetes_cluster_access_allow_thomas" {
  zone_id        = local.haydenagencies_zone_id
  application_id = cloudflare_access_application.kubernetes_cluster_access.id
  name           = "Allow thomas@haydenagencies.com.au"
  precedence     = 1
  decision       = "allow"

  include {
    email = ["thomas@haydenagencies.com.au"]
  }
}

# Service token for Odoo webhook (account-level, can be used across zones)
resource "cloudflare_access_service_token" "odoo_webhook" {
  account_id = data.cloudflare_zone.haydenagencies.account_id
  name       = "odoo-webhook"
}

resource "cloudflare_access_application" "odoo_webhook" {
  zone_id                    = local.haydenagencies_zone_id
  app_launcher_visible       = false
  auto_redirect_to_identity  = false
  domain                     = local.odoo_webhook_hostname
  enable_binding_cookie      = false
  http_only_cookie_attribute = true
  name                       = "Odoo Webhook"
  session_duration           = var.session_duration
  skip_interstitial          = true
  type                       = "self_hosted"
}

resource "cloudflare_access_policy" "odoo_webhook" {
  zone_id        = local.haydenagencies_zone_id
  application_id = cloudflare_access_application.odoo_webhook.id
  decision       = "non_identity"
  name           = "Magento webhook allowlist"
  precedence     = 1

  include {
    service_token = [cloudflare_access_service_token.odoo_webhook.id]
  }

  require {
    ip = var.odoo_webhook_allowed_ips
  }
}

# ==============================================
# WAF - Rulesets (Modern - replaces legacy filters/firewall_rules)
# ==============================================

resource "cloudflare_ruleset" "haydenagencies_rate_limit" {
  zone_id = local.haydenagencies_zone_id
  kind    = "zone"
  name    = "default"
  phase   = "http_ratelimit"

  rules {
    action      = "block"
    description = "Rate Limit"
    enabled     = true
    expression  = "(not http.request.uri.path contains \"media\" and not http.request.uri.path contains \"static\" and not http.request.uri.path contains \"haydenadmin\")"
    ratelimit {
      characteristics     = ["ip.src", "cf.colo.id"]
      mitigation_timeout  = var.haydenagencies_rate_limit_period
      period              = var.haydenagencies_rate_limit_period
      requests_per_period = var.haydenagencies_rate_limit_requests
    }
  }
}

# NOTE: Cache settings ruleset requires additional permissions
# resource "cloudflare_ruleset" "haydenagencies_cache_settings" {
#   zone_id = local.haydenagencies_zone_id
#   kind    = "zone"
#   name    = "default"
#   phase   = "http_request_cache_settings"
# }

resource "cloudflare_ruleset" "haydenagencies_firewall_custom" {
  zone_id = local.haydenagencies_zone_id
  kind    = "zone"
  name    = "default"
  phase   = "http_request_firewall_custom"

  rules {
    action = "skip"
    action_parameters {
      phases  = ["http_ratelimit", "http_request_firewall_managed", "http_request_sbfm"]
      ruleset = "current"
    }
    description = "Whitelisted IPs"
    enabled     = true
    expression  = "(ip.src in $whitelisted_ips)"
    logging {
      enabled = true
    }
  }

  rules {
    action      = "managed_challenge"
    description = "Challenge non-whitelisted countries"
    enabled     = true
    expression  = "(not ip.geoip.country in {\"${join("\" \"", var.haydenagencies_whitelisted_countries)}\"})"
  }
}

# ==============================================
# Zone Settings (matching current Cloudflare config)
# ==============================================

resource "cloudflare_zone_settings_override" "haydenagencies" {
  zone_id = local.haydenagencies_zone_id
  settings {
    always_online            = "off"
    always_use_https         = "off"
    automatic_https_rewrites = "on"
    brotli                   = "on"
    browser_cache_ttl        = 14400
    browser_check            = "on"
    cache_level              = "aggressive"
    challenge_ttl            = 1800
    cname_flattening         = "flatten_at_root"
    development_mode         = "off"
    early_hints              = "off"
    email_obfuscation        = "on"
    hotlink_protection       = "off"
    http3                    = "off"
    ip_geolocation           = "on"
    ipv6                     = "on"
    max_upload               = 100
    min_tls_version          = "1.0"
    opportunistic_encryption = "on"
    opportunistic_onion      = "on"
    privacy_pass             = "on"
    pseudo_ipv4              = "off"
    rocket_loader            = "off"
    security_header {
      enabled            = false
      include_subdomains = false
      max_age            = 0
      nosniff            = false
      preload            = false
    }
    security_level      = "medium"
    server_side_exclude = "on"
    ssl                 = "full"
    tls_1_3             = "on"
    tls_client_auth     = "off"
    websockets          = "on"
    zero_rtt            = "off"
  }
}

# ==============================================
# DNS Records - Email Authentication
# ==============================================
# IMPORTANT: The existing manual SPF and MX records in Cloudflare must be
# imported into Terraform state OR deleted before applying, to avoid duplicates.
#
# Import commands (run once before terraform apply):
#   terraform import cloudflare_record.haydenagencies_spf <zone_id>/<record_id>
#   terraform import cloudflare_record.haydenagencies_mx_primary <zone_id>/<record_id>
#   ... (repeat for each MX record)
#
# To find record IDs:
#   curl -s -H "Authorization: Bearer $CF_API_TOKEN" \
#     "https://api.cloudflare.com/client/v4/zones/012445366374fc5a3f865cc809e459e0/dns_records?type=TXT&name=haydenagencies.com.au" | jq '.result[] | {id, content}'
#   curl -s -H "Authorization: Bearer $CF_API_TOKEN" \
#     "https://api.cloudflare.com/client/v4/zones/012445366374fc5a3f865cc809e459e0/dns_records?type=MX" | jq '.result[] | {id, content, priority}'
# ==============================================

# Google site verification (existing)
resource "cloudflare_record" "haydenagencies_google_verify_1" {
  zone_id = local.haydenagencies_zone_id
  name    = "@"
  content = "google-site-verification=em-7Bk9uutkzFwrufBgu_9cLjpa7WFQ_VaVOQ8-FpXo"
  type    = "TXT"
  ttl     = 3600
  comment = "Google site verification"
}

resource "cloudflare_record" "haydenagencies_google_verify_2" {
  zone_id = local.haydenagencies_zone_id
  name    = "@"
  content = "google-site-verification=lB8iUqgQdshovh_76XdHdWB6XhGmQv1eAi1y_RZ0Rjw"
  type    = "TXT"
  ttl     = 3600
  comment = "Google site verification (secondary)"
}

# MX Records - Google Workspace
resource "cloudflare_record" "haydenagencies_mx_primary" {
  zone_id  = local.haydenagencies_zone_id
  name     = "@"
  content  = "aspmx.l.google.com"
  type     = "MX"
  priority = 10
  ttl      = 3600
  comment  = "Google Workspace primary MX"
}

resource "cloudflare_record" "haydenagencies_mx_alt1" {
  zone_id  = local.haydenagencies_zone_id
  name     = "@"
  content  = "alt1.aspmx.l.google.com"
  type     = "MX"
  priority = 20
  ttl      = 3600
  comment  = "Google Workspace alt1 MX"
}

resource "cloudflare_record" "haydenagencies_mx_alt2" {
  zone_id  = local.haydenagencies_zone_id
  name     = "@"
  content  = "alt2.aspmx.l.google.com"
  type     = "MX"
  priority = 20
  ttl      = 3600
  comment  = "Google Workspace alt2 MX"
}

resource "cloudflare_record" "haydenagencies_mx_alt3" {
  zone_id  = local.haydenagencies_zone_id
  name     = "@"
  content  = "alt3.aspmx.l.google.com"
  type     = "MX"
  priority = 30
  ttl      = 3600
  comment  = "Google Workspace alt3 MX"
}

resource "cloudflare_record" "haydenagencies_mx_alt4" {
  zone_id  = local.haydenagencies_zone_id
  name     = "@"
  content  = "alt4.aspmx.l.google.com"
  type     = "MX"
  priority = 30
  ttl      = 3600
  comment  = "Google Workspace alt4 MX"
}

# SPF Record
# Authorizes: SendGrid dedicated IP, SendGrid shared pool, Google Workspace, Migadu
resource "cloudflare_record" "haydenagencies_spf" {
  zone_id = local.haydenagencies_zone_id
  name    = "@"
  content = "v=spf1 ip4:168.245.39.222 include:sendgrid.net include:_spf.google.com include:spf.migadu.com ~all"
  type    = "TXT"
  ttl     = 3600
  comment = "SPF - SendGrid (168.245.39.222), Google Workspace, Migadu"
}

# DMARC Record
# Start with p=none (monitoring) to collect reports, then tighten to quarantine/reject
resource "cloudflare_record" "haydenagencies_dmarc" {
  zone_id = local.haydenagencies_zone_id
  name    = "_dmarc"
  content = "v=DMARC1; p=none; rua=mailto:dmarc-reports@haydenagencies.com.au; fo=1"
  type    = "TXT"
  ttl     = 3600
  comment = "DMARC policy - monitoring mode (tighten to quarantine once aligned)"
}

# SendGrid Domain Authentication (DKIM + Return Path + Link Branding)
resource "cloudflare_record" "haydenagencies_sendgrid_dkim_s1" {
  zone_id = local.haydenagencies_zone_id
  name    = "s1._domainkey"
  content = "s1.domainkey.u7591732.wl233.sendgrid.net"
  type    = "CNAME"
  ttl     = 3600
  proxied = false
  comment = "SendGrid DKIM s1"
}

resource "cloudflare_record" "haydenagencies_sendgrid_dkim_s2" {
  zone_id = local.haydenagencies_zone_id
  name    = "s2._domainkey"
  content = "s2.domainkey.u7591732.wl233.sendgrid.net"
  type    = "CNAME"
  ttl     = 3600
  proxied = false
  comment = "SendGrid DKIM s2"
}

resource "cloudflare_record" "haydenagencies_sendgrid_return_path" {
  zone_id = local.haydenagencies_zone_id
  name    = "em8375"
  content = "u7591732.wl233.sendgrid.net"
  type    = "CNAME"
  ttl     = 3600
  proxied = false
  comment = "SendGrid return path (envelope-from alignment)"
}

# SendGrid Link Branding
resource "cloudflare_record" "haydenagencies_sendgrid_link_url" {
  zone_id = local.haydenagencies_zone_id
  name    = "url8530"
  content = "sendgrid.net"
  type    = "CNAME"
  ttl     = 3600
  proxied = false
  comment = "SendGrid link branding (tracking URLs)"
}

resource "cloudflare_record" "haydenagencies_sendgrid_link_id" {
  zone_id = local.haydenagencies_zone_id
  name    = "7591732"
  content = "sendgrid.net"
  type    = "CNAME"
  ttl     = 3600
  proxied = false
  comment = "SendGrid link branding (domain verification)"
}

# SendGrid Reverse DNS (PTR) - proves dedicated IP belongs to our domain
resource "cloudflare_record" "haydenagencies_sendgrid_rdns" {
  zone_id = local.haydenagencies_zone_id
  name    = "o2.ptr4780"
  content = "168.245.39.222"
  type    = "A"
  ttl     = 3600
  proxied = false
  comment = "SendGrid reverse DNS for dedicated IP 168.245.39.222"
}

# ==============================================

# NOTE: Argo Smart Routing cannot be managed via API token
# It requires Argo subscription and special billing-level access
# Manage via Cloudflare Dashboard instead
# ==============================================
# Argo Smart Routing
# ==============================================
# resource "cloudflare_argo" "haydenagencies" {
#   zone_id        = local.haydenagencies_zone_id
#   smart_routing  = "on"
#   tiered_caching = "on"
# }
