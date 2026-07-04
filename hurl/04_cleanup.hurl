# Phase 4 — CLEANUP. Delete the connector (which also removes its resources and
# stored credentials) and confirm it is gone. run.sh runs this from its EXIT trap
# so a failed run still tidies up.
#
# Vars (set by run.sh): base, api_key, connector_id.

# 1) Delete the connector.
DELETE {{base}}/connectors/{{connector_id}}
Authorization: Bearer {{api_key}}
HTTP 200
[Asserts]
jsonpath "$.connector_id" == "{{connector_id}}"
jsonpath "$.deleted" == true

# 2) It is really gone — a subsequent get is a 404.
GET {{base}}/connectors/{{connector_id}}
Authorization: Bearer {{api_key}}
HTTP 404
