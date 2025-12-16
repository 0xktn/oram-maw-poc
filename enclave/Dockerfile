# Use pre-built kmstool image from GHCR
FROM ghcr.io/0xktn/kmstool:v0.4.3 AS builder

# Final stage: Amazon Linux 2023 runtime
FROM public.ecr.aws/amazonlinux/amazonlinux:2023

# Install runtime dependencies
RUN dnf install -y python3.11 python3.11-pip findutils && dnf clean all

# Copy built artifacts from pre-built image
COPY --from=builder /usr/lib64/libnsm.so /usr/lib64/libnsm.so
COPY --from=builder /usr/bin/kmstool_enclave_cli /usr/bin/kmstool_enclave_cli

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
