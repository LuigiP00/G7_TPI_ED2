# G7_TPI_ED2 — Pulsómetro digital con alarma térmica

Trabajo Práctico Integrador de **Electrónica Digital 2** (FCEFyN – UNC), Grupo 7.

Sistema basado en el **PIC16F887** (cristal de 4 MHz, Assembler MPASM) que mide la frecuencia cardíaca con un sensor óptico de pulso y la temperatura con un LM35. Muestra los valores en un display de 7 segmentos de 4 dígitos, los envía a una GUI en la PC por la EUSART y activa una alarma (buzzer y LED rojo) cuando la temperatura supera los 40 °C.

**Integrantes:** Echenique, Matías · Marquez, Lionel · Pandolfi, Luigi Nicola · Rodríguez, Octavio
**Profesor:** Ing. Emiliano Migliore · **Comisión:** 4.1

## Estructura del repositorio

| Carpeta | Contenido |
| --- | --- |
| `anteproyecto/` | Anteproyecto entregado (`G7_AP_TPI_ED2`) y diagramas de bloques en draw.io |
| `informe/` | Borrador del informe final |
| `hardware/kicad/` | Esquemático y PCB en KiCad (`G7_Placa_TPI.kicad_pro`) |
| `hardware/datasheets/` | Hojas de datos de los componentes |
| `firmware/` | Código Assembler del SEP (`G7_TPI_ED2.asm`, v4.0) |
| `firmware/pruebas/` | Programas de prueba de la placa y versiones anteriores |
| `gui/` | Interfaz gráfica web para la PC (`index.html`, Web Serial) |
| `docs/` | Protocolo serie y diagrama de bloques del SEP para el informe (`docs/diagramas/`) |

## Firmware: cómo compilar y cargar

1. En MPLAB X: *File → New Project → Standalone Project*, dispositivo **PIC16F887**, ensamblador **mpasm**.
2. Agregar `firmware/G7_TPI_ED2.asm` al proyecto y compilar (*Build*).
3. Cargar el `.hex` generado con **AN1310** a través del adaptador USB–UART (el PIC ya tiene el bootloader).

Los `.asm` están codificados en **Windows-1252**, igual que la plantilla de la cátedra, para que los acentos se vean bien en MPLAB X.

## Asignación de pines (placa actual)

| Pin | Señal |
| --- | --- |
| RA0 / AN0 | LM35 |
| RA1 / AN1 | Sensor de pulso HW-827 (divisor 22 kΩ / 22 kΩ) |
| RA3 / VREF+ | Referencia del ADC: 2,50 V |
| RB6 | LED verde (temperatura normal) |
| RB7 | LED rojo (alarma térmica) |
| RC0–RC3 | Dígitos del display (PNP BC557, ánodo común) |
| RC4 | Buzzer (vía BC337) |
| RD0–RD6 | Segmentos a–g |
| RC6 / RC7 | TX / RX hacia el CP2102 |

La medición de pulso se inicia desde la PC (tecla `I` en la GUI); la placa no tiene botón de inicio.

## Protocolo serie

9600 bps, 8N1. Detalle en [`docs/protocolo_serie.md`](docs/protocolo_serie.md).

## Estado

| Parte | Estado |
| --- | --- |
| Anteproyecto | Aprobado (diagrama de bloques rehecho con el formato de la cátedra en `docs/diagramas/`) |
| Placa | Fabricada y probada |
| Firmware v4.0: temperatura con alarma, conteo de pulso de 15 s, display, EUSART | Funcionando en la placa |
| GUI web | Funcionando |
| Calibración del pulso contra una referencia (oxímetro o conteo manual) | Pendiente |
| Informe final | En redacción (`informe/`) |
