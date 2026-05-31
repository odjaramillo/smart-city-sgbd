-- ==============================================================================
-- PROYECTO: Arquitectura Analítica de Resiliencia para Smart City (Smart Grid)
-- GENERADO AUTOMÁTICAMENTE por generar_datos_semilla.py
-- Seed: 42 | Días: 10 | Medidores: 15
-- Fecha generación: 2026-05-30T01:00:36.462769+00:00
-- ==============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- dim_tipo_evento (OBLIGATORIO: ejecutar ANTES de cualquier fact table)
-- ---------------------------------------------------------------------------

-- Fila obligatoria -1 (Unknown) — debe existir antes de las fact tables
INSERT INTO dim_tipo_evento (sk_tipo_evento, codigo_evento, categoria, severidad, es_critico, descripcion)
OVERRIDING SYSTEM VALUE
VALUES (-1, 'UNKNOWN', 'DESCONOCIDO', 'DESCONOCIDA', FALSE, 'Tipo de evento no reconocido');

-- Reset sequence para que los próximos inserts usen IDs正确
SELECT setval('dim_tipo_evento_sk_tipo_evento_seq', 1, false);

-- Catálogo de eventos para Stress Test
INSERT INTO dim_tipo_evento (codigo_evento, categoria, severidad, es_critico, descripcion) VALUES
('POWER_OUTAGE', 'INTERRUPCION', 'ALTA', TRUE, 'Corte de energía detectado por smart meter'),
('POWER_RESTORATION', 'INTERRUPCION', 'MEDIA', FALSE, 'Restauración de energía'),
('VOLTAGE_SPIKE', 'FLUCTUACION', 'ALTA', TRUE, 'Pico de voltaje (>260V)'),
('VOLTAGE_SAG', 'FLUCTUACION', 'MEDIA', FALSE, 'Caída de voltaje (<180V)'),
('HEARTBEAT', 'TELEMETRIA', 'BAJA', FALSE, 'Señal de vida del medidor'),
('LECTURA_PERIODICA', 'TELEMETRIA', 'BAJA', FALSE, 'Lectura periódica de consumo/voltaje');

-- ---------------------------------------------------------------------------
-- staging_telemetria (ejemplos de lecturas de telemetría - últimas 24 horas)
-- ---------------------------------------------------------------------------

