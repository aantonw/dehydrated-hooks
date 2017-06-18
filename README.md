# [Dehydrated](https://github.com/lukas2511/dehydrated) Hooks

Available hooks:

- [Cloudflare hook](#cloudflare-hook)
- [AWS ELB hook](#aws-elb-hook)

## Cloudflare Hook


This hook allows you to use Cloudflare DNS record to response `dns-01` challenges from Letsencrypt.

Requirements:

- curl
- dig
- gnu grep
- Cloudflare account

Configuration variables:

|Variable|Description|Values (default)|
|----|---|---|
|CLOUDFLARE\_EMAIL|Cloudflare email address account||
|CLOUDFLARE\_TOKEN|Cloudflare API Token||
|CLOUDFLARE\_ZONE|*[optional]* Cloudflare DNS zone, useful when using deep subdomain e.g: `this.is.deep.sub.domain.com`|(domain)|
|ELB|*[optional]* enable ELB Hook|yes, no (no)|

## AWS ELB Hook

This hook allows you to deploy server certificate to IAM and update ELB with it.

Requirements:

- AWS cli configured
- IAM account with this permissions:
	- elasticloadbalancing:DescribeLoadBalancers
	- elasticloadbalancing:SetLoadBalancerListenerSSLCertificate
	- iam:ListServerCertificates
	- iam:UploadServerCertificate
	- iam:DeleteServerCertificate
	- iam:GetServerCertificate
	- elasticbeanstalk:DescribeEnvironmentResources *
	- autoscaling:DescribeAutoScalingGroups \*<br/>\*) *required when Elastic beanstalk is used instead of direct ELB name*

|Variable|Description|Values (default)|
|----|---|---|
|ELB\_NAME|ELB name||
|EB\_ENV\_NAME|Elastic beanstalk name, use ELB in  this environment if **ELB_NAME** not specified||
|ELB\_CERT\_PREFIX|Server certificate name prefix to store in IAM|(LETSENCRYPT\_CERT\_)|
|ELB\_DELETE\_OLD\_CERT|Delete all old cert with specified prefix|yes, no (no)|	

