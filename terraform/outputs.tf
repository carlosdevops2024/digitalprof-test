output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "ecr_repository_url" {
  value = aws_ecr_repository.flask_app.repository_url
}

output "cluster_name" {
  value = module.eks.cluster_name
}