-- Fix H-5a: la telemetria usaba medidores 1001/1002 (inexistentes; el inventario
-- va de 1 a 15) y marcas de tiempo NOW(). Se remapea a medidores reales (1 y 2) y
-- se ancla al mismo periodo que los eventos de interrupcion (2025-01) para que el
-- lookup de dim_red_electrica y el JOIN a dim_tiempo resuelvan y fact_telemetria se pueble.
INSERT INTO staging_telemetria (id_medidor, timestamp_lectura, consumo_wh, voltaje, tipo_lectura) VALUES
(1, '2025-01-15 00:00:00+00'::TIMESTAMPTZ - INTERVAL '23 hours', 2500, 220, 'LECTURA_PERIODICA'),
(1, '2025-01-15 00:00:00+00'::TIMESTAMPTZ - INTERVAL '22 hours', 2300, 221, 'LECTURA_PERIODICA'),
(1, '2025-01-15 00:00:00+00'::TIMESTAMPTZ - INTERVAL '21 hours', 2400, 219, 'LECTURA_PERIODICA'),
(1, '2025-01-15 00:00:00+00'::TIMESTAMPTZ - INTERVAL '20 hours', 2350, 222, 'LECTURA_PERIODICA'),
(1, '2025-01-15 00:00:00+00'::TIMESTAMPTZ - INTERVAL '19 hours', 2600, 220, 'LECTURA_PERIODICA'),
(1, '2025-01-15 00:00:00+00'::TIMESTAMPTZ - INTERVAL '18 hours', 2800, 218, 'LECTURA_PERIODICA'),
(1, '2025-01-15 00:00:00+00'::TIMESTAMPTZ - INTERVAL '17 hours', 2900, 225, 'LECTURA_PERIODICA'),
(1, '2025-01-15 00:00:00+00'::TIMESTAMPTZ - INTERVAL '16 hours', 2700, 223, 'LECTURA_PERIODICA'),
(1, '2025-01-15 00:00:00+00'::TIMESTAMPTZ - INTERVAL '15 hours', 2450, 220, 'LECTURA_PERIODICA'),
(1, '2025-01-15 00:00:00+00'::TIMESTAMPTZ - INTERVAL '14 hours', 2300, 221, 'LECTURA_PERIODICA'),
(1, '2025-01-15 00:00:00+00'::TIMESTAMPTZ - INTERVAL '13 hours', 2200, 219, 'LECTURA_PERIODICA'),
(1, '2025-01-15 00:00:00+00'::TIMESTAMPTZ - INTERVAL '12 hours', 2100, 218, 'LECTURA_PERIODICA'),
(1, '2025-01-15 00:00:00+00'::TIMESTAMPTZ - INTERVAL '11 hours', 2000, 217, 'LECTURA_PERIODICA'),
(1, '2025-01-15 00:00:00+00'::TIMESTAMPTZ - INTERVAL '10 hours', 1950, 220, 'LECTURA_PERIODICA'),
(1, '2025-01-15 00:00:00+00'::TIMESTAMPTZ - INTERVAL '9 hours', 1900, 221, 'LECTURA_PERIODICA'),
(1, '2025-01-15 00:00:00+00'::TIMESTAMPTZ - INTERVAL '8 hours', 1850, 219, 'LECTURA_PERIODICA'),
(1, '2025-01-15 00:00:00+00'::TIMESTAMPTZ - INTERVAL '7 hours', 1800, 218, 'LECTURA_PERIODICA'),
(1, '2025-01-15 00:00:00+00'::TIMESTAMPTZ - INTERVAL '6 hours', 1750, 217, 'LECTURA_PERIODICA'),
(1, '2025-01-15 00:00:00+00'::TIMESTAMPTZ - INTERVAL '5 hours', 1700, 220, 'LECTURA_PERIODICA'),
(1, '2025-01-15 00:00:00+00'::TIMESTAMPTZ - INTERVAL '4 hours', 1650, 221, 'LECTURA_PERIODICA'),
(1, '2025-01-15 00:00:00+00'::TIMESTAMPTZ - INTERVAL '3 hours', 1600, 219, 'LECTURA_PERIODICA'),
(1, '2025-01-15 00:00:00+00'::TIMESTAMPTZ - INTERVAL '2 hours', 1550, 218, 'LECTURA_PERIODICA'),
(1, '2025-01-15 00:00:00+00'::TIMESTAMPTZ - INTERVAL '1 hour', 1500, 220, 'LECTURA_PERIODICA'),
(1, '2025-01-15 00:00:00+00'::TIMESTAMPTZ, 1450, 221, 'LECTURA_PERIODICA'),
(2, '2025-01-15 00:00:00+00'::TIMESTAMPTZ - INTERVAL '23 hours', 1800, 219, 'LECTURA_PERIODICA'),
(2, '2025-01-15 00:00:00+00'::TIMESTAMPTZ - INTERVAL '22 hours', 1750, 218, 'LECTURA_PERIODICA'),
(2, '2025-01-15 00:00:00+00'::TIMESTAMPTZ - INTERVAL '21 hours', 1700, 220, 'LECTURA_PERIODICA'),
(2, '2025-01-15 00:00:00+00'::TIMESTAMPTZ - INTERVAL '20 hours', 1650, 221, 'LECTURA_PERIODICA'),
(2, '2025-01-15 00:00:00+00'::TIMESTAMPTZ - INTERVAL '19 hours', 1600, 219, 'LECTURA_PERIODICA'),
(2, '2025-01-15 00:00:00+00'::TIMESTAMPTZ - INTERVAL '18 hours', 1550, 218, 'LECTURA_PERIODICA'),
(2, '2025-01-15 00:00:00+00'::TIMESTAMPTZ - INTERVAL '17 hours', 1500, 217, 'LECTURA_PERIODICA'),
(2, '2025-01-15 00:00:00+00'::TIMESTAMPTZ - INTERVAL '16 hours', 1450, 220, 'LECTURA_PERIODICA'),
(2, '2025-01-15 00:00:00+00'::TIMESTAMPTZ - INTERVAL '15 hours', 1400, 221, 'LECTURA_PERIODICA'),
(2, '2025-01-15 00:00:00+00'::TIMESTAMPTZ - INTERVAL '14 hours', 1350, 219, 'LECTURA_PERIODICA'),
(2, '2025-01-15 00:00:00+00'::TIMESTAMPTZ - INTERVAL '13 hours', 1300, 218, 'LECTURA_PERIODICA'),
(2, '2025-01-15 00:00:00+00'::TIMESTAMPTZ - INTERVAL '12 hours', 1250, 217, 'LECTURA_PERIODICA'),
(2, '2025-01-15 00:00:00+00'::TIMESTAMPTZ - INTERVAL '11 hours', 1200, 220, 'LECTURA_PERIODICA'),
(2, '2025-01-15 00:00:00+00'::TIMESTAMPTZ - INTERVAL '10 hours', 1150, 221, 'LECTURA_PERIODICA'),
(2, '2025-01-15 00:00:00+00'::TIMESTAMPTZ - INTERVAL '9 hours', 1100, 219, 'LECTURA_PERIODICA'),
(2, '2025-01-15 00:00:00+00'::TIMESTAMPTZ - INTERVAL '8 hours', 1050, 218, 'LECTURA_PERIODICA'),
(2, '2025-01-15 00:00:00+00'::TIMESTAMPTZ - INTERVAL '7 hours', 1000, 217, 'LECTURA_PERIODICA'),
(2, '2025-01-15 00:00:00+00'::TIMESTAMPTZ - INTERVAL '6 hours', 950, 220, 'LECTURA_PERIODICA'),
(2, '2025-01-15 00:00:00+00'::TIMESTAMPTZ - INTERVAL '5 hours', 900, 221, 'LECTURA_PERIODICA'),
(2, '2025-01-15 00:00:00+00'::TIMESTAMPTZ - INTERVAL '4 hours', 850, 219, 'LECTURA_PERIODICA'),
(2, '2025-01-15 00:00:00+00'::TIMESTAMPTZ - INTERVAL '3 hours', 800, 218, 'LECTURA_PERIODICA'),
(2, '2025-01-15 00:00:00+00'::TIMESTAMPTZ - INTERVAL '2 hours', 750, 217, 'LECTURA_PERIODICA'),
(2, '2025-01-15 00:00:00+00'::TIMESTAMPTZ - INTERVAL '1 hour', 700, 220, 'LECTURA_PERIODICA'),
(2, '2025-01-15 00:00:00+00'::TIMESTAMPTZ, 650, 221, 'LECTURA_PERIODICA');

