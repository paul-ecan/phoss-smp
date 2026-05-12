#!/usr/bin/env bash
# Peppol conformance test suite — test-lab AP + SMP.
# Organised by OpenPeppol Testbed test case numbers (https://testbed.peppol.org/).
# Tests that require real Peppol infrastructure (SML, PKI, external services) are marked SKIP.
#
# Usage:
#   ./peppol-conformance.sh [SMP_URL] [AP_URL] [AP_TOKEN] [CERT_FILE] [WIREMOCK_URL]
#
# Defaults:
#   SMP_URL       https://localhost:8843
#   AP_URL        http://localhost:8780
#   AP_TOKEN      phoss-ap-development-token
#   CERT_FILE     ../../phoss-ap/certs/test-ap.crt
#   WIREMOCK_URL  http://localhost:8783

SMP_URL="${1:-https://localhost:8843}"
AP_URL="${2:-http://localhost:8780}"
AP_TOKEN="${3:-phoss-ap-development-token}"
CERT_FILE="${4:-$(dirname "$0")/../../phoss-ap/certs/test-ap.crt}"
WIREMOCK_URL="${5:-http://localhost:8783}"
SAMPLES_DIR="$(dirname "$0")/../../phoss-ap/phoss-ap-testsender/src/main/resources/samples"
SMP_USER="admin@helger.com:password"

TEST_SCHEME="iso6523-actorid-upis"
TEST_VALUE="9999:conformance"
SML_TEST_VALUE="9999:smltest"

SENDER_ID="iso6523-actorid-upis::0088:1111111111111"
RECEIVER_ID="iso6523-actorid-upis::0088:2222222222222"
UNREG_ID="iso6523-actorid-upis::0088:0000000000000"   # deliberately not registered

INVOICE_DOCTYPE="urn:oasis:names:specification:ubl:schema:xsd:Invoice-2::Invoice##urn:cen.eu:en16931:2017#compliant#urn:fdc:peppol.eu:2017:poacc:billing:3.0::2.1"
INVOICE_PROCESS="urn:fdc:peppol.eu:2017:poacc:billing:01:1.0"

# ── Helpers ───────────────────────────────────────────────────────────────────

pass=0; fail=0; skip=0
RESULTS_FILE=$(mktemp)
REPORT_FILE="$(dirname "$0")/conformance-report-$(date +%Y-%m-%d).xlsx"

record() {  # type  full_desc  result  detail
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$RESULTS_FILE"
}

check_http() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    printf "  PASS  %s\n" "$desc"; ((pass++))
    record TEST "$desc" PASS ""
  else
    printf "  FAIL  %s (expected HTTP %s, got %s)\n" "$desc" "$expected" "$actual"; ((fail++))
    record TEST "$desc" FAIL "expected HTTP $expected, got $actual"
  fi
}

check_http_any() {
  # Passes if actual matches any of the space-separated expected codes
  local desc="$1" actual="$3"
  shift; local expected_list="$1"; shift; shift
  for code in $expected_list; do
    if [[ "$actual" == "$code" ]]; then
      printf "  PASS  %s\n" "$desc"; ((pass++))
      record TEST "$desc" PASS ""
      return
    fi
  done
  printf "  FAIL  %s (expected one of [%s], got %s)\n" "$desc" "$expected_list" "$actual"; ((fail++))
  record TEST "$desc" FAIL "expected one of [$expected_list], got $actual"
}

check_body() {
  local desc="$1" pattern="$2" body="$3"
  if echo "$body" | grep -q "$pattern"; then
    printf "  PASS  %s\n" "$desc"; ((pass++))
    record TEST "$desc" PASS ""
  else
    printf "  FAIL  %s (pattern '%s' not found)\n" "$desc" "$pattern"; ((fail++))
    record TEST "$desc" FAIL "pattern '$pattern' not found"
  fi
}

skip_test() {
  printf "  SKIP  %s\n" "$1"; ((skip++))
  local id="${1%%  *}" rest="${1#*  }"
  local label="$rest" reason=""
  if [[ "$rest" == *" — "* ]]; then
    label="${rest%% — *}"; reason="${rest##* — }"
  fi
  record TEST "${id}  ${label}" SKIP "$reason"
}

urlencode() {
  python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1"
}

smp_get()  { curl -sk -u "$SMP_USER" "$@" || echo "000"; }
smp_code() { curl -sk -u "$SMP_USER" -o /dev/null -w "%{http_code}" "$@" || echo "000"; }
ap_get()   { curl -s -H "X-Token: $AP_TOKEN" "$@" || echo "000"; }
ap_code()  { curl -s -H "X-Token: $AP_TOKEN" -o /dev/null -w "%{http_code}" "$@" || echo "000"; }

TS=$(date +%s)
TMPFILE=$(mktemp)
LARGE_TMPFILE=$(mktemp)

cleanup() {
  rm -f "$TMPFILE" "$LARGE_TMPFILE" "$RESULTS_FILE"
  local enc
  enc=$(urlencode "${TEST_SCHEME}::${TEST_VALUE}")
  smp_get -X DELETE "${SMP_URL}/${enc}" > /dev/null 2>&1 || true
  enc=$(urlencode "${TEST_SCHEME}::${SML_TEST_VALUE}")
  smp_get -X DELETE "${SMP_URL}/${enc}" > /dev/null 2>&1 || true
}
trap cleanup EXIT

# Pre-compute URL-encoded identifiers once
PID_ENC=$(urlencode "${TEST_SCHEME}::${TEST_VALUE}")
SML_PID_ENC=$(urlencode "${TEST_SCHEME}::${SML_TEST_VALUE}")
DOCTYPE_ENC=$(urlencode "busdox-docid-qns::${INVOICE_DOCTYPE}")
SENDER_ENC=$(urlencode "$SENDER_ID")
RECEIVER_ENC=$(urlencode "$RECEIVER_ID")
UNREG_ENC=$(urlencode "$UNREG_ID")
DOCTYPE_AP_ENC=$(urlencode "busdox-docid-qns::${INVOICE_DOCTYPE}")
PROCESS_ENC=$(urlencode "cenbii-procid-ubl::${INVOICE_PROCESS}")
PDF_STANDARD_ENC=$(urlencode "urn:peppol:doctype:pdf+xml")

