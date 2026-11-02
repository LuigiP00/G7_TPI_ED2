# GUI del pulsómetro

Interfaz gráfica para la PC, en **Python 3** con **pySerial** y **Tkinter**.

Funciones previstas:

- Elegir el puerto COM y conectarse a 9600 bps.
- Mostrar la temperatura, el estado de la medición, el resultado en BPM y la alarma térmica.
- Enviar las teclas `1`, `2`, `A` y `D` (también desde el teclado de la PC).
- Graficar en vivo la señal del sensor en modo depuración, para ajustar los umbrales.

Protocolo: ver [`../docs/protocolo_serie.md`](../docs/protocolo_serie.md).
