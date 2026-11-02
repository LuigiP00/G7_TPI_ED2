;*******************************************************************************
; @brief       ANEXO B - FIRMWARE DEL SEP.
;
; @brief       Pulsómetro digital con alarma térmica (PIC16F887, cristal 4 MHz).
;
; @details     PASOS 1 a 4. Deja configurados todos los periféricos del SEP
;              y la estructura de interrupciones. Por ahora:
;              - Timer0 interrumpe cada ~10 ms (base de tiempo del ADC, SSE.6)
;                y avisa cada 100 ms y cada 1 s.
;              - Timer1 interrumpe cada 5 ms y multiplexa los 4 dígitos del
;                display de ánodo común (SSE.3.2, drivers PNP SSE.5.1).
;              - Cada 100 ms se lee el LM35 en AN0 (SSE.6.1) y la temperatura
;                se muestra como "t 25" en el display.
;              - Como prueba, el LED de latido (RE0, SSE.3.4) parpadea cada 1 s.
;              ADC (AN0/AN1, Vref+ externa), EUSART (9600 8N1) y PORTB
;              (teclado, SSE.3.1) quedan configurados; sus interrupciones se
;              habilitan en los pasos siguientes.
;
; @author      G7_TPI_ED2
;
; @date        02/11/2026
;
; @version     0.3
;*******************************************************************************

;===============================================================================
; DIRECTIVAS DE INCLUSIÓN
;===============================================================================
LIST P=16F887
#include "p16f887.inc"
    ERRORLEVEL -302             ;Oculta el aviso "register not in bank 0"
                                ;(usamos BANKSEL antes de cada registro)

;===============================================================================
; CONFIGURACIÓN GENERAL DEL MCU
;===============================================================================
    __CONFIG _CONFIG1, _FOSC_XT & _WDTE_OFF & _PWRTE_ON & _MCLRE_ON & _CP_OFF & _CPD_OFF & _BOREN_OFF & _IESO_OFF & _FCMEN_OFF & _LVP_OFF
    __CONFIG _CONFIG2, _BOR4V_BOR40V & _WRT_OFF

;===============================================================================
; DEFINICIÓN DE CONSTANTES
;===============================================================================
;--- Bases de tiempo -----------------------------------------------------------
TMR0_PRECARGA   EQU D'100'      ;256-156 = 100 -> 156 x 64 us = 9,984 ms
TMR1H_PRECARGA  EQU 0xEC        ;65536-5000 = 60536 = 0xEC78 -> 5 ms
TMR1L_PRECARGA  EQU 0x78
TICKS_100MS     EQU D'10'       ;10 interrupciones de Timer0 = ~100 ms
TICKS_1S        EQU D'100'      ;100 interrupciones de Timer0 = ~1 s

;--- Umbrales del SEP (se usan en los próximos pasos) --------------------------
ALARMA_T_ON     EQU D'41'       ;T > 40 °C  (ADRESH >= 41)
ALARMA_T_OFF    EQU D'39'       ;T <= 39 °C
VENTANA_SEG     EQU D'15'       ;Ventana de conteo de latidos: 15 s
TIEMPO_MUERTO   EQU D'25'       ;25 x 10 ms = 250 ms sin contar cruces
BPM_MIN         EQU D'50'       ;Rango normal de frecuencia cardíaca
BPM_MAX         EQU D'120'

;--- Display de 4 dígitos (ánodo común, lógica negativa) ----------------------
NUM_DIGITOS     EQU D'4'        ;Dígitos del display
MASCARA_DIGITOS EQU B'00111100' ;RC2-RC5: bases de los PNP de cada dígito
CHAR_P          EQU D'10'       ;Índices de TABLA_DECO_DSPL_AC: 0-9 = dígitos
CHAR_T          EQU D'11'       ;'t'
CHAR_GUION      EQU D'12'       ;'-'
CHAR_BLANCO     EQU D'13'       ;dígito apagado

;--- EUSART --------------------------------------------------------------------
SPBRG_9600      EQU D'25'       ;4 MHz / (16 x 26) = 9615 bps (BRGH = 1)

