# Phase 2 — TRIGGER A SYNC (the "triggering a sync" step of the flow).
#
# POST /connectors/:id/sync starts a manual sync workflow and returns the
# workflow/run ids (202 Accepted). NOTE: this HTTP endpoint always drives the
# CLASSIC pipeline (handler always calls StartSync); the MOVEIT Lance-drain path
# is scheduler-driven and has no HTTP trigger. We assert the trigger CONTRACT
# here; the actual moveit drain is exercised by the scheduler and verified in
# phase 3.
#
# Vars (set by run.sh): base, api_key, connector_id.

POST {{base}}/connectors/{{connector_id}}/sync
Authorization: Bearer {{api_key}}
HTTP 202
[Asserts]
jsonpath "$.workflow_id" exists
jsonpath "$.workflow_id" isString
jsonpath "$.run_id" exists
