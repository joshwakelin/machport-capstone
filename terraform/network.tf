locals { 
  vpcs = { 
    hq     = { name = "Headquarters", cidr = "10.10.0.0/16" } 
    branch = { name = "Branch", cidr = "10.20.0.0/16" } 
    pstn   = { name = "Simulated Phone Network", cidr = "10.99.0.0/16" } 
  } 
 
  subnets = { 
    hq-dmz        = { vpc = "hq", cidr = "10.10.10.0/24", public = true } 
    hq-servers    = { vpc = "hq", cidr = "10.10.20.0/24", public = false } 
    hq-services   = { vpc = "hq", cidr = "10.10.30.0/24", public = false } 
    hq-users      = { vpc = "hq", cidr = "10.10.40.0/24", public = false } 
    branch-edge   = { vpc = "branch", cidr = "10.20.1.0/24", public = true } 
    branch-phones = { vpc = "branch", cidr = "10.20.10.0/24", public = false } 
    pstn-public   = { vpc = "pstn", cidr = "10.99.1.0/24", public = true } 
  } 
 
  routers = { 
    hq     = "edge01" 
    branch = "branchedge01" 
  } 
 
  active_vpcs    = { for k, v in local.vpcs : k => v if contains(var.sites, k) } 
  active_subnets = { for k, v in local.subnets : k => v if contains(var.sites, v.vpc) } 
  active_routers = { for k, v in local.routers : k => v if contains(var.sites, k) } 
} 
 
resource "aws_vpc" "vpc" { 
  for_each             = local.active_vpcs 
  cidr_block           = each.value.cidr 
  enable_dns_support   = true 
  enable_dns_hostnames = true 
  tags                 = { Name = each.value.name } 
} 
 
resource "aws_internet_gateway" "igw" { 
  for_each = local.active_vpcs 
  vpc_id   = aws_vpc.vpc[each.key].id 
  tags     = { Name = "${each.key}-igw" } 
} 
 
resource "aws_subnet" "subnet" { 
  for_each          = local.active_subnets 
  vpc_id            = aws_vpc.vpc[each.value.vpc].id 
  cidr_block        = each.value.cidr 
  availability_zone = var.az 
  tags              = { Name = each.key } 
} 
 
resource "aws_route_table" "public" { 
  for_each = local.active_vpcs 
  vpc_id   = aws_vpc.vpc[each.key].id 
 
  route { 
    cidr_block = "0.0.0.0/0" 
    gateway_id = aws_internet_gateway.igw[each.key].id 
  } 
 
  tags = { Name = "${each.key}-public" } 
} 
 
resource "aws_route_table" "private" { 
  for_each = local.active_routers 
  vpc_id   = aws_vpc.vpc[each.key].id 
 
  route { 
    cidr_block           = "0.0.0.0/0" 
    network_interface_id = aws_instance.server[each.value].primary_network_interface_id 
  } 
 
  tags = { Name = "${each.key}-private" } 
} 
 
resource "aws_route_table_association" "public" { 
  for_each       = { for k, v in local.active_subnets : k => v if v.public } 
  subnet_id      = aws_subnet.subnet[each.key].id 
  route_table_id = aws_route_table.public[each.value.vpc].id 
} 
 
resource "aws_route_table_association" "private" { 
  for_each       = { for k, v in local.active_subnets : k => v if !v.public } 
  subnet_id      = aws_subnet.subnet[each.key].id 
  route_table_id = aws_route_table.private[each.value.vpc].id 
}
