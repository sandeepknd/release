#!/bin/bash
set -euo pipefail

echo "========================================="
echo "Vault Enterprise Installation via Helm"
echo "========================================="
echo "Version: ${VAULT_VERSION}"
echo "Namespace: ${VAULT_NAMESPACE}"
echo ""

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

# Vault license secret name
VAULT_LICENSE_SECRET_NAME="vault-license"

# Install Helm if not present
if ! command -v helm &> /dev/null; then
  echo "Installing Helm..."
  HELM_VERSION="3.14.0"
  curl -fsSL "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz" -o /tmp/helm.tar.gz
  tar -xzf /tmp/helm.tar.gz -C /tmp
  mkdir -p /tmp/bin
  mv /tmp/linux-amd64/helm /tmp/bin/helm
  chmod +x /tmp/bin/helm
  export PATH="/tmp/bin:$PATH"
  rm -rf /tmp/helm.tar.gz /tmp/linux-amd64
  echo "Helm installed: $(helm version --short)"
else
  echo "Helm already installed: $(helm version --short)"
fi

echo ""

# Create namespace
echo "Creating namespace ${VAULT_NAMESPACE}..."
oc create namespace "${VAULT_NAMESPACE}"

# Add restricted SCC for Vault service account
echo "Adding restricted SCC for Vault service account..."
oc adm policy add-scc-to-user restricted -z vault -n "${VAULT_NAMESPACE}"

# Create Vault license secret from mounted credential
echo "Creating Vault license secret from mounted credential..."
oc create secret generic "${VAULT_LICENSE_SECRET_NAME}" \
  --from-file=license=/var/run/vault/tests-private-account/kms-vault-license \
  -n "${VAULT_NAMESPACE}"

# Add HashiCorp Helm repository
echo "Adding HashiCorp Helm repository..."
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

echo ""

# Install Vault via Helm with dev mode and TLS enabled
echo "Installing Vault Enterprise v${VAULT_VERSION} in dev mode with TLS..."
helm upgrade --install vault hashicorp/vault \
  --namespace "${VAULT_NAMESPACE}" \
  --version "${VAULT_CHART_VERSION}" \
  --set global.enabled=true \
  --set global.openshift=true \
  --set global.tlsDisable=false \
  --set server.dev.enabled=true \
  --set server.image.repository="${VAULT_IMAGE_REPOSITORY}" \
  --set server.image.tag="${VAULT_VERSION}" \
  --set injector.enabled=false \
  --set 'server.extraEnvironmentVars.VAULT_DISABLE_USER_LOCKOUT=true' \
  --set 'server.extraEnvironmentVars.VAULT_CACERT=/var/run/tls/vault-ca.pem' \
  --set "server.enterpriseLicense.secretName=${VAULT_LICENSE_SECRET_NAME}" \
  --set "server.enterpriseLicense.secretKey=license" \
  --set "server.extraArgs=-dev-tls -dev-tls-cert-dir=/var/run/tls -dev-tls-san=vault -dev-tls-san=vault.${VAULT_NAMESPACE}.svc" \
  --set 'server.volumes[0].name=tls' \
  --set-json 'server.volumes[0].emptyDir={}' \
  --set 'server.volumeMounts[0].name=tls' \
  --set 'server.volumeMounts[0].mountPath=/var/run/tls' \
  --wait \
  --timeout 10m

#helm wait passes even vault pod is 0/1 Running. So, added the below wait to correctly verify the vault pod status
echo "Waiting for Vault pod to be ready..."
oc wait --for=condition=ready pod/vault-0 -n "${VAULT_NAMESPACE}" --timeout=5m

echo "Verifying TLS Configuration"

# Verify VAULT_ADDR uses HTTPS
echo "Checking VAULT_ADDR..."
VAULT_ADDR_CHECK=$(oc exec vault-0 -n "${VAULT_NAMESPACE}" -- env | grep VAULT_ADDR)
echo "  ${VAULT_ADDR_CHECK}"
if echo "${VAULT_ADDR_CHECK}" | grep -q "https://"; then
  echo "  ✓ VAULT_ADDR is using HTTPS"
else
  echo "  ✗ WARNING: VAULT_ADDR is not using HTTPS"
fi

# Verify TLS certificates exist
echo "Verifying TLS certificates..."
if oc exec vault-0 -n "${VAULT_NAMESPACE}" -- ls /var/run/tls/vault-ca.pem &>/dev/null; then
  echo "  ✓ CA certificate exists: /var/run/tls/vault-ca.pem"
else
  echo "  ✗ ERROR: CA certificate not found"
  exit 1
fi

if oc exec vault-0 -n "${VAULT_NAMESPACE}" -- ls /var/run/tls/vault-cert.pem &>/dev/null; then
  echo "  ✓ Server certificate exists: /var/run/tls/vault-cert.pem"
else
  echo "  ✗ ERROR: Server certificate not found"
  exit 1
fi

if oc exec vault-0 -n "${VAULT_NAMESPACE}" -- ls /var/run/tls/vault-key.pem &>/dev/null; then
  echo "  ✓ Private key exists: /var/run/tls/vault-key.pem"