;--- Bits del registro FLAGS ---------------------------------------------------
F_10MS          EQU 0           ;Pasaron 10 ms (lo pone ISR_TMR0)
F_1S            EQU 1           ;Pasó 1 s (lo pone ISR_TMR0)
F_RX            EQU 2           ;Llegó un carácter por la EUSART
F_TECLA         EQU 3           ;Se apretó una tecla
F_100MS         EQU 4           ;Pasaron 100 ms (lo pone ISR_TMR0)

;--- Pines (SSE asociados) -----------------------------------------------------
#define LED_TERMICO     PORTC,0 ;SSE.3.4  OPTICAL_SIGNALING
#define BUZZER          PORTC,1 ;SSE.3.3  ACOUSTIC_SIGNALING (vía SSE.5.1)
#define LED_LATIDO      PORTE,0 ;SSE.3.4  BEAT_SIGNALING
#define LED_RANGO       PORTE,1 ;SSE.3.4  HR_RANGE_SIGNALING

;===============================================================================
; DEFINICIÓN DE VARIABLES
;===============================================================================
;--- RAM compartida (0x70-0x7F): se accede desde cualquier banco ---------------
W_TEMP          EQU 0x70        ;Copia de W durante la ISR
STATUS_TEMP     EQU 0x71        ;Copia de STATUS durante la ISR
PCLATH_TEMP     EQU 0x72        ;Copia de PCLATH durante la ISR
FSR_TEMP        EQU 0x73        ;Copia de FSR durante la ISR
TABLA_TMP       EQU 0x74        ;Índice auxiliar de las tablas

;--- Banco 0 -------------------------------------------------------------------
CONT_10MS       EQU 0x20        ;Cuenta interrupciones de Timer0 (0 a 99)
FLAGS           EQU 0x21        ;Banderas de eventos (ver bits F_xxx)
DSPL_DIG1       EQU 0x22        ;Buffer del display: dígito 1 (izquierda)
DSPL_DIG2       EQU 0x23        ;Buffer del display: dígito 2
DSPL_DIG3       EQU 0x24        ;Buffer del display: dígito 3
DSPL_DIG4       EQU 0x25        ;Buffer del display: dígito 4 (derecha)
DSPL_INDICE     EQU 0x26        ;Dígito que se enciende ahora (0 a 3)
TEMP_C          EQU 0x27        ;Última temperatura medida (°C)
PULSO_CONT      EQU 0x28        ;Latidos contados en la ventana actual
VENTANA_CONT    EQU 0x29        ;Segundos que faltan de la ventana de 15 s
MUERTO_CONT     EQU 0x2A        ;Ticks de 10 ms que faltan de tiempo muerto
BPM             EQU 0x2B        ;Resultado: PULSO_CONT x 4
ESTADO          EQU 0x2C        ;0 = ESPERA, 1 = MIDIENDO, 2 = RESULTADO
MODO            EQU 0x2D        ;0 = mostrar temperatura, 1 = mostrar pulso
RX_DATO         EQU 0x2E        ;Último carácter recibido por la EUSART
CONT_100MS      EQU 0x2F        ;Cuenta interrupciones de Timer0 (0 a 9)
CENTENAS        EQU 0x30        ;Resultado de BIN_A_BCD
DECENAS         EQU 0x31
UNIDADES        EQU 0x32
BCD_AUX         EQU 0x33        ;Número que BIN_A_BCD va descomponiendo
ADC_DEMORA      EQU 0x34        ;Contador de la demora de adquisición

