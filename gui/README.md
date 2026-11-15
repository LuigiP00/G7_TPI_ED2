# GUI del pulsómetro

Interfaz web (`index.html`) que se comunica con el PIC por el puerto serie usando la **Web Serial API** del navegador. No necesita instalar nada.

## Cómo usarla

1. Conectar el adaptador USB–UART (CP2102) a la PC.
2. Abrir `index.html` con **Google Chrome** o **Microsoft Edge** (Firefox no soporta Web Serial).
3. Tocar **Conectar PIC** y elegir el puerto COM del CP2102.
4. Comandos:
   - **Iniciar Medición de Pulso** o tecla **I**: mide el pulso durante 15 s.
   - **Alternar Display Físico** o tecla **V**: cambia lo que muestra el display entre temperatura y frecuencia cardíaca.

## Qué muestra

- Temperatura en °C con gráfico de las últimas lecturas y una línea de referencia en 40 °C. Por encima de 40 °C la tarjeta se pone en rojo (alarma).
- Frecuencia cardíaca en BPM, con cuenta regresiva y barra de progreso durante la medición.
- La última trama recibida, para depurar.

Protocolo: ver [`../docs/protocolo_serie.md`](../docs/protocolo_serie.md).
