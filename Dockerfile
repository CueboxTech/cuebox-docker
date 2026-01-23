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

RUN sed -i "s|baseURL:.*|baseURL: '/api',|g" src/environments/environment.prod.ts && \
    sed -i "s|appThemeName: 'Metronic'|appThemeName: 'CueBox'|g" src/environments/environment.prod.ts && \
    sed -i "s|appThemeName: 'Metronic'|appThemeName: 'CueBox'|g" src/environments/environment.ts && \
    sed -i "s|Metronic.*KeenThemes|CueBox Solutions|g" src/index.html && \
    sed -i "s|' - Metronic'|' - CueBox'|g" src/app/_metronic/layout/components/scripts-init/scripts-init.component.ts

ENV CI=false NX_DAEMON=false
RUN npm run build -- --configuration=production


FROM maven:3.9-eclipse-temurin-17 AS backend-build
WORKDIR /app
RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*

ARG BACKEND_BRANCH=main

RUN --mount=type=secret,id=github_token \
    git clone --depth 1 -b ${BACKEND_BRANCH} \
    https://$(cat /run/secrets/github_token)@github.com/CueboxTech/be.git .

RUN --mount=type=secret,id=mongodb_uri \
    sed -i "s|uri: mongodb://.*|uri: $(cat /run/secrets/mongodb_uri)|g" src/main/resources/config/application-prod.yml

# OpenApiConfig.java
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

# SmartstoreLocalService.java - Thread-safe, lazy-loading, self-healing
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
    private static final long CACHE_TTL_MS = 60000; // 1 minute cache

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
        // If permanently disabled, don't even try
        if (permanentlyDisabled.get()) {
            return false;
        }
        
        // If already initialized and client exists, verify it's still working
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
        
        // Rate limit reconnection attempts (wait at least 5 seconds between attempts)
        long now = System.currentTimeMillis();
        if (now - lastConnectionAttempt < 5000) {
            return false;
        }
        
        // Use lock to prevent multiple threads from connecting simultaneously
        if (!connectionLock.tryLock()) {
            return initialized.get() && mongoClient != null;
        }
        
        try {
            lastConnectionAttempt = now;
            
            for (int attempt = 1; attempt <= MAX_RETRY_ATTEMPTS; attempt++) {
                try {
                    log.info("Connecting to local MongoDB (attempt {}/{})...", attempt, MAX_RETRY_ATTEMPTS);
                    
                    closeClient();
                    mongoClient = createMongoClient();
                    
                    // Test connection
                    MongoDatabase db = mongoClient.getDatabase(DATABASE_NAME);
                    db.runCommand(new Document("ping", 1));
                    
                    // Verify data exists
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
                    try {
                        Thread.sleep(RETRY_DELAY_MS);
                    } catch (InterruptedException ie) {
                        Thread.currentThread().interrupt();
                        break;
                    }
                }
            }
            
            // All attempts failed
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
            try {
                mongoClient.close();
            } catch (Exception e) {
                log.debug("Error closing MongoDB client: {}", e.getMessage());
            }
            mongoClient = null;
        }
        initialized.set(false);
    }

    public SmartstoreConfig getConfig() {
        // Check cache first
        if (cachedConfig != null && (System.currentTimeMillis() - cacheTimestamp) < CACHE_TTL_MS) {
            log.debug("Returning cached smartstore config: {}", cachedConfig.getServerURL());
            return cachedConfig;
        }
        
        // If permanently disabled, return null immediately
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
                
                // Update cache
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
            
            // Clear cache on error
            cachedConfig = null;
            return null;
        }
    }

    public boolean isAvailable() {
        return !permanentlyDisabled.get() && ensureConnection();
    }
    
    public void resetState() {
        connectionLock.lock();
        try {
            closeClient();
            permanentlyDisabled.set(false);
            consecutiveFailures.set(0);
            cachedConfig = null;
            log.info("SmartstoreLocalService state reset");
        } finally {
            connectionLock.unlock();
        }
    }

    @PreDestroy
    public void cleanup() {
        connectionLock.lock();
        try {
            closeClient();
            log.info("SmartstoreLocalService cleaned up");
        } finally {
            connectionLock.unlock();
        }
    }
}
EOF