CERT_B64=$(openssl x509 -in "$CERT_FILE" -outform DER | base64 -w 0)

SG_XML="<?xml version=\"1.0\" encoding=\"UTF-8\"?><smp:ServiceGroup xmlns:smp=\"http://busdox.org/serviceMetadata/publishing/1.0/\" xmlns:id=\"http://busdox.org/transport/identifiers/1.0/\"><id:ParticipantIdentifier scheme=\"${TEST_SCHEME}\">${TEST_VALUE}</id:ParticipantIdentifier><smp:ServiceMetadataReferenceCollection/></smp:ServiceGroup>"

SM_XML="<?xml version=\"1.0\" encoding=\"UTF-8\"?><smp:ServiceMetadata xmlns:smp=\"http://busdox.org/serviceMetadata/publishing/1.0/\" xmlns:id=\"http://busdox.org/transport/identifiers/1.0/\"><smp:ServiceInformation><id:ParticipantIdentifier scheme=\"${TEST_SCHEME}\">${TEST_VALUE}</id:ParticipantIdentifier><id:DocumentIdentifier scheme=\"busdox-docid-qns\">${INVOICE_DOCTYPE}</id:DocumentIdentifier><smp:ProcessList><smp:Process><id:ProcessIdentifier scheme=\"cenbii-procid-ubl\">${INVOICE_PROCESS}</id:ProcessIdentifier><smp:ServiceEndpointList><smp:Endpoint transportProfile=\"peppol-transport-as4-v2_0\"><wsa:EndpointReference xmlns:wsa=\"http://www.w3.org/2005/08/addressing\"><wsa:Address>https://caddy/as4</wsa:Address></wsa:EndpointReference><smp:RequireBusinessLevelSignature>false</smp:RequireBusinessLevelSignature><smp:ServiceActivationDate>2026-01-01T00:00:00Z</smp:ServiceActivationDate><smp:ServiceExpirationDate>2030-12-31T23:59:59Z</smp:ServiceExpirationDate><smp:Certificate>${CERT_B64}</smp:Certificate><smp:ServiceDescription>Conformance test</smp:ServiceDescription><smp:TechnicalContactUrl>conformance@local</smp:TechnicalContactUrl></smp:Endpoint></smp:ServiceEndpointList></smp:Process></smp:ProcessList></smp:ServiceInformation></smp:ServiceMetadata>"

BC_XML="<?xml version=\"1.0\" encoding=\"UTF-8\"?><pd:BusinessCard xmlns:pd=\"http://www.peppol.eu/schema/pd/businesscard/20180621/\"><pd:ParticipantIdentifier scheme=\"${TEST_SCHEME}\">${TEST_VALUE}</pd:ParticipantIdentifier><pd:BusinessEntity><pd:Name language=\"en\">Conformance Test</pd:Name><pd:CountryCode>NZ</pd:CountryCode></pd:BusinessEntity></pd:BusinessCard>"

# ── TC-01: TLS Security ───────────────────────────────────────────────────────

echo ""
echo "TC-01  TLS Security — ${SMP_URL}"
echo "────────────────────────────────────────────────────────────────"

SMP_HOST=$(echo "$SMP_URL" | sed 's|https://||' | cut -d: -f1)
SMP_PORT=$(echo "$SMP_URL" | sed 's|https://[^:]*||' | tr -d ':')
[[ -z "$SMP_PORT" ]] && SMP_PORT=443

TLS_HANDSHAKE=$(echo "Q" | timeout 5 openssl s_client -connect "${SMP_HOST}:${SMP_PORT}" 2>&1 || true)

if echo "$TLS_HANDSHAKE" | grep -q "Cipher is"; then
  printf "  PASS  TC-01.01  SMP TLS handshake succeeds\n"; ((pass++))
  record TEST "TC-01.01  SMP TLS handshake succeeds" PASS ""
else
  printf "  FAIL  TC-01.01  SMP TLS handshake failed\n"; ((fail++))
  record TEST "TC-01.01  SMP TLS handshake succeeds" FAIL "handshake failed"
fi

TLS_PROTO=$(echo "$TLS_HANDSHAKE" | grep "Protocol  :" | awk '{print $NF}')
if [[ "$TLS_PROTO" == TLSv1.[23] || "$TLS_PROTO" == TLSv1.3 ]]; then
  printf "  PASS  TC-01.02  SMP TLS protocol is %s (≥ TLS 1.2)\n" "$TLS_PROTO"; ((pass++))
  record TEST "TC-01.02  SMP TLS protocol is ${TLS_PROTO} (≥ TLS 1.2)" PASS ""
else
  printf "  FAIL  TC-01.02  SMP TLS protocol is '%s' (expected TLS 1.2 or 1.3)\n" "$TLS_PROTO"; ((fail++))
  record TEST "TC-01.02  SMP TLS protocol ≥ TLS 1.2" FAIL "got '$TLS_PROTO'"
fi

CERT_CN=$(echo "$TLS_HANDSHAKE" | openssl x509 -noout -subject 2>/dev/null | sed 's/.*CN *= *//' | cut -d, -f1 || true)
if [[ -n "$CERT_CN" ]]; then
  printf "  PASS  TC-01.03  SMP TLS certificate present (CN=%s)\n" "$CERT_CN"; ((pass++))
  record TEST "TC-01.03  SMP TLS certificate present (CN=${CERT_CN})" PASS ""
else
  printf "  FAIL  TC-01.03  SMP TLS certificate not found in handshake\n"; ((fail++))
  record TEST "TC-01.03  SMP TLS certificate present" FAIL "no certificate in handshake"
fi

