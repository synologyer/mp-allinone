#!/bin/bash

# ---------------- Hardware Testing----------------
USE_NVIDIA=0
USE_DRI=0
USE_RPI=0

# NVIDIA GPU
if lspci | grep -i nvidia >/dev/null 2>&1; then
    USE_NVIDIA=1
fi

# /dev/dri
if [ -e /dev/dri ]; then
    USE_DRI=1
fi

# /dev/vchiq
if [ -e /dev/vchiq ]; then
    USE_RPI=1
fi

echo "GPU detection results:"
echo "  NVIDIA GPU: $USE_NVIDIA"
echo "  /dev/dri:   $USE_DRI"
echo "  /dev/vchiq:$USE_RPI"
echo

# ---------------- Output Compose file ----------------
OUTPUT_FILE="docker-compose.yaml"
cat > $OUTPUT_FILE <<'EOF'
version: "3.9"

networks:
  mp-allinone:
    name: mp-allinone
    driver: bridge
    enable_ipv6: false
    ipam:
      driver: default
      config:
        - gateway: ${SUBNET_PREFIX:?SUBNET_PREFIX required}.1
          subnet: ${SUBNET_PREFIX}.0/24
    driver_opts:
      com.docker.network.bridge.name: mp-allinone

services:

  moviepilot:
    stdin_open: true
    tty: true
    container_name: moviepilot-v2
    hostname: moviepilot-v2
    ports:
      - ${MP_FRONT_PORT}
      - ${MP_BACK_PORT}
    volumes:
      - ${VIDEO_DIR}/media:/media
      - ${ALLINONE_DIR}/moviepilot-v2/config:/config
      - ${ALLINONE_DIR}/moviepilot-v2/core:/moviepilot/.cache/ms-playwright
      - ${ALLINONE_DIR}/qBittorrent/config/qBittorrent/BT_backup:/BT_backup
    environment:
      - NGINX_PORT=${MP_FRONT_PORT}
      - PORT=${MP_BACK_PORT}
      - PUID=${SERVICE_UID}
      - PGID=${SERVICE_GID}
      - UMASK=${SERVICE_UMASK}
      - TZ=Asia/Shanghai
      - SUPERUSER=admin
      - SUPERUSER_PASSWORD=password
      - DB_TYPE=postgresql
      - DB_POSTGRESQL_HOST=${SUBNET_PREFIX}.4
      - DB_POSTGRESQL_PORT=5432
      - DB_POSTGRESQL_DATABASE=moviepilot
      - DB_POSTGRESQL_USERNAME=moviepilot
      - DB_POSTGRESQL_PASSWORD=${POSTGRES_PASSWORD}
      - CACHE_BACKEND_TYPE=redis
      - CACHE_BACKEND_URL=redis://:${REDIS_PASSWORD}@${SUBNET_PREFIX}.3:6379
    networks:
      mp-allinone:
        ipv4_address: ${SUBNET_PREFIX}.2
    restart: always
    depends_on:
      postgresql:
        condition: service_healthy
      redis:
        condition: service_healthy
    image: jxxghp/moviepilot-v2:${IMAGE_TAG}

  redis:
    volumes:
      - ${ALLINONE_DIR}/redis/data:/data
    networks:
      mp-allinone:
        ipv4_address: ${SUBNET_PREFIX}.3
    image: redis
    command: redis-server --save 600 1 --requirepass ${REDIS_PASSWORD}
    healthcheck:
      test: ["CMD", "redis-cli", "--raw", "incr", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5

  postgresql:
    image: postgres:${IMAGE_TAG}
    restart: always
    environment:
      - POSTGRES_DB=moviepilot
      - POSTGRES_USER=moviepilot
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
    volumes:
      - ${ALLINONE_DIR}/postgresql:/var/lib/postgresql
    networks:
      mp-allinone:
        ipv4_address: ${SUBNET_PREFIX}.4
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U moviepilot -d moviepilot"]
      interval: 10s
      timeout: 5s
      retries: 5

  qbittorrent:
    image: linuxserver/qbittorrent:${IMAGE_TAG}
    container_name: qbittorrent
    environment:
      - PUID=${SERVICE_UID}
      - PGID=${SERVICE_GID}
      - TZ=Asia/Shanghai
      - WEBUI_PORT=${QB_WEBUI_PORT}
      - TORRENTING_PORT=${QB_TORRENTING_PORT}
    volumes:
      - ${ALLINONE_DIR}/qbittorrent/config:/config
      - ${VIDEO_DIR}/downloads:/downloads
    networks:
      mp-allinone:
        ipv4_address: ${SUBNET_PREFIX}.5
    ports:
      - ${QB_WEBUI_PORT}
      - ${QB_TORRENTING_PORT}
      - ${QB_TORRENTING_PORT}/udp
    restart: unless-stopped
EOF

# ---------------- Emby GPU Automatic Detection ----------------
cat >> $OUTPUT_FILE <<'EOF'

  emby:
    image: emby/embyserver
    container_name: embyserver
    hostname: embyserver
    networks:
      mp-allinone:
        ipv4_address: ${SUBNET_PREFIX}.6
    environment:
      - UID=${SERVICE_UID}
      - GID=${SERVICE_GID}
      - GIDLIST=${EMBY_GIDLIST}
EOF

if [ "$USE_NVIDIA" = "1" ]; then
cat >> $OUTPUT_FILE <<'EOF'
    runtime: nvidia
    environment:
      - NVIDIA_VISIBLE_DEVICES=all
      - NVIDIA_DRIVER_CAPABILITIES=compute,video,utility
EOF
fi

DEVICES=()
if [ "$USE_DRI" = "1" ]; then DEVICES+=("  - /dev/dri:/dev/dri"); fi
if [ "$USE_RPI" = "1" ]; then DEVICES+=("  - /dev/vchiq:/dev/vchiq"); fi

if [ ${#DEVICES[@]} -gt 0 ]; then
    echo "    devices:" >> $OUTPUT_FILE
    for d in "${DEVICES[@]}"; do
        echo "$d" >> $OUTPUT_FILE
    done
fi

cat >> $OUTPUT_FILE <<'EOF'
    volumes:
      - ${ALLINONE_DIR}/emby/config:/config
      - ${VIDEO_DIR}/media:/media
    ports:
      - ${EMBY_HTTP}
      - ${EMBY_HTTPS}
    restart: on-failure
EOF

echo "ALLINONE_DIR=$PWD" >> .env

echo "docker-compose generation completed: $OUTPUT_FILE"

dirs=(
  "moviepilot-v2/config"
  "moviepilot-v2/core"
  "redis/data"
  "postgresql"
  "qBittorrent/config"
  "emby/config"
)

for d in "${dirs[@]}"; do
  mkdir -p "$d"
done

echo "Directory structure created"