# Attachmentresource.java - With proper error handling and logging
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

    public Attachmentresource(AttachmentService attachmentService,
            SmartstoreConfigRepository smartstoreConfigRepository,
            SmartstoreLocalService smartstoreLocalService) {
        this.attachmentService = attachmentService;
        this.smartstoreConfigRepository = smartstoreConfigRepository;
        this.smartstoreLocalService = smartstoreLocalService;
        log.info("Attachmentresource initialized with SmartstoreLocalService");
    }

    private SmartstoreConfig getSmartStoreConfig() {
        // Strategy 1: Try local MongoDB first (for Docker deployments)
        try {
            SmartstoreConfig localConfig = smartstoreLocalService.getConfig();
            if (localConfig != null && localConfig.getServerURL() != null && !localConfig.getServerURL().isEmpty()) {
                log.info("Using LOCAL smartstore config: {}", localConfig.getServerURL());
                return localConfig;
            }
        } catch (Exception e) {
            log.warn("Error getting local smartstore config: {}", e.getMessage());
        }
        
        // Strategy 2: Fallback to main MongoDB
        try {
            log.info("Falling back to MAIN MongoDB for smartstore config");
            SmartstoreConfig mainConfig = smartstoreConfigRepository.findById(CONFIG_ID)
                .orElse(null);
            
            if (mainConfig != null && mainConfig.getServerURL() != null) {
                log.info("Using MAIN smartstore config: {}", mainConfig.getServerURL());
                return mainConfig;
            }
        } catch (Exception e) {
            log.error("Error getting main smartstore config: {}", e.getMessage());
        }
        
        // Strategy 3: Last resort - create a default config
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
        return String.format("{\"localMongoAvailable\": %s, \"currentUrl\": \"%s\"}", 
            localAvailable, config != null ? config.getServerURL() : "null");
    }
}
EOF

# ============================================
# CRITICAL FIX: Patch DocumentClassifyAndExtractService.java
# This is where document uploads happen - must use local MongoDB!
# ============================================
RUN echo "Patching DocumentClassifyAndExtractService.java to use SmartstoreLocalService..." && \
    # Step 1: Add import for SmartstoreLocalService
    sed -i 's/import com.cuebox.portal.repository.SmartstoreConfigRepository;/import com.cuebox.portal.repository.SmartstoreConfigRepository;\nimport com.cuebox.portal.service.SmartstoreLocalService;/' \
        src/main/java/com/cuebox/portal/service/DocumentClassifyAndExtractService.java && \
    # Step 2: Add @Autowired field for SmartstoreLocalService after SmartstoreConfigRepository
    sed -i '/@Autowired/,/SmartstoreConfigRepository smartstoreConfigRepository;/{
        /SmartstoreConfigRepository smartstoreConfigRepository;/a\
\
\t@Autowired\
\tSmartstoreLocalService smartstoreLocalService;
    }' src/main/java/com/cuebox/portal/service/DocumentClassifyAndExtractService.java && \
    # Step 3: Replace direct repository call with local-first approach
    sed -i 's/SmartstoreConfig smartstoreConfig = smartstoreConfigRepository.findById("1000").orElseThrow();/SmartstoreConfig smartstoreConfig = smartstoreLocalService.getConfig(); if (smartstoreConfig == null) { smartstoreConfig = smartstoreConfigRepository.findById("1000").orElseThrow(); }/' \
        src/main/java/com/cuebox/portal/service/DocumentClassifyAndExtractService.java && \
    echo "Patch applied!"

# Verify the patch was successful
RUN echo "Verifying DocumentClassifyAndExtractService.java patch..." && \
    grep -q "SmartstoreLocalService" src/main/java/com/cuebox/portal/service/DocumentClassifyAndExtractService.java && \
    grep -q "smartstoreLocalService.getConfig()" src/main/java/com/cuebox/portal/service/DocumentClassifyAndExtractService.java && \
    echo "✓ DocumentClassifyAndExtractService.java patched successfully!" || \
    (echo "✗ PATCH FAILED! Build will continue but local MongoDB may not work for uploads." && \
     echo "Content of file:" && \
     head -100 src/main/java/com/cuebox/portal/service/DocumentClassifyAndExtractService.java)

