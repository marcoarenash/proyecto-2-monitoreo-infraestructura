-- =========================================================================
-- PROYECTO 2 DAP - CONSULTAS ANALÍTICAS SOBRE EL MODELO ESTRELLA (KIMBALL)
-- KPIs: MTBF, MTTR, % Uptime | Semáforo RAG | Degradación pre-falla
--       Alertas tempranas | Pareto de fallas | Media móvil 7 días
-- Window Functions usadas: LAG, LEAD, AVG() OVER (PARTITION BY ...),
--       SUM() OVER (ORDER BY ...), PERCENT_RANK, NTILE, ROW_NUMBER
-- Notas de diseño:
--   * "Ahora" del dataset = MAX(event_ts) de la telemetría (datos históricos).
--   * Supuestos de downtime (6 h mantenimiento / 12 h falla) viven en Dim_Event.
--   * Cada consulta se identifica con el encabezado "-- Consulta N:" (lo usa
--     el notebook de validación). No usar punto y coma dentro de comentarios.
-- =========================================================================

-- -------------------------------------------------------------------------
-- Consulta 0: Tarjetas de la Vista Ejecutiva (KPIs globales de la flota)
-- -------------------------------------------------------------------------
SELECT
    (SELECT COUNT(*) FROM Dim_Machine)                              AS maquinas,
    SUM(k.n_failures)                                               AS fallas_totales,
    SUM(k.n_maint_events)                                           AS mantenimientos_totales,
    ROUND(AVG(k.mtbf_hours), 1)                                     AS mtbf_prom_hrs,
    ROUND(AVG(k.mttr_hours), 2)                                     AS mttr_prom_hrs,
    ROUND(AVG(k.pct_uptime), 2)                                     AS uptime_prom_pct,
    ROUND(SUM(k.observed_hours - k.total_downtime_hrs)
          * 100.0 / SUM(k.observed_hours), 2)                       AS uptime_flota_ponderado_pct,
    (SELECT COUNT(*) FROM Fact_SystemFailures f
       JOIN Dim_Event e ON f.event_sk = e.event_sk
      WHERE e.is_error = 1)                                         AS errores_totales,
    (SELECT ROUND(AVG(is_sensorial_anomaly) * 100.0, 2)
       FROM Fact_TelemetryEvents)                                   AS pct_lecturas_anomalas_iqr
FROM Fact_ReliabilityKPI k;

-- -------------------------------------------------------------------------
-- Consulta 1: Confiabilidad por modelo y banda de edad
-- MTBF del grupo = horas operativas totales / fallas totales (no promedio de
-- promedios). MTTR = downtime total / intervenciones totales.
-- -------------------------------------------------------------------------
SELECT
    m.model,
    m.age_band,
    COUNT(*)                                                         AS maquinas,
    SUM(k.n_failures)                                                AS fallas,
    ROUND(SUM(k.observed_hours - k.total_downtime_hrs)
          / NULLIF(SUM(k.n_failures), 0), 1)                         AS mtbf_hrs,
    ROUND(SUM(k.total_downtime_hrs)
          / NULLIF(SUM(k.n_failures + k.n_maint_events), 0), 2)      AS mttr_hrs,
    ROUND(SUM(k.observed_hours - k.total_downtime_hrs)
          * 100.0 / SUM(k.observed_hours), 2)                        AS uptime_pct,
    ROUND(SUM(k.n_failures) * 100.0
          / SUM(SUM(k.n_failures)) OVER (PARTITION BY m.model), 2)   AS pct_fallas_del_modelo
FROM Fact_ReliabilityKPI k
JOIN Dim_Machine m ON k.machine_sk = m.machine_sk
GROUP BY m.model, m.age_band
ORDER BY m.model, m.age_band;