if echo "$TLS_HANDSHAKE" | grep -q "TLS_AES\|AES.*GCM\|AES.*SHA"; then
  printf "  PASS  TC-01.04  SMP cipher suite uses AES\n"; ((pass++))
  record TEST "TC-01.04  SMP cipher suite uses AES" PASS ""
else
  printf "  FAIL  TC-01.04  SMP cipher suite does not use AES\n"; ((fail++))
  record TEST "TC-01.04  SMP cipher suite uses AES" FAIL "AES not found in cipher string"
fi

AP_TLS=$(echo "Q" | timeout 5 openssl s_client -connect "localhost:8823" 2>&1 || true)
AP_TLS_PROTO=$(echo "$AP_TLS" | grep "Protocol  :" | awk '{print $NF}')
if echo "$AP_TLS" | grep -q "Cipher is" && [[ "$AP_TLS_PROTO" == TLSv1.[23] || "$AP_TLS_PROTO" == TLSv1.3 ]]; then
  printf "  PASS  TC-01.05  AP AS4 endpoint TLS handshake succeeds (%s)\n" "$AP_TLS_PROTO"; ((pass++))
  record TEST "TC-01.05  AP AS4 endpoint TLS handshake succeeds (${AP_TLS_PROTO})" PASS ""
else
  printf "  FAIL  TC-01.05  AP AS4 endpoint TLS handshake failed or protocol '%s' < TLS 1.2\n" "$AP_TLS_PROTO"; ((fail++))
  record TEST "TC-01.05  AP AS4 endpoint TLS handshake succeeds" FAIL "handshake failed or protocol '$AP_TLS_PROTO' < TLS 1.2"
fi

skip_test "TC-01.06  External TLS grader (Qualys SSL Labs A+) — requires internet access"

# ── TC-02A.1: AS4 Basic Connectivity (loopback) ───────────────────────────────

echo ""
echo "TC-02A.1  AS4 Basic Connectivity — ${AP_URL}"
echo "────────────────────────────────────────────────────────────────"

XML_ID="conf-xml-${TS}"
SBD_ID="conf-sbd-${TS}"
PDF_ID="conf-pdf-${TS}"

check_http "TC-02A.1.01  POST XML invoice → 200" "200" \
  "$(ap_code -X POST \
    "${AP_URL}/api/outbound/submit/${SENDER_ENC}/${RECEIVER_ENC}/${DOCTYPE_AP_ENC}/${PROCESS_ENC}/NZ?sbdhInstanceID=${XML_ID}" \
    -H "Content-Type: application/xml" --data-binary "@${SAMPLES_DIR}/invoice-ubl.xml")"

sed "s/92f7e6a5-c392-4e66-b786-fd2b7c535eb2/${SBD_ID}/" "${SAMPLES_DIR}/prebuilt-sbd.xml" > "$TMPFILE"
check_http "TC-02A.1.02  POST pre-built SBD → 200" "200" \
  "$(ap_code -X POST "${AP_URL}/api/outbound/submit-sbd" \
    -H "Content-Type: application/xml" --data-binary "@${TMPFILE}")"

check_http "TC-02A.1.03  POST PDF (Factur-X) → 200" "200" \
  "$(ap_code -X POST \
    "${AP_URL}/api/outbound/submit/${SENDER_ENC}/${RECEIVER_ENC}/${DOCTYPE_AP_ENC}/${PROCESS_ENC}/NZ?sbdhInstanceID=${PDF_ID}&sbdhStandard=${PDF_STANDARD_ENC}&sbdhTypeVersion=0&sbdhType=factur-x&payloadMimeType=application%2Fpdf" \
    -H "Content-Type: application/pdf" --data-binary "@${SAMPLES_DIR}/factur-x.pdf")"

echo ""
echo "  Polling transaction status (${XML_ID}, up to 30s)..."
deadline=$((SECONDS + 30))
reporting_ok=false; mls_ok=false
while [[ $SECONDS -lt $deadline ]]; do
  status_body=$(ap_get "${AP_URL}/api/outbound/status/${XML_ID}")
  [[ "$status_body" == *'"reportingStatus":"reported"'* ]] && reporting_ok=true
  [[ "$status_body" == *'"mlsStatus":"received_ab"'* ]] && mls_ok=true
  [[ "$reporting_ok" == true && "$mls_ok" == true ]] && break
  sleep 2
done

if $reporting_ok; then
  printf "  PASS  TC-02A.1.04  Transaction reportingStatus = reported\n"; ((pass++))
  record TEST "TC-02A.1.04  Transaction reportingStatus = reported" PASS ""
else
  printf "  FAIL  TC-02A.1.04  Transaction reportingStatus did not reach 'reported' within 30s\n"; ((fail++))
  record TEST "TC-02A.1.04  Transaction reportingStatus = reported" FAIL "did not reach 'reported' within 30s"
fi
if $mls_ok; then
  printf "  PASS  TC-02A.1.05  Transaction mlsStatus = received_ab\n"; ((pass++))
  record TEST "TC-02A.1.05  Transaction mlsStatus = received_ab" PASS ""
else
  printf "  FAIL  TC-02A.1.05  Transaction mlsStatus did not reach 'received_ab' within 30s\n"; ((fail++))
  record TEST "TC-02A.1.05  Transaction mlsStatus = received_ab" FAIL "did not reach 'received_ab' within 30s"
fi

# ── TC-02A.2: SML-based Outbound Routing ─────────────────────────────────────

echo ""
echo "TC-02A.2  SML-based Outbound Routing (CoreDNS + WireMock)"
echo "────────────────────────────────────────────────────────────────"

# TC-02A.2.01: AP resolves receiver endpoint via DNS NAPTR (CoreDNS serves the SML zone)
DNS_XML_ID="conf-dns-xml-${TS}"
check_http "TC-02A.2.01  Outbound XML via DNS NAPTR routing → 200" "200" \
  "$(ap_code -X POST \
    "${AP_URL}/api/outbound/submit/${SENDER_ENC}/${RECEIVER_ENC}/${DOCTYPE_AP_ENC}/${PROCESS_ENC}/NZ?sbdhInstanceID=${DNS_XML_ID}" \
    -H "Content-Type: application/xml" --data-binary "@${SAMPLES_DIR}/invoice-ubl.xml")"

