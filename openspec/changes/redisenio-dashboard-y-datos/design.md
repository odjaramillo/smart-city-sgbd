# Design: Rediseño de Dashboard y Reducción de Datos Semilla

## Technical Approach
Implementar los cambios divididos en dos capas:
1. **Capa de Datos**: Regenerar un seed SQL mucho más pequeño y corregir las vistas analíticas en PostgreSQL para calcular fechas dinámicamente en base a los datos existentes en la tabla de hechos.
2. **Capa de Visualización**: Renovar el archivo de estilos CSS (`dashboard/assets/style.css`) aplicando variables HSL personalizadas y efectos de glassmorphism, y ajustar las plantillas de Plotly en `charts.py` para fundirse estéticamente con el fondo oscuro y con las nuevas tipografías de Google Fonts (Inter).

---

## Architecture Decisions

### Decision: Anclaje Dinámico de Fechas Analíticas
| Opción | Tradeoff | Decisión |
|---|---|---|
| Usar `NOW()` rígido | Fácil de escribir, pero se desfasa inmediatamente en desarrollo y fallará si los datos semilla son históricos. | **Rechazado** |
| Usar variables/parámetros en el dashboard | Agrega lógica de control y llamadas complejas al dashboard de Python. | **Rechazado** |
| Usar `COALESCE(MAX(timestamp_inicio), NOW())` en las vistas | Las vistas se vuelven autoadaptables al dataset actual de la base de datos de manera dinámica y limpia. | **Aprobado** |

**Rationale**: Al calcular las métricas con base en la fecha máxima del dataset real (`MAX(timestamp_inicio)`), el dashboard siempre mostrará datos válidos ya sea que usemos el seed histórico (2025) o datos recién insertados en vivo (2026).

### Decision: Corrección del Rango de 24 Meses
| Opción | Tradeoff | Decisión |
|---|---|---|
| Aritmética entera `YYYYMM - 24` | Causa desbordamientos y meses inválidos (ej. `202605 - 24 = 202581`). | **Rechazado** |
| Conversión a tipo `DATE` e intervalo SQL | Código limpio y robusto que delega el cálculo de fechas de PostgreSQL antes de convertir a formato `YYYYMM`. | **Aprobado** |

**Rationale**: El uso de la función `INTERVAL '24 months'` previene cualquier bug de desbordamiento en el paso de año o resta de meses.

---

## Data Flow
- Los datos se generan y cargan una sola vez a staging.
- El procedimiento ELT consolida hechos.
- Las vistas analíticas computan los KPIs dinámicamente.
- Dash consulta las vistas y renderiza las figuras con Plotly.

```
[Script Python] ──> [staging_eventos] ──> [sp_reconciliar_interrupciones] ──> [fact_interrupciones]
                                                                                      │
                                                                                      ▼
[Dash Web UI] <── [Queries SQLAlchemy] <── [Vistas Analíticas (Filtro Relativo)] <──┘
```

---

## File Changes

| File | Action | Description |
|------|--------|-------------|
| `04-datos-semilla.sql` | Modify | Reemplazar por datos generados con `--meters 10 --days 7`. |
| `03-vistas-analiticas.sql` | Modify | Corregir la lógica de anclaje y cálculo de rango de meses en las vistas. |
| `dashboard/assets/style.css` | Modify | Overhaul visual del dashboard (colores HSL, degradados, glassmorphism). |
| `dashboard/components/charts.py` | Modify | Ajustar colores de Plotly para acoplarse a la nueva UI y fuentes. |

---

## Interfaces / Contracts
El contrato de vistas analíticas se mantiene idéntico. No se modifican nombres de columnas ni firmas de funciones para no romper la compatibilidad con SQLAlchemy en `queries.py` ni con Power BI si estuviera conectado.

---

## Testing Strategy

| Layer | What to Test | Approach |
|-------|-------------|----------|
| Database (Smoke Test) | Carga y vistas vacías | Ejecutar `05-verificacion-smoke-test.sql` y corroborar que todas las secciones digan "PASADA". |
| Manual E2E | Renderizado visual | Iniciar el dashboard localmente con `python -m dashboard.app` y auditarlo visualmente en el navegador. |

---

## Migration / Rollout
Se requiere vaciar la base de datos actual (para eliminar el seed antiguo grande) antes de correr el DDL y el nuevo seed pequeño.

---

## Open Questions
None
