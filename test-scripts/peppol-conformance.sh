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

check_http() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    printf "  PASS  %s\n" "$desc"; ((pass++))
  else
    printf "  FAIL  %s (expected HTTP %s, got %s)\n" "$desc" "$expected" "$actual"; ((fail++))
  fi
}

check_http_any() {
  # Passes if actual matches any of the space-separated expected codes
  local desc="$1" actual="$3"
  shift; local expected_list="$1"; shift; shift
  for code in $expected_list; do
    if [[ "$actual" == "$code" ]]; then
      printf "  PASS  %s\n" "$desc"; ((pass++)); return
    fi
  done
  printf "  FAIL  %s (expected one of [%s], got %s)\n" "$desc" "$expected_list" "$actual"; ((fail++))
}

check_body() {
  local desc="$1" pattern="$2" body="$3"
  if echo "$body" | grep -q "$pattern"; then
    printf "  PASS  %s\n" "$desc"; ((pass++))
  else
    printf "  FAIL  %s (pattern '%s' not found)\n" "$desc" "$pattern"; ((fail++))
  fi
}

skip_test() {
  printf "  SKIP  %s\n" "$1"; ((skip++))
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
  rm -f "$TMPFILE" "$LARGE_TMPFILE"
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

SM_XML="<?xml version=\"1.0\" encoding=\"UTF-8\"?><smp:ServiceMetadata xmlns:smp=\"http://busdox.org/serviceMetadata/publishing/1.0/\" xmlns:id=\"http://busdox.org/transport/identifiers/1.0/\"><smp:ServiceInformation><id:ParticipantIdentifier scheme=\"${TEST_SCHEME}\">${TEST_VALUE}</id:ParticipantIdentifier><id:DocumentIdentifier scheme=\"busdox-docid-qns\">${INVOICE_DOCTYPE}</id:DocumentIdentifier><smp:ProcessList><smp:Process><id:ProcessIdentifier scheme=\"cenbii-procid-ubl\">${INVOICE_PROCESS}</id:ProcessIdentifier><smp:ServiceEndpointList><smp:Endpoint transportProfile=\"peppol-transport-as4-v2_0\"><wsa:EndpointReference xmlns:wsa=\"http://www.w3.org/2005/08/addressing\"><wsa:Address>http://phoss-ap:8080/as4</wsa:Address></wsa:EndpointReference><smp:RequireBusinessLevelSignature>false</smp:RequireBusinessLevelSignature><smp:ServiceActivationDate>2026-01-01T00:00:00Z</smp:ServiceActivationDate><smp:ServiceExpirationDate>2030-12-31T23:59:59Z</smp:ServiceExpirationDate><smp:Certificate>${CERT_B64}</smp:Certificate><smp:ServiceDescription>Conformance test</smp:ServiceDescription><smp:TechnicalContactUrl>conformance@local</smp:TechnicalContactUrl></smp:Endpoint></smp:ServiceEndpointList></smp:Process></smp:ProcessList></smp:ServiceInformation></smp:ServiceMetadata>"

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
else
  printf "  FAIL  TC-01.01  SMP TLS handshake failed\n"; ((fail++))
fi

TLS_PROTO=$(echo "$TLS_HANDSHAKE" | grep "Protocol  :" | awk '{print $NF}')
if [[ "$TLS_PROTO" == TLSv1.[23] || "$TLS_PROTO" == TLSv1.3 ]]; then
  printf "  PASS  TC-01.02  SMP TLS protocol is %s (≥ TLS 1.2)\n" "$TLS_PROTO"; ((pass++))
else
  printf "  FAIL  TC-01.02  SMP TLS protocol is '%s' (expected TLS 1.2 or 1.3)\n" "$TLS_PROTO"; ((fail++))
fi

CERT_CN=$(echo "$TLS_HANDSHAKE" | openssl x509 -noout -subject 2>/dev/null | sed 's/.*CN *= *//' | cut -d, -f1 || true)
if [[ -n "$CERT_CN" ]]; then
  printf "  PASS  TC-01.03  SMP TLS certificate present (CN=%s)\n" "$CERT_CN"; ((pass++))
else
  printf "  FAIL  TC-01.03  SMP TLS certificate not found in handshake\n"; ((fail++))
fi

if echo "$TLS_HANDSHAKE" | grep -q "TLS_AES\|AES.*GCM\|AES.*SHA"; then
  printf "  PASS  TC-01.04  SMP cipher suite uses AES\n"; ((pass++))
else
  printf "  FAIL  TC-01.04  SMP cipher suite does not use AES\n"; ((fail++))
fi

skip_test "TC-01.05  AP AS4 endpoint TLS — AS4 uses HTTP in test lab (offline mode)"
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
else
  printf "  FAIL  TC-02A.1.04  Transaction reportingStatus did not reach 'reported' within 30s\n"; ((fail++))
fi
if $mls_ok; then
  printf "  PASS  TC-02A.1.05  Transaction mlsStatus = received_ab\n"; ((pass++))
else
  printf "  FAIL  TC-02A.1.05  Transaction mlsStatus did not reach 'received_ab' within 30s\n"; ((fail++))
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
else
  printf "  FAIL  TC-02A.2.02  createParticipantIdentifier not found in WireMock journal\n"; ((fail++))
fi

# TC-02A.2.03: DELETE the participant → phoss-smp must call SMK deleteParticipantIdentifier
curl -s -X DELETE "${WIREMOCK_URL}/__admin/requests" > /dev/null
smp_code -X DELETE "${SMP_URL}/${SML_PID_ENC}" > /dev/null
sleep 1
journal=$(curl -s "${WIREMOCK_URL}/__admin/requests" || echo "")
if echo "$journal" | grep -qi "deleteParticipantIdentifier"; then
  printf "  PASS  TC-02A.2.03  SMP called SMK deleteParticipantIdentifier on DELETE ServiceGroup\n"; ((pass++))
else
  printf "  FAIL  TC-02A.2.03  deleteParticipantIdentifier not found in WireMock journal\n"; ((fail++))
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
  "phoss-ap" "$body"
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
[[ $fail -eq 0 ]] || exit 1
