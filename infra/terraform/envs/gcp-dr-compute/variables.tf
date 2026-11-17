variable "project_id" { type = string }
variable "region" {
  type    = string
  default = "asia-northeast3"
}
variable "git_repo_url" {
  type    = string
  default = "https://github.com/msugr/point-infra.git"
}
