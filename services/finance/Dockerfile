FROM python:3.12-slim

# Pin dbt to the classic postgres-supporting line. An unpinned dbt-postgres
# resolves to dbt Fusion, which dropped the postgres adapter. These are the
# versions the e2e suite is validated against. No boto3 / validator: validation
# is image-free (continuo-owned image); this image only runs the team's dbt
# project for compile / seed-build / scheduled runs.
RUN pip install --no-cache-dir "dbt-core==1.12.0b1" "dbt-postgres==1.10.0"

WORKDIR /project

# The service's own dbt project. macros/ carries generate_schema_name, which
# routes a run to the candidate schema when continuo sets DBT_TARGET_SCHEMA
# (used by the candidate seed-build leg) and falls back to the default schema
# otherwise (prod runs).
COPY dbt_project.yml profiles.yml ./
COPY macros/ ./macros/
COPY models/ ./models/
COPY seeds/ ./seeds/
COPY tests/ ./tests/

# Team CustomName's dbt CLI: continuo drives finance through the dbt-commands.yaml
# dialect (customname-dbt run-model / rebuild-model / load-seed / reload-seed /
# capture-snapshot / test-model / build-model / compile-project / parse-project).
# wise-dbt is a transitional alias for dbt-commands.yaml configs that still name it.
COPY customname_dbt.py /usr/local/bin/customname-dbt
RUN chmod +x /usr/local/bin/customname-dbt && ln -s /usr/local/bin/customname-dbt /usr/local/bin/wise-dbt

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
