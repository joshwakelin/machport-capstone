resource "aws_security_group" "directory" {
  for_each    = { for site, vpc in local.active_vpcs : site => vpc if site == "hq" }
  name        = "hq-directory"
  description = "Active Directory services on dc01"
  vpc_id      = aws_vpc.vpc[each.key].id

  ingress {
    description = "DNS from company networks"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = local.corp_cidrs
  }

  ingress {
    description = "DNS over TCP from company networks"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = local.corp_cidrs
  }

  ingress {
    description = "LDAPS from pbx01 (provisioning) and WireGuard admins"
    from_port   = 636
    to_port     = 636
    protocol    = "tcp"
    cidr_blocks = ["${local.servers.pbx01.ip}/32", local.wireguard_cidr]
  }

  tags = { Name = "hq-directory" }
}
