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
├── bundle/                             # Databricks Asset Bundle (Part 8)
│   ├── configs/
│   │   ├── dev.yaml                    # Dev: catalog, cluster size, secrets, storage
│   │   ├── acc.yaml                    # Acc: larger cluster, INFO logging
│   │   └── prod.yaml                   # Prod: max workers, WARNING logging only
│   └── resources/
│       ├── jobs/
│       │   └── tvmaze_pipeline.yml     # 3-task job definition (bronze → silver → gold)
│       └── clusters/
│           └── pipeline_cluster.yml   # Reusable cluster definition
│
├── configs/                            # ADF environment configs (no secrets)
│   ├── dev.json
│   ├── acc.json
│   └── prod.json
│
├── infra/                              # Terraform IaC — all infrastructure as code
│   ├── account/                        # Databricks account-level resources (groups, users)
│   ├── azure/                          # Azure resources (ADF, Key Vault, Storage, RBAC)
│   └── databricks/                     # Workspace-level resources (catalogs, grants, clusters)
│
├── tests/                              # Data quality tests
│   └── test_data_quality.py
│
├── deliverables/                       # Screenshots and evidence per part
│   ├── part1/ … part8/
│
├── databricks.yml                      # DAB root config — targets: dev / acc / prod
├── azure-pipelines.yml                 # Azure DevOps CI/CD pipeline (5 stages)
└── README.md
```

---

## Git Branching Strategy

```
feature/*  ──►  develop  ──►  main
```

| Branch      | Purpose               | Pipeline stages triggered    |
| ----------- | --------------------- | ---------------------------- |
| `feature/*` | Individual work items | validate + test only         |
| `develop`   | Integration / staging | validate + test + deploy_dev |
| `main`      | Production-ready code | Full pipeline (all 5 stages) |

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

| Setting       | Dev                         | Acc                         | Prod                         |
| ------------- | --------------------------- | --------------------------- | ---------------------------- |
| Catalog       | `de_assessment_dev`         | `de_assessment_acc`         | `de_assessment_prod`         |
| Notebook path | `/Shared/de-assessment/dev` | `/Shared/de-assessment/acc` | `/Shared/de-assessment/prod` |
| Log level     | `DEBUG`                     | `INFO`                      | `WARNING`                    |
| Data volume   | Small/test                  | Realistic                   | Live                         |

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

| Module             | What it manages                                                      |
| ------------------ | -------------------------------------------------------------------- |
| `infra/azure`      | Resource group, ADF, Key Vault, Storage Account, RBAC, Log Analytics |
| `infra/databricks` | Unity Catalog, schemas, grants, cluster policies                     |
| `infra/account`    | Databricks account groups and SP registration                        |

Remote state is stored in Azure Blob Storage (`deassessmentd06fabcc/tfstate`).

---

## Part 8 — Databricks Asset Bundles

### Bundle Structure

```
bundle/
├── configs/
│   ├── dev.yaml     # Dev environment: 1 worker, DEBUG logging, de_assessment_dev catalog
│   ├── acc.yaml     # Acc environment: 2 workers, INFO logging, de_assessment_acc catalog
│   └── prod.yaml    # Prod environment: 4 workers, WARNING logging, de_assessment_prod catalog
└── resources/
    ├── jobs/
    │   └── tvmaze_pipeline.yml   # 3-task job: bronze → silver → gold
    └── clusters/
        └── pipeline_cluster.yml  # Cluster definition referenced by the job
databricks.yml                    # Root bundle config with targets for dev / acc / prod
```

### How to Deploy

```bash
# Validate (no changes made)
databricks bundle validate -t dev

# Deploy notebooks + job to Databricks workspace
databricks bundle deploy -t dev

# Run the pipeline end-to-end
databricks bundle run tvmaze_pipeline -t dev
```

### Explanation How Databricks Asset Bundles Simplify Enterprise Deployment

**Databricks Asset Bundles (DAB)** treat your Databricks workspace as code. Instead of manually clicking through the UI or writing ad-hoc deployment scripts, everything — notebooks, jobs, cluster configs, and permissions — is declared in YAML, stored in Git, and deployed with a single command.

**Key enterprise benefits:**

- **Reproducibility** — any environment (dev/acc/prod) can be recreated from the same codebase with `bundle deploy -t <env>`
- **Environment parity** — catalog names, cluster sizes, and log levels are parameterised per target; the code never changes
- **Version control** — job definitions live alongside the notebooks that power them, so changes are reviewable in PRs and rollbacks are a `git revert`
- **CI/CD native** — `bundle validate` + `bundle deploy` replace entire custom deploy scripts; one pipeline step covers everything
- **No config drift** — every deploy is idempotent and declarative; the workspace always reflects what's in Git

---

## Infrastructure as Code

All Azure and Databricks resources are fully managed via Terraform. No manual portal configuration is required. See `infra/` for the full module breakdown.

---

## Quickstart

```bash
# 1. Authenticate
az login

# 2. Apply Azure infrastructure (ADF, Key Vault, Storage, RBAC)
cd infra/azure
terraform init
terraform apply -var="deployer_sp_object_id=<your-sp-object-id>"

# 3. Apply Databricks workspace resources (catalogs, grants, clusters)
cd ../databricks
terraform init
terraform apply

# 4. Validate and deploy the Asset Bundle to dev
cd ../..
databricks bundle validate -t dev
databricks bundle deploy -t dev

# 5. Run the TVMaze pipeline end-to-end
databricks bundle run tvmaze_pipeline -t dev
```