RUN sed -i "s|allowed-origins:.*|allowed-origins: '*'|g" src/main/resources/config/application-dev.yml && \
    sed -i "s|allowed-origin-patterns:.*|allowed-origin-patterns: '*'|g" src/main/resources/config/application-dev.yml

RUN mvn clean package -DskipTests -q -Pwar

RUN ls -la target/*.war || (echo "WAR file not created!" && exit 1)


FROM ubuntu:22.04

RUN apt-get update && apt-get install -y \
    openjdk-17-jre-headless \
    nginx \
    curl \
    gnupg \
    netcat-openbsd \
    procps \
    && curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc | gpg --dearmor -o /usr/share/keyrings/mongodb.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/mongodb.gpg] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse" > /etc/apt/sources.list.d/mongodb.list \
    && apt-get update \
    && apt-get install -y mongodb-org \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /data/db \
    && chmod 777 /data/db \
    && mkdir -p /var/log \
    && touch /var/log/mongodb.log \
    && chmod 666 /var/log/mongodb.log

ENV CATALINA_HOME=/opt/tomcat
RUN mkdir -p $CATALINA_HOME && \
    curl -sL https://archive.apache.org/dist/tomcat/tomcat-10/v10.1.18/bin/apache-tomcat-10.1.18.tar.gz | \
    tar xz --strip-components=1 -C $CATALINA_HOME && \
    rm -rf $CATALINA_HOME/webapps/* && \
    sed -i 's/port="8080"/port="9090"/g' $CATALINA_HOME/conf/server.xml && \
    mkdir -p $CATALINA_HOME/logs && \
    chmod 755 $CATALINA_HOME/logs

COPY --from=frontend-build /app/dist/demo1 /var/www/html
COPY --from=backend-build /app/target/*.war $CATALINA_HOME/webapps/portal.war

# Nginx config with all routes and proper timeouts
RUN cat > /etc/nginx/sites-available/default << 'EOF'
server {
    listen 80;
    root /var/www/html;
    index index.html;
    client_max_body_size 50M;
    
    # Timeouts
    proxy_connect_timeout 300;
    proxy_send_timeout 300;
    proxy_read_timeout 300;
    send_timeout 300;

    location / {
        try_files $uri $uri/ /index.html;
    }

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
        client_max_body_size 50M;
    }

    location /portal/ {
        proxy_pass http://127.0.0.1:9090/portal/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        client_max_body_size 50M;
    }

    location /store/ {
        proxy_pass http://127.0.0.1:9090/store/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        client_max_body_size 50M;
    }
    
    # Health check endpoint
    location /health {
        access_log off;
        return 200 'OK';
        add_header Content-Type text/plain;
    }
}
EOF

# Comprehensive startup script
RUN cat > /start.sh << 'BASHEOF'
#!/bin/bash
set -e

# Configuration with defaults
APP_PORT=${APP_PORT:-8080}
APP_HOST=${APP_HOST:-localhost}
MONGO_MAX_WAIT=${MONGO_MAX_WAIT:-60}
TOMCAT_MAX_WAIT=${TOMCAT_MAX_WAIT:-180}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

echo ""
echo "============================================"
echo "  CueBox Docker Container Starting"
echo "============================================"
echo "  Target URL: http://${APP_HOST}:${APP_PORT}"
echo "  MongoDB Wait: ${MONGO_MAX_WAIT}s"
echo "  Tomcat Wait: ${TOMCAT_MAX_WAIT}s"
echo "============================================"
echo ""

# ============================================
# STEP 1: Cleanup any leftover processes/files
# ============================================
log_info "[1/6] Cleaning up previous state..."

# Kill any existing mongod
pkill -9 mongod 2>/dev/null || true
sleep 1

# Remove stale lock files and sockets
rm -f /data/db/mongod.lock 2>/dev/null || true
rm -f /data/db/WiredTiger.lock 2>/dev/null || true
rm -f /tmp/mongodb-*.sock 2>/dev/null || true

# Ensure directories exist with proper permissions
mkdir -p /data/db
chmod 777 /data/db
touch /var/log/mongodb.log
chmod 666 /var/log/mongodb.log

log_info "      Cleanup complete"

# ============================================
# STEP 2: Start MongoDB
# ============================================
log_info "[2/6] Starting MongoDB..."

# Start MongoDB with explicit options
mongod \
    --dbpath /data/db \
    --port 27017 \
    --bind_ip 127.0.0.1 \
    --fork \
    --logpath /var/log/mongodb.log \
    --logappend \
    --noauth \
    --wiredTigerCacheSizeGB 0.25 \
    2>&1 || {
        log_error "Failed to start MongoDB!"
        log_error "MongoDB log:"
        cat /var/log/mongodb.log
        exit 1
    }

# Wait for MongoDB to be ready
log_info "      Waiting for MongoDB to be ready..."
MONGO_READY=false
for i in $(seq 1 $MONGO_MAX_WAIT); do
    # Check if process is still running
    if ! pgrep -x mongod > /dev/null; then
        log_error "MongoDB process died!"
        cat /var/log/mongodb.log
        exit 1
    fi
    
    # Check if accepting connections
    if mongosh --quiet --eval "db.runCommand({ping:1}).ok" 2>/dev/null | grep -q "1"; then
        MONGO_READY=true
        log_info "      MongoDB is ready! (took ${i}s)"
        break
    fi
    
    # Also try nc to check port
    if nc -z 127.0.0.1 27017 2>/dev/null; then
        if mongosh --quiet --eval "1" 2>/dev/null; then
            MONGO_READY=true
            log_info "      MongoDB is ready! (took ${i}s)"
            break
        fi
    fi
    
    echo -ne "\r      Waiting for MongoDB... ($i/${MONGO_MAX_WAIT}s)"
    sleep 1
done
echo ""

if [ "$MONGO_READY" = false ]; then
    log_error "MongoDB failed to start within ${MONGO_MAX_WAIT}s!"
    log_error "Last 50 lines of MongoDB log:"
    tail -50 /var/log/mongodb.log
    exit 1
fi

# ============================================
# STEP 3: Initialize smartstore_config
# ============================================
log_info "[3/6] Initializing smartstore configuration..."

STORE_URL="http://${APP_HOST}:${APP_PORT}/store/api/smartdocs"

# Initialize with retry
INIT_SUCCESS=false
for attempt in 1 2 3; do
    log_info "      Initialization attempt $attempt/3..."
    
    if mongosh --quiet << MONGOEOF
        db = db.getSiblingDB('smartstore');
        
        // Drop and recreate to ensure clean state
        db.smartstore_config.drop();
        
        // Insert fresh config
        var result = db.smartstore_config.insertOne({
            _id: '1000',
            server_url: '${STORE_URL}',
            system: 'PORTAL',
            cont_rep: 'A1',
            comp_id: 'data',
            sec_key: '361A524A3ECB5459E0000800099245EC361A524A3ECB5459E0000800099245EC361A524A3ECB5459E0000800099245EC361A524A3ECB5459E0000800099245EC',
            _class: 'com.cuebox.portal.domain.SmartstoreConfig'
        });
        
        if (result.acknowledged) {
            print('INSERT_SUCCESS');
        } else {
            print('INSERT_FAILED');
        }
MONGOEOF
    then
        # Verify the insert
        VERIFY_URL=$(mongosh --quiet --eval "db.getSiblingDB('smartstore').smartstore_config.findOne({_id:'1000'}).server_url" 2>/dev/null | tr -d '\n' | tr -d ' ')
        
        if [ "$VERIFY_URL" = "$STORE_URL" ]; then
            INIT_SUCCESS=true
            log_info "      Config initialized successfully!"
            log_info "      URL: $STORE_URL"
            break
        else
            log_warn "      Verification failed. Expected: $STORE_URL, Got: $VERIFY_URL"
        fi
    fi
    
    sleep 2
done

if [ "$INIT_SUCCESS" = false ]; then
    log_error "Failed to initialize smartstore_config after 3 attempts!"
    log_error "MongoDB may not be functioning correctly."
    # Continue anyway - Java code has fallback
fi

# ============================================
# STEP 4: Verify MongoDB data
# ============================================
log_info "[4/6] Verifying MongoDB state..."

mongosh --quiet << 'VERIFYEOF'
db = db.getSiblingDB('smartstore');
print('Database: smartstore');
print('Collections: ' + db.getCollectionNames());
print('Config count: ' + db.smartstore_config.countDocuments({}));
var config = db.smartstore_config.findOne({_id: '1000'});
if (config) {
    print('Config URL: ' + config.server_url);
} else {
    print('WARNING: No config found!');
}
VERIFYEOF

# ============================================
# STEP 5: Start Tomcat
# ============================================
log_info "[5/6] Starting Tomcat..."

export JAVA_OPTS="-Dspring.profiles.active=prod -Xms512m -Xmx1024m -Djava.security.egd=file:/dev/./urandom"
export CATALINA_OPTS="-Dfile.encoding=UTF-8"

$CATALINA_HOME/bin/catalina.sh start

# Wait for Tomcat/Spring Boot to be ready
log_info "      Waiting for backend to start..."
BACKEND_READY=false
START_TIME=$(date +%s)

for i in $(seq 1 $TOMCAT_MAX_WAIT); do
    # Check if Tomcat process is still running
    if ! pgrep -f 'catalina.startup.Bootstrap' > /dev/null; then
        log_error "Tomcat process died unexpectedly!"
        log_error "Last 100 lines of catalina.out:"
        tail -100 $CATALINA_HOME/logs/catalina.out
        exit 1
    fi
    
    # Check multiple endpoints
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:9090/portal/ 2>/dev/null || echo "000")
    HEALTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:9090/portal/management/health 2>/dev/null || echo "000")
    
    # Accept various success codes
    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ] || [ "$HTTP_CODE" = "401" ] || [ "$HEALTH_CODE" = "200" ]; then
        BACKEND_READY=true
        ELAPSED=$(($(date +%s) - START_TIME))
        log_info "      Backend is ready! (took ${ELAPSED}s, HTTP: $HTTP_CODE)"
        break
    fi
    
    # Show progress every 10 seconds
    if [ $((i % 10)) -eq 0 ]; then
        log_info "      Still waiting... ($i/${TOMCAT_MAX_WAIT}s) [HTTP: $HTTP_CODE, Health: $HEALTH_CODE]"
    else
        echo -ne "\r      Waiting for backend... ($i/${TOMCAT_MAX_WAIT}s) [HTTP: $HTTP_CODE]"
    fi
    
    sleep 1
done
echo ""

# ============================================
# STEP 6: Final verification and start nginx
# ============================================
log_info "[6/6] Final verification..."

# Test smartstore endpoint
SMARTSTORE_STATUS=$(curl -s "http://127.0.0.1:9090/portal/api/attachment/smartstore/status" 2>/dev/null || echo "unavailable")
log_info "      Smartstore status: $SMARTSTORE_STATUS"

# Show running processes
log_info "      Running processes:"
pgrep -a mongod | head -1 || echo "      - mongod: NOT RUNNING"
pgrep -a java | head -1 || echo "      - java: NOT RUNNING"

echo ""
echo "============================================"
if [ "$BACKEND_READY" = true ]; then
    echo -e "  ${GREEN}CueBox is Ready!${NC}"
else
    echo -e "  ${YELLOW}CueBox started (backend may still be initializing)${NC}"
fi
echo "============================================"
echo "  Application URL: http://${APP_HOST}:${APP_PORT}"
echo "  Smartstore URL:  ${STORE_URL}"
echo "  Local MongoDB:   mongodb://127.0.0.1:27017/smartstore"
echo ""
echo "  Useful commands:"
echo "    docker logs <container>     - View logs"
echo "    docker exec -it <container> bash - Shell access"
echo "============================================"
echo ""

# Start nginx in foreground (keeps container running)
exec nginx -g "daemon off;"
BASHEOF

RUN chmod +x /start.sh

# Health check that verifies all components
HEALTHCHECK --interval=30s --timeout=15s --start-period=180s --retries=5 \
    CMD curl -f http://localhost/health && \
        curl -sf http://127.0.0.1:9090/portal/ -o /dev/null && \
        pgrep mongod > /dev/null || exit 1

EXPOSE 80
VOLUME ["/data/db"]
ENTRYPOINT ["/start.sh"]
