"""
=============================================================================
PROYECTO 2 DAP - FASE 3: ETL de CSV procesados -> SQLite (Kimball)
=============================================================================
Entradas (mismo directorio que el script, o la carpeta pasada por argumento):
    Dim_Machine.csv                100 equipos
    Fact_SystemFailures.csv        7.966 eventos discretos
    Fact_TelemetryEvents.csv       876.100 lecturas horarias (carga por lotes)
    Kpi_Reliability_by_Machine.csv 100 filas (MTBF / MTTR / % Uptime)
Salida:
    proyecto2_kimball.db  (Dim_Calendar, Dim_Machine, Dim_Event,
                           Fact_TelemetryEvents, Fact_SystemFailures,
                           Fact_ReliabilityKPI)

Uso:
    python 02_etl_to_sql.py                # CSVs junto al script
    python 02_etl_to_sql.py ruta/a/datos   # CSVs en otra carpeta
=============================================================================
"""

import sqlite3
import sys
from pathlib import Path

import numpy as np
import pandas as pd

# ---------------------------------------------------------------------------
# Configuración
# ---------------------------------------------------------------------------
BASE_DIR = Path(__file__).resolve().parent if "__file__" in globals() else Path(".")
DATA_DIR = Path(sys.argv[1]) if len(sys.argv) > 1 else BASE_DIR

DDL_FILE = BASE_DIR / "01_DDL_kimball.sql"
DB_FILE = BASE_DIR / "proyecto2_kimball.db"

CSV_MACHINE = DATA_DIR / "Dim_Machine.csv"
CSV_FAILURES = DATA_DIR / "Fact_SystemFailures.csv"
CSV_TELEMETRY = DATA_DIR / "Fact_TelemetryEvents.csv"
CSV_KPI = DATA_DIR / "Kpi_Reliability_by_Machine.csv"

# SLA de planta (supuesto documentado en el notebook de análisis, Bloque 5).
# Deben validarse contra el CMMS/SAP PM antes de usarse en producción.
MAINT_DOWNTIME_HOURS = 6.0
FAILURE_DOWNTIME_HOURS = 12.0

CHUNK_SIZE = 100_000

DIAS_ES = {
    "Monday": "Lunes", "Tuesday": "Martes", "Wednesday": "Miércoles",
    "Thursday": "Jueves", "Friday": "Viernes", "Saturday": "Sábado",
    "Sunday": "Domingo",
}


def fail(msg):
    print(f"[ERROR] {msg}")
    sys.exit(1)


for f in (DDL_FILE, CSV_MACHINE, CSV_FAILURES, CSV_TELEMETRY, CSV_KPI):
    if not f.exists():
        fail(f"No se encontró el archivo requerido: {f}")


def to_ts(series):
    """Normaliza a texto 'YYYY-MM-DD HH:MM:SS' (ordenable lexicográficamente)."""
    return pd.to_datetime(series).dt.strftime("%Y-%m-%d %H:%M:%S")


# ---------------------------------------------------------------------------
# 1. EXTRACT (dimensiones y hechos pequeños; la telemetría va por lotes)
# ---------------------------------------------------------------------------
machines = pd.read_csv(CSV_MACHINE)
failures = pd.read_csv(CSV_FAILURES)
kpi = pd.read_csv(CSV_KPI)
tel_dates = pd.read_csv(CSV_TELEMETRY, usecols=["datetime"])["datetime"]

print(f"[1/7] CSV cargados: {len(machines)} máquinas, {len(failures)} eventos, "
      f"{len(kpi)} KPIs, {len(tel_dates)} lecturas de telemetría")

failures["event_ts"] = to_ts(failures["datetime"])
tel_ts_all = to_ts(tel_dates)

# ---------------------------------------------------------------------------
# 2. Crear base y ejecutar DDL
# ---------------------------------------------------------------------------
if DB_FILE.exists():
    DB_FILE.unlink()
conn = sqlite3.connect(DB_FILE)
conn.executescript(DDL_FILE.read_text(encoding="utf-8"))
conn.execute("PRAGMA foreign_keys = ON;")
conn.execute("PRAGMA journal_mode = MEMORY;")
conn.execute("PRAGMA synchronous = OFF;")
conn.commit()
print("[2/7] Esquema Kimball creado")

# ---------------------------------------------------------------------------
# 3. Dim_Calendar: calendario CONTINUO que cubre telemetría + eventos
# ---------------------------------------------------------------------------
fecha_min = min(failures["event_ts"].min(), tel_ts_all.min())[:10]
fecha_max = max(failures["event_ts"].max(), tel_ts_all.max())[:10]
rango = pd.date_range(fecha_min, fecha_max, freq="D")

