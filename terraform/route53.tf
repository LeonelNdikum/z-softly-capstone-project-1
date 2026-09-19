# -----------------------------
# Hosted Zone for the subdomain
# -----------------------------

resource "aws_route53_zone" "subdomain" {
  name = "www.leonels-projects.co.uk"

  tags = {
    Name    = "${var.project_name}-zone"
    Project = var.project_name
  }
}

# -----------------------------
# Alias record pointing to the ALB
# -----------------------------

resource "aws_route53_record" "app" {
  zone_id = aws_route53_zone.subdomain.zone_id
  name    = "www.leonels-projects.co.uk"
  type    = "A"

  alias {
    name                   = aws_lb.app.dns_name
    zone_id                = aws_lb.app.zone_id
    evaluate_target_health = true
  }
}

# -----------------------------
# Nameservers output (for IONOS delegation)
# -----------------------------

output "route53_nameservers" {
  description = "Nameservers to configure at IONOS for www subdomain delegation"
  value       = aws_route53_zone.subdomain.name_servers
}