#!/bin/bash
set -euo pipefail

# === Configuration ===
REGION="uk-london-1"
DISPLAY_NAME="fedora-coreos-stable-aarch64"
QCOW2_FILE="/Volumes/Development/arr/fedora-coreos-43.20260301.3.1-oraclecloud.aarch64.qcow2"
BUCKET_NAME="custom-images"
OBJECT_NAME="fedora-coreos-aarch64.qcow2"
OLD_IMAGE_ID="ocid1.image.oc1.uk-london-1.aaaaaaaacwy3qzpzmrlsm3sosqzkcm43e2glufylyl5w3vakqtbjllgtq4tq"
OCI_AUTH="--auth security_token --profile mm67"

# === Step 0: Get tenancy info ===
echo "==> Getting tenancy namespace and compartment..."
NAMESPACE=$(oci os ns get $OCI_AUTH --query 'data' --raw-output)
COMPARTMENT_ID=$(oci iam compartment list $OCI_AUTH \
  --compartment-id-in-subtree true \
  --access-level ACCESSIBLE \
  --include-root \
  --query 'data[0]."compartment-id"' \
  --raw-output 2>/dev/null || true)

# If that didn't work, get the tenancy OCID directly
if [ -z "$COMPARTMENT_ID" ]; then
  COMPARTMENT_ID=$(oci iam compartment list $OCI_AUTH \
    --include-root \
    --query 'data[?"name"==`mm67`].id | [0]' \
    --raw-output 2>/dev/null || true)
fi

if [ -z "$COMPARTMENT_ID" ]; then
  # Fall back to tenancy ID from config
  COMPARTMENT_ID=$(grep -m1 'tenancy' ~/.oci/config | cut -d= -f2 | tr -d ' ')
fi

echo "    Namespace:    $NAMESPACE"
echo "    Compartment:  $COMPARTMENT_ID"

# === Step 1: Delete old BIOS image ===
echo ""
echo "==> Deleting old image (BIOS firmware)..."
oci compute image delete $OCI_AUTH \
  --image-id "$OLD_IMAGE_ID" \
  --force \
  2>/dev/null && echo "    Deleted." || echo "    Already gone or not found, continuing."

# === Step 2: Create bucket (if needed) ===
echo ""
echo "==> Creating object storage bucket '$BUCKET_NAME' (if it doesn't exist)..."
oci os bucket create $OCI_AUTH \
  --compartment-id "$COMPARTMENT_ID" \
  --name "$BUCKET_NAME" \
  2>/dev/null && echo "    Created." || echo "    Already exists, continuing."

# === Step 3: Upload QCOW2 to object storage ===
echo ""
echo "==> Uploading QCOW2 to object storage (this will take a while for 1.9GB)..."
oci os object put $OCI_AUTH \
  --bucket-name "$BUCKET_NAME" \
  --file "$QCOW2_FILE" \
  --name "$OBJECT_NAME" \
  --force
echo "    Upload complete."

# === Step 4: Import image with UEFI firmware ===
SOURCE_URI="https://objectstorage.${REGION}.oraclecloud.com/n/${NAMESPACE}/b/${BUCKET_NAME}/o/${OBJECT_NAME}"
echo ""
echo "==> Importing image with UEFI_64 firmware..."
echo "    Source: $SOURCE_URI"

IMAGE_ID=$(oci compute image import from-object-uri $OCI_AUTH \
  --compartment-id "$COMPARTMENT_ID" \
  --display-name "$DISPLAY_NAME" \
  --launch-mode PARAVIRTUALIZED \
  --source-image-type QCOW2 \
  --uri "$SOURCE_URI" \
  --query 'data.id' \
  --raw-output)

echo "    Image import started: $IMAGE_ID"

# === Step 5: Wait for image to be available ===
echo ""
echo "==> Waiting for image import to complete (this can take 10-20 minutes)..."
while true; do
  STATE=$(oci compute image get $OCI_AUTH \
    --image-id "$IMAGE_ID" \
    --query 'data."lifecycle-state"' \
    --raw-output)
  echo "    State: $STATE"
  if [ "$STATE" = "AVAILABLE" ]; then
    break
  elif [ "$STATE" = "IMPORTING" ] || [ "$STATE" = "PROVISIONING" ]; then
    sleep 30
  else
    echo "    ERROR: Unexpected state: $STATE"
    exit 1
  fi
done

echo ""
echo "==> Updating image to use UEFI_64 firmware..."
oci compute image update $OCI_AUTH \
  --image-id "$IMAGE_ID" \
  --launch-options '{"firmware":"UEFI_64","networkType":"PARAVIRTUALIZED","bootVolumeType":"PARAVIRTUALIZED","remoteDataVolumeType":"PARAVIRTUALIZED"}' \
  --force \
  --query 'data.{"id":id,"name":"display-name","launch-options":"launch-options"}' \
  2>/dev/null || echo "    Note: launch-options update via CLI may not be supported. See below."

# === Step 6: Verify compatible shapes ===
echo ""
echo "==> Checking compatible shapes..."
oci compute image-shape-compatibility-entry list $OCI_AUTH \
  --image-id "$IMAGE_ID" \
  --query 'data[*].shape' \
  --output table

echo ""
echo "==> If A1.Flex is not listed, adding shape compatibility..."
oci compute image-shape-compatibility-entry add $OCI_AUTH \
  --image-id "$IMAGE_ID" \
  --shape-name "VM.Standard.A1.Flex" \
  2>/dev/null && echo "    Added VM.Standard.A1.Flex." || echo "    Already present or failed."

echo ""
echo "==> Done! Image ID: $IMAGE_ID"
echo "    You can now launch with: VM.Standard.A1.Flex"
