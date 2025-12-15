"""
Temporal Workflows for ORAM-MAW POC

Demonstrates ORAM-protected state transfer between agents
with compartmentalized security based on data sensitivity.
"""

from datetime import timedelta
from temporalio import workflow

with workflow.unsafe.imports_passed_through():
    from activities import (
        configure_enclave,
        store_sensitive_data,
        retrieve_sensitive_data,
        get_acb_metrics,
        ping_enclave,
        health_check
    )


@workflow.defn
class ORAMSecureWorkflow:
    """
    Workflow demonstrating O2RAM-protected state transfer.
    
    This workflow shows how:
    1. Session keys are stored with ORAM protection (hidden access patterns)
    2. Workflow state is stored with standard encryption (high performance)
    3. Access patterns for sensitive data cannot be observed by the host
    """
    
    @workflow.run
    async def run(self, config: dict) -> dict:
        """
        Execute the ORAM-protected workflow.
        
        Args:
            config: Contains AWS credentials and encrypted TSK
            
        Returns:
            Workflow result with ACB metrics
        """
        workflow.logger.info("Starting ORAM-Secure Workflow")
        
        # Step 1: Configure enclave with O2RAM
        config_result = await workflow.execute_activity(
            configure_enclave,
            config,
            start_to_close_timeout=timedelta(seconds=60)
        )
        
        if config_result.get("status") != "ok":
            return {"status": "error", "stage": "configure", "details": config_result}
        
        workflow.logger.info("Enclave configured with O2RAM protection")
        
        # Step 2: Agent A stores a session key (ORAM-protected)
        # Access pattern is hidden - observer cannot tell which key is accessed
        session_key_result = await workflow.execute_activity(
            store_sensitive_data,
            args=["session_key:agent_a_session", "secret_session_value_12345"],
            start_to_close_timeout=timedelta(seconds=30)
        )
        
        workflow.logger.info(
            f"Session key stored via {session_key_result.get('routed_to')} pool"
        )
        
        # Step 3: Store workflow state (Standard pool - high performance)
        # Access pattern is visible, but that's acceptable for non-sensitive data
        state_result = await workflow.execute_activity(
            store_sensitive_data,
            args=["workflow:state_checkpoint_1", '{"step": 1, "status": "in_progress"}'],
            start_to_close_timeout=timedelta(seconds=30)
        )
        
        workflow.logger.info(
            f"Workflow state stored via {state_result.get('routed_to')} pool"
        )
        
        # Step 4: Agent B retrieves session key (ORAM-protected)
        # Even though we're accessing the same key, pattern is obfuscated
        retrieved = await workflow.execute_activity(
            retrieve_sensitive_data,
            args=["session_key:agent_a_session"],
            start_to_close_timeout=timedelta(seconds=30)
        )
        
        workflow.logger.info(
            f"Session key retrieved via {retrieved.get('routed_from')} pool"
        )
        
        # Step 5: Store another ephemeral secret (ORAM-protected)
        await workflow.execute_activity(
            store_sensitive_data,
            args=["ephemeral:temp_token", "short_lived_token_xyz"],
            start_to_close_timeout=timedelta(seconds=30)
        )
        
        # Step 6: Store more workflow metadata (Standard pool)
        await workflow.execute_activity(
            store_sensitive_data,
            args=["metadata:agent_b_processed", '{"completed": true}'],
            start_to_close_timeout=timedelta(seconds=30)
        )
        
        # Step 7: Get final ACB metrics
        metrics = await workflow.execute_activity(
            get_acb_metrics,
            start_to_close_timeout=timedelta(seconds=30)
        )
        
        workflow.logger.info("ORAM-Secure Workflow completed")
        
        return {
            "status": "ok",
            "message": "Workflow completed with O2RAM protection",
            "session_key_value": retrieved.get("value"),
            "acb_metrics": metrics
        }


@workflow.defn
class BenchmarkWorkflow:
    """
    Benchmark workflow to measure ORAM vs Standard pool performance.
    
    Performs multiple accesses to both pools and reports latency metrics.
    """
    
    @workflow.run
    async def run(self, config: dict) -> dict:
        """Run performance benchmark."""
        import time
        
        # Configure enclave
        await workflow.execute_activity(
            configure_enclave,
            config,
            start_to_close_timeout=timedelta(seconds=60)
        )
        
        results = {
            "oram_operations": [],
            "standard_operations": []
        }
        
        # Benchmark ORAM pool (sensitive data)
        for i in range(10):
            start = time.time()
            await workflow.execute_activity(
                store_sensitive_data,
                args=[f"session_key:bench_{i}", f"value_{i}"],
                start_to_close_timeout=timedelta(seconds=30)
            )
            elapsed = time.time() - start
            results["oram_operations"].append(elapsed)
        
        # Benchmark Standard pool
        for i in range(10):
            start = time.time()
            await workflow.execute_activity(
                store_sensitive_data,
                args=[f"benchmark:data_{i}", f"value_{i}"],
                start_to_close_timeout=timedelta(seconds=30)
            )
            elapsed = time.time() - start
            results["standard_operations"].append(elapsed)
        
        # Calculate averages
        oram_avg = sum(results["oram_operations"]) / len(results["oram_operations"])
        std_avg = sum(results["standard_operations"]) / len(results["standard_operations"])
        
        return {
            "status": "ok",
            "oram_avg_ms": oram_avg * 1000,
            "standard_avg_ms": std_avg * 1000,
            "overhead_factor": oram_avg / std_avg if std_avg > 0 else 0,
            "raw_results": results
        }
