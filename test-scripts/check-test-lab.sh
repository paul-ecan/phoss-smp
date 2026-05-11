#!/usr/bin/env bash
# End-to-end certification check for the test-lab SMP and AP.
# Runs against the live Docker stack. Creates a temporary SMP participant
# (iso6523-actorid-upis::9999:checkscript) and cleans up on exit.
#
# Usage:
#   ./check-test-lab.sh [SMP_URL] [AP_URL] [AP_TOKEN] [CERT_FILE]
#
# Defaults:
#   SMP_URL    https://localhost:8843
#   AP_URL     http://localhost:8780
#   AP_TOKEN   phoss-ap-development-token
#   CERT_FILE  ../../phoss-ap/certs/test-ap.crt

SMP_URL="${1:-https://localhost:8843}"
AP_URL="${2:-http://localhost:8780}"
AP_TOKEN="${3:-phoss-ap-development-token}"
CERT_FILE="${4:-$(dirname "$0")/../../phoss-ap/certs/test-ap.crt}"
SAMPLES_DIR="$(dirname "$0")/../../phoss-ap/phoss-ap-testsender/src/main/resources/samples"
SMP_USER="admin@helger.com:password"

# Temporary participant used for SMP tests
TEST_SCHEME="iso6523-actorid-upis"
TEST_VALUE="9999:checkscript"

# AP test participants (registered in SMP by register-test-lab.sh)
SENDER_ID="iso6523-actorid-upis::0088:1111111111111"
RECEIVER_ID="iso6523-actorid-upis::0088:2222222222222"

INVOICE_DOCTYPE="urn:oasis:names:specification:ubl:schema:xsd:Invoice-2::Invoice##urn:cen.eu:en16931:2017#compliant#urn:fdc:peppol.eu:2017:poacc:billing:3.0::2.1"
INVOICE_PROCESS="urn:fdc:peppol.eu:2017:poacc:billing:01:1.0"

# ── Helpers ───────────────────────────────────────────────────────────────────

pass=0; fail=0

check_http() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    printf "  PASS  %s\n" "$desc"; ((pass++))
  else
    printf "  FAIL  %s (expected HTTP %s, got %s)\n" "$desc" "$expected" "$actual"; ((fail++))
  fi
}

check_body() {
  local desc="$1" pattern="$2" body="$3"
  if echo "$body" | grep -q "$pattern"; then
    printf "  PASS  %s\n" "$desc"; ((pass++))
  else
    printf "  FAIL  %s (pattern '%s' not found in response)\n" "$desc" "$pattern"; ((fail++))
  fi
}

urlencode() {
  python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1"
}

# -k: skip TLS verification for self-signed cert; capture errors as "000"
smp_get()  { curl -sk -u "$SMP_USER" "$@" || echo "000"; }
smp_code() { curl -sk -u "$SMP_USER" -o /dev/null -w "%{http_code}" "$@" || echo "000"; }
ap_get()   { curl -s -H "X-Token: $AP_TOKEN" "$@" || echo "000"; }
ap_code()  { curl -s -H "X-Token: $AP_TOKEN" -o /dev/null -w "%{http_code}" "$@" || echo "000"; }

# Temp file for SBD body modification; cleaned up on exit
TMPFILE=$(mktemp)
trap "rm -f $TMPFILE; smp_get -X DELETE \"${SMP_URL}/$(urlencode "${TEST_SCHEME}::${TEST_VALUE}")\" > /dev/null 2>&1 || true" EXIT

# ── SMP REST API ──────────────────────────────────────────────────────────────

echo ""
echo "SMP REST API — $SMP_URL"
echo "────────────────────────────────────────────────────────────────"

# 1–2. Liveness
http_code=$(curl -sk -o /dev/null -w "%{http_code}" "$SMP_URL/ping" || echo "000")
body=$(curl -sk "$SMP_URL/ping" || echo "")
check_http "01. GET /ping → 200" "200" "$http_code"
check_body "02. GET /ping → body is 'pong'" "pong" "$body"

PID_ENC=$(urlencode "${TEST_SCHEME}::${TEST_VALUE}")
DOCTYPE_ENC=$(urlencode "busdox-docid-qns::${INVOICE_DOCTYPE}")

