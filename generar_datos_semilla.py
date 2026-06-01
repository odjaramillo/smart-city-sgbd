#!/usr/bin/env python3
"""
generar_datos_semilla.py
========================
Generador determinista de datos semilla para el pipeline ELT de Smart Grid.

Lee 01-ddl-modelo-estrella.sql, extrae columnas insertables, construye una
topología de red realista, genera secuencias de eventos POWER_OUTAGE /
POWER_RESTORATION con sesgos horarios y perfiles log-normales de duración,
inyecta anomalías deterministas, garantiza cierre de secuencias al final del
período, y emite un archivo SQL autocontenido con inserciones por lotes.

Uso:
    python generar_datos_semilla.py
    python generar_datos_semilla.py --seed 123 --days 30 --meters 200
"""

import argparse
import math
import random
import re
import sys
from datetime import datetime, timedelta, timezone

# ---------------------------------------------------------------------------
# Constantes de modelo
# ---------------------------------------------------------------------------

HOUR_WEIGHTS = {
    0: 0.3, 1: 0.3, 2: 0.3, 3: 0.3, 4: 0.3, 5: 0.3,
    6: 0.8, 7: 0.8, 8: 0.8, 9: 0.8, 10: 0.8, 11: 0.8,
    12: 1.0, 13: 1.0, 14: 1.0, 15: 1.0, 16: 1.0, 17: 1.0,
    18: 3.0, 19: 3.0, 20: 3.0, 21: 3.0, 22: 3.0,
    23: 0.5,
}

DURATION_PROFILES = [
    # (label, weight, mu, sigma)
    ("A_routine",      0.70, 2.5, 0.8),
    ("B_extended",     0.25, 4.5, 1.0),
    ("C_catastrophic", 0.05, 6.0, 0.5),
]

SUBSTATION_RELIABILITY = {
    "A": 1.0,
    "B": 1.5,
    "C": 2.0,
}

# ---------------------------------------------------------------------------
# 1. Parsing de DDL
# ---------------------------------------------------------------------------

def parse_ddl(path: str) -> dict:
    """
    Lee el archivo DDL y extrae los nombres de columnas insertables
    (excluyendo GENERATED ALWAYS AS IDENTITY y DEFAULT NOW()) para cada tabla
    objetivo.
    """
    with open(path, "r", encoding="utf-8") as f:
        ddl = f.read()

    target_tables = {
        "dim_geografia_urbana",
        "dim_red_electrica",
        "dim_clientes_inventario",
        "dim_tipo_evento",
        "staging_telemetria",
        "staging_eventos",
    }

    result = {}
    for table in target_tables:
        # Busca bloque CREATE TABLE <table> ( ... )
        pattern = re.compile(
            rf"CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?{re.escape(table)}\s*\((.*?)\);",
            re.DOTALL | re.IGNORECASE,
        )
        match = pattern.search(ddl)
        if not match:
            raise ValueError(f"No se encontró CREATE TABLE para {table} en {path}")

        body = match.group(1)
        columns = []
        for line in body.split("\n"):
            line = line.strip()
            if not line or line.startswith("--"):
                continue
            if line.upper().startswith("CREATE") or line.upper().startswith(");"):
                continue
            # Omitir líneas de constraints (empiezan con CONSTRAINT o CHECK)
            if re.match(r"^(CONSTRAINT|CHECK|PRIMARY|FOREIGN|UNIQUE|INDEX|COMMENT)", line, re.I):
                continue
            # Omitir líneas de CREATE INDEX
            if re.match(r"^CREATE\s+INDEX", line, re.I):
                continue

            # Extraer nombre de columna (primera palabra antes de espacio o tipo)
            col_match = re.match(r'"?([a-zA-Z_][a-zA-Z0-9_]*)"?', line)
            if not col_match:
                continue
            col_name = col_match.group(1)

            # Ignorar GENERATED ALWAYS AS IDENTITY (surrogate keys)
            if re.search(r"GENERATED\s+ALWAYS\s+AS\s+IDENTITY", line, re.I):
                continue
            # Ignorar columnas con DEFAULT NOW() — el motor las rellena al omitirlas
            if re.search(r"DEFAULT\s+NOW\s*\(\s*\)", line, re.I):
                continue
            columns.append(col_name)

        result[table] = columns

    return result