-- ---------------------------------------------------------------------------
-- dim_geografia_urbana
-- ---------------------------------------------------------------------------

INSERT INTO dim_geografia_urbana (sector_urbano, distrito, latitud, longitud, nivel_criticidad)
VALUES
('Sector Industrial', 'Norte', -34.6, -58.38, 'ALTO'),
('Sector Residencial A', 'Sur', -34.72, -58.45, 'NORMAL'),
('Sector Comercial', 'Este', -34.55, -58.3, 'MEDIO'),
('Sector Residencial B', 'Oeste', -34.68, -58.5, 'NORMAL'),
('Sector Hospitalario', 'Centro', -34.61, -58.4, 'CRITICO'),
('Sector Educativo', 'Sur', -34.73, -58.46, 'BAJO'),
('Sector Tecnológico', 'Norte', -34.59, -58.37, 'ALTO'),
('Sector Gubernamental', 'Centro', -34.62, -58.41, 'CRITICO');

-- ---------------------------------------------------------------------------
-- dim_red_electrica
-- ---------------------------------------------------------------------------

INSERT INTO dim_red_electrica (id_medidor, id_medidor_origen, codigo_medidor, transformador, circuito, subestacion, capacidad_kva, estado_operativo, fecha_fin, activo_bool)
VALUES
(1, 1, 'MED-0001', 'Transformador A1-T1', 'Circuito A1', 'Subestación A', 100.1, 'ACTIVO', NULL, TRUE),
(2, 2, 'MED-0002', 'Transformador A1-T1', 'Circuito A1', 'Subestación A', 383.7, 'ACTIVO', NULL, TRUE),
(3, 3, 'MED-0003', 'Transformador A1-T1', 'Circuito A1', 'Subestación A', 160.2, 'ACTIVO', NULL, TRUE),
(4, 4, 'MED-0004', 'Transformador A1-T2', 'Circuito A1', 'Subestación A', 381.41, 'ACTIVO', NULL, TRUE),
(5, 5, 'MED-0005', 'Transformador A1-T3', 'Circuito A1', 'Subestación A', 383.3, 'ACTIVO', NULL, TRUE),
(6, 6, 'MED-0006', 'Transformador A1-T3', 'Circuito A1', 'Subestación A', 295.41, 'ACTIVO', NULL, TRUE),
(7, 7, 'MED-0007', 'Transformador A1-T3', 'Circuito A1', 'Subestación A', 315.72, 'ACTIVO', NULL, TRUE),
(8, 8, 'MED-0008', 'Transformador A2-T1', 'Circuito A2', 'Subestación A', 63.41, 'ACTIVO', NULL, TRUE),
(9, 9, 'MED-0009', 'Transformador A2-T2', 'Circuito A2', 'Subestación A', 154.7, 'ACTIVO', NULL, TRUE),
(10, 10, 'MED-0010', 'Transformador A2-T3', 'Circuito A2', 'Subestación A', 61.94, 'ACTIVO', NULL, TRUE),
(11, 11, 'MED-0011', 'Transformador A2-T3', 'Circuito A2', 'Subestación A', 139.48, 'ACTIVO', NULL, TRUE),
(12, 12, 'MED-0012', 'Transformador B1-T1', 'Circuito B1', 'Subestación B', 365.6, 'ACTIVO', NULL, TRUE),
(13, 13, 'MED-0013', 'Transformador B1-T1', 'Circuito B1', 'Subestación B', 238.78, 'ACTIVO', NULL, TRUE),
(14, 14, 'MED-0014', 'Transformador B1-T1', 'Circuito B1', 'Subestación B', 252.14, 'ACTIVO', NULL, TRUE),
(15, 15, 'MED-0015', 'Transformador B1-T2', 'Circuito B1', 'Subestación B', 414.24, 'ACTIVO', NULL, TRUE);