;===============================================================================
; DECLARACIÓN DE MACROS PARA CONFIGURACIÓN DE REGISTROS
;===============================================================================
;-------------------------------------------------------------------------------
; CONFIG_PUERTOS: entradas analógicas, sentido de cada pin y pull-ups.
;-------------------------------------------------------------------------------
CONFIG_PUERTOS  MACRO
    BANKSEL PORTA
    CLRF    PORTA               ;Valores de salida antes de habilitarlas
    CLRF    PORTB
    MOVLW   MASCARA_DIGITOS     ;RC2-RC5 en 1: los 4 dígitos apagados (PNP)
    MOVWF   PORTC               ;RC0 (LED) y RC1 (buzzer) en 0: apagados
    MOVLW   B'11111111'         ;Segmentos en 1: apagados (ánodo común)
    MOVWF   PORTD
    CLRF    PORTE
    BANKSEL ANSEL
    MOVLW   B'00001011'         ;AN0 (LM35), AN1 (pulso), AN3 (Vref+) analógicas
    MOVWF   ANSEL               ;AN2 y AN4-AN7 (incluye RE0-RE2) digitales
    CLRF    ANSELH              ;AN8-AN13 digitales: PORTB entero digital
    BANKSEL TRISA
    MOVLW   B'11001011'         ;RA0, RA1, RA3 entradas; RA6/RA7 = cristal
    MOVWF   TRISA
    MOVLW   B'11110000'         ;RB0-RB3 filas (salidas), RB4-RB7 columnas
    MOVWF   TRISB
    MOVLW   B'11000000'         ;RC0-RC5 salidas; RC6 (TX) y RC7 (RX) para EUSART
    MOVWF   TRISC
    CLRF    TRISD               ;RD0-RD6 segmentos a-g: salidas
    CLRF    TRISE               ;RE0 y RE1 (LEDs) salidas
    MOVLW   B'11110000'         ;Pull-ups internas solo en las columnas
    MOVWF   WPUB
    BANKSEL PORTA
    ENDM

;-------------------------------------------------------------------------------
; CONFIG_TMR0: reloj interno, prescaler 1:64, pull-ups de PORTB habilitadas.
;-------------------------------------------------------------------------------
CONFIG_TMR0     MACRO
    BANKSEL OPTION_REG
    MOVLW   B'00000101'         ;RBPU=0, T0CS=0, PSA=0, PS2:PS0=101 (1:64)
    MOVWF   OPTION_REG
    BANKSEL TMR0
    MOVLW   TMR0_PRECARGA
    MOVWF   TMR0
    ENDM

;-------------------------------------------------------------------------------
; CONFIG_TMR1: reloj interno, prescaler 1:1, precarga para 5 ms, encendido.
;-------------------------------------------------------------------------------
CONFIG_TMR1     MACRO
    BANKSEL T1CON
    MOVLW   TMR1H_PRECARGA
    MOVWF   TMR1H
    MOVLW   TMR1L_PRECARGA
    MOVWF   TMR1L
    MOVLW   B'00000001'         ;T1CKPS=00 (1:1), TMR1CS=0 (Fosc/4), TMR1ON=1
    MOVWF   T1CON
    ENDM

;-------------------------------------------------------------------------------
; CONFIG_ADC: Vref+ externa en RA3, Vref- = GND, justificado a izquierda,
; reloj Fosc/8 (TAD = 2 us), canal inicial AN0, módulo encendido.
;-------------------------------------------------------------------------------
CONFIG_ADC      MACRO
    BANKSEL ADCON1
    MOVLW   B'00010000'         ;ADFM=0 (izquierda), VCFG1=0, VCFG0=1 (RA3)
    MOVWF   ADCON1
    BANKSEL ADCON0
    MOVLW   B'01000001'         ;ADCS=01 (Fosc/8), CHS=0000 (AN0), ADON=1
    MOVWF   ADCON0
    ENDM

;-------------------------------------------------------------------------------
; CONFIG_EUSART: asíncrona, 9600 bps, 8 bits, sin paridad, 1 stop (8N1).
;-------------------------------------------------------------------------------
CONFIG_EUSART   MACRO
    BANKSEL BAUDCTL
    BCF     BAUDCTL,BRG16       ;Generador de baudios de 8 bits
    BANKSEL SPBRG
    MOVLW   SPBRG_9600
    MOVWF   SPBRG
    CLRF    SPBRGH
    MOVLW   B'00100100'         ;TXEN=1, SYNC=0 (asíncrona), BRGH=1
    MOVWF   TXSTA
    BANKSEL RCSTA
    MOVLW   B'10010000'         ;SPEN=1 (habilita el puerto), CREN=1 (recibe)
    MOVWF   RCSTA
    ENDM

