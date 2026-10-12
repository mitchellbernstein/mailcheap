#!/usr/bin/env bash
# Sets up Amazon SES for Mailcheap in one go. Run it in AWS CloudShell, signed in to your account:
#
#   curl -fsSL https://raw.githubusercontent.com/mitchellbernstein/mailcheap/main/scripts/setup-ses.sh \
#     | bash -s mail.example.com https://mailcheap.example.com
#
# Arguments: the sending subdomain, then the public URL of the Mailcheap app (APP_URL).
# It is safe to run again: existing pieces are kept, and a new access key is only made when the
# Mailcheap IAM user has none.
#
# Before running, set these on the Mailcheap deployment so the SNS subscription confirms itself:
#   SES_REGION=us-east-1  SES_CONFIGURATION_SET=mailcheap
#   SES_SNS_TOPIC_ARN=arn:aws:sns:us-east-1:<account-id>:mailcheap-ses-events
set -euo pipefail

DOMAIN="${1:?Pass the sending subdomain, like mail.example.com}"
APP_URL="${2:?Pass the Mailcheap URL, like https://mailcheap.example.com}"
APP_URL="${APP_URL%/}"
REGION="${SES_REGION:-us-east-1}"
CONFIG_SET="mailcheap"
TOPIC_NAME="mailcheap-ses-events"
IAM_USER="mailcheap-sender"
MAIL_FROM="bounce.${DOMAIN}"
export AWS_DEFAULT_REGION="$REGION"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "Account ${ACCOUNT_ID}, region ${REGION}"

echo "1/7 Sending domain ${DOMAIN}"
aws sesv2 create-email-identity --email-identity "$DOMAIN" >/dev/null 2>&1 || echo "    already exists"
aws sesv2 put-email-identity-mail-from-attributes --email-identity "$DOMAIN" \
	--mail-from-domain "$MAIL_FROM" --behavior-on-mx-failure USE_DEFAULT_VALUE

echo "2/7 Configuration set ${CONFIG_SET}"
aws sesv2 create-configuration-set --configuration-set-name "$CONFIG_SET" >/dev/null 2>&1 || echo "    already exists"

echo "3/7 SNS topic ${TOPIC_NAME}"
TOPIC_ARN=$(aws sns create-topic --name "$TOPIC_NAME" --query TopicArn --output text)
aws sns set-topic-attributes --topic-arn "$TOPIC_ARN" --attribute-name SignatureVersion --attribute-value 2
aws sns set-topic-attributes --topic-arn "$TOPIC_ARN" --attribute-name Policy --attribute-value "$(cat <<EOF
{"Version":"2012-10-17","Statement":[
 {"Sid":"Owner","Effect":"Allow","Principal":{"AWS":"arn:aws:iam::${ACCOUNT_ID}:root"},"Action":["SNS:GetTopicAttributes","SNS:SetTopicAttributes","SNS:AddPermission","SNS:RemovePermission","SNS:DeleteTopic","SNS:Subscribe","SNS:ListSubscriptionsByTopic","SNS:Publish"],"Resource":"${TOPIC_ARN}"},
 {"Sid":"SesPublish","Effect":"Allow","Principal":{"Service":"ses.amazonaws.com"},"Action":"sns:Publish","Resource":"${TOPIC_ARN}",
  "Condition":{"StringEquals":{"AWS:SourceAccount":"${ACCOUNT_ID}"}}}]}
EOF
)"

echo "4/7 SES events to the topic"
DEST='{"Enabled":true,"MatchingEventTypes":["BOUNCE","COMPLAINT","DELIVERY","DELIVERY_DELAY","REJECT","RENDERING_FAILURE"],"SnsDestination":{"TopicArn":"'"$TOPIC_ARN"'"}}'
aws sesv2 create-configuration-set-event-destination --configuration-set-name "$CONFIG_SET" \
	--event-destination-name sns --event-destination "$DEST" >/dev/null 2>&1 \
	|| aws sesv2 update-configuration-set-event-destination --configuration-set-name "$CONFIG_SET" \
		--event-destination-name sns --event-destination "$DEST"

echo "5/7 Mailcheap subscribed to the topic"
ENDPOINT="${APP_URL}/api/webhooks/ses"
if ! aws sns list-subscriptions-by-topic --topic-arn "$TOPIC_ARN" --query "Subscriptions[].Endpoint" --output text | grep -q "$ENDPOINT"; then
	aws sns subscribe --topic-arn "$TOPIC_ARN" --protocol https --notification-endpoint "$ENDPOINT" >/dev/null
fi

echo "6/7 Send-only IAM user ${IAM_USER}"
aws iam create-user --user-name "$IAM_USER" >/dev/null 2>&1 || echo "    already exists"
aws iam put-user-policy --user-name "$IAM_USER" --policy-name mailcheap-ses-send --policy-document "$(cat <<EOF
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":["ses:SendEmail","ses:SendRawEmail"],"Resource":[
  "arn:aws:ses:${REGION}:${ACCOUNT_ID}:identity/${DOMAIN}",
  "arn:aws:ses:${REGION}:${ACCOUNT_ID}:configuration-set/${CONFIG_SET}"]},
 {"Effect":"Allow","Action":["ses:GetAccount","ses:ListEmailIdentities","ses:GetEmailIdentity"],"Resource":"*"}]}
EOF
)"
KEY_LINES=""
if [ "$(aws iam list-access-keys --user-name "$IAM_USER" --query 'length(AccessKeyMetadata)' --output text)" = "0" ]; then
	read -r KEY_ID KEY_SECRET < <(aws iam create-access-key --user-name "$IAM_USER" \
		--query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text)
	KEY_LINES="SES_ACCESS_KEY_ID=${KEY_ID}
SES_SECRET_ACCESS_KEY=${KEY_SECRET}"
else
	KEY_LINES="# ${IAM_USER} already has an access key; reuse the one you saved earlier."
fi

echo "7/7 Production access request"
if [ "$(aws sesv2 get-account --query ProductionAccessEnabled --output text)" = "True" ]; then
	echo "    already approved"
else
	aws sesv2 put-account-details --production-access-enabled --mail-type MARKETING --contact-language EN \
		--website-url "https://${DOMAIN#*.}" \
		--use-case-description "A personal newsletter for readers of ${DOMAIN#*.}. People subscribe themselves on the site and confirm by email (double opt-in); nobody is added from bought or imported lists. Every email has a one-click unsubscribe link. Bounces and complaints arrive through an SNS event destination and those addresses are suppressed automatically. Volume starts small, one issue at a time, sent only to confirmed subscribers." \
		>/dev/null 2>&1 && echo "    requested" || echo "    already requested or not allowed; check Account dashboard in SES"
fi

TOKENS=$(aws sesv2 get-email-identity --email-identity "$DOMAIN" --query 'DkimAttributes.Tokens' --output text)
echo
echo "===== Copy everything between the lines into Mailcheap keys.txt ====="
echo "$KEY_LINES"
echo "SES_DKIM_TOKENS=${TOKENS}"
echo "SES_TOPIC_ARN=${TOPIC_ARN}"
echo "====================================================================="
