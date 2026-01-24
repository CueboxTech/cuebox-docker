# =============================================================================
# Stage 1: Build Frontend
# =============================================================================
FROM node:18-alpine AS frontend-build
WORKDIR /app
RUN apk add --no-cache git

ARG FRONTEND_BRANCH=main

RUN --mount=type=secret,id=github_token \
    git clone --depth 1 -b ${FRONTEND_BRANCH} \
    https://$(cat /run/secrets/github_token)@github.com/CueboxTech/angular-frontend.git .

RUN npm install --legacy-peer-deps --ignore-scripts && \
    npm install @nx/nx-linux-x64-musl --legacy-peer-deps --ignore-scripts || true && \
    npm rebuild || true

# Configure frontend for Docker environment
RUN sed -i "s|baseURL:.*|baseURL: '/api',|g" src/environments/environment.prod.ts && \
    sed -i "s|appThemeName: 'Metronic'|appThemeName: 'CueBox'|g" src/environments/environment.prod.ts && \
    sed -i "s|appThemeName: 'Metronic'|appThemeName: 'CueBox'|g" src/environments/environment.ts && \
    sed -i "s|Metronic.*KeenThemes|CueBox Solutions|g" src/index.html && \
    sed -i "s|' - Metronic'|' - CueBox'|g" src/app/_metronic/layout/components/scripts-init/scripts-init.component.ts

ENV CI=false NX_DAEMON=false
RUN npm run build -- --configuration=production


# =============================================================================
# Stage 2: Build Backend
# =============================================================================
FROM maven:3.9-eclipse-temurin-17 AS backend-build
WORKDIR /app
RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*

ARG BACKEND_BRANCH=main

RUN --mount=type=secret,id=github_token \
    git clone --depth 1 -b ${BACKEND_BRANCH} \
    https://$(cat /run/secrets/github_token)@github.com/CueboxTech/be.git .

# Configure MongoDB URI for production (external MongoDB)
RUN --mount=type=secret,id=mongodb_uri \
    sed -i "s|uri: mongodb://.*|uri: $(cat /run/secrets/mongodb_uri)|g" src/main/resources/config/application-prod.yml