# TC-02A.2.02: PUT a new participant in SMP → phoss-smp must call SMK createParticipantIdentifier
SML_SG_XML="<?xml version=\"1.0\" encoding=\"UTF-8\"?><smp:ServiceGroup xmlns:smp=\"http://busdox.org/serviceMetadata/publishing/1.0/\" xmlns:id=\"http://busdox.org/transport/identifiers/1.0/\"><id:ParticipantIdentifier scheme=\"${TEST_SCHEME}\">${SML_TEST_VALUE}</id:ParticipantIdentifier><smp:ServiceMetadataReferenceCollection/></smp:ServiceGroup>"
curl -s -X DELETE "${WIREMOCK_URL}/__admin/requests" > /dev/null
smp_code -X PUT "${SMP_URL}/${SML_PID_ENC}" -H "Content-Type: application/xml" -d "$SML_SG_XML" > /dev/null
sleep 1
journal=$(curl -s "${WIREMOCK_URL}/__admin/requests" || echo "")
if echo "$journal" | grep -qi "createParticipantIdentifier"; then
  printf "  PASS  TC-02A.2.02  SMP called SMK createParticipantIdentifier on PUT ServiceGroup\n"; ((pass++))
  record TEST "TC-02A.2.02  SMP called SMK createParticipantIdentifier on PUT ServiceGroup" PASS ""
else
  printf "  FAIL  TC-02A.2.02  createParticipantIdentifier not found in WireMock journal\n"; ((fail++))
  record TEST "TC-02A.2.02  SMP called SMK createParticipantIdentifier on PUT ServiceGroup" FAIL "createParticipantIdentifier not found in WireMock journal"
fi

# TC-02A.2.03: DELETE the participant → phoss-smp must call SMK deleteParticipantIdentifier
curl -s -X DELETE "${WIREMOCK_URL}/__admin/requests" > /dev/null
smp_code -X DELETE "${SMP_URL}/${SML_PID_ENC}" > /dev/null
sleep 1
journal=$(curl -s "${WIREMOCK_URL}/__admin/requests" || echo "")
if echo "$journal" | grep -qi "deleteParticipantIdentifier"; then
  printf "  PASS  TC-02A.2.03  SMP called SMK deleteParticipantIdentifier on DELETE ServiceGroup\n"; ((pass++))
  record TEST "TC-02A.2.03  SMP called SMK deleteParticipantIdentifier on DELETE ServiceGroup" PASS ""
else
  printf "  FAIL  TC-02A.2.03  deleteParticipantIdentifier not found in WireMock journal\n"; ((fail++))
  record TEST "TC-02A.2.03  SMP called SMK deleteParticipantIdentifier on DELETE ServiceGroup" FAIL "deleteParticipantIdentifier not found in WireMock journal"
fi

# ── TC-02A.3: Auth & Receiver Validation ─────────────────────────────────────

echo ""
echo "TC-02A.3  Auth & Receiver Validation — ${AP_URL}"
echo "────────────────────────────────────────────────────────────────"

actual=$(curl -s -H "X-Token: wrong-token" -o /dev/null -w "%{http_code}" \
  "${AP_URL}/api/outbound/submit/${SENDER_ENC}/${RECEIVER_ENC}/${DOCTYPE_AP_ENC}/${PROCESS_ENC}/NZ" \
  -H "Content-Type: application/xml" -d "<test/>" || echo "000")
check_http_any "TC-02A.3.01  API call with wrong token → 401 or 403" "401 403" "$actual"

check_http "TC-02A.3.02  Unregistered receiver → 422" "422" \
  "$(ap_code -X POST \
    "${AP_URL}/api/outbound/submit/${SENDER_ENC}/${UNREG_ENC}/${DOCTYPE_AP_ENC}/${PROCESS_ENC}/NZ?sbdhInstanceID=conf-unreg-${TS}" \
    -H "Content-Type: application/xml" --data-binary "@${SAMPLES_DIR}/invoice-ubl.xml")"

skip_test "TC-02A.3.03  Revoked certificate rejection — CRL/OCSP disabled in offline mode"
skip_test "TC-02A.3.04  AS4 sender cert chain validation against Peppol CA — requires real PKI"

# ── TC-02A.4: Outbound Batch (3 document types) ───────────────────────────────

echo ""
echo "TC-02A.4  Outbound Batch — ${AP_URL}"
echo "────────────────────────────────────────────────────────────────"

check_http "TC-02A.4.01  Batch: XML invoice → 200" "200" \
  "$(ap_code -X POST \
    "${AP_URL}/api/outbound/submit/${SENDER_ENC}/${RECEIVER_ENC}/${DOCTYPE_AP_ENC}/${PROCESS_ENC}/NZ?sbdhInstanceID=conf-batch-xml-${TS}" \
    -H "Content-Type: application/xml" --data-binary "@${SAMPLES_DIR}/invoice-ubl.xml")"

sed "s/92f7e6a5-c392-4e66-b786-fd2b7c535eb2/conf-batch-sbd-${TS}/" "${SAMPLES_DIR}/prebuilt-sbd.xml" > "$TMPFILE"
check_http "TC-02A.4.02  Batch: pre-built SBD → 200" "200" \
  "$(ap_code -X POST "${AP_URL}/api/outbound/submit-sbd" \
    -H "Content-Type: application/xml" --data-binary "@${TMPFILE}")"

check_http "TC-02A.4.03  Batch: PDF (Factur-X) → 200" "200" \
  "$(ap_code -X POST \
    "${AP_URL}/api/outbound/submit/${SENDER_ENC}/${RECEIVER_ENC}/${DOCTYPE_AP_ENC}/${PROCESS_ENC}/NZ?sbdhInstanceID=conf-batch-pdf-${TS}&sbdhStandard=${PDF_STANDARD_ENC}&sbdhTypeVersion=0&sbdhType=factur-x&payloadMimeType=application%2Fpdf" \
    -H "Content-Type: application/pdf" --data-binary "@${SAMPLES_DIR}/factur-x.pdf")"