;-------------------------------------------------------------------------------
; INIT_VARIABLES: todas las variables del programa en 0.
;-------------------------------------------------------------------------------
INIT_VARIABLES  MACRO
    BANKSEL CONT_10MS
    CLRF    CONT_10MS
    CLRF    FLAGS
    CLRF    DSPL_DIG1
    CLRF    DSPL_DIG2
    CLRF    DSPL_DIG3
    CLRF    DSPL_DIG4
    CLRF    DSPL_INDICE
    CLRF    TEMP_C
    CLRF    PULSO_CONT
    CLRF    VENTANA_CONT
    CLRF    MUERTO_CONT
    CLRF    BPM
    CLRF    ESTADO
    CLRF    MODO
    CLRF    RX_DATO
    CLRF    CONT_100MS
    CLRF    CENTENAS
    CLRF    DECENAS
    CLRF    UNIDADES
    CLRF    BCD_AUX
    CLRF    ADC_DEMORA
    ENDM

;-------------------------------------------------------------------------------
; CFG_DIGITOS_DSPL: mensaje inicial del display, "t---", hasta la primera
; lectura del LM35. El buffer guarda ÍNDICES de caracteres; la ISR los
; decodifica.
;-------------------------------------------------------------------------------
CFG_DIGITOS_DSPL MACRO
    BANKSEL DSPL_DIG1
    MOVLW   CHAR_T
    MOVWF   DSPL_DIG1           ;Dígito 1 (izquierda) -> 't'
    MOVLW   CHAR_GUION
    MOVWF   DSPL_DIG2           ;Dígitos 2 a 4 -> '-'
    MOVWF   DSPL_DIG3           ;(W sigue valiendo CHAR_GUION)
    MOVWF   DSPL_DIG4
    MOVLW   NUM_DIGITOS - 1
    MOVWF   DSPL_INDICE         ;El primer barrido arranca por el dígito 1
    ENDM

;-------------------------------------------------------------------------------
; CONFIG_INTERRUPCIONES: por ahora solo Timer0 y Timer1.
; (RCIE se habilita en el paso 6 y RBIE en el paso del teclado.)
;-------------------------------------------------------------------------------
CONFIG_INTERRUPCIONES MACRO
    BANKSEL PIE1
    MOVLW   B'00000001'         ;TMR1IE=1 (RCIE=0 por ahora)
    MOVWF   PIE1
    BANKSEL PIR1
    CLRF    PIR1                ;Borra banderas pendientes de periféricos
    MOVLW   B'11100000'         ;GIE=1, PEIE=1, T0IE=1, banderas en 0
    MOVWF   INTCON
    ENDM

;===============================================================================
; INICIALIZACIÓN DEL MCU (CÓDIGO ABSOLUTO)
;===============================================================================
    ORG     0x00                ;Vector de Reset
    GOTO    INICIO              ;Salto al inicio del programa principal
    ORG     0x04                ;Vector de Interrupción
    GOTO    ISR_INICIO          ;Salto a la Rutina de Servicio de Interrupción
    ORG     0x05                ;Ubicación Programa Principal en la memoria

;===============================================================================
; INICIALIZACIÓN DE MACROS PARA CONFIGURACIÓN DE REGISTROS
;===============================================================================
INICIO      ;-----Inicialización de Macros-------
    CONFIG_PUERTOS
    INIT_VARIABLES
    CFG_DIGITOS_DSPL
    CONFIG_TMR0
    CONFIG_TMR1
    CONFIG_ADC
    CONFIG_EUSART
    CONFIG_INTERRUPCIONES       ;Siempre última: recién acá arrancan las ISR

