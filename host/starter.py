"""
Workflow Starter for ORAM-MAW POC

Triggers ORAM-protected workflows for demonstration.
"""

import asyncio
import os
import sys
import uuid
from temporalio.client import Client

from workflows import ORAMSecureWorkflow, BenchmarkWorkflow


TEMPORAL_HOST = os.getenv("TEMPORAL_HOST", "localhost:7233")
TASK_QUEUE = "oram-maw-queue"


async def run_oram_workflow(config: dict):
    """Run the main ORAM-secure workflow."""
    client = await Client.connect(TEMPORAL_HOST)
    
    workflow_id = f"oram-secure-{uuid.uuid4().hex[:8]}"
    
    print(f"[STARTER] Starting ORAMSecureWorkflow: {workflow_id}")
    
    result = await client.execute_workflow(
        ORAMSecureWorkflow.run,
        config,
        id=workflow_id,
        task_queue=TASK_QUEUE
    )
    
    print(f"[STARTER] Workflow completed!")
    print(f"[STARTER] Result: {result}")
    
    return result


async def run_benchmark(config: dict):
    """Run the benchmark workflow."""
    client = await Client.connect(TEMPORAL_HOST)
    
    workflow_id = f"oram-benchmark-{uuid.uuid4().hex[:8]}"
    
    print(f"[STARTER] Starting BenchmarkWorkflow: {workflow_id}")
    
    result = await client.execute_workflow(
        BenchmarkWorkflow.run,
        config,
        id=workflow_id,
        task_queue=TASK_QUEUE
    )
    
    print(f"[STARTER] Benchmark completed!")
    print(f"\n=== Performance Results ===")
    print(f"ORAM Pool Average: {result.get('oram_avg_ms', 0):.2f} ms")
    print(f"Standard Pool Average: {result.get('standard_avg_ms', 0):.2f} ms")
    print(f"ORAM Overhead Factor: {result.get('overhead_factor', 0):.2f}x")
    
    return result


def load_config() -> dict:
    """Load configuration from environment."""
    import boto3
    
    # Get temporary credentials
    sts = boto3.client('sts')
    credentials = sts.get_session_token()['Credentials']
    
    # Load encrypted TSK
    tsk_path = os.getenv("ENCRYPTED_TSK_PATH", "encrypted-tsk.b64.local")
    with open(tsk_path, 'r') as f:
        encrypted_tsk = f.read().strip()
    
    return {
        "aws_access_key_id": credentials['AccessKeyId'],
        "aws_secret_access_key": credentials['SecretAccessKey'],
        "aws_session_token": credentials['SessionToken'],
        "encrypted_tsk": encrypted_tsk
    }


if __name__ == "__main__":
    config = load_config()
    
    if len(sys.argv) > 1 and sys.argv[1] == "--benchmark":
        asyncio.run(run_benchmark(config))
    else:
        asyncio.run(run_oram_workflow(config))
