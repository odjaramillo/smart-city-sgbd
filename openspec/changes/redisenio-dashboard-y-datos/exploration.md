## Exploration: Rediseño de Dashboard y Reducción de Datos Semilla (Seed)

### Current State
El sistema actual cuenta con un pipeline ELT implementado en PostgreSQL (esquema estrella y stored procedure de reconciliación) y un Dashboard en Dash de Plotly. Sin embargo, el Dashboard se muestra vacío en la ejecución local debido a dos problemas principales de inconsistencia temporal en las vistas analíticas (`03-vistas-analiticas.sql`):
1. **Filtro de Año Rígido**: La vista de ranking de subestaciones filtra por el año actual (`NOW()`), mientras que los datos semilla generados por defecto corresponden a un período anterior (2025).
2. **Cálculo Matemático Erróneo de Meses**: La vista de tendencia a 12 meses hace una resta aritmética directa sobre un formato numérico entero YYYYMM (`202605 - 24 = 202581`), lo cual genera un mes inexistente y excluye toda la data válida del año 2025.
Además, el archivo `04-datos-semilla.sql` contiene más de 10,000 eventos de telemetría (300 medidores por 60 días), lo cual hace que la carga inicial tarde varios minutos, complicando el desarrollo ágil y las pruebas en vivo.

### Affected Areas
- `03-vistas-analiticas.sql` — Corrección de las consultas y filtros temporales de las vistas para usar funciones de intervalo reales de PostgreSQL (evitando el cálculo aritmético en YYYYMM) y permitir flexibilidad de fechas.
- `04-datos-semilla.sql` — Regeneración de datos semilla con un tamaño de muestra mucho más modesto y rápido de procesar (e.g., 15 medidores y 10 días).
- `dashboard/assets/style.css` — Rediseño estético completo del Dashboard (paleta de colores premium HSL, sombras sutiles, micro-animaciones y tipografía moderna).
- `dashboard/components/` y `dashboard/layouts/` — Ajustes menores para asegurar que las figuras de Plotly usen fondos transparentes, fuentes legibles y colores acordes al nuevo diseño estético.

### Approaches
1. **Enfoque 1: Conservar el Dashboard actual en Dash y rediseñar su UI/UX**
   - Pros: Mantiene el backend en Python (SQLAlchemy/pandas) ya implementado y reduce el riesgo de errores de compatibilidad en la defensa.
   - Cons: Dash tiene limitaciones en la flexibilidad de layouts avanzados si no se usa CSS a medida.
   - Effort: Medium.

2. **Enfoque 2: Migrar el Dashboard a Next.js o Vite (React)**
   - Pros: Ofrece máxima flexibilidad estética y control total de componentes interactivos (como Tailwind CSS y librerías de gráficos avanzadas).
   - Cons: Requiere rehacer toda la lógica de conexión a la base de datos de PostgreSQL y las llamadas de red, aumentando la complejidad y el riesgo para una entrega a corto plazo.
   - Effort: High.

### Recommendation
Se recomienda el **Enfoque 1**. Dado que es un proyecto académico con defensa oral inminente y Stress Test en vivo, conservar el Dash actual pero aplicando un rediseño visual de primer nivel (CSS a medida, paleta HSL oscura, layouts modernos y tipografía limpia) garantiza estabilidad operativa del 100% y una estética premium sin arriesgar la compatibilidad de las consultas SQL existentes.

### Risks
- **Desalineación temporal en la defensa**: Si el profesor realiza el Stress Test insertando datos con fecha actual (`NOW()`) y nuestras vistas están fijadas a 2025, el dashboard no mostrará los nuevos eventos.
- *Mitigación*: Las vistas corregidas deben calcular de manera relativa o dinámica respecto a los datos existentes en `fact_interrupciones` (por ejemplo, tomar el año máximo disponible en la tabla de hechos o usar ventanas relativas a la fecha máxima, no a la fecha del sistema).

### Ready for Proposal
Yes — Estamos listos para proceder con la propuesta técnica del cambio en la carpeta del cambio y guardar el estado.
