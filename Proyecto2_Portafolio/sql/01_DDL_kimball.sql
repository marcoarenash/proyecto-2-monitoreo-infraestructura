-- =========================================================================
-- PROYECTO 2 DAP: Monitoreo de Eventos de Infraestructura, Confiabilidad
--                 & Salud de Sistemas (Azure PdM)
-- FASE 3 - DDL: Modelo Dimensional Kimball (Esquema Estrella / Constelación)
-- Origen : Dim_Machine.csv, Fact_TelemetryEvents.csv (876.100 filas),
--          Fact_SystemFailures.csv (7.966 filas), Kpi_Reliability_by_Machine.csv
-- Motor  : SQLite >= 3.25 (necesario para Window Functions)
--          Compatible con PostgreSQL/DuckDB cambiando AUTOINCREMENT por IDENTITY
--
-- Diseño: constelación de hechos (3 tablas de hechos que comparten dimensiones
--         conformadas Dim_Machine y Dim_Calendar):
--
--   Dim_Calendar --+--> Fact_TelemetryEvents  (grano: 1 máquina x 1 hora)
--   Dim_Machine  --+--> Fact_SystemFailures   (grano: 1 evento discreto)
--   Dim_Event    ----> Fact_SystemFailures
--   Dim_Machine  ----> Fact_ReliabilityKPI    (grano: 1 máquina, snapshot total)
-- =========================================================================

PRAGMA foreign_keys = ON;

DROP TABLE IF EXISTS Fact_ReliabilityKPI;
DROP TABLE IF EXISTS Fact_SystemFailures;
DROP TABLE IF EXISTS Fact_TelemetryEvents;
DROP TABLE IF EXISTS Dim_Event;
DROP TABLE IF EXISTS Dim_Machine;
DROP TABLE IF EXISTS Dim_Calendar;

-- -------------------------------------------------------------------------
-- 1. Dim_Calendar
-- Calendario CONTINUO (todas las fechas del rango, con o sin eventos).
-- Requisito para promedios móviles y time intelligence en Power BI.
-- La hora del día NO va aquí: vive en las tablas de hechos (event_hour),
-- así la dimensión se mantiene pequeña (grano diario).
-- -------------------------------------------------------------------------
CREATE TABLE Dim_Calendar (
    calendar_sk   INTEGER PRIMARY KEY AUTOINCREMENT,
    date_key      TEXT    UNIQUE NOT NULL,   -- 'YYYY-MM-DD'
    year          INTEGER NOT NULL,
    quarter       INTEGER NOT NULL,
    month         INTEGER NOT NULL,
    month_name    TEXT,
    year_month    TEXT,                      -- 'YYYY-MM' (eje ordenable en Power BI)
    day           INTEGER NOT NULL,
    day_of_week   TEXT,
    dow_number    INTEGER,                   -- 1=Lunes ... 7=Domingo
    week_of_year  INTEGER,
    is_weekend    INTEGER NOT NULL           -- 0 / 1
);

-- -------------------------------------------------------------------------
-- 2. Dim_Machine
-- 100 equipos, 4 modelos. machine_sk viene del pipeline de Python (Bloque 6
-- del notebook de análisis) y coincide con machine_id.
-- -------------------------------------------------------------------------
CREATE TABLE Dim_Machine (
    machine_sk   INTEGER PRIMARY KEY,
    machine_id   INTEGER UNIQUE NOT NULL,    -- clave natural (machineID)
    model        TEXT    NOT NULL,           -- model1 ... model4
    age_years    INTEGER NOT NULL,
    age_band     TEXT                        -- '0-5' / '6-10' / '11-15' / '16-20'
);

-- -------------------------------------------------------------------------
-- 3. Dim_Event
-- Catálogo de tipos de evento discreto (13 filas):
--   error1..error5   -> errores no catastróficos
--   comp1..comp4     -> mantenimiento (reemplazo) por componente
--   comp1..comp4     -> falla por componente
-- std_downtime_hrs documenta el SLA de planta usado para MTTR y % Uptime
-- (mantenimiento 6 h, falla 12 h, error 0 h). Es un supuesto configurable.
-- -------------------------------------------------------------------------
CREATE TABLE Dim_Event (
    event_sk          INTEGER PRIMARY KEY AUTOINCREMENT,
    event_type        TEXT NOT NULL,         -- error / failure / maintenance
    event_code        TEXT NOT NULL,         -- error1..5 / comp1..4
    component         TEXT,                  -- comp1..comp4 (NULL en errores)
    event_category    TEXT NOT NULL,         -- etiqueta legible
    is_failure        INTEGER NOT NULL,      -- 0 / 1  (failure_occurred)
    is_maintenance    INTEGER NOT NULL,
    is_error          INTEGER NOT NULL,
    std_downtime_hrs  REAL    NOT NULL,
    UNIQUE (event_type, event_code)
);

