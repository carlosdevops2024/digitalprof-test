variable "aws_region" {
  description = "Región AWS"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Nombre del cluster EKS"
  type        = string
  default     = "flask-eks-cluster"
}

variable "environment" {
  description = "Ambiente de despliegue"
  type        = string
  default     = "demo"
}