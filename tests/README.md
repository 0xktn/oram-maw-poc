# ORAM-MAW Tests

Unit tests for the ORAM-MAW POC components.

## Running Tests

```bash
# Install test dependencies
pip install pytest

# Run all tests
python -m pytest tests/ -v

# Run specific test file
python -m pytest tests/test_oram.py -v

# Run with coverage
pip install pytest-cov
python -m pytest tests/ --cov=enclave --cov-report=html
```

## Test Structure

- `test_oram.py` - Tests for Path ORAM implementation
- `test_acb_routing.py` - Tests for ACB Router and compartmentalization

## Note

These tests run locally without requiring an actual Nitro Enclave.
They test the ORAM logic and routing in isolation.