# 3. Non-existent ServiceGroup → 404
check_http "03. GET non-existent ServiceGroup → 404" "404" \
  "$(smp_code "${SMP_URL}/${PID_ENC}")"

# Service group XML (reused in multiple calls)
SG_XML="<?xml version=\"1.0\" encoding=\"UTF-8\"?><smp:ServiceGroup xmlns:smp=\"http://busdox.org/serviceMetadata/publishing/1.0/\" xmlns:id=\"http://busdox.org/transport/identifiers/1.0/\"><id:ParticipantIdentifier scheme=\"${TEST_SCHEME}\">${TEST_VALUE}</id:ParticipantIdentifier><smp:ServiceMetadataReferenceCollection/></smp:ServiceGroup>"

# 4. PUT ServiceGroup → 200
check_http "04. PUT ServiceGroup → 200" "200" \
  "$(smp_code -X PUT "${SMP_URL}/${PID_ENC}" -H "Content-Type: application/xml" -d "$SG_XML")"

# 5–6. GET ServiceGroup → 200 + correct participant in body
body=$(smp_get "${SMP_URL}/${PID_ENC}")
check_http "05. GET ServiceGroup → 200" "200" \
  "$(smp_code "${SMP_URL}/${PID_ENC}")"
check_body "06. GET ServiceGroup → body contains participant value" "$TEST_VALUE" "$body"

# 7. PUT ServiceMetadata (invoice endpoint) → 200
CERT_B64=$(openssl x509 -in "$CERT_FILE" -outform DER | base64 -w 0)
SM_XML="<?xml version=\"1.0\" encoding=\"UTF-8\"?><smp:ServiceMetadata xmlns:smp=\"http://busdox.org/serviceMetadata/publishing/1.0/\" xmlns:id=\"http://busdox.org/transport/identifiers/1.0/\"><smp:ServiceInformation><id:ParticipantIdentifier scheme=\"${TEST_SCHEME}\">${TEST_VALUE}</id:ParticipantIdentifier><id:DocumentIdentifier scheme=\"busdox-docid-qns\">${INVOICE_DOCTYPE}</id:DocumentIdentifier><smp:ProcessList><smp:Process><id:ProcessIdentifier scheme=\"cenbii-procid-ubl\">${INVOICE_PROCESS}</id:ProcessIdentifier><smp:ServiceEndpointList><smp:Endpoint transportProfile=\"peppol-transport-as4-v2_0\"><wsa:EndpointReference xmlns:wsa=\"http://www.w3.org/2005/08/addressing\"><wsa:Address>http://phoss-ap:8080/as4</wsa:Address></wsa:EndpointReference><smp:RequireBusinessLevelSignature>false</smp:RequireBusinessLevelSignature><smp:ServiceActivationDate>2026-01-01T00:00:00Z</smp:ServiceActivationDate><smp:ServiceExpirationDate>2030-12-31T23:59:59Z</smp:ServiceExpirationDate><smp:Certificate>${CERT_B64}</smp:Certificate><smp:ServiceDescription>Check script</smp:ServiceDescription><smp:TechnicalContactUrl>check@local</smp:TechnicalContactUrl></smp:Endpoint></smp:ServiceEndpointList></smp:Process></smp:ProcessList></smp:ServiceInformation></smp:ServiceMetadata>"

check_http "07. PUT ServiceMetadata → 200" "200" \
  "$(smp_code -X PUT "${SMP_URL}/${PID_ENC}/services/${DOCTYPE_ENC}" \
    -H "Content-Type: application/xml" -d "$SM_XML")"

# 8–9. GET ServiceMetadata → 200 + endpoint address in body
body=$(smp_get "${SMP_URL}/${PID_ENC}/services/${DOCTYPE_ENC}")
check_http "08. GET ServiceMetadata → 200" "200" \
  "$(smp_code "${SMP_URL}/${PID_ENC}/services/${DOCTYPE_ENC}")"
check_body "09. GET ServiceMetadata → body contains AS4 endpoint" "phoss-ap" "$body"

