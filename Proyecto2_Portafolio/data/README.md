# 📂 Dataset & Fuentes de Datos - Monitoreo de Infraestructura IoT

Este directorio contiene la especificación de los datos de telemetría y mantenimiento predictivo utilizados para el análisis de confiabilidad del **Proyecto 2**.

## 📊 Descripción de los Datasets
Debido al alto volumen de registros horarios de telemetría física (más de 876,100 registros correspondientes a 100 máquinas entre marzo de 2015 y enero de 2016), los archivos masivos se encuentran alojados en almacenamiento externo.

* **Dataset Crudo / Transaccional (Parcial / Muestra):** Incluido localmente para pruebas rápidas de ETL.
* **Dataset Completo de Alta Volumetría (+200 MB):** Contiene el historial completo de telemetría de los sensores físicos (`volt`, `rotate`, `pressure`, `vibration`), registros de errores (`errorID`), mantenimientos (`comp`) y fallas (`failure_occurred`).

🔗 **[Descarga el Dataset Completo de Alta Volumetría desde Google Drive](https://drive.google.com/drive/folders/1AI7H1pWFUJRtwyWiNogXj6-tIWUR39FD)**

## 📑 Diccionario de Datos Mínimo
* **`machineID`**: Identificador único de la máquina / equipo de la flota.
* **`datetime`**: Timestamp horario de la lectura de telemetría.
* **`volt`**: Métrica continua de voltaje operativo del componente.
* **`rotate`**: Velocidad de rotación o revoluciones por minuto (RPM).
* **`pressure`**: Presión registrada por el sensor.
* **`vibration`**: Nivel de vibración mecánica de la unidad.
* **`errorID`**: Códigos de error y advertencia emitidos por los controladores.
* **`failure_occurred`**: Indicador booleano (0/1) de fallo crítico que detiene la operación.


```python

```
