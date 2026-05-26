```
la Gestión de Datos
Prof. Armen Djenanian
```
# PROYECTO # 01: Arquitectura Analítica de Resiliencia para una

# Ciudad Inteligente (Smart City)

**1. Contexto del Proyecto: Redes Eléctricas Inteligentes (Smart Grids)**

En el marco del desarrollo de las _Smart Cities_ , las Redes Eléctricas Inteligentes (
_Smart Grids_ ) constituyen la espina dorsal de la infraestructura urbana moderna. La
generación masiva de datos a través de **Medidores Inteligentes (Smart Meters)** ,
**Transformadores** y **Nodos de Red** ofrece una oportunidad sin precedentes para
fortalecer la resiliencia energética. No obstante, la data operativa por sí sola es ruido;
el rigor en el diseño arquitectónico es lo único que permite transformar este flujo en
decisiones estratégicas. Este proyecto exige al estudiante diseñar una solución de
Business Intelligence capaz de monitorear y diagnosticar la estabilidad del sistema.
El enfoque principal será la gestión de la resiliencia, evaluando indicadores críticos
como el **SAIDI** ( _System Average Interruption Duration Index_ ) y el **SAIFI** ( _System
Average Interruption Frequency Index_ ), fundamentales para minimizar el tiempo de
respuesta ante fallas y optimizar la distribución de carga en la ciudad.

**2. Objetivos del Proyecto**

**_2.1 Objetivo General_**

Diseñar e implementar una arquitectura de datos analítica, basada en un Data Mart
estratégico, que transforme eventos operativos brutos de una _Smart Grid_ en
información accionable para la gestión de resiliencia y eficiencia energética urbana.

**_2.2 Objetivos Específicos_**

```
● Desarrollar un modelado dimensional robusto que garantice la integridad
histórica de los activos de red.
● Orquestar flujos de integración (ETL) automatizados que aseguren la calidad
y el desacoplamiento arquitectónico.
● Construir un ecosistema de visualización interactivo para la monitorización
de KPIs tácticos y estratégicos.
```

```
la Gestión de Datos
Prof. Armen Djenanian
```
**3. Alcance Técnico y Requerimientos**

**_3.1 Modelado Dimensional (Metodología Kimball)_**

El diseño debe seguir estrictamente el enfoque _Bottom-up_ de Ralph Kimball. Se
requiere la entrega que justifique la relación entre los procesos de negocio y las
dimensiones compartidas.
● **Gestión Histórica:** Es obligatorio el uso de **Dimensiones** para atributos
críticos (ej. estado de salud de un transformador o ubicación de un nodo), ya
que el análisis de resiliencia depende de la trazabilidad temporal.
● **Granularidad y Jerarquías:** Se debe definir la granularidad al nivel más
atómico posible. Las dimensiones temporales deben soportar
obligatoriamente la jerarquía: **Año -> Trimestre -> Mes -> Día**.
● **Entidades Sugeridas:** Los hechos deben capturar mediciones de consumo,
fluctuaciones y tiempos de caída. Las dimensiones deben incluir sensores,
geografía urbana y tipos de infraestructura.

**_3.2 Procesos ETL (Extracción, Transformación y Carga)_**

La integración de datos se realizará mediante herramientas _Low-Code_ o
especializadas como **n8n, Make o Pentaho Data Integration**. El flujo debe
contemplar las fases de _Staging_ , limpieza de datos y carga final.

**_3.3 Dashboard de Business Intelligence_**

El producto final debe ser un Dashboard profesional (Power BI, Tableau o desarrollo
web) que presente:
● **Navegación Avanzada:** Implementación de funciones de _drill-down_ para
explorar desde el panorama general de la ciudad hasta el detalle de un nodo
específico.
● **Interactividad:** Filtros dinámicos por periodos de tiempo, sectores
geográficos y niveles de criticidad de eventos.


```
la Gestión de Datos
Prof. Armen Djenanian
```
**4. Estrategia de Evaluación y Rigor Académico**

**_4.1 Defensa Oral y Live Stress Test_**

La excelencia no es negociable. La evaluación consistirá en una defensa técnica
donde se auditará el "porqué" de cada decisión. Durante la misma, se someterá a la
arquitectura a un **Live Stress Test**.
● _Ejemplo de Stress Test:_ El profesor podría solicitar un cambio repentino en una
regla de negocio (ej. redefinir qué se considera un "Pico de Energía Crítico" o
cambiar la agrupación de sectores geográficos). El modelo dimensional y los
flujos ETL deben demostrar la flexibilidad suficiente para adaptarse sin
requerir una reconstrucción total.

