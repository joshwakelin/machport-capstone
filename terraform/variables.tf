variable "region" { 
  description = "region declaration" 
  type        = string 
  default     = "us-east-2" 
} 
 
variable "az" { 
  description = "availability zone declaration" 
  type        = string 
  default     = "us-east-2a" 
} 
 
variable "admin_cidr" { 
  description = "allowed ssh ips" 
  type        = string 
 
  validation { 
    condition     = can(regex("^\\d+\\.\\d+\\.\\d+\\.\\d+/32$", var.admin_cidr)) 
    error_message = "admin_cidr must look like 100.10.10.10/32." 
  } 
} 
 
variable "public_key_path" { 
  description = "path to pub key" 
  type        = string 
  default     = "~/.ssh/machport.pub" 
} 
 
variable "private_key_path" { 
  description = "path to priv key" 
  type        = string 
  default     = "~/.ssh/machport" 
} 
 
variable "sites" { 
  description = "network build declaration" 
  type        = list(string) 
  default     = ["hq", "branch", "pstn"] 
 
  validation { 
    condition     = alltrue([for s in var.sites : contains(["hq", "branch", "pstn"], s)]) 
    error_message = "sites can only contain hq, branch and pstn." 
  } 
} 
