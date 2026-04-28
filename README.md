# ABN AMRO DE Assessment

End-to-end data engineering solution built on Azure Databricks, Azure Data Factory, Unity Catalog, and Azure DevOps.

---

## Repository Structure

```
de-assessment/
│
├── notebooks/                          # Databricks notebooks (bronze → silver → gold)
│   ├── 01_bronze_ingestion.ipynb       # Raw ingestion from TVMaze API
│   ├── 02_silver_transformation.ipynb  # Cleaning and typing
│   └── 03_gold_aggregation.ipynb       # Business-level aggregations and fact table
│
├── configs/                            # Environment-specific configuration (no secrets)
│   ├── dev.json                        # Dev: small/test data, DEBUG logging
│   ├── acc.json                        # Acc: realistic data, validation gate
│   └── prod.json                       # Prod: live data, WARNING logging only
│
├── infra/                              # Terraform IaC — all infrastructure as code
│   ├── account/                        # Databricks account-level resources (groups, users)
│   ├── azure/                          # Azure resources (ADF, Key Vault, Storage, RBAC)
│   └── databricks/                     # Workspace-level resources (catalogs, grants, clusters)
│
├── deliverables/                       # Screenshots and evidence per part
│   ├── part1/ … part6/
│
├── azure-pipelines.yml                 # Azure DevOps CI/CD pipeline
└── README.md
```

---

## Git Branching Strategy

```
feature/*  ──►  develop  ──►  main
```

| Branch | Purpose | Pipeline stages triggered |
|---|---|---|
| `feature/*` | Individual work items | validate + test only |
| `develop` | Integration / staging | validate + test + deploy_dev |
| `main` | Production-ready code | Full pipeline (all 5 stages) |

**Workflow:**
1. Engineer creates a `feature/` branch from `develop`
2. Work is done and a Pull Request is opened into `develop`
3. Pipeline runs validate + test on the PR (feedback loop)
4. After review and merge to `develop`, deploy_dev runs automatically
5. When ready for production, `develop` is merged into `main` via PR
6. Pipeline runs the full flow: dev → acc (manual approval) → prod (manual approval)

---

## CI/CD Pipeline Overview

The pipeline has 5 stages:

```
validate → test → deploy_dev → deploy_acc → deploy_prod
```

### Stage 1 — Validate
- Runs `terraform validate` on all 3 modules (`account`, `azure`, `databricks`)
- No backend connection — fast syntax and config check
- Runs on all branches

### Stage 2 — Test
- Uploads `test_data_quality.py` to Databricks `/Shared/ci/`
- Submits a one-time cluster job via the Runs Submit API
- Polls until complete, fails if tests fail
- `continueOnError: true` — a test failure doesn't block deployment (visible warning)
- Runs on all branches

### Stage 3 — Deploy Dev
- Deploys notebooks to `/Shared/de-assessment/dev/` in the Databricks workspace
- Runs `terraform apply` for `infra/azure` with `environment=dev`
- Rotates the Databricks PAT in Key Vault
- Runs on any branch

### Stage 4 — Deploy Acc
- Deploys notebooks to `/Shared/de-assessment/acc/`
- Runs `terraform apply` with `environment=acc`
- Gated: only runs on `main` branch + requires manual approval in ADO environment `de-assessment-acc`

### Stage 5 — Deploy Prod
- Deploys notebooks to `/Shared/de-assessment/prod/`
- Runs `terraform apply` with `environment=prod`
- Gated: only runs after acc **succeeds** (not just skipped) + `main` branch + manual approval in `de-assessment-prod`

---

## Notebook Promotion (Dev → Acc → Prod)

Promotion means **the same notebook code moves through environments** with different configuration injected — no logic changes between environments.

### How it works

Each deploy stage:
1. Reads `configs/<environment>.json` to get the environment-specific notebook path and catalog
2. Uploads the notebooks from `notebooks/` to the environment-specific Databricks path
3. Passes that path into Terraform so ADF points to the correct location

```
configs/dev.json   → notebook_deploy_path: /Shared/de-assessment/dev
configs/acc.json   → notebook_deploy_path: /Shared/de-assessment/acc
configs/prod.json  → notebook_deploy_path: /Shared/de-assessment/prod
```

ADF always runs the notebooks from the path matching the current environment. There is no manual copy step — the pipeline handles promotion automatically when a stage runs.

### What changes between environments

| Setting | Dev | Acc | Prod |
|---|---|---|---|
| Catalog | `de_assessment_dev` | `de_assessment_acc` | `de_assessment_prod` |
| Notebook path | `/Shared/de-assessment/dev` | `/Shared/de-assessment/acc` | `/Shared/de-assessment/prod` |
| Log level | `DEBUG` | `INFO` | `WARNING` |
| Data volume | Small/test | Realistic | Live |

**The notebook code itself does not change.** Parameters are injected via the config at deploy time.

---

## Key Vault Integration

No secrets are stored in code or in the repository.

- **Variable group** `de-assessment-kv` is linked to Azure Key Vault `kv-de-assessment` in ADO
- Secrets are injected into pipeline steps at runtime as environment variables:
  - `databricks-pat` — Databricks personal access token (rotated by deploy_dev)
  - `databricks-sp-client-id` — Deployer service principal client ID
  - `databricks-sp-client-secret` — Deployer service principal secret
- The deployer SP holds `Key Vault Secrets Officer` on the vault — rotation is fully automated

---

## Infrastructure (Terraform)

All Azure and Databricks resources are managed as code in `infra/`:

| Module | What it manages |
|---|---|
| `infra/azure` | Resource group, ADF, Key Vault, Storage Account, RBAC, Log Analytics |
| `infra/databricks` | Unity Catalog, schemas, grants, cluster policies |
| `infra/account` | Databricks account groups and SP registration |

Remote state is stored in Azure Blob Storage (`deassessmentd06fabcc/tfstate`).

---

## Running Locally

```bash
# Authenticate
az login

# Apply Azure infrastructure
cd infra/azure
terraform init
terraform apply -var="deployer_sp_object_id=<your-object-id>"

# Apply Databricks resources
cd ../databricks
terraform init
terraform apply
```
