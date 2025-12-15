# ORAM-MAW Enclave Dockerfile
# Minimal Amazon Linux 2023 image with O2RAM support

FROM amazonlinux:2023

# Install Python and dependencies
RUN dnf install -y python3.11 python3.11-pip && dnf clean all

# Copy KMS attestation tools (will be added during build)
COPY kmstool_enclave_cli /usr/bin/
COPY libnsm.so /usr/lib64/

# Setup application directory
WORKDIR /app

# Install Python packages
COPY enclave/requirements.txt .
RUN pip3.11 install --no-cache-dir -r requirements.txt

# Copy ORAM and ACB modules
COPY enclave/oram/ ./oram/
COPY enclave/acb/ ./acb/

# Copy main application
COPY enclave/app.py enclave/run.sh ./
RUN chmod +x run.sh

# Start enclave application
CMD ["/app/run.sh"]
