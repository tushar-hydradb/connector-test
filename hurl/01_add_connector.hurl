# Phase 1 — ADD A CONNECTOR (the "adding connectors" step of the flow).
#
# Creates a sync_engine=moveit connector, then exercises the rest of the
# management surface on it: get, list(filter), resource create/list, configure.
# Everything here is deterministic HTTP contract — it does NOT wait on an actual
# extraction, so it passes in both contract-only and LIVE modes.
#
# Vars (set by run.sh): base, api_key, tenant, provider, provider_token, conn_name,
#                       resource_id, resource_name.
# The MOVEIT Lance drain is scheduler-driven (no HTTP trigger) — a freshly created
# moveit connector is immediately "due", so creating it here is what ultimately
# feeds the drain that phase 3 verifies.

# 1) Create the connector. sync_engine=moveit routes it to the MOVEIT pipeline.
POST {{base}}/connectors
Authorization: Bearer {{api_key}}
Content-Type: application/json
{
  "provider": "{{provider}}",
  "name": "{{conn_name}}",
  "database": "{{tenant}}",
  "auth_type": "api_token",
  "credentials": { "api_token": "{{provider_token}}" },
  "sync_engine": "moveit",
  "sync_interval_seconds": 3600
}
HTTP 201
[Asserts]
jsonpath "$.connector_id" exists
jsonpath "$.connector_id" isString
jsonpath "$.provider" == "{{provider}}"
jsonpath "$.name" == "{{conn_name}}"
jsonpath "$.sync_engine" == "moveit"
jsonpath "$.status" == "active"
jsonpath "$.tenant_id" == "{{tenant}}"
[Captures]
connector_id: jsonpath "$.connector_id"

# 2) Get it back by id — the persisted record matches what we created.
#    NOTE: the read projection (store.connectorProjection) deliberately does NOT
#    include sync_engine — only the scheduler's own read includes it for routing.
#    So GET/List do not echo sync_engine; we assert it on the create response
#    above (where it IS returned) and check the rest of the record here.
GET {{base}}/connectors/{{connector_id}}
Authorization: Bearer {{api_key}}
HTTP 200
[Asserts]
jsonpath "$.connector_id" == "{{connector_id}}"
jsonpath "$.provider" == "{{provider}}"
jsonpath "$.status" == "active"
jsonpath "$.tenant_id" == "{{tenant}}"

# 3) List for the org, filtered by provider — our connector is present.
GET {{base}}/connectors?provider={{provider}}
Authorization: Bearer {{api_key}}
HTTP 200
[Asserts]
jsonpath "$.connectors" exists
jsonpath "$.connectors[*].connector_id" contains "{{connector_id}}"
jsonpath "$.connectors[*].name" contains "{{conn_name}}"

# 4) Add a resource mapping (what the connector should sync).
POST {{base}}/connectors/{{connector_id}}/resources
Authorization: Bearer {{api_key}}
Content-Type: application/json
{
  "resource_id": "{{resource_id}}",
  "resource_type": "workspace",
  "display_name": "{{resource_name}}",
  "filters": { "lookback_days": 400 }
}
HTTP 201
[Asserts]
jsonpath "$.connector_id" == "{{connector_id}}"
jsonpath "$.resource_id" == "{{resource_id}}"
jsonpath "$.status" == "active"

# 5) List resources — the mapping we just added is there.
GET {{base}}/connectors/{{connector_id}}/resources
Authorization: Bearer {{api_key}}
HTTP 200
[Asserts]
jsonpath "$.resources" exists
jsonpath "$.resources[*].resource_id" contains "{{resource_id}}"

# 6) Configure — persists the selected resources and (for the classic engine)
#    kicks the initial sync/backfill. For moveit the scheduler drives the sync;
#    this still validates the configure contract and lookback handling.
POST {{base}}/connectors/{{connector_id}}/configure
Authorization: Bearer {{api_key}}
Content-Type: application/json
{
  "lookback_days": 400,
  "resources": [
    { "resource_id": "{{resource_id}}", "resource_type": "workspace", "name": "{{resource_name}}" }
  ]
}
HTTP 200
[Asserts]
jsonpath "$.connector_id" == "{{connector_id}}"
jsonpath "$.configured" == 1
