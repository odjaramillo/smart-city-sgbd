# ==============================================================================
# reset-db.ps1 — Reset completo y repoblación de la base de datos (Windows)
# Uso: .\scripts\reset-db.ps1
# Requiere: Docker Desktop, docker-compose
# ==============================================================================

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $ScriptDir

function Invoke-SqlFile {
    param([string]$File, [string]$Container, [string]$User, [string]$Db)
    $sql = Get-Content -Raw $File
    $sql | docker exec -i $Container psql -U $User -d $Db 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] Fallo al cargar $File" -ForegroundColor Red
        exit 1
    }
    Write-Host "[OK] $File"
}

Write-Host "[reset-db] Volcando base..." -ForegroundColor Cyan
Set-Location $RootDir

# 1. Bajar compose y destruir volumen
Write-Host "[reset-db] Deteniendo contenedor y destruyendo volumen..." -ForegroundColor Cyan
docker-compose down -v 2>$null

# 2. Subir compose limpio
Write-Host "[reset-db] Levantando postgres..." -ForegroundColor Cyan
docker-compose up -d

# 3. Esperar a que postgres esté listo
Write-Host "[reset-db] Esperando que postgres esté listo..." -ForegroundColor Cyan
$maxWait = 60
$elapsed = 0
while ($elapsed -lt $maxWait) {
    $ready = docker exec smart_city_postgres pg_isready -U ucab -d ucab_project 2>$null
    if ($ready -match "accepting connections") { break }
    Start-Sleep -Seconds 2
    $elapsed += 2
}
if ($elapsed -ge $maxWait) {
    Write-Host "[ERROR] Postgres no respondió en $maxWait segundos" -ForegroundColor Red
    exit 1
}
Write-Host "[reset-db] postgres listo." -ForegroundColor Green

# 4. Cargar scripts en orden
Write-Host ""
Write-Host "[reset-db] Cargando scripts..." -ForegroundColor Cyan
Invoke-SqlFile -File "$RootDir\01-ddl-modelo-estrella.sql" -Container "smart_city_postgres" -User "ucab" -Db "ucab_project"
Invoke-SqlFile -File "$RootDir\02-sp-reconciliacion-elt.sql" -Container "smart_city_postgres" -User "ucab" -Db "ucab_project"
Invoke-SqlFile -File "$RootDir\03-vistas-analiticas.sql" -Container "smart_city_postgres" -User "ucab" -Db "ucab_project"
Invoke-SqlFile -File "$RootDir\04-datos-semilla.sql" -Container "smart_city_postgres" -User "ucab" -Db "ucab_project"

# 5. Verificación
Write-Host ""
Write-Host "[reset-db] Verificación:" -ForegroundColor Cyan
docker exec smart_city_postgres psql -U ucab -d ucab_project -t -c "
SELECT 'dim_tiempo' AS tbl, COUNT(*) AS rows FROM dim_tiempo
UNION ALL SELECT 'dim_geografia', COUNT(*) FROM dim_geografia_urbana
UNION ALL SELECT 'dim_red', COUNT(*) FROM dim_red_electrica
UNION ALL SELECT 'dim_clientes', COUNT(*) FROM dim_clientes_inventario
UNION ALL SELECT 'dim_tipo_evento', COUNT(*) FROM dim_tipo_evento
UNION ALL SELECT 'staging_eventos', COUNT(*) FROM staging_eventos
UNION ALL SELECT 'staging_telemetria', COUNT(*) FROM staging_telemetria
UNION ALL SELECT 'fact_interrupciones', COUNT(*) FROM fact_interrupciones
UNION ALL SELECT 'fact_telemetria', COUNT(*) FROM fact_telemetria
ORDER BY tbl;
"

Write-Host ""
Write-Host "[reset-db] Reset completo. Base lista." -ForegroundColor Green
