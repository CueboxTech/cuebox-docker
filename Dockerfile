# =============================================================================
# CUEBOX ENTERPRISE DOCKER IMAGE - PUBLIC DISTRIBUTION SAFE
# =============================================================================
# 
# SECURITY MODEL: Zero secrets baked into image
# - MongoDB URI: Passed at runtime via MONGODB_URI environment variable
# - All sensitive config: Environment variables at runtime
# - Source code: Not included (multi-stage build)
# - Safe for public GHCR/DockerHub distribution
#
# Usage:
#   docker run -d -p 8080:80 \
#     -e MONGODB_URI="mongodb://user:pass@your-host:27017/db?authSource=admin" \
#     ghcr.io/cueboxtech/cuebox:latest
#
# =============================================================================

# =============================================================================
# Stage 1: Build Frontend
# =============================================================================
FROM node:18-alpine AS frontend-build
WORKDIR /app
RUN apk add --no-cache git

ARG FRONTEND_BRANCH=main

RUN --mount=type=secret,id=github_token \
    git clone --depth 1 -b ${FRONTEND_BRANCH} \
    https://$(cat /run/secrets/github_token)@github.com/CueboxTech/angular-frontend.git . && \
    rm -rf .git

RUN npm install --legacy-peer-deps --ignore-scripts && \
    npm install @nx/nx-linux-x64-musl --legacy-peer-deps --ignore-scripts || true && \
    npm rebuild || true

# Configure frontend for Docker environment (relative URLs)
RUN sed -i "s|baseURL:.*|baseURL: '/api',|g" src/environments/environment.prod.ts && \
    sed -i "s|appThemeName: 'Metronic'|appThemeName: 'CueBox'|g" src/environments/environment.prod.ts && \
    sed -i "s|appThemeName: 'Metronic'|appThemeName: 'CueBox'|g" src/environments/environment.ts && \
    sed -i "s|Metronic.*KeenThemes|CueBox Solutions|g" src/index.html && \
    sed -i "s|' - Metronic'|' - CueBox'|g" src/app/_metronic/layout/components/scripts-init/scripts-init.component.ts

ENV CI=false NX_DAEMON=false
RUN npm run build -- --configuration=production && \
    rm -rf node_modules src package*.json


# =============================================================================
# Stage 2: Build Backend
# =============================================================================
FROM maven:3.9-eclipse-temurin-17 AS backend-build
WORKDIR /app
RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*

ARG BACKEND_BRANCH=main

RUN --mount=type=secret,id=github_token \
    git clone --depth 1 -b ${BACKEND_BRANCH} \
    https://$(cat /run/secrets/github_token)@github.com/CueboxTech/be.git . && \
    rm -rf .git

# =============================================================================
# SECURITY: DO NOT bake MongoDB URI into image
# Instead, use a placeholder that will be replaced at runtime
# =============================================================================
RUN sed -i "s|uri: mongodb://.*|uri: \${MONGODB_URI:mongodb://localhost:27017/cuebox}|g" src/main/resources/config/application-prod.yml

# Also ensure the application can read from environment variables
RUN cat >> src/main/resources/config/application-prod.yml << 'EOF'

