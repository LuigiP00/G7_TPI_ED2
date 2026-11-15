# Protocolo serie entre el PIC y la GUI

Configuración: **9600 bps, 8 bits, sin paridad, 1 bit de stop (8N1)**.

Corresponde al firmware `firmware/G7_TPI_ED2.asm` (v4.0) y a la GUI `gui/index.html`.

## PIC → PC

El PIC envía una sola trama de texto cada ~250 ms, terminada en `\r\n`:

```
Txx,Myy,Bzzz
```

| Campo | Significado | Ejemplo |
| --- | --- | --- |
| `Txx` | Temperatura del LM35 en °C (2 cifras, satura en 99) | `T27` |
| `Myy` | Segundos que faltan de la medición de pulso; `00` si no hay medición en curso | `M12` |
| `Bzzz` | Última frecuencia cardíaca medida en BPM (3 cifras); `000` si todavía no hay resultado o no se detectaron latidos | `B072` |

Ejemplos:

- `T26,M00,B000`: en reposo, 26 °C, sin medición previa.
- `T27,M09,B000`: midiendo, faltan 9 s.
- `T27,M00,B064`: medición terminada, 64 BPM.

## PC → PIC

Un carácter por comando (se aceptan mayúsculas y minúsculas):

| Carácter | Acción |
| --- | --- |
| `I` | Inicia una medición de pulso de 15 s. El display pasa a la cuenta regresiva `t-15` … `t-01` y al final muestra `FXXX` (o `F---` si no hubo latidos). |
| `V` | Alterna el display entre temperatura (`XX°C`) y frecuencia cardíaca (`FXXX`). |

## Conversión de cuentas

Con Vref+ = 2,50 V y 8 bits, cada cuenta del ADC vale 9,77 mV. El firmware convierte la lectura del LM35 a °C enteros como `°C = cuentas × 250 / 256`.

La frecuencia cardíaca se calcula como `latidos en 15 s × 4`, por lo que la resolución es de 4 BPM.
