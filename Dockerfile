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

RUN mkdir -p src/main/java/com/cuebox/portal/config/ && \
    echo 'package com.cuebox.portal.config; import io.swagger.v3.oas.models.servers.Server; import org.springdoc.core.customizers.OpenApiCustomizer; import org.springframework.context.annotation.Bean; import org.springframework.context.annotation.Configuration; import java.util.List; @Configuration public class OpenApiConfig { @Bean public OpenApiCustomizer serverUrlCustomizer() { return openApi -> openApi.setServers(List.of(new Server().url("/portal").description("Local"))); } }' > src/main/java/com/cuebox/portal/config/OpenApiConfig.java

RUN sed -i "s|allowed-origins:.*|allowed-origins: '*'|g" src/main/resources/config/application-dev.yml && \
    sed -i "s|allowed-origin-patterns:.*|allowed-origin-patterns: '*'|g" src/main/resources/config/application-dev.yml

RUN mvn clean package -DskipTests -q -Pwar


FROM ubuntu:22.04

RUN apt-get update && apt-get install -y openjdk-17-jre-headless nginx curl && \
    rm -rf /var/lib/apt/lists/*

ENV CATALINA_HOME=/opt/tomcat
RUN mkdir -p $CATALINA_HOME && \
    curl -sL https://archive.apache.org/dist/tomcat/tomcat-10/v10.1.18/bin/apache-tomcat-10.1.18.tar.gz | \
    tar xz --strip-components=1 -C $CATALINA_HOME && \
    rm -rf $CATALINA_HOME/webapps/* && \
    sed -i 's/port="8080"/port="9090"/g' $CATALINA_HOME/conf/server.xml

COPY --from=frontend-build /app/dist/demo1 /var/www/html
COPY --from=backend-build /app/target/*.war $CATALINA_HOME/webapps/portal.war

RUN echo 'server {\n\
    listen 80;\n\
    root /var/www/html;\n\
    index index.html;\n\
    client_max_body_size 50M;\n\
\n\
    location / {\n\
        try_files $uri $uri/ /index.html;\n\
    }\n\
\n\
    location /api/ {\n\
        proxy_pass http://127.0.0.1:9090/portal/api/;\n\
        proxy_connect_timeout 300;\n\
        proxy_send_timeout 300;\n\
        proxy_read_timeout 300;\n\
        client_max_body_size 50M;\n\
    }\n\
\n\
    location /portal/ {\n\
        proxy_pass http://127.0.0.1:9090/portal/;\n\
        client_max_body_size 50M;\n\
    }\n\
\n\
    location /store/ {\n\
        proxy_pass http://127.0.0.1:9090/store/;\n\
        client_max_body_size 50M;\n\
    }\n\
}' > /etc/nginx/sites-available/default

RUN echo '#!/bin/bash\n\
set -e\n\
export JAVA_OPTS="-Dspring.profiles.active=prod -Xms512m -Xmx1024m"\n\
$CATALINA_HOME/bin/catalina.sh start\n\
echo "Starting CueBox..."\n\
sleep 10\n\
for i in $(seq 1 60); do\n\
  if curl -sf http://127.0.0.1:9090/portal/management/health >/dev/null 2>&1; then\n\
    echo "CueBox Ready! http://localhost:8080"\n\
    break\n\
  fi\n\
  echo "Waiting for backend... ($i/60)"\n\
  sleep 2\n\
done\n\
exec nginx -g "daemon off;"' > /start.sh && chmod +x /start.sh

EXPOSE 80
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s CMD curl -f http://localhost/ || exit 1
ENTRYPOINT ["/start.sh"]
