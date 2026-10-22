locals {
  wireguard_cidr = "10.30.0.0/24"

  corp_cidrs = [local.vpcs.hq.cidr, local.vpcs.branch.cidr, local.wireguard_cidr]

  vpn_peer = { hq = "branch", branch = "hq" }

  remote_cidrs = {
    hq     = [local.vpcs.branch.cidr, local.wireguard_cidr]
    branch = [local.vpcs.hq.cidr, local.wireguard_cidr]
  }

  ike_rules = merge([
    for site, router in local.active_routers : {
      for port in [500, 4500] : "${site}-${port}" => {
        site = site
        port = port
        peer = local.active_routers[local.vpn_peer[site]]
      }
    } if contains(keys(local.active_routers), local.vpn_peer[site])
  ]...)

  extra_security_groups = {
    for name, s in local.active_servers : name => concat(
      contains(values(local.active_routers), name) ? [aws_security_group.vpn[s.vpc].id] : [],
      s.access == "internal" && contains(keys(local.active_routers), s.vpc) ? [aws_security_group.corp[s.vpc].id] : [],
      name == "dc01" ? [aws_security_group.directory["hq"].id] : []
    )
  }
}

resource "aws_security_group" "vpn" {
  for_each    = local.active_routers
  name        = "${each.key}-vpn"
  description = "VPN traffic to the office router"
  vpc_id      = aws_vpc.vpc[each.key].id
  tags        = { Name = "${each.key}-vpn" }
}

resource "aws_vpc_security_group_ingress_rule" "ike" {
  for_each          = local.ike_rules
  security_group_id = aws_security_group.vpn[each.value.site].id
  description       = "IPsec from the other office router"
  ip_protocol       = "udp"
  from_port         = each.value.port
  to_port           = each.value.port
  cidr_ipv4         = "${aws_eip.public[each.value.peer].public_ip}/32"
}

resource "aws_vpc_security_group_ingress_rule" "wireguard" {
  for_each          = { for site, router in local.active_routers : site => router if site == "hq" }
  security_group_id = aws_security_group.vpn[each.key].id
  description       = "WireGuard remote access"
  ip_protocol       = "udp"
  from_port         = 51820
  to_port           = 51820
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_security_group" "corp" {
  for_each    = local.active_routers
  name        = "${each.key}-corp"
  description = "Company traffic from the other office and WireGuard"
  vpc_id      = aws_vpc.vpc[each.key].id

  ingress {
    description = "Ping from company networks"
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = local.corp_cidrs
  }

  ingress {
    description = "SSH from WireGuard users"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.wireguard_cidr]
  }

  ingress {
    description = "RDP from WireGuard users"
    from_port   = 3389
    to_port     = 3389
    protocol    = "tcp"
    cidr_blocks = [local.wireguard_cidr]
  }

  tags = { Name = "${each.key}-corp" }
}
