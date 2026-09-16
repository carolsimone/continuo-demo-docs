# continuo-demo-docs

A reference **dbt producer** for [continuo](https://github.com/carolsimone/continuo)'s blue/green release pipeline. It owns several dbt services, builds their images, and drives a continuo release from CD — the worked example of how any consumer's CD integrates with continuo.

## Reference implementation of the public "loading releases" interface

This repo is the **reference external integration** for continuo's public release-loading contract. It is a deliberate, independent reimplementation of that contract: it shares **no code** with continuo internals — no Go packages, no shared client library. Everything here (the `POST /releases` body, the bootstrap detection) is rebuilt from the contract alone. That duplication is the point: it proves the contract is self-describing enough for an outside team to integrate against without reading continuo's source.

The authoritative contract is continuo's `release-controller` HTTP API (`POST /releases`, `GET /releases/{id}`, `GET /current-prod`), documented in the continuo repo. If this README and that documentation ever disagree, the continuo docs are authoritative — open an issue against continuo or this repo.

## What it does

Each service is either a **dbt project** (`dbt_project.yml`) or a **python-node service** (a `contracts/` directory instead — see `services/service-py/`). On every push to `services/**` (or manual dispatch), `.github/workflows/release.yml` detects which kind the single changed service is and adapts:

1. **Builds + pushes** the one changed service's image to Docker Hub as `<DOCKERHUB_USERNAME>/<service>:<short-sha>` (+ `:latest`), for both `linux/amd64` and `linux/arm64`. The name/tag is the contract: continuo's executor launches dbt jobs as `<DOCKERHUB_USERNAME>/<service_name>:<image_tag>`. Both architectures are built because the *pulling cluster* decides which one it needs, and a single-architecture image is unpullable everywhere else — an arm64 node rejects an amd64-only manifest with `no matching manifest for linux/arm64`, which is what an Apple Silicon laptop running a local cluster hits. Each service image is **self-contained** — there is no shared base image, so a single-service change rebuilds only that service. Validation runs in a continuo-owned image, so team images carry no validator.
2. **Python services only**: before the image build, `continuo-runtime lint`/`validate`/`merge` (from [continuo-python-runtime](https://github.com/carolsimone/continuo-python-runtime)) lint the scripts, validate the contracts against the install's postgres dialect, and merge them into the wire `contract.yaml` continuo's manifest side recomputes hashes against. That file is uploaded to `s3://continuo-dev/<service>/<release_id>/contract.yaml` before the release is posted — continuo does no existence check, so the upload must land first.
3. **Drives the release** (`scripts/release.sh`): calls continuo's release-controller API — reads `GET /current-prod` to detect bootstrap, `POST`s the candidate to `/releases`, then **polls `GET /releases/{id}` to a terminal status — failing the deploy on `rejected`**. For a dbt service, continuo compiles the changed service and validates the full topology before promoting; for a python service, continuo parses the uploaded `contract.yaml` instead — there is no compile leg. (Transport/access details are internal to continuo and intentionally omitted here.)

### The release contract (what `scripts/release.sh` sends)

continuo models a release as a **single changed service**. The request body is:

```json
{"release_id": "rel-<sha>-<run>", "service": "service-3", "image_tag": "<sha>", "bootstrap": false, "repo": "<owner>/<repo>", "commit_sha": "<full-sha>"}
```

For a python service the body gains one field, and `image_tag` is a full pullable registry ref rather than a bare tag (continuo runs a python `image_tag` verbatim; a dbt `image_tag` is composed into a pull ref by continuo itself):

```json
{"release_id": "rel-<sha>-<run>", "service": "service-py", "image_tag": "docker.io/<user>/service-py:<sha>", "bootstrap": false, "repo": "<owner>/<repo>", "commit_sha": "<full-sha>", "kind": "python"}
```

- `service` and `image_tag` are **single values**, not maps. `repo` and `commit_sha` identify the source push (`github.repository` / `github.sha`). There is **no `service_metadata.json` sidecar** for dbt services; the image tag travels in this body, not in S3.
- The controller replies `202 Accepted` with `{"release_id": "...", "status": "received"}`.
- The script then polls `GET /releases/<release_id>` until `status` is terminal: `promoted` (success) or `rejected` (failure). For a dbt release the controller reconstructs the full manifest set via the live `service_prod` pointers, with manifests produced by continuo's internal compile leg. For a python release it reads the `contract.yaml` already uploaded to S3 (step 2 above).

### First run = bootstrap

`release.sh` sets `bootstrap:true` automatically when `GET /current-prod` reports no current release (`current_prod_release_id` empty). A bootstrap release **promotes without validation** — necessary because, against an empty `current_prod`, normal validation rejects every cross-service upstream as new. Every subsequent run posts `bootstrap:false` and goes through validation. (Bootstrap promotes whatever topology it carries, so the first push must be a trusted one.)

## Repo layout

```
services/        # one directory per service.
                 #   dbt service: dbt_project.yml, profiles.yml (schema: analytics),
                 #     macros/ (generate_schema_name), models/, seeds/, Dockerfile (plain dbt + project)
                 #   python-node service: contracts/*.yml, scripts/*.py, Dockerfile
                 #     (FROM ghcr.io/carolsimone/continuo-python-runtime:<tag>)
scripts/         # repo CD/utility tooling: release.sh, gen_users.py, gen_transactions.py,
                 #   gen_fx_rates_eur.py, gen_marketing_spend.py, gen_operational_costs.py
                 #   Seed generators are ordered: gen_users -> {gen_marketing_spend,
                 #   gen_transactions -> gen_fx_rates_eur}; gen_operational_costs is independent.
.github/workflows/   # release.yml (deploy), ci.yml (PR checks)
```

The services fall into three groups. `core`, `finance`, and `marketing` are clean dbt example workloads — the part to read if you're modelling how your own dbt producer integrates. `service-1`, `service-2`, and `service-3` are copied from continuo's e2e fixtures: they carry deliberate cross-service dependencies (including a service-2 ↔ service-3 cycle) and probe / failure nodes whose only purpose is to exercise continuo's validation and reject paths. They are testing scaffolding, not a modelling example. `service-py` is the reference **python-node** service — `analytics.py_daily_kpis` reads `core`'s `analytics.daily_transactions` table and rolls it up into a daily count/total, and `analytics.demo_orders_csv` is a contract-only `python-csv` node that loads a demo CSV export straight from object storage (no script), the worked example of integrating a python producer instead of a dbt one. All services materialize into the **`analytics`** schema.

### Cross-service references (important)

A continuo producer's services are **separate dbt projects**, and dbt's `{{ ref() }}` only resolves nodes *within one project*. So a model that depends on a table built by **another** service cannot `ref()` it — that fails at `dbt compile` with `depends on a node named '…' which was not found`. The convention:

- **Within a service** (depends on a seed/model in the same project): use `{{ ref('name') }}`. dbt resolves it and orders the build.
- **Across services** (depends on a table another service produces in the shared `analytics` schema): reference it by its **raw schema-qualified name** — `FROM analytics.table_a` — never `ref()`. continuo sequences the cross-service build itself (via the validation closure and `service_prod` pointers); dbt never needs the upstream in its own graph.

This is the easiest integration mistake to make — even an automated fixer once "corrected" a cross-service `FROM analytics.table_a` into `{{ ref('table_a') }}` and broke the build.

## Required CI secrets

Configure these in the repo's Actions secrets before the workflow can run:

| Secret | Purpose |
|---|---|
| `DOCKERHUB_USERNAME` | Docker Hub user; **must match** the username continuo's executor uses to pull job images. |
| `DOCKERHUB_TOKEN` | Docker Hub push token. |
| `HETZNER_HOST` | Deploy target for `scripts/release.sh` to reach continuo's release API. |
| `HETZNER_SSH_KEY` | Credential authorizing `scripts/release.sh` to reach continuo's release API. |
| `HETZNER_S3_ACCESS_KEY_ID` | Python services only: credential for uploading `contract.yaml` to the Hetzner object store. |
| `HETZNER_S3_SECRET_ACCESS_KEY` | Python services only: secret for the same upload. |

## Local checks

```bash
shellcheck scripts/release.sh

# Python services: lint/validate/merge with continuo-runtime. Pinned exactly
# (same pin as the release.yml/ci.yml install steps) — move this version only
# alongside a deliberate runtime upgrade:
uv tool install continuo-python-runtime==0.4.0 || \
  uv tool install "git+https://github.com/carolsimone/continuo-python-runtime@v0.4.0"
continuo-runtime lint services/service-py/scripts/
continuo-runtime validate services/service-py/contracts/ --dialect postgres
continuo-runtime merge services/service-py/contracts/ --service service-py --repo-root services/service-py --dialect postgres --out /tmp/contract.yaml
```

## License

[CC0 1.0 Universal](LICENSE) — this is example code, dedicated to the public
domain. Copy it, adapt it, ship it; no attribution required.
