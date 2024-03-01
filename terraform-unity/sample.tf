data "aws_ssm_parameter" "vpc_id" {
  name = "/unity/account/network/vpc_id"
}

data "aws_ssm_parameter" "subnet_list" {
  name = "/unity/account/network/subnet_list"
}

data "aws_ssm_parameter" "proxylambda" {
  name = "/unity/cs/management/proxy/${var.installprefix}-httpd-lambda-name"
}

data "aws_iam_policy" "mcp_operator_policy" {
  name = "mcp-tenantOperator-AMI-APIG"
}

locals {
  subnet_map = jsondecode(data.aws_ssm_parameter.subnet_list.value)
  subnet_ids = nonsensitive(local.subnet_map["private"])
  public_subnet_ids = nonsensitive(local.subnet_map["public"])
}

#####################

resource "aws_lambda_invocation" "demoinvocation2" {
  function_name = data.aws_ssm_parameter.proxylambda.value

  input = jsonencode({
    filename  = "example_filename_make_me_dynamic",
    template = var.template
  })

}

