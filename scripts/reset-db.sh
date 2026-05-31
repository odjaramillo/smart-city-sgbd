#!/bin/bash
# ==============================================================================
# reset-db.sh — Reset completo y repoblación de la base de datos
# Uso: ./scripts/reset-db.sh
# Requiere: docker-compose, psql client (o docker exec)
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
COMPOSE_FILE="$ROOT_DIR/docker-compose.yml"

echo "[reset-db] Volcando base..."
cd "$ROOT_DIR"

# 1. Bajar compose y destruir volumen para reset limpio
echo "[reset-db] Deteniendo contenedor y destruyendo volumen..."
docker-compose down -v 2>/dev/null || true

# 2. Subir compose limpio
echo "[reset-db] Levantando postgres..."
docker-compose up -d

# 3. Esperar a que postgres esté listo (healthcheck)
echo "[reset-db] Esperando que postgres esté listo..."
until docker exec smart_city_postgres pg_isready -U ucab -d ucab_project > /dev/null 2>&1; do
    sleep 2
done
echo "[reset-db] postgres listo."

# 4. Cargar scripts en orden
echo "[reset-db] Cargando 01-ddl-modelo-estrella.sql..."
docker exec -i smart_city_postgres psql -U ucab -d ucab_project < "$ROOT_DIR/01-ddl-modelo-estrella.sql" > /dev/null 2>&1

echo "[reset-db] Cargando 02-sp-reconciliacion-elt.sql..."
docker exec -i smart_city_postgres psql -U ucab -d ucab_project < "$ROOT_DIR/02-sp-reconciliacion-elt.sql" > /dev/null 2>&1

echo "[reset-db] Cargando 03-vistas-analiticas.sql..."
docker exec -i smart_city_postgres psql -U ucab -d ucab_project < "$ROOT_DIR/03-vistas-analiticas.sql" > /dev/null 2>&1

echo "[reset-db] Cargando 04-datos-semilla.sql..."
docker exec -i smart_city_postgres psql -U ucab -d ucab_project < "$ROOT_DIR/04-datos-semilla.sql" > /dev/null 2>&1

# 5. Verificación rápida
echo ""
echo "[reset-db] Verificación:"
docker exec smart_city_postgres psql -U ucab -d ucab_project -t -c "
SELECT 'dim_tiempo'        AS tbl, COUNT(*) AS rows FROM dim_tiempo
UNION ALL SELECT 'dim_geografia',    COUNT(*) FROM dim_geografia_urbana
UNION ALL SELECT 'dim_red',          COUNT(*) FROM dim_red_electrica
UNION ALL SELECT 'dim_clientes',    COUNT(*) FROM dim_clientes_inventario
UNION ALL SELECT 'dim_tipo_evento', COUNT(*) FROM dim_tipo_evento
UNION ALL SELECT 'staging_eventos',  COUNT(*) FROM staging_eventos
UNION ALL SELECT 'staging_telemetria',COUNT(*) FROM staging_telemetria
UNION ALL SELECT 'fact_interrupciones',COUNT(*) FROM fact_interrupciones
UNION ALL SELECT 'fact_telemetria',  COUNT(*) FROM fact_telemetria
ORDER BY tbl;
"

echo ""
echo "[reset-db] ✓ Reset completo. Base lista."
echo "[reset-db] Para correr el SP: docker exec smart_city_postgres psql -U ucab -d ucab_project -c 'CALL sp_reconciliar_interrupciones()'"
