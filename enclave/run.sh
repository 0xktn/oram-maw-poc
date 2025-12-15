#!/bin/sh
# Enclave startup script
# Starts the Python application and handles cleanup

echo "[ENCLAVE] Starting run.sh..."

# Start the Python application
python3.11 /app/app.py
