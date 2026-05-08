FROM tomcat:10.1-jdk21

LABEL maintainer="Test Lab"
LABEL org.opencontainers.image.title="phoss-smp"
LABEL org.opencontainers.image.description="Peppol SMP (SQL backend) — test-lab build"

# JVM tuning + config file location
ENV CATALINA_OPTS="\
  -Djava.security.egd=file:/dev/urandom \
  -XX:InitialRAMPercentage=10 \
  -XX:MinRAMPercentage=50 \
  -XX:MaxRAMPercentage=80 \
  -Dconfig.file=/config/application.properties"

# Allow encoded slashes in URLs (needed for Peppol participant IDs that contain '/')
RUN sed -i 's|connectionTimeout="20000"|connectionTimeout="20000" encodedSolidusHandling="decode"|' \
      "$CATALINA_HOME/conf/server.xml"

# Remove default ROOT webapp
RUN rm -rf "$CATALINA_HOME/webapps/ROOT"

# Copy exploded WAR — Docker build context must be the phoss-smp project root
COPY phoss-smp-webapp-sql/target/phoss-smp-webapp-sql-*-SNAPSHOT/ "$CATALINA_HOME/webapps/ROOT/"

VOLUME /var/phoss-smp/data
VOLUME /config

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --retries=5 \
  CMD curl -sf http://localhost:8080/ping || exit 1
