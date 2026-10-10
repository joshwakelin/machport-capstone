locals { 
  servers = { 
    edge01         = { subnet = "hq-dmz", ip = "10.10.10.10", type = "t3.micro", os = "ubuntu", access = "public", eip = true } 
    sbc01          = { subnet = "hq-dmz", ip = "10.10.10.20", type = "t3.small", os = "ubuntu", access = "internal", eip = true } 
    dc01           = { subnet = "hq-servers", ip = "10.10.20.10", type = "c7i-flex.large", os = "windows", access = "internal", eip = false } 
    pbx01          = { subnet = "hq-servers", ip = "10.10.20.20", type = "t3.small", os = "ubuntu", access = "internal", eip = false } 
    siem01         = { subnet = "hq-services", ip = "10.10.30.10", type = "t3.micro", os = "ubuntu", access = "internal", eip = false } 
    phones01       = { subnet = "hq-users", ip = "10.10.40.10", type = "t3.micro", os = "ubuntu", access = "internal", eip = false } 
    branchedge01   = { subnet = "branch-edge", ip = "10.20.1.5", type = "t3.micro", os = "ubuntu", access = "public", eip = true } 
    branchphones01 = { subnet = "branch-phones", ip = "10.20.10.20", type = "t3.micro", os = "ubuntu", access = "internal", eip = false } 
    carrier01      = { subnet = "pstn-public", ip = "10.99.1.10", type = "t3.small", os = "ubuntu", access = "public", eip = true } 
    world01        = { subnet = "pstn-public", ip = "10.99.1.20", type = "t3.small", os = "ubuntu", access = "public", eip = true } 
  } 
 
  # Servers in the active sites, each tagged with its VPC 
  active_servers = { 
    for k, v in local.servers : k => merge(v, { vpc = local.subnets[v.subnet].vpc }) 
    if contains(var.sites, local.subnets[v.subnet].vpc) 
  } 
} 
 
data "aws_ami" "ubuntu" { 
  most_recent = true 
  owners      = ["099720109477"] # Canonical 
 
  filter { 
    name   = "name" 
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"] 
  } 
} 
 
data "aws_ami" "windows" { 
  most_recent = true 
  owners      = ["amazon"] 
 
  filter { 
    name   = "name" 
    values = ["Windows_Server-2025-English-Full-Base-*"] 
  } 
} 
 
resource "aws_key_pair" "machport" { 
  key_name   = "machport" 
  public_key = file(pathexpand(var.public_key_path)) 
} 
 
resource "aws_instance" "server" { 
  for_each = local.active_servers 
 
  ami                    = each.value.os == "windows" ? data.aws_ami.windows.id : data.aws_ami.ubuntu.id 
  instance_type          = each.value.type 
  subnet_id              = aws_subnet.subnet[each.value.subnet].id 
  private_ip             = each.value.ip 
  key_name               = aws_key_pair.machport.key_name 
  vpc_security_group_ids = [each.value.access == "public" ? aws_security_group.public[each.value.vpc].id : aws_security_group.internal[each.value.vpc].id] 
 
  source_dest_check = !contains(values(local.routers), each.key) 
  user_data = each.value.os == "windows" ? templatefile("${path.module}/userdata/windows.ps1.tftpl", { 
    public_key = trimspace(file(pathexpand(var.public_key_path))) 
  }) : null 
 
  root_block_device { 
    volume_type = "gp3" 
    volume_size = each.value.os == "windows" ? 30 : 10 
    encrypted   = true 
  } 
 
  dynamic "credit_specification" { 
    for_each = startswith(each.value.type, "t3") ? [1] : [] 
    content { 
      cpu_credits = "standard" 
    } 
  } 
 
  metadata_options { 
    http_tokens = "required" 
  } 
 
  tags = { Name = each.key, Site = each.value.vpc } 
 
  lifecycle { 
    ignore_changes = [ami, user_data] 
  } 
} 
 
resource "aws_eip" "public" { 
  for_each = { for k, v in local.active_servers : k => v if v.eip } 
  domain   = "vpc" 
  instance = aws_instance.server[each.key].id 
  tags     = { Name = "${each.key}-eip" } 
 
  depends_on = [aws_internet_gateway.igw] 
} 