# ---------------------------------------------------------------------------
# 2. Construcción de topología
# ---------------------------------------------------------------------------

def build_topology(args) -> list:
    """
    Construye la jerarquía Subestación → Circuito → Transformador → Medidor.
    Retorna una lista de diccionarios, uno por medidor.
    """
    meters = []
    meter_id = 1

    total_transformers = (
        args.substations * args.circuits_per_sub * args.transformers_per_circuit
    )

    # Distribuir metros por transformador con algo de varianza
    base_mpt = args.meters / total_transformers

    for sub_idx in range(args.substations):
        sub_letter = chr(ord("A") + sub_idx)
        sub_name = f"Subestación {sub_letter}"
        reliability = SUBSTATION_RELIABILITY.get(sub_letter, 1.0)

        for circ_idx in range(args.circuits_per_sub):
            circ_name = f"Circuito {sub_letter}{circ_idx + 1}"

            for trans_idx in range(args.transformers_per_circuit):
                trans_name = f"Transformador {sub_letter}{circ_idx + 1}-T{trans_idx + 1}"
                # Varianza de ±3 medidores por transformador
                variance = random.randint(-3, 3)
                mpt = max(1, int(round(base_mpt + variance)))

                for _ in range(mpt):
                    if len(meters) >= args.meters:
                        break
                    meters.append({
                        "id": meter_id,
                        "id_medidor_origen": meter_id,
                        "codigo_medidor": f"MED-{meter_id:04d}",
                        "transformador": trans_name,
                        "circuito": circ_name,
                        "subestacion": sub_name,
                        "sub_letter": sub_letter,
                        "reliability": reliability,
                        "capacidad_kva": round(random.uniform(50.0, 500.0), 2),
                    })
                    meter_id += 1

                if len(meters) >= args.meters:
                    break
            if len(meters) >= args.meters:
                break
        if len(meters) >= args.meters:
            break

    return meters


# ---------------------------------------------------------------------------
# 3. Generación de eventos base
# ---------------------------------------------------------------------------

def sample_hour() -> int:
    """Devuelve una hora del día usando los pesos definidos."""
    hours = list(HOUR_WEIGHTS.keys())
    weights = [HOUR_WEIGHTS[h] for h in hours]
    return random.choices(hours, weights=weights, k=1)[0]


def sample_duration(min_minutes: float = 5.1) -> float:
    """Muestrea duración en minutos desde la mezcla de perfiles log-normales.
    El valor mínimo por defecto evita transitorios 'naturales' (< 5 min);
    estos se inyectan deterministamente en post-pass."""
    labels, weights, mus, sigmas = zip(*DURATION_PROFILES)
    chosen = random.choices(range(len(labels)), weights=weights, k=1)[0]
    mu = mus[chosen]
    sigma = sigmas[chosen]
    # log-normal: exp(Normal(mu, sigma))
    dur = math.exp(random.normalvariate(mu, sigma))
    return max(min_minutes, dur)