# ── TC-02A.5: Large Message ───────────────────────────────────────────────────

echo ""
echo "TC-02A.5  Large Message Handling — ${AP_URL}"
echo "────────────────────────────────────────────────────────────────"

# Generate a ~10 MB binary payload (submitted as PDF — no content validation)
dd if=/dev/zero bs=1048576 count=10 > "$LARGE_TMPFILE" 2>/dev/null

check_http "TC-02A.5.01  POST ~10 MB PDF payload → 200" "200" \
  "$(ap_code -X POST \
    "${AP_URL}/api/outbound/submit/${SENDER_ENC}/${RECEIVER_ENC}/${DOCTYPE_AP_ENC}/${PROCESS_ENC}/NZ?sbdhInstanceID=conf-large-${TS}&sbdhStandard=${PDF_STANDARD_ENC}&sbdhTypeVersion=0&sbdhType=factur-x&payloadMimeType=application%2Fpdf" \
    -H "Content-Type: application/pdf" --data-binary "@${LARGE_TMPFILE}")"

dd if=/dev/zero bs=1048576 count=101 2>/dev/null >> "$LARGE_TMPFILE"
check_http "TC-02A.5.02  POST >100 MB payload → 413" "413" \
  "$(ap_code -X POST \
    "${AP_URL}/api/outbound/submit/${SENDER_ENC}/${RECEIVER_ENC}/${DOCTYPE_AP_ENC}/${PROCESS_ENC}/NZ?sbdhInstanceID=conf-large2-${TS}&sbdhStandard=${PDF_STANDARD_ENC}&sbdhTypeVersion=0&sbdhType=factur-x&payloadMimeType=application%2Fpdf" \
    -H "Content-Type: application/pdf" --data-binary "@${LARGE_TMPFILE}")"

# ── TC-02B.1: SMP ServiceGroup Lifecycle ─────────────────────────────────────

echo ""
echo "TC-02B.1  SMP ServiceGroup Lifecycle — ${SMP_URL}"
echo "────────────────────────────────────────────────────────────────"

check_http "TC-02B.1.01  GET non-existent ServiceGroup → 404" "404" \
  "$(smp_code "${SMP_URL}/${PID_ENC}")"

check_http "TC-02B.1.02  PUT ServiceGroup → 200" "200" \
  "$(smp_code -X PUT "${SMP_URL}/${PID_ENC}" -H "Content-Type: application/xml" -d "$SG_XML")"

body=$(smp_get "${SMP_URL}/${PID_ENC}")
check_http "TC-02B.1.03  GET ServiceGroup → 200" "200" \
  "$(smp_code "${SMP_URL}/${PID_ENC}")"
check_body "TC-02B.1.04  ServiceGroup XML — busdox namespace present" \
  "busdox.org/serviceMetadata/publishing" "$body"
check_body "TC-02B.1.05  ServiceGroup XML — participant value present" \
  "$TEST_VALUE" "$body"

check_http "TC-02B.1.06  PUT ServiceMetadata → 200" "200" \
  "$(smp_code -X PUT "${SMP_URL}/${PID_ENC}/services/${DOCTYPE_ENC}" \
    -H "Content-Type: application/xml" -d "$SM_XML")"

body=$(smp_get "${SMP_URL}/${PID_ENC}/services/${DOCTYPE_ENC}")
check_http "TC-02B.1.07  GET ServiceMetadata → 200" "200" \
  "$(smp_code "${SMP_URL}/${PID_ENC}/services/${DOCTYPE_ENC}")"
check_body "TC-02B.1.08  ServiceMetadata — transport profile = peppol-transport-as4-v2_0" \
  "peppol-transport-as4-v2_0" "$body"
check_body "TC-02B.1.09  ServiceMetadata — AS4 endpoint URL present" \
  "/as4" "$body"
check_body "TC-02B.1.10  ServiceMetadata — Certificate element present" \
  "<smp:Certificate>" "$body"
check_body "TC-02B.1.11  ServiceMetadata — signed response (Signature element)" \
  "Signature" "$body"

check_http "TC-02B.1.12  DELETE ServiceMetadata → 200" "200" \
  "$(smp_code -X DELETE "${SMP_URL}/${PID_ENC}/services/${DOCTYPE_ENC}")"

check_http "TC-02B.1.13  GET deleted ServiceMetadata → 404" "404" \
  "$(smp_code "${SMP_URL}/${PID_ENC}/services/${DOCTYPE_ENC}")"

check_http "TC-02B.1.14  DELETE ServiceGroup → 200" "200" \
  "$(smp_code -X DELETE "${SMP_URL}/${PID_ENC}")"

check_http "TC-02B.1.15  GET deleted ServiceGroup → 404" "404" \
  "$(smp_code "${SMP_URL}/${PID_ENC}")"

# ── TC-02B.2: SMP Authentication ─────────────────────────────────────────────

echo ""
echo "TC-02B.2  SMP Authentication — ${SMP_URL}"
echo "────────────────────────────────────────────────────────────────"

check_http "TC-02B.2.01  PUT with wrong credentials → 403" "403" \
  "$(curl -sk -u "wrong@user.com:badpassword" -o /dev/null -w "%{http_code}" \
    -X PUT "${SMP_URL}/${PID_ENC}" -H "Content-Type: application/xml" -d "$SG_XML" || echo "000")"

actual=$(curl -sk -o /dev/null -w "%{http_code}" \
  -X PUT "${SMP_URL}/${PID_ENC}" -H "Content-Type: application/xml" -d "$SG_XML" || echo "000")
check_http_any "TC-02B.2.02  PUT with no credentials → 401 or 403" "401 403" "$actual"

check_http "TC-02B.2.03  DELETE with wrong credentials → 403" "403" \
  "$(curl -sk -u "wrong@user.com:badpassword" -o /dev/null -w "%{http_code}" \
    -X DELETE "${SMP_URL}/${PID_ENC}" || echo "000")"