# -----------------------------------------------------------------------------
# Create OpenApiConfig.java - Fix Swagger UI server URL
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
# Create SmartstoreLocalService.java - Handle local MongoDB for document storage
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
            .applyToClusterSettings(builder -> {
                builder.serverSelectionTimeout(CONNECTION_TIMEOUT_MS, TimeUnit.MILLISECONDS);
            })
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
                log.warn("Existing MongoDB connection failed, will reconnect: {}", e.getMessage());
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
                    log.info("Connecting to local MongoDB (attempt {}/{})...", attempt, MAX_RETRY_ATTEMPTS);
                    closeClient();
                    mongoClient = createMongoClient();
                    MongoDatabase db = mongoClient.getDatabase(DATABASE_NAME);
                    db.runCommand(new Document("ping", 1));
                    MongoCollection<Document> collection = db.getCollection(COLLECTION_NAME);
                    Document doc = collection.find(new Document("_id", "1000")).first();
                    if (doc == null) {
                        log.warn("Local MongoDB connected but no config found with _id=1000");
                        closeClient();
                        return false;
                    }
                    initialized.set(true);
                    consecutiveFailures.set(0);
                    log.info("Successfully connected to local MongoDB. Config URL: {}", doc.getString("server_url"));
                    return true;
                } catch (MongoTimeoutException e) {
                    log.warn("MongoDB connection timeout (attempt {}): {}", attempt, e.getMessage());
                } catch (Exception e) {
                    log.warn("MongoDB connection failed (attempt {}): {}", attempt, e.getMessage());
                }
                if (attempt < MAX_RETRY_ATTEMPTS) {
                    try { Thread.sleep(RETRY_DELAY_MS); } catch (InterruptedException ie) { Thread.currentThread().interrupt(); break; }
                }
            }
            int failures = consecutiveFailures.incrementAndGet();
            if (failures >= MAX_CONSECUTIVE_FAILURES) {
                log.error("Max consecutive failures ({}) reached. Permanently disabling local MongoDB.", failures);
                permanentlyDisabled.set(true);
            }
            return false;
        } finally {
            connectionLock.unlock();
        }
    }

    private void closeClient() {
        if (mongoClient != null) {
            try { mongoClient.close(); } catch (Exception e) { log.debug("Error closing MongoDB client: {}", e.getMessage()); }
            mongoClient = null;
        }
        initialized.set(false);
    }

    public SmartstoreConfig getConfig() {
        if (cachedConfig != null && (System.currentTimeMillis() - cacheTimestamp) < CACHE_TTL_MS) {
            log.debug("Returning cached smartstore config: {}", cachedConfig.getServerURL());
            return cachedConfig;
        }
        if (permanentlyDisabled.get()) {
            log.debug("Local MongoDB permanently disabled, returning null");
            return null;
        }
        if (!ensureConnection()) {
            log.debug("Could not connect to local MongoDB, returning null");
            cachedConfig = null;
            return null;
        }
        try {
            MongoDatabase database = mongoClient.getDatabase(DATABASE_NAME);
            MongoCollection<Document> collection = database.getCollection(COLLECTION_NAME);
            Document doc = collection.find(new Document("_id", "1000")).first();
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
                consecutiveFailures.set(0);
                log.info("Loaded smartstore config from LOCAL MongoDB: {}", config.getServerURL());
                return config;
            }
            log.warn("No smartstore config found in local MongoDB with _id=1000");
            return null;
        } catch (Exception e) {
            log.error("Error fetching from local MongoDB: {}", e.getMessage());
            int failures = consecutiveFailures.incrementAndGet();
            if (failures >= MAX_CONSECUTIVE_FAILURES) {
                log.error("Max consecutive failures reached. Disabling local MongoDB.");
                permanentlyDisabled.set(true);
            }
            cachedConfig = null;
            return null;
        }
    }

    public boolean isAvailable() { return !permanentlyDisabled.get() && ensureConnection(); }
    public void resetState() {
        connectionLock.lock();
        try {
            closeClient();
            permanentlyDisabled.set(false);
            consecutiveFailures.set(0);
            cachedConfig = null;
            log.info("SmartstoreLocalService state reset");
        } finally { connectionLock.unlock(); }
    }
    @PreDestroy
    public void cleanup() {
        connectionLock.lock();
        try { closeClient(); log.info("SmartstoreLocalService cleaned up"); } finally { connectionLock.unlock(); }
    }
}
EOF

# -----------------------------------------------------------------------------
# Create Attachmentresource.java - REST endpoint for document attachments
# -----------------------------------------------------------------------------
RUN cat > src/main/java/com/cuebox/portal/web/rest/Attachmentresource.java << 'EOF'
package com.cuebox.portal.web.rest;