# 10. DELETE ServiceMetadata → 200
check_http "10. DELETE ServiceMetadata → 200" "200" \
  "$(smp_code -X DELETE "${SMP_URL}/${PID_ENC}/services/${DOCTYPE_ENC}")"

# 11. GET deleted ServiceMetadata → 404
check_http "11. GET deleted ServiceMetadata → 404" "404" \
  "$(smp_code "${SMP_URL}/${PID_ENC}/services/${DOCTYPE_ENC}")"

# 12. DELETE ServiceGroup → 200
check_http "12. DELETE ServiceGroup → 200" "200" \
  "$(smp_code -X DELETE "${SMP_URL}/${PID_ENC}")"

# 13. GET deleted ServiceGroup → 404
check_http "13. GET deleted ServiceGroup → 404" "404" \
  "$(smp_code "${SMP_URL}/${PID_ENC}")"

# 14. PUT with wrong credentials → 403 (SMP denies without WWW-Authenticate challenge)
check_http "14. PUT with wrong credentials → 403" "403" \
  "$(curl -sk -u "wrong@user.com:badpassword" -o /dev/null -w "%{http_code}" \
    -X PUT "${SMP_URL}/${PID_ENC}" -H "Content-Type: application/xml" -d "$SG_XML" || echo "000")"

# 15–19. BusinessCard CRUD (recreate service group first)
smp_get -X PUT "${SMP_URL}/${PID_ENC}" -H "Content-Type: application/xml" -d "$SG_XML" > /dev/null

BC_XML="<?xml version=\"1.0\" encoding=\"UTF-8\"?><pd:BusinessCard xmlns:pd=\"http://www.peppol.eu/schema/pd/businesscard/20180621/\"><pd:ParticipantIdentifier scheme=\"${TEST_SCHEME}\">${TEST_VALUE}</pd:ParticipantIdentifier><pd:BusinessEntity><pd:Name language=\"en\">Check Script Test</pd:Name><pd:CountryCode>NZ</pd:CountryCode></pd:BusinessEntity></pd:BusinessCard>"

check_http "15. GET non-existent BusinessCard → 404" "404" \
  "$(smp_code "${SMP_URL}/businesscard/${PID_ENC}")"

check_http "16. PUT BusinessCard → 200" "200" \
  "$(smp_code -X PUT "${SMP_URL}/businesscard/${PID_ENC}" \
    -H "Content-Type: application/xml" -d "$BC_XML")"

body=$(smp_get "${SMP_URL}/businesscard/${PID_ENC}")
check_http "17. GET BusinessCard → 200" "200" \
  "$(smp_code "${SMP_URL}/businesscard/${PID_ENC}")"
check_body "18. GET BusinessCard → body contains entity name" "Check Script Test" "$body"

check_http "19. DELETE BusinessCard → 200" "200" \
  "$(smp_code -X DELETE "${SMP_URL}/businesscard/${PID_ENC}")"

check_http "20. GET deleted BusinessCard → 404" "404" \
  "$(smp_code "${SMP_URL}/businesscard/${PID_ENC}")"

# Service group is cleaned up by the EXIT trap

# ── AP Outbound ───────────────────────────────────────────────────────────────

echo ""
echo "AP Outbound — $AP_URL"
echo "────────────────────────────────────────────────────────────────"

SENDER_ENC=$(urlencode "$SENDER_ID")
RECEIVER_ENC=$(urlencode "$RECEIVER_ID")
DOCTYPE_AP_ENC=$(urlencode "busdox-docid-qns::${INVOICE_DOCTYPE}")
PROCESS_ENC=$(urlencode "cenbii-procid-ubl::${INVOICE_PROCESS}")

# Timestamp suffix makes instance IDs unique across runs
TS=$(date +%s)
XML_INSTANCE_ID="check-xml-${TS}"
PDF_INSTANCE_ID="check-pdf-${TS}"