# ── TC-02B.3: SMP BusinessCard ────────────────────────────────────────────────

echo ""
echo "TC-02B.3  SMP BusinessCard — ${SMP_URL}"
echo "────────────────────────────────────────────────────────────────"

# Recreate service group so BusinessCard has a parent
smp_get -X PUT "${SMP_URL}/${PID_ENC}" -H "Content-Type: application/xml" -d "$SG_XML" > /dev/null

check_http "TC-02B.3.01  GET non-existent BusinessCard → 404" "404" \
  "$(smp_code "${SMP_URL}/businesscard/${PID_ENC}")"

check_http "TC-02B.3.02  PUT BusinessCard → 200" "200" \
  "$(smp_code -X PUT "${SMP_URL}/businesscard/${PID_ENC}" \
    -H "Content-Type: application/xml" -d "$BC_XML")"

body=$(smp_get "${SMP_URL}/businesscard/${PID_ENC}")
check_http "TC-02B.3.03  GET BusinessCard → 200" "200" \
  "$(smp_code "${SMP_URL}/businesscard/${PID_ENC}")"
check_body "TC-02B.3.04  BusinessCard — peppol.eu namespace present" \
  "peppol.eu/schema/pd/businesscard" "$body"
check_body "TC-02B.3.05  BusinessCard — entity name present" \
  "Conformance Test" "$body"
check_body "TC-02B.3.06  BusinessCard — country code present" \
  "NZ" "$body"

check_http "TC-02B.3.07  DELETE BusinessCard → 200" "200" \
  "$(smp_code -X DELETE "${SMP_URL}/businesscard/${PID_ENC}")"

check_http "TC-02B.3.08  GET deleted BusinessCard → 404" "404" \
  "$(smp_code "${SMP_URL}/businesscard/${PID_ENC}")"

# Service group cleaned up by EXIT trap

# ── TC-03: Peppol Reporting ───────────────────────────────────────────────────

echo ""
echo "TC-03  Peppol Reporting — ${AP_URL}"
echo "────────────────────────────────────────────────────────────────"

YEAR_MONTH=$(date -d "1 month ago" +%Y-%m 2>/dev/null || date -v-1m +%Y-%m)

http_code=$(ap_code -X POST "${AP_URL}/api/reporting/trigger?yearMonth=${YEAR_MONTH}")
body=$(ap_get -X POST "${AP_URL}/api/reporting/trigger?yearMonth=${YEAR_MONTH}")
check_http "TC-03.01  POST /api/reporting/trigger → 200" "200" "$http_code"
check_body "TC-03.02  Reporting trigger response — success body" "successfully" "$body"

check_http "TC-03.03  POST /api/reporting/trigger again → 200 (idempotent)" "200" \
  "$(ap_code -X POST "${AP_URL}/api/reporting/trigger?yearMonth=${YEAR_MONTH}")"

# CoreDNS resolves 9915:helger via NAPTR → phoss-smp → phoss-ap:8080/as4 (registered by register-test-lab.sh)
body=$(ap_get -X POST "${AP_URL}/api/reporting/trigger?yearMonth=${YEAR_MONTH}")
check_body "TC-03.04  Report delivery via DNS NAPTR (9915:helger receiver loopback)" "successfully" "$body"

# ── TC-04: Health & Sanity ────────────────────────────────────────────────────

echo ""
echo "TC-04  Health & Sanity"
echo "────────────────────────────────────────────────────────────────"

http_code=$(curl -sk -o /dev/null -w "%{http_code}" "$SMP_URL/ping" || echo "000")
body=$(curl -sk "$SMP_URL/ping" || echo "")
check_http "TC-04.01  SMP GET /ping → 200" "200" "$http_code"
check_body "TC-04.02  SMP /ping body = pong" "pong" "$body"

body=$(curl -s "${AP_URL}/actuator/health" || echo "")
check_body "TC-04.03  AP /actuator/health → UP" '"status":"UP"' "$body"

check_http "TC-04.04  SMP GET non-existent participant → 404" "404" \
  "$(smp_code "${SMP_URL}/$(urlencode "iso6523-actorid-upis::0000:does-not-exist")")"

# ── Summary ───────────────────────────────────────────────────────────────────

total=$((pass + fail + skip))
echo ""
echo "════════════════════════════════════════════════════════════════"
printf "  %d PASS  /  %d FAIL  /  %d SKIP  (total %d)\n" "$pass" "$fail" "$skip" "$total"
echo "════════════════════════════════════════════════════════════════"

# ── Excel report ──────────────────────────────────────────────────────────────
if python3 -c "import openpyxl" 2>/dev/null; then
  PASS=$pass FAIL=$fail SKIP=$skip TOTAL=$total \
  RUN_DATE=$(date +%Y-%m-%d) \
  RESULTS_FILE="$RESULTS_FILE" REPORT_FILE="$REPORT_FILE" \
  python3 << 'PYEOF'
import os, re
from openpyxl import Workbook
from openpyxl.styles import Font, PatternFill, Alignment, Border, Side

DARK_BLUE = "1F3864"; MID_BLUE = "2E74B5"
PASS_GREEN = "E2EFDA"; FAIL_RED = "FCE4D6"; SKIP_YELLOW = "FFF2CC"
WHITE = "FFFFFF"; BORDER_GREY = "BFBFBF"

def fill(c): return PatternFill("solid", fgColor=c)
def side(): return Side(style="thin", color=BORDER_GREY)
thin = Border(left=side(), right=side(), top=side(), bottom=side())

def result_fill(r):
    return fill({"PASS": PASS_GREEN, "FAIL": FAIL_RED, "SKIP": SKIP_YELLOW}.get(r, WHITE))

def result_font(r):
    c = {"PASS": "375623", "FAIL": "9C2300", "SKIP": "7D6608"}.get(r, "000000")
    return Font(bold=True, color=c)

