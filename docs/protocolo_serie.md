# Protocolo serie entre el PIC y la GUI

Configuración: **9600 bps, 8 bits, sin paridad, 1 bit de stop (8N1)**.

Todas las tramas del PIC son texto y terminan en `\r\n`. Los valores numéricos van siempre con tres cifras.

## PIC → PC

| Trama | Cuándo | Significado |
| --- | --- | --- |
| `T=025` | Cada 500 ms | Temperatura del LM35 (cuentas del ADC ≈ °C) |
| `S=0` | Al encender | En espera |
| `S=1,15` | Al iniciar y cada segundo de la medición | Midiendo; segundos que faltan |
| `S=2` | Al terminar la medición | Resultado listo |
| `B=072` | Al terminar la medición | Frecuencia cardíaca en BPM (`B=000` si no hubo latidos) |
| `A=1` / `A=0` | Al cambiar | Alarma térmica activada / desactivada |
| `P=128` | 50 veces por segundo, solo en modo depuración | Muestra cruda del sensor de pulso (cuentas del ADC) |

## PC → PIC

Un carácter por tecla:

| Carácter | Acción |
| --- | --- |
| `1` | Mostrar la temperatura en el display |
| `2` | Mostrar la frecuencia cardíaca en el display |
| `A` | Iniciar una medición de pulso de 15 s |
| `D` | Activar o desactivar el modo depuración (tramas `P=`) |

## Conversión de cuentas

Con Vref+ = 2,50 V y 8 bits, cada cuenta del ADC vale 9,77 mV.

- Temperatura: °C ≈ cuentas × 0,977.
- Señal de pulso en el pin: V = cuentas × 0,00977 (antes del divisor, el doble).