**_4.2 Auditoría de Prompts y Ética en IA_**

Si se utilizan herramientas de IA generativa, es obligatorio entregar una **Bitácora de
Auditoría de Prompts**. No se aceptará un simple listado de preguntas; el estudiante
debe documentar el proceso de verificación y justificar cómo validó técnicamente
que el código o diseño sugerido por la IA cumple con los requisitos del proyecto.
● **Política de Plagio:** Según el reglamento de la UCAB, cualquier detección de
plagio o uso no atribuido de IA resultará en la reprobación inmediata de la
unidad curricular.

**5. Entregables y Cronograma**

Entregable,Descripción
Dashboard Interactivo,Archivo fuente o enlace a la solución publicada con KPIs de
resiliencia funcionales.
Documento Técnico, Diagrama Dimensional, screenshots de flujos ETL y
justificación de arquitectura."
Bitácora de IA, Registro de auditoría de prompts con validación de resultados y
justificación técnica.
● **Fecha de Entrega:** Semana 09.


```
la Gestión de Datos
Prof. Armen Djenanian
```
**6. Rúbrica de Evaluación (25% de la Nota Definitiva)**

**Rúbrica de Evaluación: Proyecto 01 (Enfoque BI y Datamart)**

```
Criterio Descripción Ponderació
n
```
**1. Modelado
Dimensional
(Criterio Kimball)**

```
Evaluación del diseño del Modelo en Estrella.
Se mide la correcta identificación de la Tabla de
Hechos y Dimensiones , la definición de la
granularidad y la gestión de cambios en las
dimensiones.
```
## 25%

**2. Orquestación y
Calidad (ETL)**

```
Capacidad de extraer datos de fuentes
operativas (OLTP), transformarlos (limpieza de
datos inconsistentes) y cargarlos en el Data
Mart local utilizando herramientas como n8n,
Make o Pentaho.
```
## 20%

**3. Visualización y
KPIs Estratégicos**

```
Diseño de un Dashboard interactivo con
capacidad de multifiltros. No se evalúa solo la
estética, sino la relevancia de los indicadores
para la toma de decisiones tácticas y
estratégicas de la Smart City.
```
## 20%

**4. Auditoría
Técnica (The Why
& Stress Test)**

```
Defensa oral donde el estudiante justifica sus
decisiones arquitectónicas y supera un Live
Stress Test (modificación de reglas de negocio
en vivo) sin dependencia de la IA.
```
## 25%


```
la Gestión de Datos
Prof. Armen Djenanian
```
**5. Informe de
Criterio e
Ingeniería de
Prompts**

```
Documentación de la interacción con la IA,
justificando qué sugerencias fueron aceptadas o
rechazadas y por qué, demostrando un
aprendizaje crítico y autónomo.
```
## 10%

**Niveles de Logro por Criterio (Escala 0-20)**

```
● Excelente (18-20): Integra todos los elementos de forma coherente, aplica
fluidez en la terminología técnica y resuelve problemas complejos con
procedimientos de la disciplina. El modelo dimensional es óptimo y el
proceso ETL maneja inconsistencias de forma robusta.
● Bueno (14-17): Cumple con la mayoría de los requisitos pero con detalles
menores por mejorar en la justificación técnica o en la limpieza de datos. El
dashboard es funcional pero los indicadores podrían tener mayor
profundidad estratégica.
● Regular (10-13): Presenta un modelo incompleto, con errores de cardinalidad
o inconsistencias en el flujo de datos. Dependencia excesiva de soluciones
genéricas de IA sin adaptación al caso de la Smart City.
● Deficiente (0-9): El sistema no es funcional, hay una ausencia de justificación
técnica o se detecta un uso de "vibe coding" sin comprensión alguna del
sistema implementado.
```
**7. Notas Generales**
    1. **Integridad de Datos:** El uso de datos reales y consistentes es obligatorio. El
       rigor en el diseño es la base de la confianza en los datos; modelos basados en
       datos aleatorios carentes de sentido de negocio serán penalizados.
    2. **Asistencia:** La asistencia a la sesión de defensa y Stress Test es de carácter
       **obligatorio** para todos los integrantes del equipo.
    3. **Equipos:** Se mantendrán los equipos de trabajo conformados al inicio del
       semestre.


