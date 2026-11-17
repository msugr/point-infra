output "vpc_id" { value = module.vpc.vpc_id }
output "eks_cluster_name" { value = module.eks.cluster_name }
output "aurora_endpoint" { value = module.aurora.endpoint }
output "aurora_secret_arn" { value = module.aurora.master_secret_arn }
output "ecr_monolith_url" { value = aws_ecr_repository.monolith.repository_url }
output "ecr_event_service_url" { value = aws_ecr_repository.event_service.repository_url }