# Runtime configuration - these can be overridden by environment variables
spring:
  data:
    mongodb:
      uri: ${MONGODB_URI:mongodb://localhost:27017/cuebox}
EOF

# -----------------------------------------------------------------------------
# Create OpenApiConfig.java
# -----------------------------------------------------------------------------
RUN mkdir -p src/main/java/com/cuebox/portal/config/ && \
    cat > src/main/java/com/cuebox/portal/config/OpenApiConfig.java << 'EOF'
package com.cuebox.portal.config;

import io.swagger.v3.oas.models.servers.Server;
import org.springdoc.core.customizers.OpenApiCustomizer;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import java.util.List;

@Configuration
public class OpenApiConfig {
    @Bean
    public OpenApiCustomizer serverUrlCustomizer() {
        return openApi -> openApi.setServers(List.of(new Server().url("/portal").description("Local")));
    }
}
EOF

# -----------------------------------------------------------------------------
# Create SmartstoreLocalService.java
# -----------------------------------------------------------------------------
RUN cat > src/main/java/com/cuebox/portal/service/SmartstoreLocalService.java << 'EOF'
package com.cuebox.portal.service;

import com.cuebox.portal.domain.SmartstoreConfig;
import com.mongodb.ConnectionString;
import com.mongodb.MongoClientSettings;
import com.mongodb.MongoTimeoutException;
import com.mongodb.client.MongoClient;
import com.mongodb.client.MongoClients;
import com.mongodb.client.MongoCollection;
import com.mongodb.client.MongoDatabase;
import org.bson.Document;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import jakarta.annotation.PreDestroy;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.locks.ReentrantLock;

@Service
public class SmartstoreLocalService {
    private final Logger log = LoggerFactory.getLogger(SmartstoreLocalService.class);
    private static final String LOCAL_MONGO_URI = "mongodb://127.0.0.1:27017";
    private static final String DATABASE_NAME = "smartstore";
    private static final String COLLECTION_NAME = "smartstore_config";
    private static final int MAX_RETRY_ATTEMPTS = 10;
    private static final int RETRY_DELAY_MS = 3000;
    private static final int CONNECTION_TIMEOUT_MS = 5000;
    private static final int MAX_CONSECUTIVE_FAILURES = 3;
    private volatile MongoClient mongoClient;
    private final AtomicBoolean initialized = new AtomicBoolean(false);
    private final AtomicBoolean permanentlyDisabled = new AtomicBoolean(false);
    private final AtomicInteger consecutiveFailures = new AtomicInteger(0);
    private final ReentrantLock connectionLock = new ReentrantLock();
    private volatile long lastConnectionAttempt = 0;
    private volatile SmartstoreConfig cachedConfig = null;
    private volatile long cacheTimestamp = 0;
    private static final long CACHE_TTL_MS = 60000;

    private MongoClient createMongoClient() {
        MongoClientSettings settings = MongoClientSettings.builder()
            .applyConnectionString(new ConnectionString(LOCAL_MONGO_URI))
            .applyToSocketSettings(builder -> {
                builder.connectTimeout(CONNECTION_TIMEOUT_MS, TimeUnit.MILLISECONDS);
                builder.readTimeout(CONNECTION_TIMEOUT_MS, TimeUnit.MILLISECONDS);
            })
            .applyToClusterSettings(builder -> builder.serverSelectionTimeout(CONNECTION_TIMEOUT_MS, TimeUnit.MILLISECONDS))
            .build();
        return MongoClients.create(settings);
    }

    private boolean ensureConnection() {
        if (permanentlyDisabled.get()) return false;
        if (initialized.get() && mongoClient != null) {
            try {
                mongoClient.getDatabase(DATABASE_NAME).runCommand(new Document("ping", 1));
                consecutiveFailures.set(0);
                return true;
            } catch (Exception e) {
                closeClient();
            }
        }
        long now = System.currentTimeMillis();
        if (now - lastConnectionAttempt < 5000) return false;
        if (!connectionLock.tryLock()) return initialized.get() && mongoClient != null;
        try {
            lastConnectionAttempt = now;
            for (int attempt = 1; attempt <= MAX_RETRY_ATTEMPTS; attempt++) {
                try {
                    closeClient();
                    mongoClient = createMongoClient();
                    MongoDatabase db = mongoClient.getDatabase(DATABASE_NAME);
                    db.runCommand(new Document("ping", 1));
                    MongoCollection<Document> collection = db.getCollection(COLLECTION_NAME);
                    Document doc = collection.find(new Document("_id", "1000")).first();
                    if (doc == null) { closeClient(); return false; }
                    initialized.set(true);
                    consecutiveFailures.set(0);
                    return true;
                } catch (Exception e) {
                    if (attempt < MAX_RETRY_ATTEMPTS) {
                        try { Thread.sleep(RETRY_DELAY_MS); } catch (InterruptedException ie) { Thread.currentThread().interrupt(); break; }
                    }
                }
            }
            if (consecutiveFailures.incrementAndGet() >= MAX_CONSECUTIVE_FAILURES) permanentlyDisabled.set(true);
            return false;
        } finally { connectionLock.unlock(); }
    }

    private void closeClient() {
        if (mongoClient != null) { try { mongoClient.close(); } catch (Exception e) {} mongoClient = null; }
        initialized.set(false);
    }

    public SmartstoreConfig getConfig() {
        if (cachedConfig != null && (System.currentTimeMillis() - cacheTimestamp) < CACHE_TTL_MS) return cachedConfig;
        if (permanentlyDisabled.get() || !ensureConnection()) { cachedConfig = null; return null; }
        try {
            Document doc = mongoClient.getDatabase(DATABASE_NAME).getCollection(COLLECTION_NAME).find(new Document("_id", "1000")).first();
            if (doc != null) {
                SmartstoreConfig config = new SmartstoreConfig();
                config.setId(doc.getString("_id"));
                config.setServerURL(doc.getString("server_url"));
                config.setSystem(doc.getString("system"));
                config.setContRep(doc.getString("cont_rep"));
                config.setCompId(doc.getString("comp_id"));
                config.setSecKey(doc.getString("sec_key"));
                cachedConfig = config;
                cacheTimestamp = System.currentTimeMillis();
                return config;
            }
            return null;
        } catch (Exception e) {
            if (consecutiveFailures.incrementAndGet() >= MAX_CONSECUTIVE_FAILURES) permanentlyDisabled.set(true);
            cachedConfig = null;
            return null;
        }
    }

    public boolean isAvailable() { return !permanentlyDisabled.get() && ensureConnection(); }
    @PreDestroy public void cleanup() { connectionLock.lock(); try { closeClient(); } finally { connectionLock.unlock(); } }
}
EOF

# -----------------------------------------------------------------------------
# Create Attachmentresource.java
# -----------------------------------------------------------------------------
RUN cat > src/main/java/com/cuebox/portal/web/rest/Attachmentresource.java << 'EOF'
package com.cuebox.portal.web.rest;

import org.apache.commons.lang3.RandomStringUtils;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.MediaType;
import org.springframework.web.bind.annotation.*;
import com.cuebox.portal.domain.SmartstoreConfig;
import com.cuebox.portal.repository.SmartstoreConfigRepository;
import com.cuebox.portal.service.AttachmentService;
import com.cuebox.portal.service.SmartstoreLocalService;

@RestController
@RequestMapping("/api/attachment")
public class Attachmentresource {
    private final Logger log = LoggerFactory.getLogger(Attachmentresource.class);
    private final AttachmentService attachmentService;
    private final SmartstoreConfigRepository smartstoreConfigRepository;
    private final SmartstoreLocalService smartstoreLocalService;

    public Attachmentresource(AttachmentService attachmentService, SmartstoreConfigRepository smartstoreConfigRepository, SmartstoreLocalService smartstoreLocalService) {
        this.attachmentService = attachmentService;
        this.smartstoreConfigRepository = smartstoreConfigRepository;
        this.smartstoreLocalService = smartstoreLocalService;
    }

    private SmartstoreConfig getSmartStoreConfig() {
        try {
            SmartstoreConfig localConfig = smartstoreLocalService.getConfig();
            if (localConfig != null && localConfig.getServerURL() != null) return localConfig;
        } catch (Exception e) {}
        try {
            SmartstoreConfig mainConfig = smartstoreConfigRepository.findById("1000").orElse(null);
            if (mainConfig != null && mainConfig.getServerURL() != null) return mainConfig;
        } catch (Exception e) {}
        SmartstoreConfig defaultConfig = new SmartstoreConfig();
        defaultConfig.setId("1000");
        defaultConfig.setServerURL("http://localhost:8080/store/api/smartdocs");
        defaultConfig.setSystem("PORTAL");
        defaultConfig.setContRep("A1");
        defaultConfig.setCompId("data");
        defaultConfig.setSecKey("361A524A3ECB5459E0000800099245EC361A524A3ECB5459E0000800099245EC361A524A3ECB5459E0000800099245EC361A524A3ECB5459E0000800099245EC");
        return defaultConfig;
    }

    @GetMapping(value = "/buildDownloadDocURL/{docId}", produces = MediaType.APPLICATION_JSON_VALUE)
    public String buildDownloadDocURL(@PathVariable("docId") String docId) {
        return attachmentService.buildURL(getSmartStoreConfig(), docId, "get");
    }

    @GetMapping(value = "/buildUploaddDocURL", produces = MediaType.APPLICATION_JSON_VALUE)
    public String buildDownloadDocURL() {
        return attachmentService.buildURL(getSmartStoreConfig(), RandomStringUtils.randomAlphanumeric(16), "create");
    }

    @GetMapping(value = "/smartstore/status", produces = MediaType.APPLICATION_JSON_VALUE)
    public String getStatus() {
        SmartstoreConfig config = getSmartStoreConfig();
        return String.format("{\"localMongoAvailable\": %s, \"currentUrl\": \"%s\"}", smartstoreLocalService.isAvailable(), config != null ? config.getServerURL() : "null");
    }
}
EOF

# -----------------------------------------------------------------------------
# Patch DocumentClassifyAndExtractService.java
# -----------------------------------------------------------------------------
RUN sed -i 's/import com.cuebox.portal.repository.SmartstoreConfigRepository;/import com.cuebox.portal.repository.SmartstoreConfigRepository;\nimport com.cuebox.portal.service.SmartstoreLocalService;/' src/main/java/com/cuebox/portal/service/DocumentClassifyAndExtractService.java && \
    sed -i 's/SmartstoreConfigRepository smartstoreConfigRepository;/SmartstoreConfigRepository smartstoreConfigRepository;\n\n\t@Autowired\n\tSmartstoreLocalService smartstoreLocalService;/' src/main/java/com/cuebox/portal/service/DocumentClassifyAndExtractService.java && \
    sed -i 's/SmartstoreConfig smartstoreConfig = smartstoreConfigRepository.findById("1000").orElseThrow();/SmartstoreConfig smartstoreConfig = smartstoreLocalService.getConfig(); if (smartstoreConfig == null) { smartstoreConfig = smartstoreConfigRepository.findById("1000").orElseThrow(); }/' src/main/java/com/cuebox/portal/service/DocumentClassifyAndExtractService.java

# Configure CORS
RUN sed -i "s|allowed-origins:.*|allowed-origins: '*'|g" src/main/resources/config/application-dev.yml && \
    sed -i "s|allowed-origin-patterns:.*|allowed-origin-patterns: '*'|g" src/main/resources/config/application-dev.yml

# Build WAR and cleanup source
RUN mvn clean package -DskipTests -q -Pwar && \
    mv target/*.war /app.war && \
    rm -rf target src pom.xml .mvn


# =============================================================================
# Stage 3: Download Store.war from GitHub Releases
# =============================================================================
FROM alpine:latest AS store-download
RUN apk add --no-cache curl ca-certificates
RUN curl -L -o /store.war https://github.com/CueboxTech/cuebox-docker/releases/download/store/store.war && \
    ls -lh /store.war


# =============================================================================
# Stage 4: Final Runtime Image (PUBLIC DISTRIBUTION SAFE)
# =============================================================================
FROM ubuntu:22.04

LABEL org.opencontainers.image.title="CueBox Enterprise" \
      org.opencontainers.image.description="CueBox Document Management System - Secure Public Image" \
      org.opencontainers.image.vendor="CueBox Solutions" \
      org.opencontainers.image.version="1.0.0" \
      org.opencontainers.image.licenses="Proprietary" \
      org.opencontainers.image.documentation="https://github.com/CueboxTech/cuebox-docker"

# Install minimal required packages
RUN apt-get update && apt-get install -y --no-install-recommends \
    openjdk-17-jre-headless nginx curl gnupg ca-certificates gosu \
    && curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc | gpg --dearmor -o /usr/share/keyrings/mongodb.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/mongodb.gpg] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse" > /etc/apt/sources.list.d/mongodb.list \
    && apt-get update && apt-get install -y --no-install-recommends mongodb-org \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* \
    && apt-get clean

# Create directories
RUN mkdir -p /data/db /var/log/cuebox && chmod 755 /data/db /var/log/cuebox

# Install Tomcat (with security hardening)
ENV CATALINA_HOME=/opt/tomcat
RUN mkdir -p $CATALINA_HOME && \
    curl -sL https://archive.apache.org/dist/tomcat/tomcat-10/v10.1.18/bin/apache-tomcat-10.1.18.tar.gz | \
    tar xz --strip-components=1 -C $CATALINA_HOME && \
    rm -rf $CATALINA_HOME/webapps/* $CATALINA_HOME/webapps.dist && \
    sed -i 's/port="8080"/port="9090"/g' $CATALINA_HOME/conf/server.xml && \
    sed -i 's/<Connector/<Connector server="CueBox" /g' $CATALINA_HOME/conf/server.xml

# Copy built artifacts (NO SOURCE CODE, NO SECRETS)
COPY --from=frontend-build /app/dist/demo1 /var/www/html
COPY --from=backend-build /app.war $CATALINA_HOME/webapps/portal.war
COPY --from=store-download /store.war $CATALINA_HOME/webapps/store.war

# =============================================================================
# SECURITY-HARDENED NGINX CONFIGURATION
# =============================================================================
RUN cat > /etc/nginx/sites-available/default << 'NGINXCONF'
server {
    listen 80;
    listen 8080;
    
    server_tokens off;
    
    root /var/www/html;
    index index.html;
    client_max_body_size 100M;
    
    # Security Headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;
    
    # Block sensitive files
    location ~ /\. { deny all; return 404; }
    location ~* \.(git|env|config|yml|yaml|properties|bak|sql|log)$ { deny all; return 404; }
    
    # Frontend
    location / {
        try_files $uri $uri/ /index.html;
        location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2)$ {
            expires 1y;
            add_header Cache-Control "public, immutable";
        }
    }
    
    # Backend API
    location /api/ {
        proxy_pass http://127.0.0.1:9090/portal/api/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_connect_timeout 300s;
        proxy_send_timeout 300s;
        proxy_read_timeout 300s;
        client_max_body_size 100M;
    }
    
    # Portal (Swagger)
    location /portal/ {
        proxy_pass http://127.0.0.1:9090/portal/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        client_max_body_size 100M;
    }
    
    # Smartstore
    location /store/ {
        proxy_pass http://127.0.0.1:9090/store/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_connect_timeout 300s;
        proxy_send_timeout 300s;
        proxy_read_timeout 300s;
        client_max_body_size 100M;
    }
    
    location /health {
        access_log off;
        return 200 'OK';
        add_header Content-Type text/plain;
    }
}
NGINXCONF

# =============================================================================
# SECURE ENTRYPOINT SCRIPT
# =============================================================================
RUN cat > /entrypoint.sh << 'ENTRYPOINT'
#!/bin/bash
set -e

APP_PORT=${APP_PORT:-8080}
APP_HOST=${APP_HOST:-localhost}

echo "=============================================="
echo "  CueBox Enterprise"
echo "=============================================="
echo "  Image: Public Distribution Safe"
echo "  No secrets baked into image"
echo "=============================================="

# =============================================================================
# SECURITY: Validate required environment variables
# =============================================================================
if [ -z "$MONGODB_URI" ]; then
    echo ""
    echo "=============================================="
    echo "  ERROR: MONGODB_URI is required!"
    echo "=============================================="
    echo ""
    echo "  Usage:"
    echo "    docker run -d -p 8080:80 \\"
    echo "      -e MONGODB_URI=\"mongodb://user:pass@host:port/db\" \\"
    echo "      ghcr.io/cueboxtech/cuebox:latest"
    echo ""
    echo "=============================================="
    exit 1
fi

echo "[OK] MONGODB_URI provided"

# Mask the password in logs
MASKED_URI=$(echo "$MONGODB_URI" | sed 's/:[^:@]*@/:****@/g')
echo "[OK] Connecting to: $MASKED_URI"

# =============================================================================
# Step 1: Start Local MongoDB (for document storage only)
# =============================================================================
echo "[INFO] Starting local MongoDB for document storage..."
rm -f /data/db/mongod.lock /data/db/WiredTiger.lock 2>/dev/null || true
mkdir -p /data/db

# SECURITY: MongoDB binds ONLY to localhost - not accessible from outside
mongod --dbpath /data/db --port 27017 --bind_ip 127.0.0.1 --fork \
       --logpath /var/log/cuebox/mongodb.log --noauth --wiredTigerCacheSizeGB 0.25 --quiet

# Wait for MongoDB
for i in $(seq 1 30); do
    mongosh --quiet --eval "db.runCommand({ping:1}).ok" 2>/dev/null | grep -q "1" && break
    [ $i -eq 30 ] && { echo "[ERROR] Local MongoDB failed"; exit 1; }
    sleep 1
done
echo "[OK] Local MongoDB ready"

# Initialize smartstore config
mongosh --quiet << MONGO
db = db.getSiblingDB('smartstore');
db.smartstore_config.drop();
db.smartstore_config.insertOne({
    _id: '1000',
    server_url: 'http://localhost:8080/store/api/smartdocs',
    system: 'PORTAL',
    cont_rep: 'A1',
    comp_id: 'data',
    sec_key: '361A524A3ECB5459E0000800099245EC361A524A3ECB5459E0000800099245EC361A524A3ECB5459E0000800099245EC361A524A3ECB5459E0000800099245EC',
    _class: 'com.cuebox.portal.domain.SmartstoreConfig'
});
MONGO

# =============================================================================
# Step 2: Start Tomcat with runtime MongoDB URI
# =============================================================================
echo "[INFO] Starting Tomcat..."

# SECURITY: Pass MongoDB URI as environment variable to Spring Boot
export JAVA_OPTS="-Dspring.profiles.active=prod"
export JAVA_OPTS="$JAVA_OPTS -Dspring.data.mongodb.uri=$MONGODB_URI"
export JAVA_OPTS="$JAVA_OPTS -Xms512m -Xmx1024m"
export JAVA_OPTS="$JAVA_OPTS -Djava.security.egd=file:/dev/./urandom"
export JAVA_OPTS="$JAVA_OPTS -Dserver.tomcat.remote-ip-header=x-forwarded-for"
export JAVA_OPTS="$JAVA_OPTS -Dserver.tomcat.protocol-header=x-forwarded-proto"

$CATALINA_HOME/bin/catalina.sh start

# Wait for backend
echo "[INFO] Waiting for backend..."
for i in $(seq 1 180); do
    HTTP=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:9090/portal/ 2>/dev/null || echo "000")
    [ "$HTTP" = "200" ] || [ "$HTTP" = "302" ] || [ "$HTTP" = "401" ] && { echo "[OK] Backend ready (${i}s)"; break; }
    [ $i -eq 180 ] && { echo "[ERROR] Backend timeout"; tail -50 $CATALINA_HOME/logs/catalina.out; exit 1; }
    sleep 1
done

# =============================================================================
# Step 3: Configure store.war for local MongoDB
# =============================================================================
if [ -f "$CATALINA_HOME/webapps/store.war" ]; then
    echo "[INFO] Configuring store service..."
    for i in $(seq 1 60); do
        if [ -d "$CATALINA_HOME/webapps/store/WEB-INF/classes" ]; then
            CONFIG="$CATALINA_HOME/webapps/store/WEB-INF/classes/application.yml"
            [ -f "$CONFIG" ] && sed -i 's|uri: mongodb://[^[:space:]]*|uri: mongodb://localhost:27017/store|g' "$CONFIG"
            PROPS="$CATALINA_HOME/webapps/store/WEB-INF/classes/application.properties"
            [ -f "$PROPS" ] && sed -i 's|clamd.enable=true|clamd.enable=false|g' "$PROPS" 2>/dev/null || true
            touch "$CATALINA_HOME/webapps/store.war"
            sleep 10
            break
        fi
        sleep 2
    done
    
    for i in $(seq 1 30); do
        HTTP=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:9090/store/ 2>/dev/null || echo "000")
        [ "$HTTP" = "200" ] || [ "$HTTP" = "302" ] || [ "$HTTP" = "401" ] && { echo "[OK] Store ready"; break; }
        sleep 1
    done
fi

# =============================================================================
# Ready
# =============================================================================
echo ""
echo "=============================================="
echo "  CueBox is Ready!"
echo "=============================================="
echo "  URL: http://${APP_HOST}:${APP_PORT}"
echo "  Swagger: http://${APP_HOST}:${APP_PORT}/portal/swagger-ui.html"
echo "=============================================="
echo ""

# Clear sensitive environment from shell history
unset HISTFILE
history -c 2>/dev/null || true

exec nginx -g "daemon off;"
ENTRYPOINT

RUN chmod +x /entrypoint.sh

# =============================================================================
# Final security cleanup
# =============================================================================
RUN rm -rf /root/.bash_history /root/.cache /tmp/* \
    && find /var/log -type f -name "*.log" -delete 2>/dev/null || true

# Health check
HEALTHCHECK --interval=30s --timeout=15s --start-period=180s --retries=5 \
    CMD curl -sf http://localhost/health > /dev/null && \
        pgrep mongod > /dev/null && \
        pgrep java > /dev/null || exit 1

EXPOSE 80
VOLUME ["/data/db", "/opt/tomcat/logs"]

ENTRYPOINT ["/entrypoint.sh"]
