# Proposal: Rediseño de Dashboard y Reducción de Datos Semilla

## Intent
Resolver el problema de carga de datos y visualización vacía en el dashboard local (causado por bugs de fecha en las vistas analíticas) y optimizar el desarrollo mediante la reducción de tamaño de la data semilla de pruebas, elevando la estética visual a nivel premium para la defensa académica.

## Scope

### In Scope
- Regenerar el archivo de datos semilla `04-datos-semilla.sql` con una muestra más acotada y rápida.
- Corregir en `03-vistas-analiticas.sql` los filtros fijos de `NOW()` por cálculos dinámicos basados en la fecha máxima del dataset real.
- Reemplazar la aritmética incorrecta en formato entero `YYYYMM - 24` por intervalos reales de fecha PostgreSQL.
- Diseñar una UI/UX premium mediante CSS a medida en `dashboard/assets/style.css` con colores HSL, bordes suaves y micro-animaciones.
- Asegurar que los componentes y callbacks de Dash carguen y rendericen correctamente.

### Out of Scope
- Migración a frameworks React (Next.js o Vite).
- Reescritura del stored procedure de reconciliación `sp_reconciliar_interrupciones`.
- Configuración de servidores n8n externos (solo verificación local de la función wrapper).

## Capabilities

### New Capabilities
None

### Modified Capabilities
- `analytical-views`: Adaptar consultas temporales a lógica relativa de fechas dinámica y resolver la aritmética entera YYYYMM.
- `dashboard-ui`: Renovar la hoja de estilos global, tipografías y paletas de colores en los gráficos de Plotly.

## Approach
- Correr el script `generar_datos_semilla.py` con parámetros optimizados.
- Modificar las vistas analíticas en `03-vistas-analiticas.sql`.
- Reemplazar y enriquecer los estilos CSS de la UI en `dashboard/assets/style.css`.
- Configurar plantillas y colores estéticos en `dashboard/components/charts.py`.

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `03-vistas-analiticas.sql` | Modified | Corrige filtros de año actual e intervalos de tendencia. |
| `04-datos-semilla.sql` | Modified | Reduce el volumen de eventos cargados en staging. |
| `dashboard/assets/style.css` | Modified | Overhaul estético completo con CSS moderno. |
| `dashboard/components/charts.py` | Modified | Adapta colores e interactividad de los gráficos Plotly. |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Inconsistencia de fechas si se cargan datos futuros en la defensa | Medium | Las vistas utilizarán dinámicamente `COALESCE(MAX(timestamp_inicio), NOW())` como ancla de tiempo relativo. |
| Fallo en carga inicial en la base de datos local | Low | Validación previa de carga mediante script de smoke test. |

## Rollback Plan
- Deshacer cambios usando `git checkout -- <archivo>` para restaurar los archivos DDL y Dash originales.

## Success Criteria
- [ ] Las vistas analíticas devuelven filas con el dataset de prueba.
- [ ] El Dashboard de Dash carga datos y renderiza todos los gráficos (Trend, Ranking, Heatmap, Ops).
- [ ] El tiempo de carga de los datos semilla es inferior a 10 segundos.
- [ ] La interfaz visual tiene un acabado profesional oscuro con acentos HSL y transiciones suaves.
