resource "aws_security_group" "public" { 
  for_each    = local.active_vpcs 
  name        = "${each.key}-public" 
  description = "ssh from admin ip" 
  vpc_id      = aws_vpc.vpc[each.key].id 
 
  ingress { 
    description = "mac connection via ssh" 
    from_port   = 22 
    to_port     = 22 
    protocol    = "tcp" 
    cidr_blocks = [var.admin_cidr] 
  } 
 
  ingress { 
    description = "anything from inside this vpc" 
    from_port   = 0 
    to_port     = 0 
    protocol    = "-1" 
    cidr_blocks = [each.value.cidr] 
  } 
 
  egress { 
    description = "all outbound" 
    from_port   = 0 
    to_port     = 0 
    protocol    = "-1" 
    cidr_blocks = ["0.0.0.0/0"] 
  } 
 
  tags = { Name = "${each.key}-public" } 
} 
 
resource "aws_security_group" "internal" { 
  for_each    = local.active_vpcs 
  name        = "${each.key}-internal" 
  description = "Management from inside the VPC only" 
  vpc_id      = aws_vpc.vpc[each.key].id 
 
  ingress { 
    description = "ssh through the router" 
    from_port   = 22 
    to_port     = 22 
    protocol    = "tcp" 
    cidr_blocks = [each.value.cidr] 
  } 
 
  ingress { 
    description = "rdp to dc01 through ssh tunnel" 
    from_port   = 3389 
    to_port     = 3389 
    protocol    = "tcp" 
    cidr_blocks = [each.value.cidr] 
  } 
 
  ingress { 
    description = "ping" 
    from_port   = -1 
    to_port     = -1 
    protocol    = "icmp" 
    cidr_blocks = [each.value.cidr] 
  } 
 
  egress { 
    description = "outbound" 
    from_port   = 0 
    to_port     = 0 
    protocol    = "-1" 
    cidr_blocks = ["0.0.0.0/0"] 
  } 
 
  tags = { Name = "${each.key}-internal" } 
} 