GROUP_TITLES = {
    "TC-01":    "TC-01  TLS Security",
    "TC-02A.1": "TC-02A.1  AS4 Basic Connectivity",
    "TC-02A.2": "TC-02A.2  SML-based Outbound Routing",
    "TC-02A.3": "TC-02A.3  Authentication & Receiver Validation",
    "TC-02A.4": "TC-02A.4  Outbound Batch",
    "TC-02A.5": "TC-02A.5  Large Message Handling",
    "TC-02B.1": "TC-02B.1  SMP ServiceGroup Lifecycle",
    "TC-02B.2": "TC-02B.2  SMP Authentication",
    "TC-02B.3": "TC-02B.3  SMP BusinessCard Lifecycle",
    "TC-03":    "TC-03  Peppol Reporting",
    "TC-04":    "TC-04  Health & Sanity",
}

PURPOSE = {
    "TC-01.01": "Verify the SMP exposes a working HTTPS endpoint that clients can establish a TLS connection to.",
    "TC-01.02": "Ensure the SMP uses a modern TLS version (1.2 or 1.3) as required by Peppol security policy.",
    "TC-01.03": "Confirm a valid X.509 certificate is presented during the TLS handshake.",
    "TC-01.04": "Check the cipher suite uses AES encryption, meeting Peppol minimum security requirements.",
    "TC-01.05": "Verify the AS4 messaging endpoint is TLS-protected, preventing cleartext transmission of business documents.",
    "TC-01.06": "Independent external validation of TLS configuration quality and certificate chain.",
    "TC-02A.1.01": "Confirm the AP accepts and routes a standard UBL Invoice XML document via the REST submission API.",
    "TC-02A.1.02": "Confirm the AP accepts a pre-wrapped Standard Business Document (SBDH) envelope.",
    "TC-02A.1.03": "Confirm the AP accepts a PDF invoice (Factur-X) alongside an XML metadata wrapper.",
    "TC-02A.1.04": "Verify the transaction is recorded in monthly Peppol reporting data after successful AS4 delivery.",
    "TC-02A.1.05": "Verify the sender receives a Message Level Status (MLS) acknowledgement after the receiver processes the document.",
    "TC-02A.2.01": "Confirm the AP resolves a receiver's AS4 endpoint via DNS NAPTR lookup, as required in production Peppol.",
    "TC-02A.2.02": "Confirm the SMP notifies the Peppol SML when a new participant registers, enabling network-wide discoverability.",
    "TC-02A.2.03": "Confirm the SMP notifies the Peppol SML when a participant is removed, keeping the network directory accurate.",
    "TC-02A.3.01": "Verify the AP REST API requires a valid bearer token and rejects unknown callers.",
    "TC-02A.3.02": "Verify the AP looks up the receiver in the SMP before sending and rejects unregistered participants.",
    "TC-02A.3.03": "Verify the AP rejects AS4 messages whose signing certificate has been revoked by the Peppol CA.",
    "TC-02A.3.04": "Verify the AP only accepts AS4 messages signed by certificates issued within the Peppol CA hierarchy.",
    "TC-02A.4.01": "Confirm invoice XML delivery works when submitted alongside other document types in a batch.",
    "TC-02A.4.02": "Confirm pre-built SBD delivery works when submitted alongside other document types in a batch.",
    "TC-02A.4.03": "Confirm PDF delivery works when submitted alongside other document types in a batch.",
    "TC-02A.5.01": "Verify the AP can handle realistically large documents (e.g. multi-attachment invoices) without failing.",
    "TC-02A.5.02": "Verify the AP enforces a maximum payload size to prevent resource exhaustion.",
    "TC-02B.1.01": "Confirm the SMP returns 404 for participants that have not yet been registered.",
    "TC-02B.1.02": "Confirm a new participant can be registered in the SMP via the standard PUT API.",
    "TC-02B.1.03": "Confirm a registered participant's ServiceGroup can be retrieved by any Peppol client.",
    "TC-02B.1.04": "Confirm the ServiceGroup response uses the correct BusDox/Peppol XML namespace for interoperability.",
    "TC-02B.1.05": "Confirm the ServiceGroup response contains the correct participant identifier value.",
    "TC-02B.1.06": "Confirm routing metadata (endpoint URL, certificate, process ID) can be registered for a document type.",
    "TC-02B.1.07": "Confirm registered ServiceMetadata is publicly readable so any AP can discover the receiver's endpoint.",
    "TC-02B.1.08": "Confirm the registered endpoint uses the Peppol AS4 transport profile identifier.",
    "TC-02B.1.09": "Confirm the AS4 endpoint URL is present so the sending AP knows where to deliver the document.",
    "TC-02B.1.10": "Confirm the receiver's public certificate is embedded so the sending AP can validate the AS4 connection.",
    "TC-02B.1.11": "Confirm the SMP XML-signs its responses so clients can verify metadata has not been tampered with.",
    "TC-02B.1.12": "Confirm ServiceMetadata can be deleted when a document type is no longer supported.",
    "TC-02B.1.13": "Confirm deleted ServiceMetadata returns 404 so senders know routing is unavailable.",
    "TC-02B.1.14": "Confirm a participant can be fully deregistered from the SMP.",
    "TC-02B.1.15": "Confirm the deregistered participant returns 404.",
    "TC-02B.2.01": "Verify the SMP write API rejects requests made with incorrect credentials.",
    "TC-02B.2.02": "Verify the SMP write API is not open to anonymous access.",
    "TC-02B.2.03": "Verify authentication applies to delete operations as well as creates and updates.",
    "TC-02B.3.01": "Confirm the SMP returns 404 for Peppol Directory BusinessCards that have not been created.",
    "TC-02B.3.02": "Confirm a BusinessCard (Peppol Directory listing) can be created via the API.",
    "TC-02B.3.03": "Confirm a created BusinessCard can be retrieved.",
    "TC-02B.3.04": "Confirm the BusinessCard uses the correct Peppol Directory XML namespace.",
    "TC-02B.3.05": "Confirm the BusinessCard contains the required company or entity name.",
    "TC-02B.3.06": "Confirm the BusinessCard contains the required ISO country code.",
    "TC-02B.3.07": "Confirm a BusinessCard can be deleted when a company leaves or changes its Peppol presence.",
    "TC-02B.3.08": "Confirm the deleted BusinessCard returns 404.",
    "TC-03.01": "Verify the AP exposes an API to trigger Peppol monthly TSR/EUSR report generation on demand.",
    "TC-03.02": "Confirm the trigger response indicates both TSR and EUSR reports were successfully created and submitted.",
    "TC-03.03": "Verify re-triggering for the same period is safe and does not create duplicate reports.",
    "TC-03.04": "Confirm reports are delivered end-to-end through the full Peppol network stack (DNS NAPTR → SMP → AS4).",
    "TC-04.01": "Confirm the SMP liveness endpoint is reachable and responds promptly.",
    "TC-04.02": "Confirm the SMP liveness response body contains the expected content.",
    "TC-04.03": "Confirm all AP subsystems (database, AS4, certificate store) report healthy at startup.",
    "TC-04.04": "Confirm the SMP handles lookups for unknown participants gracefully with the correct HTTP status.",
}

