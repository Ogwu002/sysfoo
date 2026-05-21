kerfile — cfo service (Maven / Java)
# Multi-stage build:
#   Stage 1 — builder : compiles and packages the JAR with Maven
#   Stage 2 — runtime : runs the JAR on a lean JRE image
#
# BUILD_DATE and VCS_REF are injected by the Jenkinsfile
# Package stage via --build-arg.
# APP_PORT = 9000 (matches Jenkinsfile)
# ============================================================


# ════════════════════════════════════════════════════════════
# STAGE 1 — Builder
# Full JDK + Maven needed here to compile and package.
# This stage is discarded after the JAR is extracted —
# none of the build tools end up in the final image.
# ════════════════════════════════════════════════════════════
FROM maven:3.9-eclipse-temurin-21-alpine AS builder

WORKDIR /build

# ── Dependency layer (cache-friendly) ────────────────────────
# Copy the POM first and download all dependencies.
# As long as pom.xml does not change, Docker reuses this cached
# layer even when source files are edited — saving 1-3 minutes
# on every incremental build.
COPY pom.xml .
RUN mvn dependency:go-offline -q

# ── Source ────────────────────────────────────────────────────
# Copied after dependency download so code edits do not bust
# the expensive dependency cache layer.
COPY src ./src

# ── Package ───────────────────────────────────────────────────
# -DskipTests: tests are already run by the Jenkins Test stage.
#              Running them again here would double the build time.
RUN mvn package -DskipTests -q


# ════════════════════════════════════════════════════════════
# STAGE 2 — Runtime
# Lean JRE-only image — no JDK, no Maven, no build cache.
# eclipse-temurin is the recommended OpenJDK distribution:
#   - Actively maintained by the Adoptium working group
#   - Regular security patches
#   - Alpine variant keeps the image ~90 MB vs ~300 MB (Debian)
# ════════════════════════════════════════════════════════════
FROM eclipse-temurin:21-jre-alpine AS runtime

# ── Build-time arguments ──────────────────────────────────────
# Injected by the Jenkinsfile Package stage:
#   --build-arg BUILD_DATE=...
#   --build-arg VCS_REF=...
ARG BUILD_DATE
ARG VCS_REF

# ── Image metadata ────────────────────────────────────────────
LABEL maintainer="auduj01" \
      org.opencontainers.image.title="cfo" \
      org.opencontainers.image.description="CFO Maven application service" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.source="https://github.com/auduj01/cfo"

WORKDIR /app

# ── Copy only the packaged JAR from the builder stage ─────────
# Wildcard handles version numbers: cfo-1.0.0.jar, cfo-0.0.1-SNAPSHOT.jar
COPY --from=builder /build/target/*.jar app.jar

# ── Non-root user ─────────────────────────────────────────────
RUN addgroup -S appgroup \
    && adduser -S appuser -G appgroup \
    && chown -R appuser:appgroup /app

USER appuser

# ── Runtime environment ───────────────────────────────────────
ENV JAVA_OPTS="-XX:+UseContainerSupport \
               -XX:MaxRAMPercentage=75.0 \
               -Djava.security.egd=file:/dev/./urandom" \
    SERVER_PORT=9000 \
    SPRING_PROFILES_ACTIVE=production

# ── Expose port declared in Jenkinsfile (APP_PORT=9000) ───────
EXPOSE 9000

# ── Health check ──────────────────────────────────────────────
# start-period=60s gives the JVM and Spring context time to
# fully initialise before failures start counting.
# Adjust path if not using Spring Boot actuator:
#   Spring Boot actuator default : /actuator/health
#   Custom                       : /health  or  /api/health
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
  CMD wget -qO- http://localhost:9000/actuator/health || exit 1

# ── Entry point ───────────────────────────────────────────────
# Shell form so JAVA_OPTS is expanded correctly.
ENTRYPOINT ["sh", "-c", "java $JAVA_OPTS -jar app.jar"]
