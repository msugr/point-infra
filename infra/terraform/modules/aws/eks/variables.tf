variable "cluster_name" { type = string }
variable "cluster_version" {
  type    = string
  default = "1.31"
}
variable "vpc_id" { type = string }
variable "subnet_ids" { type = list(string) }
variable "core_instance_types" {
  type    = list(string)
  default = ["t3.large"]
}
variable "tags" {
  type    = map(string)
  default = {}
}
variable "allowed_cidrs" {
  description = "EKS public API endpoint 접근 허용 CIDR 목록"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
