# Primary infrastructure resources belong here
resource "aws_s3_bucket" "example" {
  bucket = "${var.environment}-app-storage-bucket"

  tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}
