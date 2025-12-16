"""
Temporal Worker for ORAM-MAW POC

Runs the Temporal worker that executes ORAM-protected workflows.
"""

import asyncio
import os
from temporalio.client import Client
from temporalio.worker import Worker

from activities import (
    configure_enclave,
    store_sensitive_data,
    retrieve_sensitive_data,
    get_acb_metrics,
    ping_enclave,
    health_check
)
from workflows import ORAMSecureWorkflow, BenchmarkWorkflow


TEMPORAL_HOST = os.getenv("TEMPORAL_HOST", "localhost:7233")
TEMPORAL_NAMESPACE = os.getenv("TEMPORAL_NAMESPACE", "confidential-workflow-poc")
TASK_QUEUE = "oram-maw-queue"


async def main():
    """Start the Temporal worker."""
    print(f"[WORKER] Connecting to Temporal at {TEMPORAL_HOST}...")
    
    client = await Client.connect(TEMPORAL_HOST, namespace=TEMPORAL_NAMESPACE)
    
    print(f"[WORKER] Starting worker on queue: {TASK_QUEUE}")
    print("[WORKER] O2RAM-enabled workflows ready")
    
    worker = Worker(
        client,
        task_queue=TASK_QUEUE,
        workflows=[ORAMSecureWorkflow, BenchmarkWorkflow],
        activities=[
            configure_enclave,
            store_sensitive_data,
            retrieve_sensitive_data,
            get_acb_metrics,
            ping_enclave,
            health_check
        ]
    )
    
    await worker.run()


if __name__ == "__main__":
    asyncio.run(main())