# 21. Submit XML invoice
check_http "21. POST XML invoice → 200" "200" \
  "$(ap_code -X POST \
    "${AP_URL}/api/outbound/submit/${SENDER_ENC}/${RECEIVER_ENC}/${DOCTYPE_AP_ENC}/${PROCESS_ENC}/NZ?sbdhInstanceID=${XML_INSTANCE_ID}" \
    -H "Content-Type: application/xml" --data-binary "@${SAMPLES_DIR}/invoice-ubl.xml")"

# 22. Submit pre-built SBD (replace hardcoded instance ID for idempotency across runs)
sed "s/92f7e6a5-c392-4e66-b786-fd2b7c535eb2/check-sbd-${TS}/" "${SAMPLES_DIR}/prebuilt-sbd.xml" > "$TMPFILE"
check_http "22. POST pre-built SBD → 200" "200" \
  "$(ap_code -X POST "${AP_URL}/api/outbound/submit-sbd" \
    -H "Content-Type: application/xml" --data-binary "@${TMPFILE}")"

# 23. Submit PDF (requires Factur-X SBDH params in addition to instance ID)
PDF_STANDARD_ENC=$(urlencode "urn:peppol:doctype:pdf+xml")
check_http "23. POST PDF → 200" "200" \
  "$(ap_code -X POST \
    "${AP_URL}/api/outbound/submit/${SENDER_ENC}/${RECEIVER_ENC}/${DOCTYPE_AP_ENC}/${PROCESS_ENC}/NZ?sbdhInstanceID=${PDF_INSTANCE_ID}&sbdhStandard=${PDF_STANDARD_ENC}&sbdhTypeVersion=0&sbdhType=factur-x&payloadMimeType=application%2Fpdf" \
    -H "Content-Type: application/pdf" --data-binary "@${SAMPLES_DIR}/factur-x.pdf")"

# 24–25. Poll XML transaction status for reportingStatus and mlsStatus
echo ""
echo "  Polling transaction status (${XML_INSTANCE_ID}, up to 30s)..."
deadline=$((SECONDS + 30))
reporting_ok=false; mls_ok=false
while [[ $SECONDS -lt $deadline ]]; do
  status_body=$(ap_get "${AP_URL}/api/outbound/status/${XML_INSTANCE_ID}")
  [[ "$status_body" == *'"reportingStatus":"reported"'* ]] && reporting_ok=true
  [[ "$status_body" == *'"mlsStatus":"received_ab"'* ]] && mls_ok=true
  [[ "$reporting_ok" == true && "$mls_ok" == true ]] && break
  sleep 2
done
if $reporting_ok; then
  printf "  PASS  24. Transaction reportingStatus = reported\n"; ((pass++))
else
  printf "  FAIL  24. Transaction reportingStatus did not reach 'reported' within 15s\n"; ((fail++))
fi
if $mls_ok; then
  printf "  PASS  25. Transaction mlsStatus = received_ab\n"; ((pass++))
else
  printf "  FAIL  25. Transaction mlsStatus did not reach 'received_ab' within 15s\n"; ((fail++))
fi

# ── Peppol Reporting ──────────────────────────────────────────────────────────

echo ""
echo "Peppol Reporting — $AP_URL"
echo "────────────────────────────────────────────────────────────────"

YEAR_MONTH=$(date -d "1 month ago" +%Y-%m 2>/dev/null || date -v-1m +%Y-%m)

# 26–27. Trigger + verify success body
http_code=$(ap_code -X POST "${AP_URL}/api/reporting/trigger?yearMonth=${YEAR_MONTH}")
body=$(ap_get -X POST "${AP_URL}/api/reporting/trigger?yearMonth=${YEAR_MONTH}")
check_http "26. POST /api/reporting/trigger → 200" "200" "$http_code"
check_body "27. Reporting trigger → success body" "successfully" "$body"

# 28. Re-trigger same month (idempotent)
check_http "28. POST /api/reporting/trigger again → 200 (idempotent)" "200" \
  "$(ap_code -X POST "${AP_URL}/api/reporting/trigger?yearMonth=${YEAR_MONTH}")"

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════════════════════════════"
printf "  %d PASS  /  %d FAIL  (total %d)\n" "$pass" "$fail" "$((pass + fail))"
echo "════════════════════════════════════════════════════════════════"
[[ $fail -eq 0 ]] || exit 1