def generate_events(meters: list, args) -> dict:
    """
    Genera eventos por medidor durante el rango de días configurado.
    Retorna dict: meter_id -> lista de (timestamp, tipo_evento).
    """
    start = args.start_date
    days = args.days
    events = {}

    # Determinar días catastróficos (2-3 días con SAIDI ~10×)
    catastrophic_days = set(random.sample(range(days), k=random.choice([2, 3])))

    for meter in meters:
        meter_id = meter["id"]
        reliability = meter["reliability"]
        base_rate = 0.25 * reliability  # ~0.25 outage/día para sub A
        meter_events = []

        for day in range(days):
            jitter = random.uniform(0.8, 1.2)
            daily_rate = base_rate * jitter

            if day in catastrophic_days:
                # Día catastrófico: forzar al menos un outage largo por medidor
                n_outages = max(1, int(round(daily_rate)) + random.randint(0, 1))
            else:
                # Usar distribución simple (redondeo de Poisson aproximado)
                n_outages = max(0, int(round(daily_rate + random.uniform(-0.3, 0.3))))

            day_events = []
            for _ in range(n_outages):
                hour = sample_hour()
                minute = random.randint(0, 59)
                second = random.randint(0, 59)
                ts = start + timedelta(days=day, hours=hour, minutes=minute, seconds=second)

                dur = sample_duration()

                # Cap de seguridad
                dur = min(dur, 720.0)  # máx 12 horas

                outage_ts = ts
                restoration_ts = ts + timedelta(minutes=dur)
                day_events.append((outage_ts, "POWER_OUTAGE"))
                day_events.append((restoration_ts, "POWER_RESTORATION"))

            # Ordenar y eliminar solapamientos / secuencias corruptas
            day_events.sort(key=lambda x: x[0])
            cleaned = []
            last_restoration = None
            for ts, tipo in day_events:
                if tipo == "POWER_OUTAGE":
                    # 1) Evitar outage demasiado cercano a la última restauración
                    if last_restoration and ts < last_restoration + timedelta(minutes=5):
                        continue
                    # 2) Evitar outage consecutivo sin restauración intermedia
                    if cleaned and cleaned[-1][1] == "POWER_OUTAGE":
                        continue
                    cleaned.append((ts, tipo))
                else:
                    # RESTORATION: solo si hay un outage abierto pendiente
                    if cleaned and cleaned[-1][1] == "POWER_OUTAGE":
                        # Asegurar que restoration > outage
                        if ts <= cleaned[-1][0]:
                            ts = cleaned[-1][0] + timedelta(minutes=1)
                        cleaned.append((ts, tipo))
                        last_restoration = ts

            meter_events.extend(cleaned)

        events[meter_id] = meter_events

    return events


# ---------------------------------------------------------------------------
# 4. Inyección de casos borde (post-pass determinista)
# ---------------------------------------------------------------------------

def inject_edge_cases(events: dict, meters: list, args) -> dict:
    """
    Inyecta anomalías deterministas sobre el conjunto de eventos ya generados.
    Modifica el dict in-place y lo retorna.
    """
    start = args.start_date
    days = args.days
    end_ts = start + timedelta(days=days)

    meter_ids = list(events.keys())
    random.shuffle(meter_ids)

    # --- 4.1 Huérfanos: 5 RESTORATION sin OUTAGE previa ---
    orphan_count = 0
    for mid in meter_ids:
        if orphan_count >= 5:
            break
        # Insertar RESTORATION al inicio de la secuencia o en un hueco
        existing = events[mid]
        # Elegir un timestamp aleatorio en el rango
        orphan_day = random.randint(0, days - 1)
        orphan_hour = sample_hour()
        orphan_min = random.randint(0, 59)
        orphan_ts = start + timedelta(days=orphan_day, hours=orphan_hour, minutes=orphan_min)
        # Insertar ordenado
        existing.append((orphan_ts, "POWER_RESTORATION"))
        existing.sort(key=lambda x: x[0])
        events[mid] = existing
        orphan_count += 1

    # --- 4.2 Transitorios < 5 min: 5 pares OUTAGE→RESTORATION con duración < 5 min ---
    transient_count = 0
    for mid in meter_ids:
        if transient_count >= 5:
            break
        existing = events[mid]
        # Necesitamos al menos un par válido para reemplazarlo
        pairs = []
        for i in range(len(existing) - 1):
            if existing[i][1] == "POWER_OUTAGE" and existing[i + 1][1] == "POWER_RESTORATION":
                pairs.append(i)
        if not pairs:
            continue
        idx = random.choice(pairs)
        # Reemplazar por par transitorio (1-4 minutos)
        outage_ts = existing[idx][0]
        dur_min = random.uniform(1.0, 4.5)
        restoration_ts = outage_ts + timedelta(minutes=dur_min)
        existing[idx] = (outage_ts, "POWER_OUTAGE")
        existing[idx + 1] = (restoration_ts, "POWER_RESTORATION")
        events[mid] = existing
        transient_count += 1

    # --- 4.3 Consecutive OUTAGEs (DOBLE_OUTAGE): 3 instancias ---
    consecutive_count = 0
    for mid in meter_ids:
        if consecutive_count >= 3:
            break
        existing = events[mid]
        # Encontrar un par OUTAGE→RESTORATION e insertar un OUTAGE extra
        pairs = []
        for i in range(len(existing) - 1):
            if existing[i][1] == "POWER_OUTAGE" and existing[i + 1][1] == "POWER_RESTORATION":
                pairs.append(i)
        if not pairs:
            continue
        idx = random.choice(pairs)
        outage_ts = existing[idx][0]
        # Insertar un segundo OUTAGE justo después del primero (1-2 min después)
        second_outage_ts = outage_ts + timedelta(minutes=random.uniform(0.5, 2.0))
        existing.insert(idx + 1, (second_outage_ts, "POWER_OUTAGE"))
        events[mid] = existing
        consecutive_count += 1

    # --- 4.4 Fin de stream: cerrar todo outage abierto ---
    for mid in meter_ids:
        existing = events[mid]
        if not existing:
            continue
        if existing[-1][1] == "POWER_OUTAGE":
            # Cerrar con RESTORATION justo antes del final del período
            close_ts = end_ts - timedelta(minutes=random.uniform(5, 30))
            if close_ts <= existing[-1][0]:
                close_ts = existing[-1][0] + timedelta(minutes=random.uniform(5, 30))
            existing.append((close_ts, "POWER_RESTORATION"))
            events[mid] = existing

    return events