-- Fix H-4: asignar geografia a cada activo de red de forma determinista.
-- Subestacion A -> sectores ordinales 1..4 ; Subestacion B -> sectores 5..8.
-- Da estructura geografica real al drill-down y a los filtros por sector.
WITH geo AS (
    SELECT sk_geografia_urbana AS sk,
           ROW_NUMBER() OVER (ORDER BY sk_geografia_urbana) AS rn
    FROM dim_geografia_urbana
)
UPDATE dim_red_electrica dre
SET sk_geografia_urbana = geo.sk
FROM geo
WHERE geo.rn = CASE dre.subestacion
        WHEN 'Subestación A' THEN 1 + (dre.id_medidor % 4)
        WHEN 'Subestación B' THEN 5 + (dre.id_medidor % 4)
        ELSE 1 + (dre.id_medidor % 8)
    END;

-- El seed omite fecha_inicio, por lo que tomaba DEFAULT NOW() (fecha de carga).
-- Eso dejaba la version SCD2 vigente DESPUES de los eventos historicos, y el lookup
-- temporal del SP (fecha_inicio <= ts_outage) nunca encontraba el activo, mandando
-- todo al fallback "DESCONOCIDO". Se retrodata el alta antes del periodo de datos.
UPDATE dim_red_electrica
SET fecha_inicio = '2024-01-01 00:00:00+00'::TIMESTAMPTZ
WHERE fecha_inicio > '2024-06-01 00:00:00+00'::TIMESTAMPTZ;