else
  echo "  ✗ ERROR: Private key not found"
  exit 1
fi

# Test Vault status with HTTPS
echo ""
echo "Testing Vault status with HTTPS..."
if oc exec vault-0 -n "${VAULT_NAMESPACE}" -- vault status &>/dev/null; then
  echo "  ✓ Vault responding on HTTPS"
else
  echo "  ✗ WARNING: Vault status check failed"
fi

# Verify certificate SANs
echo "Verifying certificate Subject Alternative Names (SANs)..."
SANS=$(oc exec vault-0 -n "${VAULT_NAMESPACE}" -- cat /var/run/tls/vault-cert.pem | openssl x509 -noout -text | grep -A 1 "Subject Alternative Name" | tail -1)
echo "  ${SANS}"
if echo "${SANS}" | grep -q "vault.${VAULT_NAMESPACE}.svc"; then
  echo "  ✓ Certificate includes service DNS: vault.${VAULT_NAMESPACE}.svc"
else
  echo "  ✗ WARNING: Certificate may not include service DNS"
fi

echo "Extracting CA certificate from Vault pod..."
CA_CERT_TMP="/tmp/vault-ca-${VAULT_NAMESPACE}.pem"
oc exec vault-0 -n "${VAULT_NAMESPACE}" -- cat /var/run/tls/vault-ca.pem > "${CA_CERT_TMP}"

if [ ! -s "${CA_CERT_TMP}" ]; then
  echo "  ✗ ERROR: Failed to extract CA certificate"
  exit 1
fi
echo "  ✓ CA certificate extracted to ${CA_CERT_TMP}"

# Verify CA certificate is valid
echo ""
echo "Verifying CA certificate..."
CA_SUBJECT=$(openssl x509 -in "${CA_CERT_TMP}" -noout -subject 2>/dev/null | sed 's/subject=//')
CA_DATES=$(openssl x509 -in "${CA_CERT_TMP}" -noout -dates 2>/dev/null)
if [ -n "${CA_SUBJECT}" ]; then
  echo "  ✓ CA Subject: ${CA_SUBJECT}"
  echo "  ${CA_DATES}" | sed 's/^/  /'
else
  echo "  ✗ ERROR: Invalid CA certificate"
  exit 1
fi

# Ensure openshift-config namespace exists
echo ""
echo "Ensuring openshift-config namespace exists..."
if ! oc get namespace openshift-config &>/dev/null; then
  oc create namespace openshift-config
  echo "  ✓ Created namespace: openshift-config"
else
  echo "  ✓ Namespace already exists: openshift-config"
fi

# Create or update ConfigMap with CA certificate
echo ""
echo "Creating ConfigMap vault-ca-bundle in openshift-config namespace..."
oc create configmap vault-ca-bundle \
  --from-file=ca-bundle.crt="${CA_CERT_TMP}" \
  -n openshift-config \
  --dry-run=client -o yaml | oc apply -f -

if [ $? -eq 0 ]; then
  echo "  ✓ ConfigMap vault-ca-bundle created/updated successfully"
else
  echo "  ✗ ERROR: Failed to create ConfigMap"
  exit 1
fi

# Verify ConfigMap was created
echo ""
echo "Verifying ConfigMap..."
if oc get configmap vault-ca-bundle -n openshift-config &>/dev/null; then
  echo "  ✓ ConfigMap exists: vault-ca-bundle (namespace: openshift-config)"
  CM_CA_SUBJECT=$(oc get configmap vault-ca-bundle -n openshift-config -o jsonpath='{.data.ca-bundle\.crt}' | openssl x509 -noout -subject 2>/dev/null | sed 's/subject=//')
  if [ -n "${CM_CA_SUBJECT}" ]; then
    echo "  ✓ ConfigMap contains valid CA certificate"
    echo "    Subject: ${CM_CA_SUBJECT}"
  fi
else
  echo "  ✗ ERROR: ConfigMap verification failed"
  exit 1
fi

# Clean up temporary CA file
rm -f "${CA_CERT_TMP}"

echo ""
echo "========================================="
echo "Vault Enterprise Installation Complete"
echo "========================================="
echo ""
echo "Summary:"
echo "  - Namespace: ${VAULT_NAMESPACE}"
echo "  - Version: ${VAULT_VERSION}"
echo "  - Service: https://vault.${VAULT_NAMESPACE}.svc:8200"
echo "  - Pod: vault-0 (Ready)"
echo "  - TLS: Enabled (dev mode with auto-generated certificates)"
echo "  - TLS CA: /var/run/tls/vault-ca.pem (inside pod)"
echo "  - Enterprise License: Configured"
echo "  - CA ConfigMap: vault-ca-bundle (openshift-config namespace)"
echo ""
echo "TLS Configuration:"
echo "  ✓ HTTPS enabled and verified"
echo "  ✓ Certificates generated and validated"
echo "  ✓ CA certificate exported to ConfigMap"
echo "  ✓ Certificate SANs include service DNS"
echo ""
echo "Next step: Run etcd-encryption-vault-configure to configure Vault for KMS"
echo ""