import org.apache.commons.lang3.RandomStringUtils;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.MediaType;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;
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
    private static final String CONFIG_ID = "1000";

    public Attachmentresource(AttachmentService attachmentService, SmartstoreConfigRepository smartstoreConfigRepository, SmartstoreLocalService smartstoreLocalService) {
        this.attachmentService = attachmentService;
        this.smartstoreConfigRepository = smartstoreConfigRepository;
        this.smartstoreLocalService = smartstoreLocalService;
        log.info("Attachmentresource initialized with SmartstoreLocalService");
    }

    private SmartstoreConfig getSmartStoreConfig() {
        try {
            SmartstoreConfig localConfig = smartstoreLocalService.getConfig();
            if (localConfig != null && localConfig.getServerURL() != null && !localConfig.getServerURL().isEmpty()) {
                log.info("Using LOCAL smartstore config: {}", localConfig.getServerURL());
                return localConfig;
            }
        } catch (Exception e) { log.warn("Error getting local smartstore config: {}", e.getMessage()); }
        try {
            log.info("Falling back to MAIN MongoDB for smartstore config");
            SmartstoreConfig mainConfig = smartstoreConfigRepository.findById(CONFIG_ID).orElse(null);
            if (mainConfig != null && mainConfig.getServerURL() != null) {
                log.info("Using MAIN smartstore config: {}", mainConfig.getServerURL());
                return mainConfig;
            }
        } catch (Exception e) { log.error("Error getting main smartstore config: {}", e.getMessage()); }
        log.error("No smartstore config found! Using hardcoded default.");
        SmartstoreConfig defaultConfig = new SmartstoreConfig();
        defaultConfig.setId(CONFIG_ID);
        defaultConfig.setServerURL("http://localhost:8080/store/api/smartdocs");
        defaultConfig.setSystem("PORTAL");
        defaultConfig.setContRep("A1");
        defaultConfig.setCompId("data");
        defaultConfig.setSecKey("361A524A3ECB5459E0000800099245EC361A524A3ECB5459E0000800099245EC361A524A3ECB5459E0000800099245EC361A524A3ECB5459E0000800099245EC");
        return defaultConfig;
    }

    @GetMapping(value = "/buildDownloadDocURL/{docId}", produces = MediaType.APPLICATION_JSON_VALUE)
    public String buildDownloadDocURL(@PathVariable("docId") String docId) {
        log.debug("Building download URL for docId: {}", docId);
        SmartstoreConfig smartstoreConfig = getSmartStoreConfig();
        String url = attachmentService.buildURL(smartstoreConfig, docId, "get");
        log.debug("Built download URL: {}", url);
        return url;
    }

    @GetMapping(value = "/buildUploaddDocURL", produces = MediaType.APPLICATION_JSON_VALUE)
    public String buildDownloadDocURL() {
        log.debug("Building upload URL");
        SmartstoreConfig smartstoreConfig = getSmartStoreConfig();
        String url = attachmentService.buildURL(smartstoreConfig, RandomStringUtils.randomAlphanumeric(16), "create");
        log.debug("Built upload URL: {}", url);
        return url;
    }

    @GetMapping(value = "/smartstore/status", produces = MediaType.APPLICATION_JSON_VALUE)
    public String getStatus() {
        boolean localAvailable = smartstoreLocalService.isAvailable();
        SmartstoreConfig config = getSmartStoreConfig();
        return String.format("{\"localMongoAvailable\": %s, \"currentUrl\": \"%s\"}", localAvailable, config != null ? config.getServerURL() : "null");
    }
}
EOF

# -----------------------------------------------------------------------------
# Patch DocumentClassifyAndExtractService.java to use local smartstore
# -----------------------------------------------------------------------------
RUN sed -i 's/import com.cuebox.portal.repository.SmartstoreConfigRepository;/import com.cuebox.portal.repository.SmartstoreConfigRepository;\nimport com.cuebox.portal.service.SmartstoreLocalService;/' src/main/java/com/cuebox/portal/service/DocumentClassifyAndExtractService.java

RUN sed -i 's/SmartstoreConfigRepository smartstoreConfigRepository;/SmartstoreConfigRepository smartstoreConfigRepository;\n\n\t@Autowired\n\tSmartstoreLocalService smartstoreLocalService;/' src/main/java/com/cuebox/portal/service/DocumentClassifyAndExtractService.java

RUN sed -i 's/SmartstoreConfig smartstoreConfig = smartstoreConfigRepository.findById("1000").orElseThrow();/SmartstoreConfig smartstoreConfig = smartstoreLocalService.getConfig(); if (smartstoreConfig == null) { smartstoreConfig = smartstoreConfigRepository.findById("1000").orElseThrow(); }/' src/main/java/com/cuebox/portal/service/DocumentClassifyAndExtractService.java

# Verify patch was applied
RUN grep -q "SmartstoreLocalService" src/main/java/com/cuebox/portal/service/DocumentClassifyAndExtractService.java && \
    grep -q "smartstoreLocalService.getConfig()" src/main/java/com/cuebox/portal/service/DocumentClassifyAndExtractService.java && \
    echo "DocumentClassifyAndExtractService.java patched successfully!" || \
    (echo "PATCH FAILED!" && head -80 src/main/java/com/cuebox/portal/service/DocumentClassifyAndExtractService.java && exit 1)