# ---------------------------------------------------------------------------
# 5. Emisión SQL
# ---------------------------------------------------------------------------

def sql_value(val):
    """Escapa un valor Python a literal SQL."""
    if val is None:
        return "NULL"
    if isinstance(val, bool):
        return "TRUE" if val else "FALSE"
    if isinstance(val, (int, float)):
        return str(val)
    if isinstance(val, datetime):
        return f"'{val.isoformat()}'::TIMESTAMPTZ"
    # string
    s = str(val).replace("'", "''")
    return f"'{s}'"


def emit_insert_section(f, table_name: str, columns: list, rows: list, batch_size: int = 500):
    """Escribe una sección de INSERTs por lotes."""
    if not rows:
        f.write(f"\n-- Sin filas para {table_name}\n")
        return

    col_list = ", ".join(columns)
    f.write(f"\n-- ---------------------------------------------------------------------------\n")
    f.write(f"-- {table_name}\n")
    f.write(f"-- ---------------------------------------------------------------------------\n")

    for i in range(0, len(rows), batch_size):
        batch = rows[i:i + batch_size]
        values = ",\n".join(
            "(" + ", ".join(sql_value(row.get(c)) for c in columns) + ")"
            for row in batch
        )
        f.write(f"\nINSERT INTO {table_name} ({col_list})\nVALUES\n{values};\n")


