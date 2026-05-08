#!/usr/bin/env bash
# Re-registers all test-lab participants and document types in the SMP.
# Safe to run multiple times — all operations are idempotent PUTs.
#
# Usage:
#   ./register-test-lab.sh [SMP_URL] [AP_ENDPOINT] [CERT_FILE]
#
# Defaults:
#   SMP_URL      http://localhost:8880
#   AP_ENDPOINT  http://phoss-ap:8080/as4   (Docker-internal, as seen by the AP)
#   CERT_FILE    ../phoss-ap/certs/test-ap.crt

set -euo pipefail

SMP_URL="${1:-http://localhost:8880}"
AP_ENDPOINT="${2:-http://phoss-ap:8080/as4}"
CERT_FILE="${3:-$(dirname "$0")/../../phoss-ap/certs/test-ap.crt}"
SMP_USER="admin@helger.com:password"

# ── Document types ────────────────────────────────────────────────────────────

INVOICE_DOCTYPE="urn:oasis:names:specification:ubl:schema:xsd:Invoice-2::Invoice##urn:cen.eu:en16931:2017#compliant#urn:fdc:peppol.eu:2017:poacc:billing:3.0::2.1"
INVOICE_PROCESS="urn:fdc:peppol.eu:2017:poacc:billing:01:1.0"

ORDER_DOCTYPE="urn:oasis:names:specification:ubl:schema:xsd:Order-2::Order##urn:fdc:peppol.eu:2017:poacc:ordering:01:1.0::2.1"
ORDER_PROCESS="urn:fdc:peppol.eu:2017:poacc:ordering:01:1.0"

TSR_DOCTYPE="urn:fdc:peppol:transaction-statistics-report:1.0::TransactionStatisticsReport##urn:fdc:peppol.eu:edec:trns:transaction-statistics-reporting:1.0::1.0"
EUSR_DOCTYPE="urn:fdc:peppol:end-user-statistics-report:1.1::EndUserStatisticsReport##urn:fdc:peppol.eu:edec:trns:end-user-statistics-report:1.1::1.1"
REPORTING_PROCESS="urn:fdc:peppol.eu:edec:bis:reporting:1.0"

# ── Participants ──────────────────────────────────────────────────────────────
# Add or remove entries in the format "scheme::value"

PARTICIPANTS=(
  "iso6523-actorid-upis::0088:1111111111111"
  "iso6523-actorid-upis::0088:2222222222222"
  "iso6523-actorid-upis::0088:3333333333333"
)

# ── Helpers ───────────────────────────────────────────────────────────────────

urlencode() {
  python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1"
}

put_service_group() {
  local scheme="$1" value="$2"
  local pid_enc
  pid_enc=$(urlencode "${scheme}::${value}")
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
    "${SMP_URL}/${pid_enc}" \
    -u "${SMP_USER}" \
    -H "Content-Type: application/xml" \
    -d "<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<smp:ServiceGroup xmlns:smp=\"http://busdox.org/serviceMetadata/publishing/1.0/\"
                  xmlns:id=\"http://busdox.org/transport/identifiers/1.0/\">
  <id:ParticipantIdentifier scheme=\"${scheme}\">${value}</id:ParticipantIdentifier>
  <smp:ServiceMetadataReferenceCollection/>
</smp:ServiceGroup>")
  echo "  ServiceGroup ${scheme}::${value}: ${http_code}"
}

put_service_metadata() {
  local scheme="$1" value="$2" doctype_val="$3" process_val="$4" cert_b64="$5"
  local pid_enc doctype_enc
  pid_enc=$(urlencode "${scheme}::${value}")
  doctype_enc=$(urlencode "busdox-docid-qns::${doctype_val}")
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
    "${SMP_URL}/${pid_enc}/services/${doctype_enc}" \
    -u "${SMP_USER}" \
    -H "Content-Type: application/xml" \
    -d "<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<smp:ServiceMetadata xmlns:smp=\"http://busdox.org/serviceMetadata/publishing/1.0/\"
                     xmlns:id=\"http://busdox.org/transport/identifiers/1.0/\">
  <smp:ServiceInformation>
    <id:ParticipantIdentifier scheme=\"${scheme}\">${value}</id:ParticipantIdentifier>
    <id:DocumentIdentifier scheme=\"busdox-docid-qns\">${doctype_val}</id:DocumentIdentifier>
    <smp:ProcessList>
      <smp:Process>
        <id:ProcessIdentifier scheme=\"cenbii-procid-ubl\">${process_val}</id:ProcessIdentifier>
        <smp:ServiceEndpointList>
          <smp:Endpoint transportProfile=\"peppol-transport-as4-v2_0\">
            <wsa:EndpointReference xmlns:wsa=\"http://www.w3.org/2005/08/addressing\">
              <wsa:Address>${AP_ENDPOINT}</wsa:Address>
            </wsa:EndpointReference>
            <smp:RequireBusinessLevelSignature>false</smp:RequireBusinessLevelSignature>
            <smp:ServiceActivationDate>2026-01-01T00:00:00Z</smp:ServiceActivationDate>
            <smp:ServiceExpirationDate>2030-12-31T23:59:59Z</smp:ServiceExpirationDate>
            <smp:Certificate>${cert_b64}</smp:Certificate>
            <smp:ServiceDescription>Test AP endpoint</smp:ServiceDescription>
            <smp:TechnicalContactUrl>testlab@local</smp:TechnicalContactUrl>
          </smp:Endpoint>
        </smp:ServiceEndpointList>
      </smp:Process>
    </smp:ProcessList>
  </smp:ServiceInformation>
</smp:ServiceMetadata>")
  echo "  ServiceMetadata busdox-docid-qns::$(echo "$doctype_val" | cut -d: -f1-3)...: ${http_code}"
}

# ── Main ──────────────────────────────────────────────────────────────────────

if [[ ! -f "$CERT_FILE" ]]; then
  echo "ERROR: cert file not found: $CERT_FILE" >&2
  exit 1
fi

CERT_B64=$(openssl x509 -in "$CERT_FILE" -outform DER | base64 -w 0)

echo "SMP:         $SMP_URL"
echo "AP endpoint: $AP_ENDPOINT"
echo "Cert:        $CERT_FILE"
echo ""

for PARTICIPANT in "${PARTICIPANTS[@]}"; do
  SCHEME="${PARTICIPANT%%::*}"
  VALUE="${PARTICIPANT#*::}"
  echo "Registering ${PARTICIPANT}..."
  put_service_group "$SCHEME" "$VALUE"
  put_service_metadata "$SCHEME" "$VALUE" "$INVOICE_DOCTYPE" "$INVOICE_PROCESS" "$CERT_B64"
  put_service_metadata "$SCHEME" "$VALUE" "$ORDER_DOCTYPE"   "$ORDER_PROCESS"   "$CERT_B64"
  echo ""
done

# ── Offline OpenPeppol reporting receiver ─────────────────────────────────────
# Routes TSR/EUSR report submissions back to the AP's own AS4 endpoint so the
# monthly reporting scheduler works without a real OpenPeppol connection.
echo "Registering offline reporting receiver (iso6523-actorid-upis::9915:helger)..."
put_service_group "iso6523-actorid-upis" "9915:helger"
put_service_metadata "iso6523-actorid-upis" "9915:helger" "$TSR_DOCTYPE"  "$REPORTING_PROCESS" "$CERT_B64"
put_service_metadata "iso6523-actorid-upis" "9915:helger" "$EUSR_DOCTYPE" "$REPORTING_PROCESS" "$CERT_B64"
echo ""

echo "Done."
