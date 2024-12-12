#!/bin/bash

# This is one-time setup script to install pulumi backend on GCS with all 
# applicable permissions and enable encryption for secrets, initialize the 
# stack, and setup the ci trigger. Only use this on initial reporting-iac setup 
# in a project.

# **************************************************************************
# ********** Please set the following variables for your use case **********
# **************************************************************************

export BASE_NAME="reporting-iac"
export PROJECT_ID="reporting-test-444502"
export STACK_NAME="dev"
export REGION="us-central1"

export BUCKET_NAME="$BASE_NAME-bucket"
export SERVICE_ACCOUNT_NAME="$BASE_NAME-service-account"
export SERVICE_ACCOUNT_DISPLAY_NAME="Pulumi Reporting ETL IaC"
export SERVICE_ACCOUNT_EMAIL=$SERVICE_ACCOUNT_NAME@$PROJECT_ID.iam.gserviceaccount.com
export SERVICE_ACCOUNT_KEY_NAME="$SERVICE_ACCOUNT_NAME-key"
export KEY_NAME="$BASE_NAME-key"
export KEY_RING_NAME="$BASE_NAME-keyring"
export GCP_KMS_URL="gcpkms://projects/$PROJECT_ID/locations/$REGION/keyRings/$KEY_RING_NAME/cryptoKeys/$KEY_NAME"

export TRIGGER_NAME="$BASE_NAME-$STACK_NAME-trigger"
export REPO_NAME="devops"
export REPO_OWNER="jason-wiens"
export BRANCH_NAME="main"
export TAG_REGEX="^$BASE_NAME-$STACK_NAME-.*$"
export CLOUD_BUILD_CONFIG="cloudbuild.yml"

#**************************************************************************
#**************************************************************************
#**************************************************************************

# Login to gcloud and set application default credentials
echo "Logging in to gcloud..."
gcloud auth login
gcloud config set project $PROJECT_ID
gcloud auth application-default login
gcloud auth application-default set-quota-project $PROJECT_ID

# Create iam service account
echo "Creating IAM service account $SERVICE_ACCOUNT_NAME..."
gcloud services enable iam.googleapis.com --project=$PROJECT_ID
gcloud iam service-accounts create $SERVICE_ACCOUNT_NAME --display-name "$SERVICE_ACCOUNT_DISPLAY_NAME"
sleep 2
gcloud projects add-iam-policy-binding $PROJECT_ID --member=serviceAccount:$SERVICE_ACCOUNT_EMAIL --role=roles/editor

# Generate a JSON key for the service account and save it to a secret
echo "Generating JSON key for $SERVICE_ACCOUNT_NAME and saving to secret..."
sleep 1
gcloud services enable secretmanager.googleapis.com --project=$PROJECT_ID
gcloud secrets create $SERVICE_ACCOUNT_KEY_NAME --replication-policy="automatic"
gcloud iam service-accounts keys create /tmp/$SERVICE_ACCOUNT_KEY_NAME.json --iam-account=$SERVICE_ACCOUNT_EMAIL
gcloud secrets versions add $SERVICE_ACCOUNT_KEY_NAME --data-file=/tmp/$SERVICE_ACCOUNT_KEY_NAME.json
rm /tmp/$SERVICE_ACCOUNT_KEY_NAME.json

# Create a GCP managed encryption key for Pulumi secrets
echo "Create Encryption Key $KEY_NAME in Key Ring $KEY_RING_NAME for Pulumi Secrets in $PROJECT_ID"
sleep 1
gcloud services enable cloudkms.googleapis.com --project=$PROJECT_ID
gcloud kms keyrings create $KEY_RING_NAME --location=$REGION --project=$PROJECT_ID
gcloud kms keys create $KEY_NAME \
    --location=$REGION \
    --keyring=$KEY_RING_NAME \
    --purpose=encryption \
    --project=$PROJECT_ID
gcloud kms keys add-iam-policy-binding $KEY_NAME \
    --location=$REGION \
    --keyring=$KEY_RING_NAME \
    --member="serviceAccount:$SERVICE_ACCOUNT_EMAIL" \
    --role="roles/cloudkms.cryptoKeyEncrypterDecrypter" \
    --project=$PROJECT_ID

#Setup the CI trigger
echo "Setting up CI trigger $TRIGGER_NAME..."
sleep 1
gcloud beta builds triggers create github \
    --name="$TRIGGER_NAME" \
    --repo-name="$REPO_NAME" \
    --repo-owner="$REPO_OWNER" \
    --branch-pattern="$BRANCH_NAME" \
    --tag-pattern="$TAG_REGEX" \
    --build-config="$CLOUD_BUILD_CONFIG" \
    --project="$PROJECT_ID" \
    --substitutions=_PROJECT_ID="$PROJECT_ID",_SERVICE_ACCOUNT_KEY_NAME="$SERVICE_ACCOUNT_KEY_NAME",_SERVICE_ACCOUNT_EMAIL="$SERVICE_ACCOUNT_EMAIL"

# create the bucket and enable versioning
echo "Creating bucket $BUCKET_NAME..."
sleep 1
gsutil mb -p $PROJECT_ID -l $REGION gs://$BUCKET_NAME/
gsutil versioning set on gs://$BUCKET_NAME/

# login to pulumi
echo "Logging in to pulumi and initializing stack: $STACK_NAME..."
sleep 1
pulumi login gs://$BUCKET_NAME
echo "Initializing stack $STACK_NAME..."
pulumi stack init $STACK_NAME --secrets-provider=$GCP_KMS_URL

# Set the pulumi config variables for the stack
echo "Setting pulumi config variables for $STACK_NAME..."

echo "Pulumi GCS Backend setup complete!"