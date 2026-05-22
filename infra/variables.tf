variable "region" {
  description = "AWS region"
  type        = string
  default     = "ap-south-1"
}

variable "gateway_instance_type" {
  description = "EC2 instance type for gateway"
  type        = string
  default     = "t2.micro"
}

variable "inference_instance_type" {
  description = "EC2 instance type for inference"
  type        = string
  default     = "t2.medium"
}

variable "ssh_public_key" {
  description = "SSH public key content"
  type        = string
}

variable "repo_url" {
  description = "GitHub repo URL"
  type        = string
  default     = "https://github.com/YOUR_USERNAME/alchemyst-devops.git"
}