def emit_sql(events: dict, meters: list, ddl_cols: dict, args):
    """Escribe el archivo SQL de salida."""
    output_path = args.output

    # Dimension geography
    geo_rows = []
    # Crear ~6-8 sectores para que haya variedad
    districts = ["Norte", "Sur", "Este", "Oeste", "Centro"]
    sectors = [
        ("Sector Industrial", "Norte", -34.60, -58.38, "ALTO"),
        ("Sector Residencial A", "Sur", -34.72, -58.45, "NORMAL"),
        ("Sector Comercial", "Este", -34.55, -58.30, "MEDIO"),
        ("Sector Residencial B", "Oeste", -34.68, -58.50, "NORMAL"),
        ("Sector Hospitalario", "Centro", -34.61, -58.40, "CRITICO"),
        ("Sector Educativo", "Sur", -34.73, -58.46, "BAJO"),
        ("Sector Tecnológico", "Norte", -34.59, -58.37, "ALTO"),
        ("Sector Gubernamental", "Centro", -34.62, -58.41, "CRITICO"),
    ]
    for sector, distrito, lat, lon, criticidad in sectors:
        geo_rows.append({
            "sector_urbano": sector,
            "distrito": distrito,
            "latitud": lat,
            "longitud": lon,
            "nivel_criticidad": criticidad,
        })

    # Asignar geography a medidores (round-robin)
    for i, meter in enumerate(meters):
        meter["sk_geografia_urbana"] = (i % len(geo_rows)) + 1  # 1-based para referencia visual

    # Dimension red eléctrica — una fila por medidor (SCD tipo 2, activo)
    red_rows = []
    for meter in meters:
        red_rows.append({
            "id_medidor": meter["id"],
            "id_medidor_origen": meter["id_medidor_origen"],
            "codigo_medidor": meter["codigo_medidor"],
            "transformador": meter["transformador"],
            "circuito": meter["circuito"],
            "subestacion": meter["subestacion"],
            "sk_geografia_urbana": meter["sk_geografia_urbana"],
            "capacidad_kva": meter["capacidad_kva"],
            "estado_operativo": "ACTIVO",
            "fecha_inicio": args.start_date,
            "fecha_fin": None,
            "activo_bool": True,
        })

    # Dimension clientes inventario — 2 snapshots para mostrar SCD tipo 2
    client_rows = []
    mid_point = args.start_date + timedelta(days=args.days // 2)
    client_rows.append({
        "total_clientes_servidos": len(meters),
        "fecha_inicio": args.start_date,
        "fecha_fin": mid_point,
        "activo_bool": False,
        "version": 1,
    })
    client_rows.append({
        "total_clientes_servidos": len(meters) + random.randint(10, 50),
        "fecha_inicio": mid_point,
        "fecha_fin": None,
        "activo_bool": True,
        "version": 2,
    })

    # dim_tipo_evento — fila -1 obligatoria + catálogo para Stress Test
    tipo_evento_rows = []
    # Fila -1 (Unknown) — insertada primero, sequence se resetea después
    tipo_evento_rows.append({
        "sk_tipo_evento": -1,
        "codigo_evento": "UNKNOWN",
        "categoria": "DESCONOCIDO",
        "severidad": "DESCONOCIDA",
        "es_critico": False,
        "descripcion": "Tipo de evento no reconocido",
    })
    # Catálogo de eventos
    catalog_events = [
        ("POWER_OUTAGE", "INTERRUPCION", "ALTA", True, "Corte de energía detectado por smart meter"),
        ("POWER_RESTORATION", "INTERRUPCION", "MEDIA", False, "Restauración de energía"),
        ("VOLTAGE_SPIKE", "FLUCTUACION", "ALTA", True, "Pico de voltaje (>260V)"),
        ("VOLTAGE_SAG", "FLUCTUACION", "MEDIA", False, "Caída de voltaje (<180V)"),
        ("HEARTBEAT", "TELEMETRIA", "BAJA", False, "Señal de vida del medidor"),
        ("LECTURA_PERIODICA", "TELEMETRIA", "BAJA", False, "Lectura periódica de consumo/voltaje"),
    ]
    for codigo, categoria, severidad, es_critico, descripcion in catalog_events:
        tipo_evento_rows.append({
            "codigo_evento": codigo,
            "categoria": categoria,
            "severidad": severidad,
            "es_critico": es_critico,
            "descripcion": descripcion,
        })

    # staging_telemetria — lecturas de consumo/voltaje
    # Genera N lecturas por medidor por día durante todo el período.
    # Por defecto: 1 lectura/día (diaria). Con --telemetry-daily-readings se controla.
    telemetry_rows = []
    # Horas del día con perfiles de consumo típicos (residencial)
    HOURLY_CONSUMPTION_PROFILE = {
        0: 0.8, 1: 0.7, 2: 0.7, 3: 0.7, 4: 0.7, 5: 0.8,  # Noche baja
        6: 1.0, 7: 1.2, 8: 1.5, 9: 1.3, 10: 1.2, 11: 1.3,  # Mañana
        12: 1.4, 13: 1.3, 14: 1.2, 15: 1.1, 16: 1.2, 17: 1.3,  # Tarde
        18: 1.8, 19: 2.0, 20: 2.2, 21: 1.9, 22: 1.5, 23: 1.0,  # Pico vespertino
    }
    base_consumption = 2.0  # kWh base por hora
    base_voltage = 220.0  # V base

    for meter in meters:
        meter_id = meter["id"]
        # Generar lecturas para cada día del período
        for day_offset in range(args.days):
            # Determinar horas de lectura para este día
            hours_today = random.sample(range(24), k=min(args.telemetry_daily_readings, 24))
            for hour in sorted(hours_today):
                minute = random.randint(0, 59)
                second = random.randint(0, 59)
                ts = args.start_date + timedelta(days=day_offset, hours=hour, minutes=minute, seconds=second)
                # Consumption con variación aleatoria ±15%
                consumption_factor = HOURLY_CONSUMPTION_PROFILE.get(hour, 1.0)
                consumo_wh = base_consumption * consumption_factor * random.uniform(0.85, 1.15) * 1000  # Wh
                # Voltage con pequeña variación ±5V
                voltaje = base_voltage + random.uniform(-5, 5)
                telemetry_rows.append({
                    "id_medidor": meter_id,
                    "timestamp_lectura": ts,
                    "consumo_wh": round(consumo_wh, 2),
                    "voltaje": round(voltaje, 2),
                    "tipo_lectura": "LECTURA_PERIODICA",
                    "procesado": False,
                })

    # Staging events — aplanar todos los eventos de todos los medidores
    staging_rows = []
    for mid in sorted(events.keys()):
        for ts, tipo in events[mid]:
            staging_rows.append({
                "id_medidor": mid,
                "timestamp_evento": ts,
                "tipo_evento": tipo,
                "procesado": False,
            })

    # Ordenar staging por timestamp, luego por medidor, luego por tipo
    # (OUTAGE antes que RESTORATION si mismo timestamp)
    staging_rows.sort(key=lambda r: (r["timestamp_evento"], r["id_medidor"], r["tipo_evento"]))

    # Contadores de anomalías para comentario descriptivo
    orphan_count = 0
    transient_count = 0
    double_outage_count = 0
    open_count = 0
    for mid in events:
        evs = events[mid]
        if evs and evs[-1][1] == "POWER_OUTAGE":
            open_count += 1
        prev = None
        prev_ts = None
        for ts, tipo in evs:
            if tipo == "POWER_RESTORATION" and prev != "POWER_OUTAGE":
                orphan_count += 1
            if tipo == "POWER_OUTAGE" and prev == "POWER_OUTAGE":
                double_outage_count += 1
            if prev == "POWER_OUTAGE" and tipo == "POWER_RESTORATION":
                dur = (ts - prev_ts).total_seconds() / 60.0
                if dur < 5.0:
                    transient_count += 1
            prev = tipo
            prev_ts = ts

    # Escribir archivo
    with open(output_path, "w", encoding="utf-8") as f:
        f.write("-- ==============================================================================\n")
        f.write("-- PROYECTO: Arquitectura Analítica de Resiliencia para Smart City (Smart Grid)\n")
        f.write("-- GENERADO AUTOMÁTICAMENTE por generar_datos_semilla.py\n")
        f.write(f"-- Seed: {args.seed} | Días: {args.days} | Medidores: {len(meters)}\n")
        f.write(f"-- Fecha generación: {datetime.now(timezone.utc).isoformat()}\n")
        f.write("-- ==============================================================================\n")
        f.write("\nBEGIN;\n")

        # dim_tipo_evento — OBLIGATORIO: ejecutar antes de cualquier fact table
        f.write("\n-- ---------------------------------------------------------------------------\n")
        f.write("-- dim_tipo_evento (OBLIGATORIO: ejecutar ANTES de cualquier fact table)\n")
        f.write("-- ---------------------------------------------------------------------------\n")
        f.write("-- Fila obligatoria -1 (Unknown) — debe existir antes de las fact tables\n")
        # Emitir solo la fila -1 primero (sin columns para usar DEFAULT)
        unknown_row = [r for r in tipo_evento_rows if r.get("sk_tipo_evento") == -1]
        if unknown_row:
            f.write("INSERT INTO dim_tipo_evento (sk_tipo_evento, codigo_evento, categoria, severidad, es_critico, descripcion)\n")
            f.write("OVERRIDING SYSTEM VALUE\n")
            f.write("VALUES (-1, 'UNKNOWN', 'DESCONOCIDO', 'DESCONOCIDA', FALSE, 'Tipo de evento no reconocido');\n")
            f.write("\n-- Reset sequence para que los próximos inserts usen IDs correctos\n")
            f.write("SELECT setval('dim_tipo_evento_sk_tipo_evento_seq', 1, false);\n")
        # Emitir catálogo (sin sk_tipo_evento para usar IDENTITY)
        catalog_rows = [r for r in tipo_evento_rows if r.get("sk_tipo_evento") != -1]
        emit_insert_section(f, "dim_tipo_evento", ddl_cols["dim_tipo_evento"], catalog_rows)

        # staging_telemetria
        f.write("\n-- ---------------------------------------------------------------------------\n")
        f.write("-- staging_telemetria (lecturas horarias de consumo/voltaje)\n")
        f.write("-- ---------------------------------------------------------------------------\n")
        emit_insert_section(f, "staging_telemetria", ddl_cols["staging_telemetria"], telemetry_rows)

        emit_insert_section(f, "dim_geografia_urbana", ddl_cols["dim_geografia_urbana"], geo_rows)
        emit_insert_section(f, "dim_red_electrica", ddl_cols["dim_red_electrica"], red_rows)
        emit_insert_section(f, "dim_clientes_inventario", ddl_cols["dim_clientes_inventario"], client_rows)

        f.write("\n-- ---------------------------------------------------------------------------\n")
        f.write("-- staging_eventos\n")
        f.write("-- ---------------------------------------------------------------------------\n")
        f.write(f"-- Anomalías inyectadas: {orphan_count} RESTORATION huérfana(s),\n")
        f.write(f"--                       {transient_count} transitorio(s) < 5 min,\n")
        f.write(f"--                       {double_outage_count} par(es) de OUTAGE consecutivo(s),\n")
        f.write(f"--                       {open_count} outage(s) abierto(s) al final (esperado: 0).\n")
        f.write(f"-- Total eventos staging: {len(staging_rows)}\n")

        emit_insert_section(f, "staging_eventos", ddl_cols["staging_eventos"], staging_rows)

        f.write("\nCOMMIT;\n")
        f.write("\n-- ==============================================================================\n")
        f.write("-- END OF FILE\n")
        f.write("-- ==============================================================================\n")

    print(f"[OK] SQL escrito en {output_path}")
    print(f"     Filas: tipo_evento={len(tipo_evento_rows)} telemetry={len(telemetry_rows)} geo={len(geo_rows)} red={len(red_rows)} clientes={len(client_rows)} staging={len(staging_rows)}")


# ---------------------------------------------------------------------------
# 6. CLI y main
# ---------------------------------------------------------------------------

def parse_args():
    parser = argparse.ArgumentParser(
        description="Genera datos semilla SQL para el pipeline ELT Smart Grid."
    )
    parser.add_argument(
        "--ddl-path", default="01-ddl-modelo-estrella.sql",
        help="Ruta al archivo DDL (default: 01-ddl-modelo-estrella.sql)"
    )
    parser.add_argument(
        "--output", default="04-datos-semilla.sql",
        help="Ruta de salida SQL (default: 04-datos-semilla.sql)"
    )
    parser.add_argument(
        "--seed", type=int, default=42,
        help="Semilla RNG para reproducibilidad (default: 42)"
    )
    parser.add_argument(
        "--start-date", type=lambda s: datetime.strptime(s, "%Y-%m-%d").replace(tzinfo=timezone.utc),
        default=datetime(2025, 1, 1, tzinfo=timezone.utc),
        help="Fecha inicio del período (YYYY-MM-DD, default: 2025-01-01)"
    )
    parser.add_argument(
        "--days", type=int, default=60,
        help="Días de eventos a generar (default: 60)"
    )
    parser.add_argument(
        "--meters", type=int, default=300,
        help="Cantidad total de medidores (default: 300)"
    )
    parser.add_argument(
        "--substations", type=int, default=3,
        help="Número de subestaciones (default: 3)"
    )
    parser.add_argument(
        "--circuits-per-sub", type=int, default=2,
        help="Circuitos por subestación (default: 2)"
    )
    parser.add_argument(
        "--transformers-per-circuit", type=int, default=3,
        help="Transformadores por circuito (default: 3)"
    )
    parser.add_argument(
        "--telemetry-daily-readings", type=int, default=1,
        help="Lecturas de telemetría por medidor por día (default: 1)"
    )
    return parser.parse_args()


def main():
    args = parse_args()
    random.seed(args.seed)

    print(f"[INFO] Seed: {args.seed}")
    print(f"[INFO] DDL: {args.ddl_path}")
    print(f"[INFO] Output: {args.output}")
    print(f"[INFO] Período: {args.start_date.date()} + {args.days} días")

    # 1. Parse DDL
    print("[INFO] Parseando DDL...")
    ddl_cols = parse_ddl(args.ddl_path)
    for table, cols in ddl_cols.items():
        print(f"       {table}: {cols}")

    # 2. Topología
    print("[INFO] Construyendo topología...")
    meters = build_topology(args)
    print(f"       Medidores creados: {len(meters)}")

    # 3. Eventos base
    print("[INFO] Generando eventos base...")
    events = generate_events(meters, args)
    total_base = sum(len(v) for v in events.values())
    print(f"       Eventos base: {total_base}")

    # 4. Casos borde
    print("[INFO] Inyectando casos borde...")
    events = inject_edge_cases(events, meters, args)
    total_after = sum(len(v) for v in events.values())
    print(f"       Eventos tras inyección: {total_after}")

    # 5. SQL
    print("[INFO] Emitiendo SQL...")
    emit_sql(events, meters, ddl_cols, args)

    # 6. Quick sanity checks
    print("\n[CHECKS]")
    # Verificar que todo medidor termina en RESTORATION
    open_meters = [mid for mid, evs in events.items() if evs and evs[-1][1] == "POWER_OUTAGE"]
    print(f"       Medidores con outage abierto al final: {len(open_meters)}")
    if open_meters:
        print("       [ERROR] Se encontraron medidores sin cierre!")
        sys.exit(1)

    # Contar huérfanos, transitorios, doble-outage
    orphan_rest = 0
    transient_pairs = 0
    double_outage = 0
    for mid, evs in events.items():
        prev = None
        for ts, tipo in evs:
            if tipo == "POWER_RESTORATION" and (prev is None or prev == "POWER_RESTORATION"):
                orphan_rest += 1
            if tipo == "POWER_OUTAGE" and prev == "POWER_OUTAGE":
                double_outage += 1
            # Detectar transitorio: par OUTAGE→RESTORATION con < 5 min
            # (contado después en otro loop)
            prev = tipo
        # Transitorios
        for i in range(len(evs) - 1):
            if evs[i][1] == "POWER_OUTAGE" and evs[i + 1][1] == "POWER_RESTORATION":
                dur = (evs[i + 1][0] - evs[i][0]).total_seconds() / 60.0
                if dur < 5.0:
                    transient_pairs += 1

    print(f"       Huérfanos RESTORATION: {orphan_rest}")
    print(f"       Transitorios < 5 min: {transient_pairs}")
    print(f"       Doble OUTAGE consecutivo: {double_outage}")
    print("[DONE]")


if __name__ == "__main__":
    main()