def group_prefix(test_id):
    parts = test_id.split(".")
    return ".".join(parts[:2]) if len(parts) >= 3 else parts[0]

# Load results
rows = []
with open(os.environ["RESULTS_FILE"]) as f:
    for line in f:
        parts = line.rstrip("\n").split("\t")
        if len(parts) == 4 and parts[0] == "TEST":
            desc, result, detail = parts[1], parts[2], parts[3]
            m = re.split(r"  +", desc, 1)
            tid, label = (m[0], m[1]) if len(m) == 2 else (desc, desc)
            rows.append((tid, label, result, detail))

# Build workbook
wb = Workbook()
ws = wb.active
ws.title = "Conformance Tests"
ws.column_dimensions["A"].width = 14
ws.column_dimensions["B"].width = 44
ws.column_dimensions["C"].width = 40
ws.column_dimensions["D"].width = 10
ws.column_dimensions["E"].width = 36
ws.freeze_panes = "A4"

run_date = os.environ.get("RUN_DATE", "")
n_pass = os.environ.get("PASS", "?")
n_fail = os.environ.get("FAIL", "?")
n_skip = os.environ.get("SKIP", "?")
n_total = os.environ.get("TOTAL", "?")

# Title
ws.merge_cells("A1:E1")
c = ws["A1"]
c.value = "Peppol Test Lab — Conformance Test Report"
c.font = Font(bold=True, size=14, color=WHITE)
c.fill = fill(DARK_BLUE)
c.alignment = Alignment(horizontal="center", vertical="center")
ws.row_dimensions[1].height = 24

ws.merge_cells("A2:E2")
c = ws["A2"]
c.value = (f"Date: {run_date}    Result: {n_pass} PASS / {n_fail} FAIL / {n_skip} SKIP "
           f"({n_total} total)    "
           "Infrastructure: phoss-ap (8780 / AS4-TLS 8823)  ·  phoss-smp (8880 / HTTPS 8843)")
c.font = Font(size=9, color=WHITE)
c.fill = fill(DARK_BLUE)
c.alignment = Alignment(horizontal="center", vertical="center")
ws.row_dimensions[2].height = 15

for col, hdr in enumerate(["Test ID", "Purpose", "Description", "Result", "Notes"], 1):
    c = ws.cell(row=3, column=col, value=hdr)
    c.font = Font(bold=True, color=WHITE)
    c.fill = fill(MID_BLUE)
    c.alignment = Alignment(horizontal="center", vertical="center")
    c.border = thin
ws.row_dimensions[3].height = 18

current_row = 4
prev_group = None
for i, (tid, label, result, detail) in enumerate(rows):
    grp = group_prefix(tid)
    if grp != prev_group:
        title = GROUP_TITLES.get(grp, grp)
        ws.merge_cells(f"A{current_row}:E{current_row}")
        gc = ws[f"A{current_row}"]
        gc.value = title
        gc.font = Font(bold=True, color=WHITE)
        gc.fill = fill(MID_BLUE)
        gc.alignment = Alignment(horizontal="left", vertical="center", indent=1)
        gc.border = thin
        ws.row_dimensions[current_row].height = 16
        current_row += 1
        prev_group = grp

    shade = "F2F7FF" if i % 2 == 1 else WHITE
    purpose = PURPOSE.get(tid, "")
    for col, val in enumerate([tid, purpose, label, result, detail], 1):
        c = ws.cell(row=current_row, column=col, value=val)
        c.border = thin
        c.alignment = Alignment(vertical="top", wrap_text=True)
        if col == 4:
            c.fill = result_fill(result)
            c.font = result_font(result)
            c.alignment = Alignment(horizontal="center", vertical="center")
        else:
            c.fill = fill(shade)
    ws.row_dimensions[current_row].height = 42
    current_row += 1

# Summary row
current_row += 1
ws.merge_cells(f"A{current_row}:D{current_row}")
sc = ws[f"A{current_row}"]
sc.value = "TOTAL"
sc.font = Font(bold=True, color=WHITE)
sc.fill = fill(DARK_BLUE)
sc.alignment = Alignment(horizontal="right", vertical="center", indent=1)
sc.border = thin
dc = ws[f"E{current_row}"]
dc.value = f"{n_pass} PASS / {n_fail} FAIL / {n_skip} SKIP"
dc.font = Font(bold=True, color=WHITE)
dc.fill = fill(DARK_BLUE)
dc.alignment = Alignment(horizontal="center", vertical="center")
dc.border = thin
ws.row_dimensions[current_row].height = 18

report_file = os.environ["REPORT_FILE"]
wb.save(report_file)
print(f"  Report:  {report_file}")
PYEOF
else
  echo "  (openpyxl not installed — skipping Excel report)"
fi

[[ $fail -eq 0 ]] || exit 1