-- -------------------------------------------------------------------------
-- Consulta 2: SEMÁFORO DE RIESGO (RAG) por máquina
-- Score = 40% percentil de fallas + 30% (1 - percentil de uptime)
--       + 30% percentil de tasa de anomalías en las últimas 72 h.
-- Verde < 0.40 / Ámbar 0.40-0.65 / Rojo >= 0.65. Ajustable.
-- -------------------------------------------------------------------------
WITH corte AS (
    SELECT MAX(event_ts) AS ahora FROM Fact_TelemetryEvents
),
anom_recientes AS (
    SELECT t.machine_sk,
           AVG(t.is_sensorial_anomaly) AS tasa_anom_72h
    FROM Fact_TelemetryEvents t, corte c
    WHERE t.event_ts > datetime(c.ahora, '-72 hours')
    GROUP BY t.machine_sk
),
scored AS (
    SELECT
        m.machine_id, m.model, m.age_years,
        k.n_failures, k.mtbf_hours, k.mttr_hours, k.pct_uptime,
        COALESCE(a.tasa_anom_72h, 0)                                  AS tasa_anom_72h,
        0.40 * PERCENT_RANK() OVER (ORDER BY k.n_failures)
      + 0.30 * (1 - PERCENT_RANK() OVER (ORDER BY k.pct_uptime))
      + 0.30 * PERCENT_RANK() OVER (ORDER BY COALESCE(a.tasa_anom_72h, 0))
                                                                      AS risk_score
    FROM Fact_ReliabilityKPI k
    JOIN Dim_Machine m          ON k.machine_sk = m.machine_sk
    LEFT JOIN anom_recientes a  ON k.machine_sk = a.machine_sk
)
SELECT
    machine_id, model, age_years, n_failures,
    ROUND(mtbf_hours, 1)       AS mtbf_hrs,
    ROUND(mttr_hours, 2)       AS mttr_hrs,
    ROUND(pct_uptime, 2)       AS pct_uptime,
    ROUND(tasa_anom_72h * 100, 2) AS pct_anom_72h,
    ROUND(risk_score, 3)       AS risk_score,
    CASE WHEN risk_score >= 0.65 THEN 'ROJO'
         WHEN risk_score >= 0.40 THEN 'AMBAR'
         ELSE 'VERDE' END      AS rag_status,
    ROW_NUMBER() OVER (ORDER BY risk_score DESC) AS ranking_riesgo
FROM scored
ORDER BY risk_score DESC;

-- -------------------------------------------------------------------------
-- Consulta 3: Tiempo entre fallas consecutivas con LAG / LEAD
-- Insumo del MTBF empírico: horas desde la falla previa y hasta la siguiente
-- por máquina, y la desviación contra el promedio de su propia máquina.
-- -------------------------------------------------------------------------
WITH fallas AS (
    SELECT f.machine_sk, f.event_ts, e.component
    FROM Fact_SystemFailures f
    JOIN Dim_Event e ON f.event_sk = e.event_sk
    WHERE e.is_failure = 1
),
ventana AS (
    SELECT
        machine_sk, event_ts, component,
        LAG(event_ts)  OVER (PARTITION BY machine_sk ORDER BY event_ts) AS falla_previa_ts,
        LEAD(event_ts) OVER (PARTITION BY machine_sk ORDER BY event_ts) AS falla_siguiente_ts,
        LAG(component) OVER (PARTITION BY machine_sk ORDER BY event_ts) AS componente_previo,
        ROW_NUMBER()   OVER (PARTITION BY machine_sk ORDER BY event_ts) AS nro_falla
    FROM fallas
),
con_horas AS (
    SELECT *,
        ROUND((julianday(event_ts) - julianday(falla_previa_ts)) * 24, 1)       AS hrs_desde_previa,
        ROUND((julianday(falla_siguiente_ts) - julianday(event_ts)) * 24, 1)    AS hrs_hasta_siguiente
    FROM ventana
)
SELECT
    m.machine_id, m.model, c.nro_falla, c.component, c.componente_previo,
    c.event_ts, c.falla_previa_ts, c.hrs_desde_previa, c.hrs_hasta_siguiente,
    ROUND(AVG(c.hrs_desde_previa) OVER (PARTITION BY c.machine_sk), 1)          AS mtbf_empirico_maquina,
    ROUND(c.hrs_desde_previa
          - AVG(c.hrs_desde_previa) OVER (PARTITION BY c.machine_sk), 1)        AS desvio_vs_promedio
FROM con_horas c
JOIN Dim_Machine m ON c.machine_sk = m.machine_sk
ORDER BY m.machine_id, c.event_ts;