-- ---------------------------------------------------------------------------
-- dim_clientes_inventario
-- ---------------------------------------------------------------------------

INSERT INTO dim_clientes_inventario (total_clientes_servidos, fecha_inicio, fecha_fin, activo_bool, version)
VALUES
(15, '2025-01-01T00:00:00+00:00'::TIMESTAMPTZ, '2025-01-06T00:00:00+00:00'::TIMESTAMPTZ, FALSE, 1),
(38, '2025-01-06T00:00:00+00:00'::TIMESTAMPTZ, NULL, TRUE, 2);

-- ---------------------------------------------------------------------------
-- staging_eventos
-- ---------------------------------------------------------------------------
-- Anomalías inyectadas: 5 RESTORATION huérfana(s),
--                       5 transitorio(s) < 5 min,
--                       3 par(es) de OUTAGE consecutivo(s),
--                       0 outage(s) abierto(s) al final (esperado: 0).
-- Total eventos staging: 102

-- ---------------------------------------------------------------------------
-- staging_eventos
-- ---------------------------------------------------------------------------

INSERT INTO staging_eventos (id_medidor, timestamp_evento, tipo_evento, procesado)
VALUES
(3, '2025-01-01T08:31:05+00:00'::TIMESTAMPTZ, 'POWER_OUTAGE', FALSE),
(3, '2025-01-01T11:38:06.550456+00:00'::TIMESTAMPTZ, 'POWER_RESTORATION', FALSE),
(9, '2025-01-01T11:52:58+00:00'::TIMESTAMPTZ, 'POWER_OUTAGE', FALSE),
(9, '2025-01-01T11:58:04+00:00'::TIMESTAMPTZ, 'POWER_RESTORATION', FALSE),
(4, '2025-01-01T22:38:20+00:00'::TIMESTAMPTZ, 'POWER_OUTAGE', FALSE),
(4, '2025-01-01T22:43:36.757134+00:00'::TIMESTAMPTZ, 'POWER_RESTORATION', FALSE),
(13, '2025-01-02T01:56:48+00:00'::TIMESTAMPTZ, 'POWER_OUTAGE', FALSE),
(13, '2025-01-02T02:03:48.974801+00:00'::TIMESTAMPTZ, 'POWER_RESTORATION', FALSE),
(15, '2025-01-02T12:44:49+00:00'::TIMESTAMPTZ, 'POWER_OUTAGE', FALSE),
(15, '2025-01-02T13:29:32.002872+00:00'::TIMESTAMPTZ, 'POWER_RESTORATION', FALSE),
(10, '2025-01-02T20:12:23+00:00'::TIMESTAMPTZ, 'POWER_OUTAGE', FALSE),
(10, '2025-01-02T20:32:30.694614+00:00'::TIMESTAMPTZ, 'POWER_RESTORATION', FALSE),
(8, '2025-01-03T00:49:08+00:00'::TIMESTAMPTZ, 'POWER_OUTAGE', FALSE),
(8, '2025-01-03T00:54:14+00:00'::TIMESTAMPTZ, 'POWER_RESTORATION', FALSE),
(5, '2025-01-03T07:42:27+00:00'::TIMESTAMPTZ, 'POWER_OUTAGE', FALSE),
(5, '2025-01-03T07:47:33+00:00'::TIMESTAMPTZ, 'POWER_RESTORATION', FALSE),
(6, '2025-01-03T12:50:50+00:00'::TIMESTAMPTZ, 'POWER_OUTAGE', FALSE),
(6, '2025-01-03T12:55:56+00:00'::TIMESTAMPTZ, 'POWER_RESTORATION', FALSE),
(9, '2025-01-03T13:04:49+00:00'::TIMESTAMPTZ, 'POWER_OUTAGE', FALSE),
(9, '2025-01-03T13:21:39.087582+00:00'::TIMESTAMPTZ, 'POWER_RESTORATION', FALSE),
(1, '2025-01-03T15:22:38+00:00'::TIMESTAMPTZ, 'POWER_OUTAGE', FALSE),
(15, '2025-01-03T15:27:42+00:00'::TIMESTAMPTZ, 'POWER_OUTAGE', FALSE),
(1, '2025-01-03T15:27:44+00:00'::TIMESTAMPTZ, 'POWER_RESTORATION', FALSE),
(15, '2025-01-03T15:40:02.083308+00:00'::TIMESTAMPTZ, 'POWER_RESTORATION', FALSE),
(3, '2025-01-03T16:29:33+00:00'::TIMESTAMPTZ, 'POWER_OUTAGE', FALSE),
(3, '2025-01-03T16:33:00.599538+00:00'::TIMESTAMPTZ, 'POWER_RESTORATION', FALSE),
(7, '2025-01-03T16:42:41+00:00'::TIMESTAMPTZ, 'POWER_OUTAGE', FALSE),
(7, '2025-01-03T16:47:47+00:00'::TIMESTAMPTZ, 'POWER_RESTORATION', FALSE),
(2, '2025-01-03T18:15:10+00:00'::TIMESTAMPTZ, 'POWER_OUTAGE', FALSE),
(2, '2025-01-03T18:32:07.653957+00:00'::TIMESTAMPTZ, 'POWER_RESTORATION', FALSE),
(10, '2025-01-03T18:42:26+00:00'::TIMESTAMPTZ, 'POWER_OUTAGE', FALSE),
(10, '2025-01-03T19:04:47.779605+00:00'::TIMESTAMPTZ, 'POWER_RESTORATION', FALSE),
(12, '2025-01-03T19:46:57+00:00'::TIMESTAMPTZ, 'POWER_OUTAGE', FALSE),
(11, '2025-01-03T20:14:51+00:00'::TIMESTAMPTZ, 'POWER_OUTAGE', FALSE),
(12, '2025-01-03T20:20:10.761140+00:00'::TIMESTAMPTZ, 'POWER_RESTORATION', FALSE),
(11, '2025-01-03T20:24:33.455112+00:00'::TIMESTAMPTZ, 'POWER_RESTORATION', FALSE),
(14, '2025-01-03T20:53:26+00:00'::TIMESTAMPTZ, 'POWER_OUTAGE', FALSE),
(14, '2025-01-03T20:54:24.399315+00:00'::TIMESTAMPTZ, 'POWER_OUTAGE', FALSE),
(14, '2025-01-03T21:00:11.761601+00:00'::TIMESTAMPTZ, 'POWER_RESTORATION', FALSE),
(13, '2025-01-03T21:53:26+00:00'::TIMESTAMPTZ, 'POWER_OUTAGE', FALSE),
(4, '2025-01-03T22:05:05+00:00'::TIMESTAMPTZ, 'POWER_OUTAGE', FALSE),
(13, '2025-01-03T22:54:19.237243+00:00'::TIMESTAMPTZ, 'POWER_RESTORATION', FALSE),
(4, '2025-01-03T23:41:04.029004+00:00'::TIMESTAMPTZ, 'POWER_RESTORATION', FALSE),
(15, '2025-01-04T07:23:40+00:00'::TIMESTAMPTZ, 'POWER_OUTAGE', FALSE),
(15, '2025-01-04T08:46:38.086329+00:00'::TIMESTAMPTZ, 'POWER_RESTORATION', FALSE),
(4, '2025-01-04T09:33:55+00:00'::TIMESTAMPTZ, 'POWER_OUTAGE', FALSE),
(4, '2025-01-04T10:11:36.908589+00:00'::TIMESTAMPTZ, 'POWER_RESTORATION', FALSE),
(11, '2025-01-04T14:37:00+00:00'::TIMESTAMPTZ, 'POWER_RESTORATION', FALSE),
(12, '2025-01-04T18:16:48+00:00'::TIMESTAMPTZ, 'POWER_OUTAGE', FALSE),
(12, '2025-01-04T18:44:05.774726+00:00'::TIMESTAMPTZ, 'POWER_RESTORATION', FALSE),
(14, '2025-01-04T20:15:12+00:00'::TIMESTAMPTZ, 'POWER_OUTAGE', FALSE),
(14, '2025-01-04T20:17:41.355801+00:00'::TIMESTAMPTZ, 'POWER_RESTORATION', FALSE),
(7, '2025-01-05T06:13:32+00:00'::TIMESTAMPTZ, 'POWER_OUTAGE', FALSE),
(7, '2025-01-05T06:41:20.942230+00:00'::TIMESTAMPTZ, 'POWER_RESTORATION', FALSE),
(3, '2025-01-05T11:44:00+00:00'::TIMESTAMPTZ, 'POWER_RESTORATION', FALSE),
(8, '2025-01-06T18:33:00+00:00'::TIMESTAMPTZ, 'POWER_RESTORATION', FALSE),
(8, '2025-01-06T18:53:23+00:00'::TIMESTAMPTZ, 'POWER_OUTAGE', FALSE),
(8, '2025-01-06T18:54:48.337736+00:00'::TIMESTAMPTZ, 'POWER_RESTORATION', FALSE),
(6, '2025-01-06T19:34:03+00:00'::TIMESTAMPTZ, 'POWER_OUTAGE', FALSE),
(6, '2025-01-06T19:48:32.026877+00:00'::TIMESTAMPTZ, 'POWER_RESTORATION', FALSE),
(9, '2025-01-07T03:38:27+00:00'::TIMESTAMPTZ, 'POWER_OUTAGE', FALSE),
(9, '2025-01-07T04:02:55.237788+00:00'::TIMESTAMPTZ, 'POWER_RESTORATION', FALSE),
(6, '2025-01-07T05:32:05+00:00'::TIMESTAMPTZ, 'POWER_OUTAGE', FALSE),
(4, '2025-01-07T08:14:04+00:00'::TIMESTAMPTZ, 'POWER_OUTAGE', FALSE),
(4, '2025-01-07T08:28:19.568809+00:00'::TIMESTAMPTZ, 'POWER_RESTORATION', FALSE),
(14, '2025-01-07T09:38:47+00:00'::TIMESTAMPTZ, 'POWER_OUTAGE', FALSE),
(6, '2025-01-07T09:47:02.026266+00:00'::TIMESTAMPTZ, 'POWER_RESTORATION', FALSE),
(5, '2025-01-07T10:28:08+00:00'::TIMESTAMPTZ, 'POWER_OUTAGE', FALSE),
(5, '2025-01-07T10:36:15.460713+00:00'::TIMESTAMPTZ, 'POWER_RESTORATION', FALSE),
(2, '2025-01-07T11:31:25+00:00'::TIMESTAMPTZ, 'POWER_OUTAGE', FALSE),
(14, '2025-01-07T12:17:56.388508+00:00'::TIMESTAMPTZ, 'POWER_RESTORATION', FALSE),
(10, '2025-01-07T13:13:27+00:00'::TIMESTAMPTZ, 'POWER_OUTAGE', FALSE),
(2, '2025-01-07T13:31:13.660432+00:00'::TIMESTAMPTZ, 'POWER_RESTORATION', FALSE),
(12, '2025-01-07T14:57:34+00:00'::TIMESTAMPTZ, 'POWER_OUTAGE', FALSE),
(12, '2025-01-07T15:03:10.173128+00:00'::TIMESTAMPTZ, 'POWER_RESTORATION', FALSE),
(10, '2025-01-07T15:11:22.031109+00:00'::TIMESTAMPTZ, 'POWER_RESTORATION', FALSE),
(3, '2025-01-07T18:46:56+00:00'::TIMESTAMPTZ, 'POWER_OUTAGE', FALSE),
(3, '2025-01-07T18:47:42.663486+00:00'::TIMESTAMPTZ, 'POWER_OUTAGE', FALSE),
(15, '2025-01-07T18:52:46+00:00'::TIMESTAMPTZ, 'POWER_OUTAGE', FALSE),
(15, '2025-01-07T19:01:35.070555+00:00'::TIMESTAMPTZ, 'POWER_RESTORATION', FALSE),
(1, '2025-01-07T20:02:42+00:00'::TIMESTAMPTZ, 'POWER_OUTAGE', FALSE),
(1, '2025-01-07T20:11:35.912669+00:00'::TIMESTAMPTZ, 'POWER_RESTORATION', FALSE),
(3, '2025-01-07T20:18:17.269273+00:00'::TIMESTAMPTZ, 'POWER_RESTORATION', FALSE),
(7, '2025-01-07T20:35:19+00:00'::TIMESTAMPTZ, 'POWER_OUTAGE', FALSE),
(7, '2025-01-07T20:36:37.227757+00:00'::TIMESTAMPTZ, 'POWER_OUTAGE', FALSE),
(7, '2025-01-07T20:38:14.581579+00:00'::TIMESTAMPTZ, 'POWER_RESTORATION', FALSE),
(13, '2025-01-07T21:58:08+00:00'::TIMESTAMPTZ, 'POWER_OUTAGE', FALSE),
(8, '2025-01-07T22:13:43+00:00'::TIMESTAMPTZ, 'POWER_OUTAGE', FALSE),
(8, '2025-01-07T22:43:19.574712+00:00'::TIMESTAMPTZ, 'POWER_RESTORATION', FALSE),
(11, '2025-01-07T22:55:49+00:00'::TIMESTAMPTZ, 'POWER_OUTAGE', FALSE),
(11, '2025-01-07T22:57:53.390828+00:00'::TIMESTAMPTZ, 'POWER_RESTORATION', FALSE),
(13, '2025-01-08T07:10:39.238931+00:00'::TIMESTAMPTZ, 'POWER_RESTORATION', FALSE),
(14, '2025-01-08T19:31:00+00:00'::TIMESTAMPTZ, 'POWER_RESTORATION', FALSE),
(7, '2025-01-08T21:05:00+00:00'::TIMESTAMPTZ, 'POWER_RESTORATION', FALSE),
(15, '2025-01-09T19:42:24+00:00'::TIMESTAMPTZ, 'POWER_OUTAGE', FALSE),
(15, '2025-01-09T19:54:26.536689+00:00'::TIMESTAMPTZ, 'POWER_RESTORATION', FALSE),
(8, '2025-01-09T22:51:11+00:00'::TIMESTAMPTZ, 'POWER_OUTAGE', FALSE),
(8, '2025-01-10T01:57:26.014481+00:00'::TIMESTAMPTZ, 'POWER_RESTORATION', FALSE),
(4, '2025-01-10T06:15:17+00:00'::TIMESTAMPTZ, 'POWER_OUTAGE', FALSE),
(4, '2025-01-10T06:23:02.146758+00:00'::TIMESTAMPTZ, 'POWER_RESTORATION', FALSE),
(5, '2025-01-10T21:05:59+00:00'::TIMESTAMPTZ, 'POWER_OUTAGE', FALSE),
(5, '2025-01-10T21:48:00.105286+00:00'::TIMESTAMPTZ, 'POWER_RESTORATION', FALSE);

COMMIT;

-- ==============================================================================
-- END OF FILE
-- ==============================================================================
