#!/usr/bin/env bash
#
# Secret Rotation Helper
# Generates new GCP service account keys and updates 1Password automatically
#
# Usage:
#   ./hack/rotate-secrets.sh              # Rotate all keys (auto-update 1Password)
#   ./hack/rotate-secrets.sh velero       # Rotate specific key
#   ./hack/rotate-secrets.sh --list       # List service accounts
#   ./hack/rotate-secrets.sh --manual     # Skip 1Password, use clipboard instead
#
set -euo pipefail

GCP_PROJECT="hayden-agencies-infra"
OP_VAULT="Kubernetes"  # 1Password vault name

# Colors (defined early for use in functions)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# -----------------------------------------------------------------------------
# Force fresh GCP login every time (no cached credentials)
# -----------------------------------------------------------------------------

require_gcloud_login() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  GCP Authentication Required${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    # Check if gcloud is installed
    if ! command -v gcloud &> /dev/null; then
        echo -e "${RED}✗ gcloud CLI not found${NC}"
        echo ""
        echo "Install: https://cloud.google.com/sdk/docs/install"
        exit 1
    fi

    # Revoke existing credentials to force fresh login
    echo -e "${YELLOW}Revoking any cached credentials...${NC}"
    gcloud auth revoke --all 2>/dev/null || true

    # Force fresh login
    echo ""
    echo -e "${BLUE}Please login to GCP (opens browser):${NC}"
    echo ""
    if ! gcloud auth login --no-launch-browser=false; then
        echo -e "${RED}✗ GCP login failed${NC}"
        exit 1
    fi

    # Set project
    echo ""
    echo -e "${BLUE}Setting project to: ${GCP_PROJECT}${NC}"
    gcloud config set project "$GCP_PROJECT"

    echo ""
    echo -e "${GREEN}✓ Authenticated as: $(gcloud auth list --filter=status:ACTIVE --format='value(account)')${NC}"
    echo ""
}

# GCP Service Accounts: SA name → 1Password item name
# SA names must match Terraform account_id values in terraform/gcp/*.tf
declare -A GCP_SA_MAP=(
    ["velero"]="velero-gcs"
    ["thanos"]="thanos-objstore"
    ["odoo-pg-backup"]="odoo-objstore"
    ["chatwoot-pg-backup"]="chatwoot-objstore"
    ["nextcloud-backup"]="nextcloud-objstore"
    ["openebs-backup"]="openebs-objstore"
    ["threecx-backup"]="threecx-objstore"
)

# 1Password field names for each item (most use serviceAccount, velero uses credentials)
declare -A OP_FIELD_MAP=(
    ["velero-gcs"]="credentials"
    ["thanos-objstore"]="serviceAccount"
    ["odoo-objstore"]="serviceAccount"
    ["chatwoot-objstore"]="serviceAccount"
    ["nextcloud-objstore"]="serviceAccount"
    ["openebs-objstore"]="serviceAccount"
    ["threecx-objstore"]="serviceAccount"
)
# Note: magento2-pg-backup uses HMAC keys (S3-style), not SA JSON - rotate via GCP Console

# Mode: auto (use op CLI) or manual (use clipboard)
USE_OP_CLI=true