-- -------------------------------------------------------------------------
-- 4. Fact_TelemetryEvents
-- Grano: 1 fila = 1 máquina x 1 hora (serie regularizada a 1 h).
-- Conserva el valor físico original del sensor (sin eliminar ni imputar
-- outliers): los picos se etiquetan con flags IQR / Z-Score.
-- Los lags son NULL en las primeras 1h / 3h de cada máquina (esperado).
-- -------------------------------------------------------------------------
CREATE TABLE Fact_TelemetryEvents (
    fact_telemetry_id        INTEGER PRIMARY KEY,
    machine_sk               INTEGER NOT NULL,
    calendar_sk              INTEGER NOT NULL,
    event_ts                 TEXT    NOT NULL,    -- 'YYYY-MM-DD HH:MM:SS'
    event_hour               INTEGER NOT NULL,    -- 0-23

    -- Telemetría continua
    volt                     REAL,
    rotate                   REAL,
    pressure                 REAL,
    vibration                REAL,

    -- Anomalías por IQR
    is_volt_anomaly_iqr      INTEGER,
    is_rotate_anomaly_iqr    INTEGER,
    is_pressure_anomaly_iqr  INTEGER,
    is_vibration_anomaly_iqr INTEGER,

    -- Z-Score y anomalías por Z
    zscore_volt              REAL,
    is_volt_anomaly_z        INTEGER,
    zscore_rotate            REAL,
    is_rotate_anomaly_z      INTEGER,
    zscore_pressure          REAL,
    is_pressure_anomaly_z    INTEGER,
    zscore_vibration         REAL,
    is_vibration_anomaly_z   INTEGER,

    -- Flags consolidadas
    is_sensorial_anomaly     INTEGER,             -- IQR en cualquier sensor
    is_sensorial_anomaly_z   INTEGER,             -- Z en cualquier sensor

    -- Rolling averages (3h / 6h / 24h)
    volt_roll_3h             REAL, rotate_roll_3h      REAL,
    pressure_roll_3h         REAL, vibration_roll_3h   REAL,
    volt_roll_6h             REAL, rotate_roll_6h      REAL,
    pressure_roll_6h         REAL, vibration_roll_6h   REAL,
    volt_roll_24h            REAL, rotate_roll_24h     REAL,
    pressure_roll_24h        REAL, vibration_roll_24h  REAL,

    -- Lags (1h / 3h)
    volt_lag_1h              REAL, rotate_lag_1h       REAL,
    pressure_lag_1h          REAL, vibration_lag_1h    REAL,
    volt_lag_3h              REAL, rotate_lag_3h       REAL,
    pressure_lag_3h          REAL, vibration_lag_3h    REAL,

    UNIQUE (machine_sk, event_ts),
    FOREIGN KEY (machine_sk)  REFERENCES Dim_Machine(machine_sk),
    FOREIGN KEY (calendar_sk) REFERENCES Dim_Calendar(calendar_sk)
);

-- -------------------------------------------------------------------------
-- 5. Fact_SystemFailures
-- Grano: 1 fila = 1 evento discreto (falla, mantenimiento o error).
-- Los eventos simultáneos (mismo machine_sk + event_ts) son LEGÍTIMOS y se
-- conservan como filas independientes: por eso la PK es fact_event_id y no
-- existe UNIQUE sobre (machine_sk, event_ts).
-- -------------------------------------------------------------------------
CREATE TABLE Fact_SystemFailures (
    fact_event_id   INTEGER PRIMARY KEY,
    machine_sk      INTEGER NOT NULL,
    calendar_sk     INTEGER NOT NULL,
    event_sk        INTEGER NOT NULL,
    event_ts        TEXT    NOT NULL,
    event_hour      INTEGER NOT NULL,
    downtime_hrs    REAL    NOT NULL,             -- 12 falla / 6 mant. / 0 error
    FOREIGN KEY (machine_sk)  REFERENCES Dim_Machine(machine_sk),
    FOREIGN KEY (calendar_sk) REFERENCES Dim_Calendar(calendar_sk),
    FOREIGN KEY (event_sk)    REFERENCES Dim_Event(event_sk)
);

-- -------------------------------------------------------------------------
-- 6. Fact_ReliabilityKPI
-- Grano: 1 fila = 1 máquina (snapshot sobre toda la ventana observada).
-- Valores calculados en el notebook de Python y cargados tal cual; el DML
-- los reconcilia contra un recálculo en SQL a partir de los hechos.
--   observed_hours      = horas de telemetría de la máquina (T observado)
--   total_downtime_hrs  = n_failures x 12 + n_maint_events x 6
-- -------------------------------------------------------------------------
CREATE TABLE Fact_ReliabilityKPI (
    machine_sk          INTEGER PRIMARY KEY,
    n_failures          INTEGER NOT NULL,
    n_maint_events      INTEGER NOT NULL,
    mtbf_hours          REAL,
    mttr_hours          REAL,
    pct_uptime          REAL,
    observed_hours      REAL,
    total_downtime_hrs  REAL,
    FOREIGN KEY (machine_sk) REFERENCES Dim_Machine(machine_sk)
);

-- -------------------------------------------------------------------------
-- Índices de apoyo (los de ventana por máquina+tiempo son los críticos)
-- -------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_tel_calendar     ON Fact_TelemetryEvents(calendar_sk);
CREATE INDEX IF NOT EXISTS idx_tel_ts           ON Fact_TelemetryEvents(event_ts);
CREATE INDEX IF NOT EXISTS idx_tel_anom         ON Fact_TelemetryEvents(is_sensorial_anomaly, machine_sk);
CREATE INDEX IF NOT EXISTS idx_fail_machine_ts  ON Fact_SystemFailures(machine_sk, event_ts);
CREATE INDEX IF NOT EXISTS idx_fail_calendar    ON Fact_SystemFailures(calendar_sk);
CREATE INDEX IF NOT EXISTS idx_fail_event       ON Fact_SystemFailures(event_sk);