;===============================================================================
; INICIO PROGRAMA PRINCIPAL
;===============================================================================
MAIN_LOOP
    BTFSC   FLAGS,F_100MS       ;¿Pasaron 100 ms?
    CALL    TAREA_100MS         ;Sí: medir y mostrar la temperatura
    BTFSC   FLAGS,F_1S          ;¿Pasó 1 segundo?
    CALL    TAREA_1S            ;Sí: tareas de cada segundo
    GOTO    MAIN_LOOP

;===============================================================================
; INICIALIZACIÓN DE RUTINAS DE SERVICIO DE INTERRUPCIÓN
;===============================================================================
ISR_INICIO
    ;----------Guardado de Contexto----------
    MOVWF   W_TEMP              ;Guarda W (RAM compartida, cualquier banco)
    SWAPF   STATUS,W            ;Copia STATUS sin modificar sus banderas
    CLRF    STATUS              ;Banco 0 para el resto de la ISR
    MOVWF   STATUS_TEMP
    MOVF    PCLATH,W
    MOVWF   PCLATH_TEMP
    CLRF    PCLATH              ;Página 0 de programa
    MOVF    FSR,W               ;FSR se usa en el multiplexado
    MOVWF   FSR_TEMP
    ;----------------------------------------
    ;-----Identificación de Interrupción-----
    BTFSC   INTCON,T0IF         ;¿Desbordó Timer0?
    GOTO    ISR_TMR0
    BTFSC   PIR1,TMR1IF         ;¿Desbordó Timer1?
    GOTO    ISR_TMR1
    BTFSC   PIR1,RCIF           ;¿Llegó un dato por la EUSART?
    GOTO    ISR_RX
    BTFSC   INTCON,RBIF         ;¿Cambió alguna columna del teclado?
    GOTO    ISR_IOC
    GOTO    ISR_FIN             ;Ninguna conocida: salir
    ;----------------------------------------

;===============================================================================
; FINALIZACIÓN DE RUTINAS DE SERVICIO DE INTERRUPCIÓN
;===============================================================================
ISR_FIN
    ;--------Restauración de Contexto--------
    MOVF    FSR_TEMP,W
    MOVWF   FSR
    MOVF    PCLATH_TEMP,W
    MOVWF   PCLATH
    SWAPF   STATUS_TEMP,W       ;Vuelve STATUS (y el banco) como estaba
    MOVWF   STATUS
    SWAPF   W_TEMP,F            ;Vuelve W sin tocar STATUS
    SWAPF   W_TEMP,W
    RETFIE                      ;Regresa y vuelve a habilitar GIE
    ;----------------------------------------

;===============================================================================
; SUBRUTINAS
;===============================================================================
;*******************************************************************************
; @brief    TAREA_100MS: mide la temperatura y la muestra.
;
; @details  Corre cada 100 ms, cuando ISR_TMR0 levanta F_100MS.
;*******************************************************************************
TAREA_100MS
    BCF     FLAGS,F_100MS       ;Baja la bandera
    CALL    ADC_LEER_TEMP       ;W = lectura del LM35 = °C
    MOVWF   TEMP_C
    CALL    MOSTRAR_TEMP        ;"t 25" en el display
    RETURN

;*******************************************************************************
; @brief    TAREA_1S: tareas de cada segundo.
;*******************************************************************************
TAREA_1S
    BCF     FLAGS,F_1S          ;Baja la bandera
    CALL    PRUEBA_LED_1S       ;Prueba de la base de tiempo (paso 2)
    RETURN

;*******************************************************************************
; @brief    PRUEBA_LED_1S: invierte el LED de latido (RE0).
;
; @details  Prueba temporal del paso 2: si el LED cambia una vez por segundo,
;           Timer0 y su ISR funcionan. Se elimina cuando RE0 pase a marcar
;           los latidos.
;*******************************************************************************
PRUEBA_LED_1S
    MOVLW   B'00000001'         ;Máscara del bit 0 (RE0)
    XORWF   PORTE,F             ;Invierte RE0
    RETURN