cal = pd.DataFrame({"date_key": rango.strftime("%Y-%m-%d")})
cal["year"] = rango.year
cal["quarter"] = rango.quarter
cal["month"] = rango.month
cal["month_name"] = rango.month_name()
cal["year_month"] = rango.strftime("%Y-%m")
cal["day"] = rango.day
cal["day_of_week"] = pd.Series(rango.day_name()).map(DIAS_ES).values
cal["dow_number"] = rango.dayofweek + 1            # 1=Lunes ... 7=Domingo
cal["week_of_year"] = rango.isocalendar().week.astype(int).values
cal["is_weekend"] = (rango.dayofweek >= 5).astype(int)
cal.to_sql("Dim_Calendar", conn, if_exists="append", index=False)
cal_map = pd.read_sql("SELECT calendar_sk, date_key FROM Dim_Calendar", conn) \
            .set_index("date_key")["calendar_sk"]

# ---------------------------------------------------------------------------
# 4. Dim_Machine
# ---------------------------------------------------------------------------
dim_machine = machines.rename(columns={"machineID": "machine_id", "age": "age_years"}).copy()
dim_machine["age_band"] = pd.cut(
    dim_machine["age_years"], bins=[-1, 5, 10, 15, 200],
    labels=["0-5", "6-10", "11-15", "16-20"]).astype(str)
dim_machine = dim_machine[["machine_sk", "machine_id", "model", "age_years", "age_band"]]
dim_machine.to_sql("Dim_Machine", conn, if_exists="append", index=False)

# machine_id -> machine_sk (para KPIs, que sólo traen machineID)
mid_to_sk = dim_machine.set_index("machine_id")["machine_sk"]

# ---------------------------------------------------------------------------
# 5. Dim_Event: catálogo type + code
# ---------------------------------------------------------------------------
tipos = failures[["event_type", "comp_or_failure"]].drop_duplicates() \
            .rename(columns={"comp_or_failure": "event_code"}) \
            .sort_values(["event_type", "event_code"]).reset_index(drop=True)

CATEGORIA = {"error": "Error no catastrófico", "failure": "Falla de componente",
             "maintenance": "Mantenimiento de componente"}
DOWNTIME = {"error": 0.0, "failure": FAILURE_DOWNTIME_HOURS,
            "maintenance": MAINT_DOWNTIME_HOURS}

tipos["component"] = np.where(tipos["event_type"] == "error", None, tipos["event_code"])
tipos["event_category"] = tipos["event_type"].map(CATEGORIA)
tipos["is_failure"] = (tipos["event_type"] == "failure").astype(int)
tipos["is_maintenance"] = (tipos["event_type"] == "maintenance").astype(int)
tipos["is_error"] = (tipos["event_type"] == "error").astype(int)
tipos["std_downtime_hrs"] = tipos["event_type"].map(DOWNTIME)
tipos.to_sql("Dim_Event", conn, if_exists="append", index=False)
conn.commit()

ev_map = pd.read_sql("SELECT event_sk, event_type, event_code FROM Dim_Event", conn)
print(f"[3/7] Dimensiones pobladas: {len(cal)} fechas, {len(dim_machine)} máquinas, "
      f"{len(ev_map)} tipos de evento")

# ---------------------------------------------------------------------------
# 6. Fact_SystemFailures
# ---------------------------------------------------------------------------
f = failures.rename(columns={"comp_or_failure": "event_code"})
f = f.merge(ev_map, on=["event_type", "event_code"], how="left")
f["calendar_sk"] = f["event_ts"].str[:10].map(cal_map)
f["event_hour"] = f["event_ts"].str[11:13].astype(int)
f["downtime_hrs"] = f["event_type"].map(DOWNTIME)

# El machine_sk del CSV debe coincidir con el de Dim_Machine
sk_check = f["machineID"].map(mid_to_sk)
if not (sk_check == f["machine_sk"]).all():
    fail("machine_sk de Fact_SystemFailures no coincide con Dim_Machine")

fact_fail = f[["fact_event_id", "machine_sk", "calendar_sk", "event_sk",
               "event_ts", "event_hour", "downtime_hrs"]]
if fact_fail[["calendar_sk", "event_sk"]].isna().any().any():
    fail("Hay eventos sin calendar_sk o event_sk (mapeo de llaves roto)")
fact_fail.to_sql("Fact_SystemFailures", conn, if_exists="append", index=False)
conn.commit()
print(f"[4/7] Fact_SystemFailures cargada: {len(fact_fail)} filas")

