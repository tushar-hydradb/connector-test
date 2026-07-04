# Negative / contract guards. Pure HTTP contract — no provider token or worker
# needed, so run.sh runs this in every mode. Covers auth, input validation, and
# not-found behaviour on the connector surface.
#
# Vars (set by run.sh): base, api_key, tenant.

# 1) No auth token → 401 on the connector group (RequireConnectorAuth).
POST {{base}}/connectors
Content-Type: application/json
{
  "provider": "{{provider}}",
  "database": "{{tenant}}",
  "credentials": { "api_token": "x" },
  "sync_engine": "moveit"
}
HTTP 401

# 2) Invalid sync_engine is rejected (must be "classic" or "moveit").
POST {{base}}/connectors
Authorization: Bearer {{api_key}}
Content-Type: application/json
{
  "provider": "{{provider}}",
  "database": "{{tenant}}",
  "credentials": { "api_token": "x" },
  "sync_engine": "bogus"
}
HTTP 400

# 3) Missing provider is rejected.
POST {{base}}/connectors
Authorization: Bearer {{api_key}}
Content-Type: application/json
{
  "database": "{{tenant}}",
  "credentials": { "api_token": "x" },
  "sync_engine": "moveit"
}
HTTP 400

# 4) Unknown connector id → 404 (scoped to the caller's org).
GET {{base}}/connectors/does-not-exist-00000000
Authorization: Bearer {{api_key}}
HTTP 404