# -----------------------------------------------------------------------------
# 1Password CLI detection and login
# -----------------------------------------------------------------------------
require_op_login() {
    if ! command -v op &>/dev/null; then
        echo -e "${RED}✗ 1Password CLI (op) not found${NC}"
        echo ""
        echo "Install: https://developer.1password.com/docs/cli/get-started/"
        echo "Or run with --manual flag to use clipboard instead"
        exit 1
    fi

    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  1Password Authentication${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    # Check if already signed in
    if op account list &>/dev/null; then
        local account
        account=$(op account list --format=json 2>/dev/null | jq -r '.[0].email // empty')
        if [[ -n "$account" ]]; then
            echo -e "${GREEN}✓ Already signed in as: ${account}${NC}"
            # Verify vault access
            if op vault get "$OP_VAULT" &>/dev/null; then
                echo -e "${GREEN}✓ Vault '${OP_VAULT}' accessible${NC}"
                echo ""
                return 0
            fi
        fi
    fi

    # Need to sign in
    echo -e "${BLUE}Please sign in to 1Password:${NC}"
    if ! eval "$(op signin)"; then
        echo -e "${RED}✗ 1Password login failed${NC}"
        exit 1
    fi

    # Verify vault access
    if ! op vault get "$OP_VAULT" &>/dev/null; then
        echo -e "${RED}✗ Cannot access vault: ${OP_VAULT}${NC}"
        echo "Available vaults:"
        op vault list --format=json | jq -r '.[].name'
        exit 1
    fi

    echo -e "${GREEN}✓ Signed in and vault '${OP_VAULT}' accessible${NC}"
    echo ""
}

# Update 1Password item with new key
update_op_item() {
    local item_name=$1
    local field_name=$2
    local key_file=$3

    echo -e "${BLUE}Updating 1Password: ${item_name}.${field_name}${NC}"

    # Read key content and escape for JSON
    local key_content
    key_content=$(cat "$key_file")

    # Use op item edit to update the field
    if op item edit "$item_name" --vault="$OP_VAULT" "${field_name}=${key_content}" &>/dev/null; then
        echo -e "${GREEN}✓ 1Password updated${NC}"
        return 0
    else
        echo -e "${RED}✗ Failed to update 1Password${NC}"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Clipboard detection - finds available clipboard command (fallback for manual mode)
# -----------------------------------------------------------------------------
CLIPBOARD_CMD=""
detect_clipboard() {
    if command -v pbcopy &>/dev/null; then
        CLIPBOARD_CMD="pbcopy"
    elif command -v wl-copy &>/dev/null; then
        CLIPBOARD_CMD="wl-copy"
    elif command -v xclip &>/dev/null; then
        CLIPBOARD_CMD="xclip -selection clipboard"
    elif command -v xsel &>/dev/null; then
        CLIPBOARD_CMD="xsel --clipboard --input"
    elif command -v clip.exe &>/dev/null; then
        CLIPBOARD_CMD="clip.exe"
    fi
}
detect_clipboard

# -----------------------------------------------------------------------------
# Helper to prompt yes/no
# -----------------------------------------------------------------------------
prompt_yn() {
    local prompt="$1"
    local default="${2:-n}"
    local reply

    if [[ "$default" == "y" ]]; then
        prompt="$prompt [Y/n]: "
    else
        prompt="$prompt [y/N]: "
    fi

    read -r -p "$prompt" reply
    reply="${reply:-$default}"

    [[ "$reply" =~ ^[Yy]$ ]]
}

show_help() {
    echo "Usage: $0 [OPTIONS] [service-account-name]"
    echo ""
    echo "Options:"
    echo "  --manual    Skip 1Password CLI, use clipboard instead"
    echo "  --list      List available service accounts"
    echo "  --help      Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                  # Rotate all keys (auto-update 1Password)"
    echo "  $0 velero           # Rotate only velero key"
    echo "  $0 --manual         # Rotate all, use clipboard instead of op CLI"
    echo "  $0 --manual velero  # Rotate velero, use clipboard"
    echo ""
    echo "Note: magento2-pg-backup uses HMAC keys - rotate via GCP Console."
}

list_accounts() {
    echo -e "${BLUE}Available service accounts:${NC}"
    for sa in "${!GCP_SA_MAP[@]}"; do
        echo "  $sa → 1Password item: ${GCP_SA_MAP[$sa]}"
    done
}

rotate_key() {
    local sa_name=$1
    local op_item="${GCP_SA_MAP[$sa_name]}"
    local sa_email="${sa_name}@${GCP_PROJECT}.iam.gserviceaccount.com"
    local output_file
    output_file=$(mktemp --suffix="-${sa_name}.json")
    chmod 600 "$output_file"

    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Rotating: ${sa_name}${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    # Check if SA exists
    if ! gcloud iam service-accounts describe "$sa_email" &>/dev/null; then
        echo -e "${YELLOW}⚠ Service account not found: ${sa_email}${NC}"
        echo "  You may need to create it first in Terraform"
        return 1
    fi

    # Capture current keys for later cleanup
    local old_keys
    old_keys=$(gcloud iam service-accounts keys list \
        --iam-account="$sa_email" \
        --format="value(name.basename())" \
        --filter="keyType=USER_MANAGED" 2>/dev/null || true)

    # List current keys
    echo -e "${BLUE}Current keys:${NC}"
    if [[ -n "$old_keys" ]]; then
        gcloud iam service-accounts keys list \
            --iam-account="$sa_email" \
            --format="table(name.basename(),validAfterTime,validBeforeTime,keyType)" \
            --filter="keyType=USER_MANAGED" 2>/dev/null
    else
        echo "  (none)"
    fi
    echo ""

    # Create new key
    echo -e "${BLUE}Creating new key...${NC}"
    if gcloud iam service-accounts keys create "$output_file" \
        --iam-account="$sa_email" 2>/dev/null; then
        echo -e "${GREEN}✓ Key created${NC}"
    else
        echo -e "${RED}✗ Failed to create key${NC}"
        return 1
    fi

    # Get the 1Password field name for this item
    local op_field="${OP_FIELD_MAP[$op_item]:-serviceAccount}"

    echo ""
    if [[ "$USE_OP_CLI" == true ]]; then
        # Automatic mode: update 1Password directly
        if update_op_item "$op_item" "$op_field" "$output_file"; then
            echo -e "${GREEN}✓ Key automatically saved to 1Password${NC}"
        else
            echo -e "${YELLOW}⚠ Auto-update failed, falling back to clipboard${NC}"
            USE_OP_CLI=false
        fi
    fi

    if [[ "$USE_OP_CLI" == false ]]; then
        # Manual mode: use clipboard
        echo -e "${YELLOW}┌─────────────────────────────────────────────────────────────┐${NC}"
        echo -e "${YELLOW}│  MANUAL STEP: Update 1Password                              │${NC}"
        echo -e "${YELLOW}└─────────────────────────────────────────────────────────────┘${NC}"
        echo ""
        echo -e "Open 1Password item: ${GREEN}${op_item}${NC}"
        echo -e "Update the ${GREEN}${op_field}${NC} field with the new key."
        echo ""

        # Copy to clipboard if available, otherwise display
        if [[ -n "$CLIPBOARD_CMD" ]]; then
            eval "$CLIPBOARD_CMD" < "$output_file"
            echo -e "${GREEN}✓ Key copied to clipboard${NC}"
            echo ""
            echo -e "${YELLOW}Paste into 1Password now, then press Enter to continue...${NC}"
            read -r
        else
            echo -e "${BLUE}--- BEGIN KEY (copy everything below until END KEY) ---${NC}"
            cat "$output_file"
            echo ""
            echo -e "${BLUE}--- END KEY ---${NC}"
            echo ""
            echo -e "${YELLOW}Copy the key above, paste into 1Password, then press Enter...${NC}"
            read -r
        fi
    fi

    # Securely delete the temp file
    echo -e "${BLUE}Deleting temp key file...${NC}"
    if command -v shred &>/dev/null; then
        shred -u "$output_file" 2>/dev/null && echo -e "${GREEN}✓ Key file shredded${NC}"
    else
        rm -f "$output_file" && echo -e "${GREEN}✓ Key file deleted${NC}"
    fi

    # Offer to delete old keys
    if [[ -n "$old_keys" ]]; then
        echo ""
        echo -e "${YELLOW}Old keys found:${NC}"
        echo "$old_keys" | while read -r key_id; do
            echo "  - $key_id"
        done
        echo ""

        if prompt_yn "Delete old keys now?" "y"; then
            echo "$old_keys" | while read -r key_id; do
                echo -e "${BLUE}Deleting key: ${key_id}${NC}"
                if gcloud iam service-accounts keys delete "$key_id" \
                    --iam-account="$sa_email" --quiet 2>/dev/null; then
                    echo -e "${GREEN}✓ Deleted${NC}"
                else
                    echo -e "${RED}✗ Failed to delete${NC}"
                fi
            done
        else
            echo -e "${YELLOW}Skipped. Delete manually later:${NC}"
            echo -e "  gcloud iam service-accounts keys list --iam-account=${sa_email}"
            echo -e "  gcloud iam service-accounts keys delete KEY_ID --iam-account=${sa_email}"
        fi
    fi

    echo ""
    echo -e "${GREEN}✓ Rotation complete for ${sa_name}${NC}"
    echo ""
}

print_manual_checklist() {
    echo ""
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  OTHER SECRETS (Manual Rotation)${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${BLUE}Magento2 Backup (HMAC Keys):${NC}"
    echo "  1. https://console.cloud.google.com/storage/settings;tab=interoperability"
    echo "  2. Create new HMAC key for magento2-pg-backup@${GCP_PROJECT}.iam.gserviceaccount.com"
    echo "  3. Update 1Password: magento2-objstore → accessKeyId, secretAccessKey"
    echo "  4. Delete old HMAC key"
    echo ""
    echo -e "${BLUE}Cloudflare API Token:${NC}"
    echo "  1. https://dash.cloudflare.com/profile/api-tokens"
    echo "  2. Roll the token"
    echo "  3. Update 1Password: cloudflare → CLOUDFLARE_API_TOKEN"
    echo ""
    echo -e "${BLUE}Cloudflare Tunnel:${NC}"
    echo "  1. https://one.dash.cloudflare.com → Access → Tunnels"
    echo "  2. Get new tunnel token"
    echo "  3. Update 1Password: cloudflare → CLOUDFLARED_TUNNEL_CREDENTIALS"
    echo ""
    echo -e "${BLUE}GitHub App (Actions Runner):${NC}"
    echo "  1. https://github.com/settings/apps"
    echo "  2. Generate new private key"
    echo "  3. Update 1Password: actions-runner → ACTIONS_RUNNER_PRIVATE_KEY"
    echo ""
    echo -e "${BLUE}Google OAuth (Dex):${NC}"
    echo "  1. https://console.cloud.google.com/apis/credentials"
    echo "  2. Reset client secret"
    echo "  3. Update 1Password: dex → clientSecret"
    echo ""
}

# Parse arguments
TARGET="all"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            show_help
            exit 0
            ;;
        --list|-l)
            list_accounts
            exit 0
            ;;
        --manual|-m)
            USE_OP_CLI=false
            shift
            ;;
        *)
            TARGET="$1"
            shift
            ;;
    esac
done

# Authenticate
require_gcloud_login
if [[ "$USE_OP_CLI" == true ]]; then
    require_op_login
fi

# Main execution
case "$TARGET" in
    all)
        echo -e "${BLUE}Rotating all GCP service account keys...${NC}"
        for sa in "${!GCP_SA_MAP[@]}"; do
            rotate_key "$sa" || true
        done
        print_manual_checklist
        ;;
    *)
        if [[ -v "GCP_SA_MAP[$TARGET]" ]]; then
            rotate_key "$TARGET"
        else
            echo -e "${RED}Unknown service account: $TARGET${NC}"
            echo ""
            list_accounts
            exit 1
        fi
        ;;
esac