# Configure CORS for development
RUN sed -i "s|allowed-origins:.*|allowed-origins: '*'|g" src/main/resources/config/application-dev.yml && \
    sed -i "s|allowed-origin-patterns:.*|allowed-origin-patterns: '*'|g" src/main/resources/config/application-dev.yml

# Build the backend WAR
RUN mvn clean package -DskipTests -q -Pwar
RUN ls -la target/*.war || (echo "WAR file not created!" && exit 1)


# =============================================================================
# Stage 3: Download Store.war from GitHub Releases
# =============================================================================
FROM alpine:latest AS store-download

RUN apk add --no-cache curl

# Download store.war from GitHub Releases
# URL: https://github.com/CueboxTech/cuebox-docker/releases/download/store/store.war
RUN curl -L -o /store.war https://github.com/CueboxTech/cuebox-docker/releases/download/store/store.war && \
    ls -lh /store.war && \
    echo "store.war downloaded successfully ($(du -h /store.war | cut -f1))"


# =============================================================================
# Stage 4: Final Runtime Image
# =============================================================================
FROM ubuntu:22.04

# Install dependencies
RUN apt-get update && apt-get install -y \
    openjdk-17-jre-headless nginx curl gnupg netcat-openbsd procps unzip \
    && curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc | gpg --dearmor -o /usr/share/keyrings/mongodb.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/mongodb.gpg] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse" > /etc/apt/sources.list.d/mongodb.list \
    && apt-get update && apt-get install -y mongodb-org \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /data/db && chmod 777 /data/db \
    && mkdir -p /var/log && touch /var/log/mongodb.log && chmod 666 /var/log/mongodb.log

# Install Tomcat
ENV CATALINA_HOME=/opt/tomcat
RUN mkdir -p $CATALINA_HOME && \
    curl -sL https://archive.apache.org/dist/tomcat/tomcat-10/v10.1.18/bin/apache-tomcat-10.1.18.tar.gz | \
    tar xz --strip-components=1 -C $CATALINA_HOME && \
    rm -rf $CATALINA_HOME/webapps/* && \
    sed -i 's/port="8080"/port="9090"/g' $CATALINA_HOME/conf/server.xml && \
    mkdir -p $CATALINA_HOME/logs && chmod 755 $CATALINA_HOME/logs

# Copy built artifacts
COPY --from=frontend-build /app/dist/demo1 /var/www/html
COPY --from=backend-build /app/target/*.war $CATALINA_HOME/webapps/portal.war

# -----------------------------------------------------------------------------
# Copy store.war from GitHub Releases (Stage 3)
# -----------------------------------------------------------------------------
COPY --from=store-download /store.war $CATALINA_HOME/webapps/store.war

# Verify both WAR files are present
RUN ls -lh $CATALINA_HOME/webapps/*.war && \
    echo "=== WAR files ready ===" && \
    echo "portal.war: $(du -h $CATALINA_HOME/webapps/portal.war | cut -f1)" && \
    echo "store.war: $(du -h $CATALINA_HOME/webapps/store.war | cut -f1)"

# -----------------------------------------------------------------------------
# Nginx Configuration
# CRITICAL: Listen on BOTH port 80 AND 8080 inside the container
# - Port 80 is for external access (mapped to host 8080)
# - Port 8080 is for internal Java app calls (localhost:8080/store/...)
# -----------------------------------------------------------------------------
RUN cat > /etc/nginx/sites-available/default << 'EOF'
server {
    listen 80;
    listen 8080;
    
    root /var/www/html;
    index index.html;
    client_max_body_size 100M;
    
    proxy_connect_timeout 300;
    proxy_send_timeout 300;
    proxy_read_timeout 300;
    send_timeout 300;
    
    # Frontend - Angular SPA
    location / {
        try_files $uri $uri/ /index.html;
    }
    
    # Backend API
    location /api/ {
        proxy_pass http://127.0.0.1:9090/portal/api/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_connect_timeout 300;
        proxy_send_timeout 300;
        proxy_read_timeout 300;
        client_max_body_size 100M;
    }
    
    # Portal direct access (Swagger, etc)
    location /portal/ {
        proxy_pass http://127.0.0.1:9090/portal/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        client_max_body_size 100M;
    }
    
    # Smartstore - Document storage service
    location /store/ {
        proxy_pass http://127.0.0.1:9090/store/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_connect_timeout 300;
        proxy_send_timeout 300;
        proxy_read_timeout 300;
        client_max_body_size 100M;
    }
    
    # Health check endpoint
    location /health {
        access_log off;
        return 200 'OK';
        add_header Content-Type text/plain;
    }
}
EOF

# -----------------------------------------------------------------------------
# Start Script - Comprehensive initialization
# -----------------------------------------------------------------------------
RUN cat > /start.sh << 'STARTSCRIPT'
#!/bin/bash
set -e

# Configuration
APP_PORT=${APP_PORT:-8080}
APP_HOST=${APP_HOST:-localhost}
MONGO_MAX_WAIT=${MONGO_MAX_WAIT:-60}
TOMCAT_MAX_WAIT=${TOMCAT_MAX_WAIT:-180}
STORE_MAX_WAIT=${STORE_MAX_WAIT:-60}

echo "============================================"
echo "  CueBox Docker Container Starting"
echo "============================================"
echo "  External URL: http://${APP_HOST}:${APP_PORT}"
echo "  Internal URL: http://localhost:8080"
echo "============================================"

# =============================================================================
# Step 1: Start MongoDB
# =============================================================================
echo "[INFO] Cleaning up any stale MongoDB processes..."
pkill -9 mongod 2>/dev/null || true
sleep 1
rm -f /data/db/mongod.lock /data/db/WiredTiger.lock /tmp/mongodb-*.sock 2>/dev/null || true
mkdir -p /data/db && chmod 777 /data/db
touch /var/log/mongodb.log && chmod 666 /var/log/mongodb.log

echo "[INFO] Starting MongoDB..."
mongod --dbpath /data/db \
       --port 27017 \
       --bind_ip 127.0.0.1 \
       --fork \
       --logpath /var/log/mongodb.log \
       --logappend \
       --noauth \
       --wiredTigerCacheSizeGB 0.25 2>&1 || {
    echo "[ERROR] Failed to start MongoDB!"
    cat /var/log/mongodb.log
    exit 1
}

echo "[INFO] Waiting for MongoDB..."
for i in $(seq 1 $MONGO_MAX_WAIT); do
    if mongosh --quiet --eval "db.runCommand({ping:1}).ok" 2>/dev/null | grep -q "1"; then
        echo "[INFO] MongoDB is ready! (took ${i}s)"
        break
    fi
    if [ $i -eq $MONGO_MAX_WAIT ]; then
        echo "[ERROR] MongoDB failed to start within ${MONGO_MAX_WAIT}s"
        cat /var/log/mongodb.log
        exit 1
    fi
    sleep 1
done

# =============================================================================
# Step 2: Initialize Smartstore Configuration
# =============================================================================
echo "[INFO] Initializing smartstore configuration..."
STORE_URL="http://localhost:8080/store/api/smartdocs"

mongosh --quiet << MONGOEOF
db = db.getSiblingDB('smartstore');
db.smartstore_config.drop();
db.smartstore_config.insertOne({
    _id: '1000',
    server_url: '${STORE_URL}',
    system: 'PORTAL',
    cont_rep: 'A1',
    comp_id: 'data',
    sec_key: '361A524A3ECB5459E0000800099245EC361A524A3ECB5459E0000800099245EC361A524A3ECB5459E0000800099245EC361A524A3ECB5459E0000800099245EC',
    _class: 'com.cuebox.portal.domain.SmartstoreConfig'
});
print('Config initialized: ' + db.smartstore_config.findOne({_id:'1000'}).server_url);
MONGOEOF

# =============================================================================
# Step 3: Start Tomcat
# =============================================================================
echo "[INFO] Starting Tomcat..."
export JAVA_OPTS="-Dspring.profiles.active=prod -Xms512m -Xmx1024m -Djava.security.egd=file:/dev/./urandom"
$CATALINA_HOME/bin/catalina.sh start

echo "[INFO] Waiting for backend (portal.war)..."
for i in $(seq 1 $TOMCAT_MAX_WAIT); do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:9090/portal/ 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ] || [ "$HTTP_CODE" = "401" ]; then
        echo "[INFO] Backend is ready! (took ${i}s, HTTP: $HTTP_CODE)"
        break
    fi
    if [ $i -eq $TOMCAT_MAX_WAIT ]; then
        echo "[ERROR] Backend failed to start within ${TOMCAT_MAX_WAIT}s"
        tail -100 $CATALINA_HOME/logs/catalina.out
        exit 1
    fi
    sleep 1
done

# =============================================================================
# Step 4: Configure Store.war MongoDB (after extraction)
# =============================================================================
if [ -f "$CATALINA_HOME/webapps/store.war" ]; then
    echo "[INFO] Waiting for store.war to deploy..."
    for i in $(seq 1 $STORE_MAX_WAIT); do
        if [ -d "$CATALINA_HOME/webapps/store/WEB-INF/classes" ]; then
            echo "[INFO] store.war extracted, applying local MongoDB configuration..."
            
            CONFIG_FILE="$CATALINA_HOME/webapps/store/WEB-INF/classes/application.yml"
            if [ -f "$CONFIG_FILE" ]; then
                cp "$CONFIG_FILE" "$CONFIG_FILE.bak"
                sed -i 's|uri: mongodb://[^[:space:]]*|uri: mongodb://localhost:27017/store|g' "$CONFIG_FILE"
                echo "[INFO] Store MongoDB configuration updated"
            fi
            
            PROPS_FILE="$CATALINA_HOME/webapps/store/WEB-INF/classes/application.properties"
            if [ -f "$PROPS_FILE" ]; then
                sed -i 's|clamd.enable=true|clamd.enable=false|g' "$PROPS_FILE" 2>/dev/null || true
            fi
            
            touch "$CATALINA_HOME/webapps/store.war"
            echo "[INFO] Store.war marked for redeploy with new config"
            sleep 15
            break
        fi
        sleep 2
    done
    
    echo "[INFO] Verifying store service..."
    for i in $(seq 1 30); do
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:9090/store/ 2>/dev/null || echo "000")
        if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ] || [ "$HTTP_CODE" = "401" ]; then
            echo "[INFO] Store service is ready! (HTTP: $HTTP_CODE)"
            break
        fi
        sleep 1
    done
else
    echo "[WARNING] store.war not found!"
fi

# =============================================================================
# Step 5: Final Status
# =============================================================================
echo ""
echo "============================================"
echo "  CueBox is Ready!"
echo "============================================"
echo "  Application URL: http://${APP_HOST}:${APP_PORT}"
echo "  Smartstore URL:  ${STORE_URL}"
echo "  Local MongoDB:   mongodb://127.0.0.1:27017"
echo "============================================"
echo ""
mongosh --quiet --eval "print('Smartstore URL: ' + db.getSiblingDB('smartstore').smartstore_config.findOne({_id:'1000'}).server_url)"

exec nginx -g "daemon off;"
STARTSCRIPT

RUN chmod +x /start.sh

# Health Check
HEALTHCHECK --interval=30s --timeout=15s --start-period=180s --retries=5 \
    CMD curl -f http://localhost/health && \
        curl -f http://localhost:8080/health && \
        pgrep mongod > /dev/null && \
        pgrep java > /dev/null || exit 1

EXPOSE 80
VOLUME ["/data/db", "/opt/tomcat/logs"]

ENTRYPOINT ["/start.sh"]
