# Tasks: Rediseño de Dashboard y Reducción de Datos Semilla

## Review Workload Forecast

Decision needed before apply: No
Chained PRs recommended: No
Chain strategy: size-exception
400-line budget risk: Low

| Field | Value |
|-------|-------|
| Estimated changed lines | ~150 |
| 400-line budget risk | Low |
| Chained PRs recommended | No |
| Suggested split | Single PR |
| Delivery strategy | ask-on-risk |
| Chain strategy | size-exception |

## Phase 1: Capa de Datos y Seed
- [x] 1.1 Ejecutar `python generar_datos_semilla.py --seed 42 --days 10 --meters 15 --output 04-datos-semilla.sql` para generar el seed pequeño.
- [ ] 1.2 Limpiar la base de datos PostgreSQL local y recargar el DDL (`01-ddl-modelo-estrella.sql`), el SP (`02-sp-reconciliacion-elt.sql`) y el nuevo seed generado (`04-datos-semilla.sql`).

## Phase 2: Corrección de Vistas Analíticas
- [x] 2.1 Modificar `03-vistas-analiticas.sql` para que `vw_ranking_subestaciones` filtre dinámicamente usando el año máximo en `fact_interrupciones` en lugar de `NOW()`.
- [x] 2.2 Modificar `03-vistas-analiticas.sql` para que `vw_tendencia_12_meses` reste 24 meses usando `INTERVAL '24 months'` sobre la fecha máxima del dataset.
- [ ] 2.3 Recargar `03-vistas-analiticas.sql` en PostgreSQL local y ejecutar `sp_reconciliar_interrupciones` para consolidar hechos.

## Phase 3: Rediseño Estético del Dashboard
- [x] 3.1 Modificar `dashboard/assets/style.css` para aplicar fondo degradado oscuro, tarjetas con glassmorphism y micro-animaciones en hover.
- [x] 3.2 Modificar `dashboard/components/charts.py` para establecer fondos transparentes en los gráficos Plotly y adaptar la paleta a tonos HSL premium (cyan, amber, coral).

## Phase 4: Verificación
- [ ] 4.1 Ejecutar `05-verificacion-smoke-test.sql` en PostgreSQL y asegurar que todas las secciones del test de aserciones terminen con "PASADA".
- [ ] 4.2 Levantar el servidor Dash local y validar visualmente el funcionamiento correcto de todos los paneles en el navegador.
