-- Test-lab Flyway migration: pre-configure WireMock as the SML endpoint.
-- Runs before the app starts, so SMPSettings picks up sml.enabled=true on first load.
-- Uses ON CONFLICT DO UPDATE so re-deploying is idempotent.

INSERT INTO smp_sml_info (id, displayname, dnszone, serviceurl, managesmp, manageparticipant, clientcert)
VALUES ('wiremock-sml', 'WireMock SML (test lab)', 'edelivery.tech.ec.europa.eu.',
        'http://wiremock:8080',
        '/sml/managesmp',
        '/sml/manageparticipant',
        false)
ON CONFLICT (id) DO NOTHING;

INSERT INTO smp_settings (id, value) VALUES ('sml-enabled', 'true')
ON CONFLICT (id) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO smp_settings (id, value) VALUES ('sml-required', 'false')
ON CONFLICT (id) DO UPDATE SET value = EXCLUDED.value;

INSERT INTO smp_settings (id, value) VALUES ('smlinfo-id', 'wiremock-sml')
ON CONFLICT (id) DO UPDATE SET value = EXCLUDED.value;