;*******************************************************************************
; @brief    ADC_LEER_TEMP: convierte el canal AN0 (LM35, SSE.6.1).
;
; @details  Con Vref+ = 2,56 V y 8 bits, cada cuenta vale 10 mV = 1 °C:
;           el resultado en W ya es la temperatura en °C.
;*******************************************************************************
ADC_LEER_TEMP
    MOVLW   B'01000001'         ;ADCS=01 (Fosc/8), CHS=0000 (AN0), ADON=1
    MOVWF   ADCON0
    CALL    ADC_CONVERTIR
    RETURN

;*******************************************************************************
; @brief    ADC_CONVERTIR: convierte el canal ya elegido en ADCON0.
;
; @details  1) Espera ~20 us para que el capacitor interno del ADC se cargue
;           con la tensión del canal (tiempo de adquisición).
;           2) Pone GO=1 y espera a que el hardware lo baje (~22 us).
;           3) Devuelve en W los 8 bits altos del resultado (ADRESH).
;           La usan AN0 (temperatura) y, más adelante, AN1 (pulso).
;*******************************************************************************
ADC_CONVERTIR
    MOVLW   D'7'
    MOVWF   ADC_DEMORA
ADC_ADQUISICION
    DECFSZ  ADC_DEMORA,F        ;7 vueltas de 3 us = ~20 us
    GOTO    ADC_ADQUISICION
    BSF     ADCON0,GO           ;Arranca la conversión
ADC_ESPERA
    BTFSC   ADCON0,GO           ;¿Terminó? (GO vuelve a 0 solo)
    GOTO    ADC_ESPERA          ;No: seguir esperando
    MOVF    ADRESH,W            ;Sí: W = resultado (8 bits)
    RETURN

;*******************************************************************************
; @brief    MOSTRAR_TEMP: escribe "t" y TEMP_C en el buffer del display.
;
; @details  Formato "t 25" (o "t125" a partir de 100 °C): la centena se
;           muestra apagada cuando vale 0.
;*******************************************************************************
MOSTRAR_TEMP
    MOVF    TEMP_C,W
    CALL    BIN_A_BCD           ;Separa centenas, decenas y unidades
    MOVLW   CHAR_T
    MOVWF   DSPL_DIG1           ;'t'
    MOVF    CENTENAS,W          ;W = centenas (Z = 1 si es 0)
    BTFSC   STATUS,Z
    MOVLW   CHAR_BLANCO         ;Si es 0: dígito apagado
    MOVWF   DSPL_DIG2
    MOVF    DECENAS,W
    MOVWF   DSPL_DIG3
    MOVF    UNIDADES,W
    MOVWF   DSPL_DIG4
    RETURN

;*******************************************************************************
; @brief    BIN_A_BCD: separa un número de 0 a 255 en sus tres cifras.
;
; @details  Entrada en W. Resta 100 mientras se pueda (cuenta CENTENAS),
;           después resta 10 (cuenta DECENAS); lo que queda son UNIDADES.
;           Ejemplo: 137 -> 1 resta de 100 (queda 37) -> 3 restas de 10
;           (queda 7) -> CENTENAS=1, DECENAS=3, UNIDADES=7.
;*******************************************************************************
BIN_A_BCD
    MOVWF   BCD_AUX
    CLRF    CENTENAS
    CLRF    DECENAS
BCD_CENTENAS
    MOVLW   D'100'
    SUBWF   BCD_AUX,W           ;W = BCD_AUX - 100
    BTFSS   STATUS,C            ;C = 0 si el resultado dio negativo
    GOTO    BCD_DECENAS         ;No entra otro 100: pasar a decenas
    MOVWF   BCD_AUX             ;Sí entra: guardar lo que queda
    INCF    CENTENAS,F
    GOTO    BCD_CENTENAS
BCD_DECENAS
    MOVLW   D'10'
    SUBWF   BCD_AUX,W           ;W = BCD_AUX - 10
    BTFSS   STATUS,C
    GOTO    BCD_UNIDADES
    MOVWF   BCD_AUX
    INCF    DECENAS,F
    GOTO    BCD_DECENAS
BCD_UNIDADES
    MOVF    BCD_AUX,W           ;Lo que quedó (0 a 9)
    MOVWF   UNIDADES
    RETURN