-- -------------------------------------------------------------------------
-- Consulta 4: DEGRADACIÓN PRE-FALLA (insumo del gráfico de línea de tiempo)
-- Promedio de z-scores y tasa de anomalías por cubeta de horas antes de la
-- falla (0-3 h, 3-6 h, 6-12 h, 12-24 h), por componente que falló.
-- Un z-score creciente hacia la falla evidencia degradación.
-- -------------------------------------------------------------------------
WITH fallas AS (
    SELECT f.fact_event_id, f.machine_sk, f.event_ts, e.component
    FROM Fact_SystemFailures f
    JOIN Dim_Event e ON f.event_sk = e.event_sk
    WHERE e.is_failure = 1
),
pre AS (
    SELECT
        fa.component,
        CAST((julianday(fa.event_ts) - julianday(t.event_ts)) * 24 AS INTEGER) AS hrs_antes,
        t.zscore_volt, t.zscore_rotate, t.zscore_pressure, t.zscore_vibration,
        t.is_sensorial_anomaly
    FROM fallas fa
    JOIN Fact_TelemetryEvents t
      ON t.machine_sk = fa.machine_sk
     AND t.event_ts >= datetime(fa.event_ts, '-24 hours')
     AND t.event_ts <= fa.event_ts
)
SELECT
    component,
    CASE WHEN hrs_antes < 3  THEN '1) 0-3 h antes'
         WHEN hrs_antes < 6  THEN '2) 3-6 h antes'
         WHEN hrs_antes < 12 THEN '3) 6-12 h antes'
         ELSE                     '4) 12-24 h antes' END   AS ventana_pre_falla,
    COUNT(*)                                               AS lecturas,
    ROUND(AVG(zscore_volt), 3)                             AS z_volt,
    ROUND(AVG(zscore_rotate), 3)                           AS z_rotate,
    ROUND(AVG(zscore_pressure), 3)                         AS z_pressure,
    ROUND(AVG(zscore_vibration), 3)                        AS z_vibration,
    ROUND(AVG(is_sensorial_anomaly) * 100.0, 2)            AS pct_anomalias
FROM pre
GROUP BY component, ventana_pre_falla
ORDER BY component, ventana_pre_falla;

-- -------------------------------------------------------------------------
-- Consulta 5: TARJETAS DE ALERTA TEMPRANA por superación de umbrales
-- Regla: alerta si en las últimas 24 h hay >= 3 lecturas con anomalía
-- sensorial (IQR), o si algún sensor promedió |z| > 2 en las últimas 6 h
-- (se usa el rolling de 6 h de la última lectura contra la media de la flota).
-- -------------------------------------------------------------------------
WITH corte AS (
    SELECT MAX(event_ts) AS ahora FROM Fact_TelemetryEvents
),
ult24 AS (
    SELECT t.machine_sk,
           SUM(t.is_sensorial_anomaly)    AS anomalias_24h,
           SUM(t.is_sensorial_anomaly_z)  AS anomalias_z_24h
    FROM Fact_TelemetryEvents t, corte c
    WHERE t.event_ts > datetime(c.ahora, '-24 hours')
    GROUP BY t.machine_sk
),
global_stats AS (
    SELECT AVG(vibration) AS mu_vib, AVG(vibration * vibration) - AVG(vibration) * AVG(vibration) AS var_vib,
           AVG(volt)      AS mu_volt, AVG(volt * volt) - AVG(volt) * AVG(volt)                     AS var_volt
    FROM Fact_TelemetryEvents
),
ultima AS (
    SELECT t.machine_sk, t.vibration_roll_6h, t.volt_roll_6h, t.event_ts
    FROM Fact_TelemetryEvents t, corte c
    WHERE t.event_ts = c.ahora
)
SELECT
    m.machine_id, m.model,
    u.event_ts                                                       AS ultima_lectura,
    a.anomalias_24h,
    a.anomalias_z_24h,
    ROUND((u.vibration_roll_6h - g.mu_vib) / SQRT(g.var_vib), 2)     AS z_vibracion_6h,
    ROUND((u.volt_roll_6h - g.mu_volt) / SQRT(g.var_volt), 2)        AS z_voltaje_6h,
    CASE
        WHEN a.anomalias_24h >= 3 THEN 'ALERTA: anomalías sostenidas 24 h'
        WHEN ABS((u.vibration_roll_6h - g.mu_vib) / SQRT(g.var_vib)) > 2
          OR ABS((u.volt_roll_6h - g.mu_volt) / SQRT(g.var_volt)) > 2
                                  THEN 'ALERTA: deriva en rolling 6 h'
        ELSE 'Normal'
    END                                                              AS estado_alerta
FROM ultima u
JOIN ult24 a         ON u.machine_sk = a.machine_sk
JOIN Dim_Machine m   ON u.machine_sk = m.machine_sk
CROSS JOIN global_stats g
ORDER BY a.anomalias_24h DESC, ABS((u.vibration_roll_6h - g.mu_vib) / SQRT(g.var_vib)) DESC;

