"""
Workflow Starter for ORAM-MAW POC

Triggers ORAM-protected workflows for demonstration.
"""

import asyncio
import sys
import os
import uuid
import json
import logging
from temporalio.client import Client

from workflows import ORAMSecureWorkflow, BenchmarkWorkflow

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


TEMPORAL_HOST = os.getenv("TEMPORAL_HOST", "localhost:7233")
TEMPORAL_NAMESPACE = os.getenv("TEMPORAL_NAMESPACE", "confidential-workflow-poc")
TASK_QUEUE = "oram-maw-queue"


async def run_oram_workflow(config: dict):
    """Run the main ORAM-secure workflow."""
    client = await Client.connect(TEMPORAL_HOST, namespace=TEMPORAL_NAMESPACE)
    
    workflow_id = f"oram-secure-{uuid.uuid4().hex[:8]}"
    
    logger.info("Starting workflow...")
    
    result = await client.execute_workflow(
        ORAMSecureWorkflow.run,
        config,
        id=workflow_id,
        task_queue=TASK_QUEUE
    )
    
    logger.info(f"Workflow Result: {result}")
    
    return result


async def run_benchmark(config: dict):
    """Run the benchmark workflow."""
    client = await Client.connect(TEMPORAL_HOST, namespace=TEMPORAL_NAMESPACE)
    
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


def load_config():
    """Load configuration from environment and AWS"""
    import boto3
    
    # Use EC2 instance profile credentials directly
    session = boto3.Session(region_name=os.getenv('AWS_REGION', 'ap-southeast-1'))
    credentials = session.get_credentials()
    
    # Load encrypted TSK - use absolute path
    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_root = os.path.dirname(script_dir)
    tsk_path = os.getenv("ENCRYPTED_TSK_PATH", os.path.join(project_root, "encrypted-tsk.b64"))
    with open(tsk_path, 'r') as f:
        encrypted_tsk = f.read().strip()
    
    return {
        'temporal_host': os.getenv('TEMPORAL_HOST', 'localhost:7233'),
        'temporal_namespace': os.getenv('TEMPORAL_NAMESPACE', 'confidential-workflow-poc'),
        'aws_region': os.getenv('AWS_REGION', 'ap-southeast-1'),
        'aws_access_key_id': credentials.access_key,
        'aws_secret_access_key': credentials.secret_key,
        'aws_session_token': credentials.token,
        "encrypted_tsk": encrypted_tsk
    }


if __name__ == "__main__":
    config = load_config()
    
    if len(sys.argv) > 1 and sys.argv[1] == "--benchmark":
        asyncio.run(run_benchmark(config))
    else:
        asyncio.run(run_oram_workflow(config))
