#!/bin/bash

# Install dependencies
forge install --no-commit OpenZeppelin/openzeppelin-contracts
forge install --no-commit Uniswap/v4-core
forge install --no-commit Uniswap/v4-periphery

# Try to build
forge build 