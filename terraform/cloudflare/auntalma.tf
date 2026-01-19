# ==============================================
# auntalma.com.au - Additional Domain
# Zone ID: 889a3d92f5045d3901cb850324d45506
# ==============================================

locals {
  auntalma_zone_id = data.cloudflare_zone.auntalma.id
}

# ==============================================
# Zone Settings (matching current Cloudflare config)
# ==============================================

resource "cloudflare_zone_settings_override" "auntalma" {
  zone_id = local.auntalma_zone_id
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
    http3                    = "on"
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
# DNS Records - Migadu Email
# ==============================================

# Domain verification
resource "cloudflare_record" "auntalma_migadu_verify" {
  zone_id = local.auntalma_zone_id
  name    = "@"
  content = "hosted-email-verify=w91tu70e"
  type    = "TXT"
  ttl     = 3000
  comment = "Migadu domain verification"
}

# MX Records
resource "cloudflare_record" "auntalma_mx_primary" {
  zone_id  = local.auntalma_zone_id
  name     = "@"
  content  = "aspmx1.migadu.com"
  type     = "MX"
  priority = 10
  ttl      = 3000
  comment  = "Migadu primary MX"
}

resource "cloudflare_record" "auntalma_mx_secondary" {
  zone_id  = local.auntalma_zone_id
  name     = "@"
  content  = "aspmx2.migadu.com"
  type     = "MX"
  priority = 20
  ttl      = 3000
  comment  = "Migadu secondary MX"
}

# SPF Record
resource "cloudflare_record" "auntalma_spf" {
  zone_id = local.auntalma_zone_id
  name    = "@"
  content = "v=spf1 include:spf.migadu.com -all"
  type    = "TXT"
  ttl     = 3000
  comment = "Migadu SPF"
}

# DKIM Records
resource "cloudflare_record" "auntalma_dkim_key1" {
  zone_id = local.auntalma_zone_id
  name    = "key1._domainkey"
  content = "key1.auntalma.com.au._domainkey.migadu.com"
  type    = "CNAME"
  ttl     = 3000
  proxied = false
  comment = "Migadu DKIM key1"
}

resource "cloudflare_record" "auntalma_dkim_key2" {
  zone_id = local.auntalma_zone_id
  name    = "key2._domainkey"
  content = "key2.auntalma.com.au._domainkey.migadu.com"
  type    = "CNAME"
  ttl     = 3000
  proxied = false
  comment = "Migadu DKIM key2"
}

resource "cloudflare_record" "auntalma_dkim_key3" {
  zone_id = local.auntalma_zone_id
  name    = "key3._domainkey"
  content = "key3.auntalma.com.au._domainkey.migadu.com"
  type    = "CNAME"
  ttl     = 3000
  proxied = false
  comment = "Migadu DKIM key3"
}

# DMARC Record
resource "cloudflare_record" "auntalma_dmarc" {
  zone_id = local.auntalma_zone_id
  name    = "_dmarc"
  content = "v=DMARC1; p=quarantine;"
  type    = "TXT"
  ttl     = 3000
  comment = "Migadu DMARC policy"
}

# Autoconfig for mail clients
resource "cloudflare_record" "auntalma_autoconfig" {
  zone_id = local.auntalma_zone_id
  name    = "autoconfig"
  content = "autoconfig.migadu.com"
  type    = "CNAME"
  ttl     = 3000
  proxied = false
  comment = "Migadu autoconfig for Thunderbird/etc"
}

# SRV Records for mail client autodiscovery
resource "cloudflare_record" "auntalma_autodiscover" {
  zone_id = local.auntalma_zone_id
  name    = "_autodiscover._tcp"
  type    = "SRV"
  ttl     = 3000
  comment = "Migadu autodiscover for Outlook"
  data {
    priority = 0
    weight   = 1
    port     = 443
    target   = "autodiscover.migadu.com"
  }
}

resource "cloudflare_record" "auntalma_submissions" {
  zone_id = local.auntalma_zone_id
  name    = "_submissions._tcp"
  type    = "SRV"
  ttl     = 3000
  comment = "Migadu SMTP submission"
  data {
    priority = 0
    weight   = 1
    port     = 465
    target   = "smtp.migadu.com"
  }
}

resource "cloudflare_record" "auntalma_imaps" {
  zone_id = local.auntalma_zone_id
  name    = "_imaps._tcp"
  type    = "SRV"
  ttl     = 3000
  comment = "Migadu IMAP"
  data {
    priority = 0
    weight   = 1
    port     = 993
    target   = "imap.migadu.com"
  }
}

resource "cloudflare_record" "auntalma_pop3s" {
  zone_id = local.auntalma_zone_id
  name    = "_pop3s._tcp"
  type    = "SRV"
  ttl     = 3000
  comment = "Migadu POP3"
  data {
    priority = 0
    weight   = 1
    port     = 995
    target   = "pop.migadu.com"
  }
}

# ==============================================
# DNS Records - Web Traffic (Kubernetes Cluster)
# ==============================================

# Root domain - Magento store via Cloudflare Tunnel
resource "cloudflare_record" "auntalma_web" {
  zone_id = local.auntalma_zone_id
  name    = "@"
  content = "external.haydenagencies.com.au"
  type    = "CNAME"
  proxied = true
  comment = "Magento store via K8s cluster"
}

# WWW redirect
resource "cloudflare_record" "auntalma_www" {
  zone_id = local.auntalma_zone_id
  name    = "www"
  content = "external.haydenagencies.com.au"
  type    = "CNAME"
  proxied = true
  comment = "Magento store www redirect"
}
