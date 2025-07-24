# Openstack-installer

**An intelligent Bash script that installs OpenStack 2024.2 (Dalmatian) on Ubuntu 24.04 LTS.**

This script aims to be **development-ready**, **idempotent**, and **safe for your existing network configuration**.

---

## Overview

A comprehensive installer that sets up a full OpenStack environment on a **fresh Ubuntu 24.04 LTS** server, including core and supporting services, plus test artifacts so you can verify functionality immediately.

---

## Key Features

### 1) Pre-flight Checks

- Verifies Ubuntu version  
- Checks available memory and disk space  
- Validates network configuration

### 2) Robust Error Handling

- State tracking for **idempotent** execution (safe to re-run)  
- Clear error messages with **line numbers**  
- Configuration validation

### 3) Network Safety

- **Does NOT** modify your existing management network config  
- Validates that the **provider interface has no IP** assigned  
- Preserves SSH / management connectivity

---

## Network Requirements

- **Management Interface**: Must have a **static IP** configured  
  - Example: `ens33` → `10.172.89.10`
- **Provider Interface**: Must have **no IP address** configured  
  - Example: `ens34`

---

## Usage

1. **Download and run the script**

   ```bash
   chmod +x ubuntu-openstack-final.sh
   ./ubuntu-openstack-final.sh