# ---------------------------------------------------------------------------
# 7. Fact_TelemetryEvents (carga por lotes: 876.100 filas x 42 columnas)
# ---------------------------------------------------------------------------
total_tel = 0
for chunk in pd.read_csv(CSV_TELEMETRY, chunksize=CHUNK_SIZE):
    chunk["event_ts"] = to_ts(chunk["datetime"])
    chunk["calendar_sk"] = chunk["event_ts"].str[:10].map(cal_map)
    chunk["event_hour"] = chunk["event_ts"].str[11:13].astype(int)

    if not (chunk["machineID"].map(mid_to_sk) == chunk["machine_sk"]).all():
        fail("machine_sk de Fact_TelemetryEvents no coincide con Dim_Machine")
    if chunk["calendar_sk"].isna().any():
        fail("Telemetría con fecha fuera de Dim_Calendar")

    chunk = chunk.drop(columns=["datetime", "machineID"])
    # Los NaN de lag_1h / lag_3h (primeras horas de cada máquina) pasan a NULL
    chunk.to_sql("Fact_TelemetryEvents", conn, if_exists="append", index=False)
    total_tel += len(chunk)
    print(f"      ... telemetría: {total_tel:>9,} filas cargadas", end="\r")
conn.commit()
print(f"\n[5/7] Fact_TelemetryEvents cargada: {total_tel:,} filas")

# ---------------------------------------------------------------------------
# 8. Fact_ReliabilityKPI
# ---------------------------------------------------------------------------
k = kpi.copy()
k["machine_sk"] = k["machineID"].map(mid_to_sk)
if k["machine_sk"].isna().any():
    fail("Kpi_Reliability_by_Machine contiene machineID inexistentes en Dim_Machine")

# Consistencia model / age entre el KPI y la dimensión
chk = k.merge(dim_machine, on="machine_sk", suffixes=("", "_dim"))
if not ((chk["model"] == chk["model_dim"]) & (chk["age"] == chk["age_years"])).all():
    print("[!] Advertencia: model/age del KPI difieren de Dim_Machine "
          "(se usa Dim_Machine como fuente de verdad)")

k = k.rename(columns={"MTBF_hours": "mtbf_hours", "MTTR_hours": "mttr_hours"})
k["total_downtime_hrs"] = (k["n_failures"] * FAILURE_DOWNTIME_HOURS
                           + k["n_maint_events"] * MAINT_DOWNTIME_HOURS)
k["observed_hours"] = np.nan  # se completa abajo con el conteo real de telemetría
k = k[["machine_sk", "n_failures", "n_maint_events", "mtbf_hours", "mttr_hours",
       "pct_uptime", "observed_hours", "total_downtime_hrs"]]
k.to_sql("Fact_ReliabilityKPI", conn, if_exists="append", index=False)

# T observado = horas de telemetría de la máquina (rejilla de 1 h, extremos incluidos)
conn.execute("""
    UPDATE Fact_ReliabilityKPI
    SET observed_hours = (SELECT COUNT(*) FROM Fact_TelemetryEvents t
                          WHERE t.machine_sk = Fact_ReliabilityKPI.machine_sk)
""")
conn.commit()
print(f"[6/7] Fact_ReliabilityKPI cargada: {len(k)} filas")

# ---------------------------------------------------------------------------
# 9. Verificación de integridad referencial
# ---------------------------------------------------------------------------
cur = conn.cursor()
print("\n--- VERIFICACIÓN DE INGESTA KIMBALL ---")
for t in ["Dim_Calendar", "Dim_Machine", "Dim_Event",
          "Fact_TelemetryEvents", "Fact_SystemFailures", "Fact_ReliabilityKPI"]:
    cur.execute(f"SELECT COUNT(*) FROM {t};")
    print(f"{t:<22}: {cur.fetchone()[0]:>9,} filas")

cur.execute("PRAGMA foreign_key_check;")
viol = cur.fetchall()
print(f"Violaciones de FK      : {len(viol)} (debe ser 0)")

cur.execute("""
    SELECT m.model, COUNT(*) AS n_maquinas,
           ROUND(AVG(k.mtbf_hours), 1) AS mtbf_prom,
           ROUND(AVG(k.pct_uptime), 2) AS uptime_prom
    FROM Fact_ReliabilityKPI k JOIN Dim_Machine m ON k.machine_sk = m.machine_sk
    GROUP BY m.model ORDER BY m.model;
""")
print("\nMuestra de cruce relacional (KPIs por modelo):")
for row in cur.fetchall():
    print(" ", row)

conn.close()
print(f"\n[7/7] Fase 3 completada. Base generada: {DB_FILE}")
