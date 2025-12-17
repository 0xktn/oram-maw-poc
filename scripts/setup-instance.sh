#!/bin/bash
# Instance Setup Script
# Run this on the EC2 instance after launch

set -e

# Colors
GREEN='\033[0;32m'
NC='\033[0m'
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }

log_info "Updating system packages..."
sudo dnf update -y

log_info "Installing Nitro Enclaves CLI..."
sudo dnf install -y aws-nitro-enclaves-cli aws-nitro-enclaves-cli-devel

log_info "Starting Nitro Enclaves allocator..."
sudo systemctl start nitro-enclaves-allocator.service
sudo systemctl enable nitro-enclaves-allocator.service

log_info "Adding user to 'ne' group..."
sudo usermod -aG ne ec2-user

log_info "Configuring enclave allocator..."
sudo cp /etc/nitro_enclaves/allocator.yaml /etc/nitro_enclaves/allocator.yaml.bak
sudo tee /etc/nitro_enclaves/allocator.yaml > /dev/null << 'EOF'
---
memory_mib: 2048
cpu_count: 2
EOF
sudo systemctl restart nitro-enclaves-allocator.service

log_info "Installing Docker..."
sudo dnf install -y docker
sudo systemctl start docker
sudo systemctl enable docker
sudo usermod -aG docker ec2-user

log_info "Verifying installation..."
nitro-cli --version
docker --version

echo ""
echo "=========================================="
echo "Setup complete!"
echo "=========================================="
echo ""
echo "Run 'newgrp ne && newgrp docker' to apply group changes"
echo "Or log out and back in"
