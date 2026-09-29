# 🏭 Lab Equipment Onboarding System (IaC)

This directory manages the **Infrastructure as Code (IaC)** layer for onboarding new pilot plants, reactors, and testing rigs to the lab's operational database. By using structured YAML files, it ensures a highly scalable, developer-agnostic onboarding process.

---

## 📂 Directory Layout

```text
onboarding/
├── README.md               # This instruction reference
├── onboard.py              # Secure automation script (Python 3)
└── configurations/         # Storage home for raw machine configurations
    ├── aem_electrolyser_01.yaml
    └── biomass_pyrolyser_01.yaml
```

---

## ⚡ Quick Start: Onboarding a New System

When a new PLC or data logger needs to join the laboratory network, follow these exact steps:

### Step 1: Create the System Profile Configuration File
Generate a new text file inside the `configurations/` folder naming it after your unique asset token ID (e.g., `biomass_pyrolyser_01.yaml`). Utilize the matching layout format:

```yaml
asset:
  id: "biomass_pyrolyser_01"
  name: "Biomass Pyrolyser V1 Rig"
  location_zone: "PILOT_PLANT_B"

plc:
  ip_address: "192.168.1.205"
  port: 102
  data_block: "DB50"

tags:
  - name: "TT_101"
    address_offset: "DBD0"
    description: "Pyrolyser Bed Core Temperature"
    data_type: "float" # Enforced primitives: 'float', 'boolean', 'text'

  - name: "VALVE_STATUS"
    address_offset: "DBX4.0"
    description: "Main Feed Isolation Valve State"
    data_type: "boolean"
```

### Step 2: Run the Secure Automated Registration Script
Log into the central Linux server command line, navigate to the deployment workspace, load the platform's `.env` profile credentials into your session memory, and pass the configuration file target to the script:

```bash
# Move to the onboarding workspace directory
cd /opt/lab-iot-platform

# Securely inject server credentials into terminal session memory
export $(cat .env | xargs)

# Run the automated database synchronization tool
python onboarding/onboard.py onboarding/configurations/biomass_pyrolyser_01.yaml
```

---

## ⚙️ What the Automation Script Executes

1. **Relational Database Synchronization:** Natively injects rows into the `platform_data.assets` and `platform_data.asset_tags` relational schema tables inside TimescaleDB. If tags already exist, it securely syncs metadata modifications seamlessly (`ON CONFLICT DO UPDATE`).
2. **Edge Asset Compilation:** Generates a custom configuration file titled `telegraf_<asset_id>.conf` inside the working directory path.
3. **Client Configuration Hand-off:** The onboarding engineer copies this clean text output configuration and saves it onto the target plant floor **Raspberry Pi 5** instance as its active `/etc/telegraf/telegraf.conf` layer to start streaming real-time metrics instantly.

---

## 🛡️ Security Parameters & Standards

* **Credential Concealment:** The source file `onboard.py` features absolutely zero plaintext credentials or database access secrets. It dynamically queries server runtime environments (`os.getenv`).
* **Tag Primitive Constraints:** To ensure performance benchmarks for AI pipelines (e.g., Celery Bayesian Optimization workers), data types are restricted to strict primitives: `float`, `boolean`, and `text`. Integer channels use `float` to guarantee zero mathematical data degradation.
