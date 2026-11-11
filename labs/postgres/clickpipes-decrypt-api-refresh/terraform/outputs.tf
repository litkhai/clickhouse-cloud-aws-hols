output "pg_host" { value = aws_rds_cluster.this.endpoint }
output "pg_user" { value = aws_rds_cluster.this.master_username }
output "kms_alias" { value = aws_kms_alias.master.name }
output "keyring_param" { value = aws_ssm_parameter.keyring.name }
output "lambda_name" { value = aws_lambda_function.api.function_name }
output "api_url" { value = "${aws_api_gateway_stage.v1.invoke_url}/decrypt" }

output "pg_password" {
  value     = random_password.master.result
  sensitive = true
}

output "api_token" {
  value     = random_password.api_token.result
  sensitive = true
}
