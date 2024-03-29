variable "tags" {
  description = "AWS Tags"
  type = map(string)
}
variable "project"{
  description = "The unity project its installed into"
  type = string
  default = "UnknownProject"
}

variable "venue" {
  description = "The unity venue its installed into"
  type = string
  default = "UnknownVenue"
}
variable "deployment_name" {
  description = "The deployment name"
  type        = string
}
variable "installprefix" {
  description = "The management console install prefix"
  type = string
  default = "UnknownPrefix"
}
variable "template" {
  default = <<EOT
                  RewriteEngine on
                  ProxyPass /sample http://test-demo-alb-616613476.us-west-2.elb.amazonaws.com:8888/sample/hello.jsp
                  ProxyPassReverse /sample http://test-demo-alb-616613476.us-west-2.elb.amazonaws.com:8888/sample/hello.jsp
EOT
}
