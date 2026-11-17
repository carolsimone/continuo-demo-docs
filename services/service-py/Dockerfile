# The python node service of the demo estate: the engine-matched runtime base
# plus this service's ODCS contracts and scripts. One image serves every node
# this service declares; the harness picks the node from NODE_ID at run time.
#
# The base must be continuo-python-runtime 0.13.0 or later, the first release
# that reads contracts/*.odcs.yaml. Keep this tag equal to the runtime that CI
# uses to validate and pack the contracts: the harness checks the image against
# the released content hash when a node starts.
FROM ghcr.io/carolsimone/continuo-python-runtime-postgres:v0.13.0
COPY contracts/ /app/contracts/
COPY scripts/ /app/scripts/
# The runtime base already sets USER 65532:65532, the uid continuo's
# execution-controller expects. The harness only reads its baked contracts and
# scripts and writes only to the warehouse, so nothing here changes ownership.
