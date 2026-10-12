#!/usr/bin/env bash
# Creates the bucket and a dedicated, bucket-only MinIO user for QEVA CRM, using the MinIO
# admin API through the `mc` client. Run it yourself on a machine that can reach MinIO.
#
# It asks for the MinIO ROOT credentials interactively (they are never stored or printed).
# The app secret is generated here and saved to ~/.config/qeva/minio-app-secret (mode 600).
#
# Usage:
#   deploy/minio-setup.sh
#
# Optional overrides (environment variables):
#   MINIO_URL   default https://s3.qeva.xyz
#   BUCKET      default crm-qeva
#   APP_KEY     default qeva-crm      (becomes AWS_ACCESS_KEY_ID)
#   POLICY      default crm-qeva-rw

set -euo pipefail

MINIO_URL="${MINIO_URL:-https://s3.qeva.xyz}"
BUCKET="${BUCKET:-crm-qeva}"
APP_KEY="${APP_KEY:-qeva-crm}"
POLICY="${POLICY:-crm-qeva-rw}"
SECRET_FILE="${HOME}/.config/qeva/minio-app-secret"

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Isolated mc config so no alias (and no root credential) is left behind in ~/.mc.
WORKDIR="$(mktemp -d)"
export MC_CONFIG_DIR="${WORKDIR}/mc"
cleanup() { rm -rf "${WORKDIR}"; }
trap cleanup EXIT

# 1. Get mc (use an existing one if present).
if command -v mc >/dev/null 2>&1; then
  MC="$(command -v mc)"
else
  log "Downloading the MinIO client (mc)"
  MC="${WORKDIR}/mc-bin"
  curl -sSf -o "${MC}" https://dl.min.io/client/mc/release/linux-amd64/mc
  chmod +x "${MC}"
fi

# 2. Ask for the root credentials (input is hidden for the password).
log "MinIO root credentials for ${MINIO_URL}"
read -r -p "Root user: " ROOT_USER
read -r -s -p "Root password: " ROOT_PASS; echo
[ -n "${ROOT_USER}" ] && [ -n "${ROOT_PASS}" ] || die "root user and password are required"

"${MC}" alias set qeva-root "${MINIO_URL}" "${ROOT_USER}" "${ROOT_PASS}" >/dev/null \
  || die "could not connect to ${MINIO_URL} with those credentials"
unset ROOT_USER ROOT_PASS

# 3. Bucket.
log "Creating bucket ${BUCKET}"
"${MC}" mb --ignore-existing "qeva-root/${BUCKET}"

# 4. Bucket-only policy (what ActiveStorage needs, nothing else).
log "Creating policy ${POLICY}"
POLICY_FILE="${WORKDIR}/policy.json"
cat > "${POLICY_FILE}" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetBucketLocation",
        "s3:ListBucket",
        "s3:ListBucketMultipartUploads",
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts"
      ],
      "Resource": ["arn:aws:s3:::${BUCKET}", "arn:aws:s3:::${BUCKET}/*"]
    }
  ]
}
JSON
"${MC}" admin policy create qeva-root "${POLICY}" "${POLICY_FILE}" >/dev/null 2>&1 \
  || "${MC}" admin policy update qeva-root "${POLICY}" "${POLICY_FILE}" >/dev/null

# 5. Dedicated user with a generated secret.
log "Creating user ${APP_KEY}"
if "${MC}" admin user info qeva-root "${APP_KEY}" >/dev/null 2>&1; then
  die "user ${APP_KEY} already exists. Remove it first (mc admin user remove qeva-root ${APP_KEY}) or set APP_KEY to another name."
fi

APP_SECRET="$(openssl rand -hex 24)"
"${MC}" admin user add qeva-root "${APP_KEY}" "${APP_SECRET}" >/dev/null
"${MC}" admin policy attach qeva-root "${POLICY}" --user "${APP_KEY}" >/dev/null

umask 077
mkdir -p "$(dirname "${SECRET_FILE}")"
printf '%s\n' "${APP_SECRET}" > "${SECRET_FILE}"
chmod 600 "${SECRET_FILE}"

# 6. Verify the app user sees its bucket and nothing else.
log "Verifying the app user"
"${MC}" alias set qeva-app "${MINIO_URL}" "${APP_KEY}" "${APP_SECRET}" >/dev/null
"${MC}" ls "qeva-app/${BUCKET}" >/dev/null && echo "bucket ${BUCKET}: OK"
if "${MC}" ls qeva-app >/dev/null 2>&1; then
  echo "WARNING: the app user can list all buckets; check the policy."
else
  echo "listing other buckets: denied (OK)"
fi

log "Done"
cat <<EOF
Next steps (the secret itself is NOT printed):
  1. Create the Swarm secret qeva_env_v2 with the content of qeva_env plus:
       AWS_ACCESS_KEY_ID=${APP_KEY}
       AWS_SECRET_ACCESS_KEY=<contents of ${SECRET_FILE}>
  2. In Portainer, stack variables:
       QEVA_ENV_SECRET=qeva_env_v2
       ACTIVE_STORAGE_SERVICE=amazon
       AWS_ENDPOINT=${MINIO_URL}
       AWS_S3_FORCE_PATH_STYLE=true
  3. Redeploy the stack and upload an attachment to test.
  4. Rotate the MinIO root password when you are done.
EOF
