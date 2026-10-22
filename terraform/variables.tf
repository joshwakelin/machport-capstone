variable "region" {
  description = "AWS region for every resource (the only one the AWS organization allows)"
  type        = string
  default     = "us-east-2"
}

variable "az" {
  description = "Availability zone for every subnet"
  type        = string
  default     = "us-east-2a"
}

variable "admin_cidr" {
  description = "Public IP of the host machine followed by /32. Only this address can SSH in."
  type        = string

  validation {
    condition     = can(regex("^\\d+\\.\\d+\\.\\d+\\.\\d+/32$", var.admin_cidr))
    error_message = "admin_cidr must look like 203.0.113.25/32."
  }
}

variable "public_key_path" {
  description = "SSH public key that every server will trust"
  type        = string
  default     = "~/.ssh/machport.pub"
}

variable "private_key_path" {
  description = "Matching private key, used in the Ansible inventory"
  type        = string
  default     = "~/.ssh/machport"
}

variable "sites" {
  description = "Which networks to build. Remove one and apply to delete it."
  type        = list(string)
  default     = ["hq", "branch", "pstn"]

  validation {
    condition     = alltrue([for s in var.sites : contains(["hq", "branch", "pstn"], s)])
    error_message = "sites can only contain hq, branch and pstn."
  }
}
