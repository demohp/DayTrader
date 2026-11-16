# =============================================================================
# Multi-stage Dockerfile for DayTrader EE7 EJB Module (daytrader-ee7-ejb)
# Java 8 | Maven | JAR packaging | Azure AKS deployment
# Runtime base image: eclipse-temurin:8-jdk (explicit)
# =============================================================================

# ---- Stage 1: Build ----
FROM maven:3.8.6-openjdk-8-slim AS builder

WORKDIR /workspace

# Copy Maven POM first for dependency layer caching
COPY pom.xml .

# Download all dependencies (cached layer unless pom.xml changes)
RUN mvn dependency:go-offline -B

# Copy the full source tree
COPY src ./src

# Build the application JAR (skip tests for Docker build)
RUN mvn clean package -DskipTests -B

# ---- Stage 2: Runtime ----
FROM eclipse-temurin:8-jdk

# Metadata labels
LABEL maintainer="DayTrader Team" \
      application="daytrader-ee7-ejb" \
      version="1.0-SNAPSHOT" \
      description="DayTrader EE7 EJB Module - Azure AKS"

# Set timezone
ENV TZ=UTC

# JVM tuning for containerized environments
ENV JAVA_OPTS="-Xms256m -Xmx512m \
  -XX:+UseContainerSupport \
  -XX:MaxRAMPercentage=75.0 \
  -XX:+UnlockExperimentalVMOptions \
  -Djava.security.egd=file:/dev/./urandom \
  -Dfile.encoding=UTF-8 \
  -Duser.timezone=UTC"

# Application environment variables (overridable at runtime)
ENV DB_URL="jdbc:db2://localhost:50000/daytrader" \
    DB_USER="daytrader" \
    DB_PASSWORD="" \
    DB_DRIVER="com.ibm.db2.jcc.DB2Driver" \
    JMS_QUEUE_CONNECTION_FACTORY_CLASS="" \
    JMS_QUEUE_CONNECTION_FACTORY_URL="" \
    JMS_BROKER_QUEUE_CLASS="" \
    JMS_BROKER_QUEUE_NAME="TradeBrokerQueue" \
    JMS_TOPIC_CONNECTION_FACTORY_CLASS="" \
    JMS_TOPIC_CONNECTION_FACTORY_URL="" \
    JMS_STREAMER_TOPIC_CLASS="" \
    JMS_STREAMER_TOPIC_NAME="TradeStreamerTopic" \
    REDIS_HOST="localhost" \
    REDIS_PORT="6379"

# Application port
EXPOSE 8080

# Create a non-root user for security
RUN groupadd --gid 1001 appgroup && \
    useradd --uid 1001 --gid appgroup --shell /bin/bash --create-home appuser

WORKDIR /app

# Copy the built JAR from the builder stage
COPY --from=builder /workspace/target/*.jar app.jar

# Copy resources if needed
COPY --from=builder /workspace/src/main/resources ./resources

# Set ownership
RUN chown -R appuser:appgroup /app

# Switch to non-root user
USER appuser

# Entrypoint with JVM options and graceful shutdown support
ENTRYPOINT ["sh", "-c", "exec java $JAVA_OPTS -jar /app/app.jar"]