-- -------------------------------------------------------------------------
-- Consulta 6: PARETO 80/20 de fallas por componente
-- -------------------------------------------------------------------------
WITH base AS (
    SELECT
        e.component,
        COUNT(*)                                   AS fallas,
        SUM(f.downtime_hrs)                        AS horas_downtime
    FROM Fact_SystemFailures f
    JOIN Dim_Event e ON f.event_sk = e.event_sk
    WHERE e.is_failure = 1
    GROUP BY e.component
),
acumulado AS (
    SELECT
        base.*,
        SUM(fallas) OVER (ORDER BY fallas DESC
                          ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS fallas_acum,
        SUM(fallas) OVER ()                                                 AS fallas_total
    FROM base
)
SELECT
    component, fallas, horas_downtime,
    ROUND(fallas * 100.0 / fallas_total, 2)                 AS pct_fallas,
    ROUND(fallas_acum * 100.0 / fallas_total, 2)            AS pct_acumulado,
    CASE WHEN (fallas_acum - fallas) * 100.0 / fallas_total < 80.0
         THEN 'POCOS VITALES' ELSE 'Muchos triviales' END   AS clase_pareto
FROM acumulado
ORDER BY fallas DESC;

-- -------------------------------------------------------------------------
-- Consulta 7: Horas desde el último mantenimiento del mismo componente
-- hasta cada falla (LAG por máquina + componente). Evalúa si el
-- mantenimiento preventivo está llegando antes de la falla.
-- -------------------------------------------------------------------------
WITH eventos AS (
    SELECT f.machine_sk, e.component, e.event_type, f.event_ts
    FROM Fact_SystemFailures f
    JOIN Dim_Event e ON f.event_sk = e.event_sk
    WHERE e.is_failure = 1 OR e.is_maintenance = 1
),
con_prev AS (
    SELECT
        machine_sk, component, event_type, event_ts,
        LAG(event_type) OVER (PARTITION BY machine_sk, component ORDER BY event_ts, event_type) AS tipo_previo,
        LAG(event_ts)   OVER (PARTITION BY machine_sk, component ORDER BY event_ts, event_type) AS ts_previo
    FROM eventos
)
SELECT
    component,
    COUNT(*)                                                                AS fallas_con_mant_previo,
    ROUND(AVG(julianday(event_ts) - julianday(ts_previo)), 1)               AS dias_prom_desde_mant,
    ROUND(MIN((julianday(event_ts) - julianday(ts_previo))), 1)             AS dias_min,
    ROUND(MAX((julianday(event_ts) - julianday(ts_previo))), 1)             AS dias_max
FROM con_prev
WHERE event_type = 'failure' AND tipo_previo = 'maintenance'
GROUP BY component
ORDER BY component;

-- -------------------------------------------------------------------------
-- Consulta 8: Serie diaria con PROMEDIO MÓVIL DE 7 DÍAS
-- Calendario continuo: los días sin eventos cuentan como 0.
-- -------------------------------------------------------------------------
WITH fallas_dia AS (
    SELECT f.calendar_sk, COUNT(*) AS fallas
    FROM Fact_SystemFailures f
    JOIN Dim_Event e ON f.event_sk = e.event_sk
    WHERE e.is_failure = 1
    GROUP BY f.calendar_sk
),
anom_dia AS (
    SELECT calendar_sk,
           SUM(is_sensorial_anomaly) AS lecturas_anomalas,
           AVG(vibration)            AS vibracion_prom
    FROM Fact_TelemetryEvents
    GROUP BY calendar_sk
),
serie AS (
    SELECT c.date_key,
           COALESCE(fd.fallas, 0)            AS fallas,
           COALESCE(ad.lecturas_anomalas, 0) AS lecturas_anomalas,
           ad.vibracion_prom
    FROM Dim_Calendar c
    LEFT JOIN fallas_dia fd ON fd.calendar_sk = c.calendar_sk
    LEFT JOIN anom_dia  ad ON ad.calendar_sk = c.calendar_sk
)
SELECT
    date_key, fallas, lecturas_anomalas,
    ROUND(vibracion_prom, 2)                                                       AS vibracion_prom,
    ROUND(AVG(fallas) OVER (ORDER BY date_key ROWS BETWEEN 6 PRECEDING AND CURRENT ROW), 2)
                                                                                   AS ma7_fallas,
    ROUND(AVG(lecturas_anomalas) OVER (ORDER BY date_key ROWS BETWEEN 6 PRECEDING AND CURRENT ROW), 1)
                                                                                   AS ma7_anomalias
FROM serie
ORDER BY date_key;

-- -------------------------------------------------------------------------
-- Consulta 9: HEATMAP de fallas por día de la semana x hora del día
-- -------------------------------------------------------------------------
SELECT
    c.dow_number, c.day_of_week, f.event_hour,
    COUNT(*)                         AS fallas,
    ROUND(SUM(f.downtime_hrs), 1)    AS horas_downtime
FROM Fact_SystemFailures f
JOIN Dim_Event e    ON f.event_sk = e.event_sk
JOIN Dim_Calendar c ON f.calendar_sk = c.calendar_sk
WHERE e.is_failure = 1
GROUP BY c.dow_number, c.day_of_week, f.event_hour
ORDER BY c.dow_number, f.event_hour;

-- -------------------------------------------------------------------------
-- Consulta 10: Reconciliación de KPIs (SQL recalculado vs Fact_ReliabilityKPI)
-- Recalcula n_failures, n_maint, MTBF, MTTR y %Uptime desde Fact_SystemFailures
-- y mide la diferencia contra los valores cargados desde Python.
-- Incluye cuántos mantenimientos caen ANTES de la ventana de telemetría
-- (esos eventos descuentan downtime en el KPI pero fuera del T observado).
-- -------------------------------------------------------------------------
WITH rec AS (
    SELECT
        f.machine_sk,
        SUM(e.is_failure)                                               AS n_fail,
        SUM(e.is_maintenance)                                           AS n_maint,
        SUM(CASE WHEN e.is_maintenance = 1 AND f.event_ts < v.ini
                 THEN 1 ELSE 0 END)                                     AS maint_previos_a_telemetria,
        SUM(f.downtime_hrs)                                             AS downtime
    FROM Fact_SystemFailures f
    JOIN Dim_Event e ON f.event_sk = e.event_sk
    CROSS JOIN (SELECT MIN(event_ts) AS ini FROM Fact_TelemetryEvents) v
    GROUP BY f.machine_sk
)
SELECT
    COUNT(*)                                                            AS maquinas_comparadas,
    SUM(CASE WHEN r.n_fail  <> k.n_failures     THEN 1 ELSE 0 END)      AS dif_n_failures,
    SUM(CASE WHEN r.n_maint <> k.n_maint_events THEN 1 ELSE 0 END)      AS dif_n_maint,
    ROUND(MAX(ABS(r.downtime - k.total_downtime_hrs)), 4)               AS max_dif_downtime_hrs,
    ROUND(MAX(ABS((k.observed_hours - r.downtime) * 100.0 / k.observed_hours
                  - k.pct_uptime)), 4)                                  AS max_dif_uptime_pct,
    ROUND(MAX(ABS(CASE WHEN r.n_fail > 0
                       THEN (k.observed_hours - r.downtime) / r.n_fail
                       ELSE k.observed_hours END - k.mtbf_hours)), 4)   AS max_dif_mtbf_hrs,
    ROUND(MAX(ABS(r.downtime / NULLIF(r.n_fail + r.n_maint, 0)
                  - k.mttr_hours)), 4)                                  AS max_dif_mttr_hrs,
    SUM(r.maint_previos_a_telemetria)                                   AS mant_previos_a_ventana
FROM rec r
JOIN Fact_ReliabilityKPI k ON r.machine_sk = k.machine_sk;

-- -------------------------------------------------------------------------
-- Consulta 11: Control de calidad de datos (auditoría del ETL)
-- -------------------------------------------------------------------------
SELECT
    (SELECT COUNT(*) FROM Fact_TelemetryEvents)                                   AS lecturas_totales,
    (SELECT COUNT(*) FROM (SELECT machine_sk FROM Fact_TelemetryEvents
                           GROUP BY machine_sk
                           HAVING COUNT(*) <> (SELECT MAX(n) FROM
                               (SELECT COUNT(*) AS n FROM Fact_TelemetryEvents GROUP BY machine_sk))))
                                                                                  AS maquinas_con_huecos_horarios,
    (SELECT COUNT(*) FROM Fact_TelemetryEvents WHERE volt_lag_1h IS NULL)         AS lags_1h_nulos_esperados,
    (SELECT COUNT(*) FROM Fact_TelemetryEvents WHERE volt_lag_3h IS NULL)         AS lags_3h_nulos_esperados,
    (SELECT COUNT(*) FROM (SELECT machine_sk, event_ts FROM Fact_SystemFailures
                           GROUP BY machine_sk, event_ts HAVING COUNT(*) > 1))    AS instantes_con_eventos_simultaneos,
    (SELECT COUNT(*) FROM Fact_ReliabilityKPI WHERE n_failures = 0)               AS maquinas_sin_fallas_control;
