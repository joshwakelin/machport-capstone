# written to ../ansible/inventory.ini 
locals { 
  private_key = pathexpand(var.private_key_path) 
 
  router_ips = { for site, name in local.active_routers : site => aws_eip.public[name].public_ip } 
 
  inventory_lines = { 
    for k, v in local.active_servers : k => join(" ", compact([ 
      k, 
      "ansible_host=${v.access == "public" ? aws_eip.public[k].public_ip : v.ip}", 
      "site=${v.vpc}", 
      "vpc_cidr=${local.vpcs[v.vpc].cidr}", 
      v.access == "public" ? "" : "ansible_ssh_common_args='-o ProxyCommand=\"ssh -W %h:%p -q -i ${local.private_key} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@${lookup(local.router_ips, v.vpc, "")}\"'", 
    ])) 
  } 
} 
 
resource "local_file" "inventory" { 
  filename        = "${path.module}/../ansible/inventory.ini" 
  file_permission = "0644" 
 
  content = templatefile("${path.module}/templates/inventory.tftpl", { 
    lines   = local.inventory_lines 
    linux   = [for k, v in local.active_servers : k if v.os == "ubuntu"] 
    windows = [for k, v in local.active_servers : k if v.os == "windows"] 
    routers = values(local.active_routers) 
  }) 
} 
 
output "public_ips" { 
  description = "Elastic IPs of the servers that face the internet" 
  value       = { for k, e in aws_eip.public : k => e.public_ip } 
} 
 
output "dc01_instance_id" { 
  description = "Needed to get the Windows Administrator password" 
  value       = try(aws_instance.server["dc01"].id, null) 
} 
 
output "backup_bucket" { 
  value = aws_s3_bucket.backups.bucket 
} 
