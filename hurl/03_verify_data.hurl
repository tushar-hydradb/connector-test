# Phase 3 — DRAINED DATA SHOWS UP (the "draining lance" + "showing up in the
# dashboard" steps). LIVE mode only — run.sh runs this after it has polled the
# read side and observed a source reach a terminal indexing state, so these
# assertions are deterministic by the time they run.
#
# We assert on the API-key context surface, which returns the SAME ingested
# sources the dashboard renders (GET /dashboard/resources/list/knowledge needs a
# NextAuth JWT and is not portable to staging, so we use the portable read path).
#
# Vars (set by run.sh): base, api_key, tenant, source_id.

# 1) The source landed and finished indexing — the true "data drained" signal.
GET {{base}}/context/status?id={{source_id}}
Authorization: Bearer {{api_key}}
HTTP 200
[Asserts]
jsonpath "$.success" == true
jsonpath "$.data.statuses" exists
jsonpath "$.data.statuses[0].id" == "{{source_id}}"
jsonpath "$.data.statuses[0].indexing_status" == "completed"

# 2) The source is listed for the tenant — this is what the dashboard docs table
#    shows. (Envelope wraps the v2 source list: $.data.sources / $.data.total.)
POST {{base}}/context/list
Authorization: Bearer {{api_key}}
Content-Type: application/json
{
  "database": "{{tenant}}",
  "type": "knowledge",
  "page_size": 50
}
HTTP 200
[Asserts]
jsonpath "$.success" == true
jsonpath "$.data.total" >= 1
jsonpath "$.data.sources" count > 0
jsonpath "$.data.sources[*].id" contains "{{source_id}}"

# 3) The drained content is retrievable via unified query — full round trip.
POST {{base}}/v2/query
Authorization: Bearer {{api_key}}
Content-Type: application/json
{
  "database": "{{tenant}}",
  "type": "all",
  "query_by": "hybrid",
  "mode": "fast",
  "query": "summarize the most recent content",
  "max_results": 10
}
HTTP 200
[Asserts]
jsonpath "$.success" == true
jsonpath "$.error" == null
jsonpath "$.data.chunks" exists
jsonpath "$.data.sources" exists