;*******************************************************************************
; @brief    MUX_DSPL: enciende el siguiente dígito del display (uno por vez).
;
; @details  Se llama desde ISR_TMR1 cada 5 ms; 4 dígitos -> cada uno se
;           refresca cada 20 ms (50 Hz). Orden anti-fantasma: primero apagar
;           todos, después cargar los segmentos, recién al final encender el
;           dígito nuevo. Lógica negativa: 0 = encendido.
;*******************************************************************************
MUX_DSPL
    MOVLW   MASCARA_DIGITOS
    IORWF   PORTC,F             ;RC2-RC5 en 1: apaga los 4 dígitos
    INCF    DSPL_INDICE,F       ;Pasa al dígito siguiente
    MOVF    DSPL_INDICE,W
    XORLW   NUM_DIGITOS         ;¿Llegó a 4?
    BTFSC   STATUS,Z
    CLRF    DSPL_INDICE         ;Sí: vuelve al dígito 1 (índice 0)
    MOVF    DSPL_INDICE,W       ;Direccionamiento indirecto:
    ADDLW   DSPL_DIG1           ;FSR = dirección de DSPL_DIG1 + índice
    MOVWF   FSR
    BCF     STATUS,IRP          ;Bancos 0 y 1 para el acceso indirecto
    MOVF    INDF,W              ;W = carácter guardado en ese dígito
    CALL    TABLA_DECO_DSPL_AC  ;W = patrón de segmentos
    MOVWF   PORTD               ;Carga los segmentos
    MOVF    DSPL_INDICE,W
    CALL    TABLA_CTRL_DSPL_AC  ;W = máscara con un 0 en el dígito a encender
    ANDWF   PORTC,F             ;Enciende solo ese dígito (no toca RC0, RC1)
    RETURN

;*******************************************************************************
; @brief    TABLA_CTRL_DSPL_AC: índice de dígito (0-3) -> máscara para PORTC.
;
; @details  Un 0 en la base del PNP lo satura y enciende el dígito. Se aplica
;           con ANDWF, así RC0 (LED) y RC1 (buzzer) quedan como estaban.
;           Carga PCLATH antes del salto: funciona en cualquier posición de
;           memoria, siempre que la tabla no cruce un límite de 256 palabras.
;*******************************************************************************
TABLA_CTRL_DSPL_AC
    MOVWF   TABLA_TMP           ;Guarda el índice
    MOVLW   HIGH(TABLA_CTRL_INI)
    MOVWF   PCLATH              ;Parte alta de la dirección de la tabla
    MOVF    TABLA_TMP,W
    ADDWF   PCL,F               ;Salta a la fila "índice"
TABLA_CTRL_INI
    RETLW   B'11111011'         ;0: dígito 1 (RC2 = 0)
    RETLW   B'11110111'         ;1: dígito 2 (RC3 = 0)
    RETLW   B'11101111'         ;2: dígito 3 (RC4 = 0)
    RETLW   B'11011111'         ;3: dígito 4 (RC5 = 0)
TABLA_CTRL_FIN
    IF HIGH(TABLA_CTRL_INI) != HIGH(TABLA_CTRL_FIN - 1)
        ERROR "TABLA_CTRL_DSPL_AC cruza un limite de 256 palabras"
    ENDIF

;*******************************************************************************
; @brief    TABLA_DECO_DSPL_AC: índice de carácter -> segmentos (ánodo común).
;
; @details  Bits: 0=a 1=b 2=c 3=d 4=e 5=f 6=g. 0 = segmento encendido.
;           Los dígitos 0-9 son los mismos valores del TPL3.
;*******************************************************************************
TABLA_DECO_DSPL_AC
    MOVWF   TABLA_TMP
    MOVLW   HIGH(TABLA_DECO_INI)
    MOVWF   PCLATH
    MOVF    TABLA_TMP,W
    ADDWF   PCL,F
