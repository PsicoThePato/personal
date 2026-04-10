# Deploy bot to Oracle Cloud VM
deploy:
    ssh-add -t 60 ~/.ssh/id_ed25519 && ansible-playbook -i infra/inventory.ini infra/playbook.yml

# Run bot locally
bot:
    cd kbase_bot && set -a && source .env && set +a && mix run --no-halt

# Re-index QMD
index:
    cd kbase_bot && qmd update && qmd embed

# Destroy VM
destroy:
    cd infra && tofu destroy
