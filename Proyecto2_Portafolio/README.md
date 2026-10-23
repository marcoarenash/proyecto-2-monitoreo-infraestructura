# 📊 Monitoreo de Eventos de Infraestructura, Confiabilidad & Salud de Sistemas

> **Portafolio Data Analyst / Data Engineer** | Mantenimiento predictivo de flota industrial (Azure PdM): de 876 mil registros de telemetría a un Dashboard de Control Táctico con semáforos de riesgo (RAG).

![Python](https://img.shields.io/badge/Python-Pandas%20%7C%20NumPy-3776AB?logo=python&logoColor=white)
![SQL](https://img.shields.io/badge/SQL-Window%20Functions-336791)
![Power BI](https://img.shields.io/badge/Power%20BI-Dashboard%20T%C3%A1ctico-F2C811?logo=powerbi&logoColor=black)
![Dominio](https://img.shields.io/badge/Dominio-Ingenier%C3%ADa%20de%20Confiabilidad-2E7D32)

---

## 🚀 1. Resumen Ejecutivo

En operaciones de infraestructura crítica (plantas, redes, flotas de equipos), **cada hora de indisponibilidad no planificada impacta directamente la continuidad del negocio**. Este proyecto construye un pipeline analítico de extremo a extremo para responder tres preguntas gerenciales:

1. **¿Qué tan disponible está mi flota?** → Disponibilidad (% Uptime)
2. **¿Con qué frecuencia falla y qué tan rápido se repara?** → MTBF y MTTR
3. **¿Qué equipos y modelos requieren intervención prioritaria, y qué señales lo anticipan?** → Anomalías de telemetría y semáforo de riesgo

**Dataset:** Azure Predictive Maintenance (PdM) — telemetría horaria de sensores (`volt`, `rotate`, `pressure`, `vibration`), registros de errores, mantenimientos y fallas de **100 máquinas** pertenecientes a 4 modelos (`model1`–`model4`).

### KPIs globales de la flota
* **Disponibilidad promedio:** **95,24 %** (zona de advertencia, cercana al umbral mínimo de 95 %).
* **MTBF promedio:** **≈ 1.540 hrs** (Tiempo Medio Entre Fallas).
* **MTTR promedio:** **7,10 hrs** (Tiempo Medio de Reparación).
* **Máquinas en riesgo:** **100** (el parque completo presenta alertas o picos anómalos).

---
## 🗂️ 2. Estructura del Repositorio

El repositorio se encuentra organizado bajo un estándar de ingeniería de datos y analítica reproducible:

* **data/**
  * `README.md` — Diccionario de datos, procedencia y enlace para descarga del dataset masivo de telemetría (+200 MB).
* **docs/**
  * `reporte_ejecutivo_proyecto2.pdf` — Informe gerencial formal en PDF de 3 páginas orientado a Dirección y Operaciones Técnicas.
* **notebooks/**
  * `Proyecto2_DAP_Analisis.ipynb` — Jupyter Notebook con ETL vectorizado, resampleo 1h, imputación, IQR/Z-Score y Feature Engineering.
* **pbix/**
  * `README.md` — Enlace de acceso externo al archivo .pbix completo y pesado (+350 MB) alojado en Google Drive.
* **sql/**
  * `01_modelo_dimensional.sql` — Scripts DDL de creación del Esquema Estrella Kimball (`Fact_TelemetryEvents`, `Dim_Machine`).
  * `02_window_functions.sql` — Consultas analíticas con funciones de ventana (`LAG`, `LEAD`, `AVG() OVER`).
  * `03_kpis_confiabilidad.sql` — Consultas para el cálculo relacional de MTBF, MTTR y Disponibilidad (% Uptime).
  * `04_validacion_kimball.ipynb` — Validación e inspección del modelo dimensional.


```python

```