TABLA_DECO_INI
    RETLW   0x40                ;0  '0'
    RETLW   0x79                ;1  '1'
    RETLW   0x24                ;2  '2'
    RETLW   0x30                ;3  '3'
    RETLW   0x19                ;4  '4'
    RETLW   0x12                ;5  '5'
    RETLW   0x02                ;6  '6'
    RETLW   0x78                ;7  '7'
    RETLW   0x00                ;8  '8'
    RETLW   0x18                ;9  '9'
    RETLW   0x0C                ;10 'P' (a,b,e,f,g)
    RETLW   0x07                ;11 't' (d,e,f,g)
    RETLW   0x3F                ;12 '-' (g)
    RETLW   0xFF                ;13 apagado
TABLA_DECO_FIN
    IF HIGH(TABLA_DECO_INI) != HIGH(TABLA_DECO_FIN - 1)
        ERROR "TABLA_DECO_DSPL_AC cruza un limite de 256 palabras"
    ENDIF

;*******************************************************************************
; @brief    ISR_TMR0: base de tiempo de 10 ms.
;
; @details  Recarga Timer0 y avisa cada 10 ms (F_10MS), cada 100 ms
;           (F_100MS) y cada 1 s (F_1S).
;*******************************************************************************
ISR_TMR0
    MOVLW   TMR0_PRECARGA
    MOVWF   TMR0                ;Recarga para el próximo período de 10 ms
    BCF     INTCON,T0IF         ;Baja la bandera de Timer0
    BSF     FLAGS,F_10MS        ;Aviso al lazo principal: pasaron 10 ms
    INCF    CONT_100MS,F        ;Cuenta para los 100 ms
    MOVF    CONT_100MS,W
    XORLW   TICKS_100MS         ;¿Llegó a 10?
    BTFSS   STATUS,Z
    GOTO    ISR_TMR0_1S         ;No: seguir con la cuenta de 1 s
    CLRF    CONT_100MS          ;Sí: reiniciar
    BSF     FLAGS,F_100MS       ;Aviso: pasaron 100 ms
ISR_TMR0_1S
    INCF    CONT_10MS,F         ;Cuenta para el segundo
    MOVF    CONT_10MS,W
    XORLW   TICKS_1S            ;¿Llegó a 100?
    BTFSS   STATUS,Z
    GOTO    ISR_FIN             ;No: salir
    CLRF    CONT_10MS           ;Sí: reiniciar la cuenta
    BSF     FLAGS,F_1S          ;Aviso: pasó 1 segundo
    GOTO    ISR_FIN

;*******************************************************************************
; @brief    ISR_TMR1: base de tiempo de 5 ms para el multiplexado.
;
; @details  Recarga Timer1 y enciende el dígito siguiente (MUX_DSPL).
;*******************************************************************************
ISR_TMR1
    MOVLW   TMR1H_PRECARGA
    MOVWF   TMR1H               ;Recarga para el próximo período de 5 ms
    MOVLW   TMR1L_PRECARGA
    MOVWF   TMR1L
    BCF     PIR1,TMR1IF         ;Baja la bandera de Timer1
    CALL    MUX_DSPL            ;Barrido del display
    GOTO    ISR_FIN

;*******************************************************************************
; @brief    ISR_RX: dato recibido por la EUSART.
;
; @details  Leer RCREG baja RCIF. Guarda el carácter y avisa con F_RX.
;           (Se habilita en el paso 6.)
;*******************************************************************************
ISR_RX
    MOVF    RCREG,W             ;Leer RCREG borra RCIF
    MOVWF   RX_DATO
    BSF     FLAGS,F_RX
    GOTO    ISR_FIN

;*******************************************************************************
; @brief    ISR_IOC: cambio de estado en RB4-RB7 (columnas del teclado).
;
; @details  Leer PORTB y luego borrar RBIF. (Se completa en el paso del
;           teclado.)
;*******************************************************************************
ISR_IOC
    MOVF    PORTB,W             ;Leer PORTB termina la condición de cambio
    BCF     INTCON,RBIF
    GOTO    ISR_FIN

;===============================================================================
    END
;===============================================================================
