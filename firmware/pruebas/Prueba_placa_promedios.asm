;*******************************************************************************
; @brief       PULSÓMETRO (HW-827) - DETECCIÓN POR CRUCE DE DOS PROMEDIOS
;              + SALIDA A DISPLAY DE 7 SEGMENTOS DE 4 DÍGITOS (ÁNODO COMÚN)
;
; @details     IDEA DE LA DETECCIÓN
;              El PIC lleva dos promedios de la señal del sensor:
;                - Promedio RÁPIDO: sigue a la señal casi al instante.
;                - Promedio LENTO:  representa el nivel de reposo.
;              Con el dedo quieto los dos valen casi lo mismo, así que su
;              diferencia es ~0 sin importar a qué tensión esté la señal.
;              Cuando llega un latido la señal sube rápido: el promedio rápido
;              la sigue, el lento se queda atrás y la diferencia crece.
;              Si la diferencia supera THR_CUENTAS se cuenta UN latido; luego se
;              ignora todo durante 250 ms y no se cuenta otro hasta que la
;              diferencia vuelva a bajar del umbral.
;
;              FUNCIONAMIENTO GENERAL
;              - Una vez por tick (9.98 ms): se lee el ADC y se actualizan los
;                promedios (en todos los estados).
;              - Estado 0: Espera. LED Rojo (RB1) fijo, LED Verde apagado.
;                          Display: G07.
;              - Estado 1: Medición de 15 s. LED Rojo destella con cada latido.
;                          Display: serpentina (un segmento a la vez, de a a g).
;              - Estado 2: Reproducción. LED Verde (RB2) fijo; el LED Rojo
;                destella tantas veces cada 15 s como latidos se contaron.
;                          Display: F + frecuencia cardíaca (BPM, 3 dígitos).
;                          Si no se contó ningún latido: F---.
;              - Botón en RB0 (activo en bajo): inicia (o reinicia) la medición.
;
;              DISPLAY (multiplexado por Timer1, interrupción cada 5 ms)
;              - Lógica negativa (ánodo común): segmento encendido = 0 en el
;                pin de datos; dígito habilitado = 0 en el pin de control.
;              - Una ISR de Timer1 enciende un dígito por vez: cada dígito se
;                refresca cada 4 x 5 ms = 20 ms (50 Hz). El lazo principal solo
;                escribe los 4 bytes de DSPL_1..DSPL_4 (ya en formato de
;                segmentos) y la ISR los saca por PORTD.
;
;              CONEXIONES
;              - Reloj: cristal 4 MHz (XT) en OSC1/OSC2 (pines 13 y 14).
;              - Sensor (a través del divisor resistivo): RA0/AN0 (pin 2).
;              - Vref+ del ADC: RA3 (pin 5), 2.50 V.
;              - RB0 (pin 33) botón a GND, pull-up interno.
;              - RB1 (pin 34) LED rojo. RB2 (pin 35) LED verde.
;              - RC0..RC3: control de los dígitos 1..4 (0 = habilitado).
;                Dígito 1 = el de la izquierda.
;              - RD0..RD6: segmentos a..g (0 = encendido). RD7 = dp (siempre 1,
;                apagado, no se usa).
;*******************************************************************************

;===============================================================================
; DIRECTIVAS Y CONFIGURACIÓN
;===============================================================================
    LIST P=16F887
#include "p16f887.inc"

    __CONFIG _CONFIG1, _XT_OSC & _WDT_OFF & _PWRTE_ON & _MCLRE_ON & _CP_OFF & _LVP_OFF
    __CONFIG _CONFIG2, _BOR40V & _WRT_OFF

;===============================================================================
; CONSTANTES
;===============================================================================
; --- Base de tiempo -----------------------------------------------------------
; Fosc = 4 MHz -> 1 us por instrucción -> Timer0 con prescaler 1:64 cuenta cada
; 64 us. Con precarga 100 desborda tras 256-100 = 156 cuentas = 9.984 ms.
; Es el valor del anteproyecto (~100 muestras por segundo) y está muy por encima
; del doble de la frecuencia máxima útil del pulso (8 Hz).
TMR0_PRELOAD    EQU d'100'

; --- Ventana de medición ------------------------------------------------------
; 15 s / 9.984 ms = 1502.4 ticks -> 1502 ticks = 14.996 s
WINDOW_TICKS    EQU d'1502'
WINDOW_H        EQU (WINDOW_TICKS >> 8)
WINDOW_L        EQU (WINDOW_TICKS & 0xFF)

; --- Promedios exponenciales --------------------------------------------------
; Cada tick: promedio = promedio + (muestra - promedio) / 2^SHIFT
; SHIFT 3 -> equivale a promediar ~8 muestras (~80 ms): duración del pico del pulso.
; SHIFT 6 -> equivale a promediar ~64 muestras (~640 ms): aprox. un latido.
FAST_SHIFT      EQU d'2'
SLOW_SHIFT      EQU d'7'

; --- Umbral de detección ------------------------------------------------------
; Diferencia (promedio rápido - promedio lento) mínima para contar un latido,
; en cuentas de ADC (1 cuenta = ~9.8 mV en el pin). SIN JUSTIFICAR: es un valor
; de partida que hay que ajustar con la señal real del sensor.
THR_CUENTAS     EQU d'2'

; --- Bloqueo tras cada latido -------------------------------------------------
; 20 ticks x 9.984 ms = 200 ms (valor del anteproyecto).
REFRACT_TICKS   EQU d'20'

; --- Duración de los destellos del LED rojo (solo visual) ---------------------
LED_LIVE_TICKS  EQU d'6'        ; ~60 ms, destello en vivo
LED_PLAY_TICKS  EQU d'10'       ; ~100 ms, destello en reproducción

; --- Multiplexado del display -------------------------------------------------
; Timer1 con prescaler 1:1 cuenta cada 1 us. Precarga 0xEC78 = 60536:
; 65536 - 60536 = 5000 cuentas = 5 ms por dígito (valor del anteproyecto).
TMR1_PRELOAD_H  EQU 0xEC
TMR1_PRELOAD_L  EQU 0x78

; --- Serpentina ---------------------------------------------------------------
; Cada cuántos ticks avanza un segmento: 20 ticks x 9.984 ms = ~200 ms
; (5 pasos por segundo; una vuelta a..g dura ~1.4 s). Solo es estético.
SNAKE_TICKS     EQU d'20'

; --- Segmentos en lógica negativa (ánodo común): bit0 = a ... bit6 = g, ------
; --- bit7 = dp (siempre 1 = apagado) ------------------------------------------
SEG_F           EQU 0x8E        ; a, e, f, g
SEG_G           EQU 0xC2        ; a, c, d, e, f
SEG_DASH        EQU 0xBF        ; solo g
SEG_OFF         EQU 0xFF        ; todo apagado

;===============================================================================
; VARIABLES (Banco 0)
;===============================================================================
    CBLOCK 0x20
        SYS_STATE               ; 0 = espera, 1 = medición, 2 = reproducción
        TIME_L                  ; Contador de ticks de la medición
        TIME_H
        PULSE_COUNT             ; Latidos contados en la ventana
        ACCUM_L                 ; Acumulador de la reproducción
        ACCUM_H
        LED_TIMER               ; Ticks restantes del destello del LED rojo
        REFRACT                 ; Ticks restantes del bloqueo
        BEAT_LOCK               ; 1 = ya se contó este latido (esperar que baje)
        CURRENT_ADC             ; Última lectura del ADC (8 bits)
        FAST_L                  ; Promedio rápido (16 bits: parte entera en FAST_H)
        FAST_H
        SLOW_L                  ; Promedio lento (16 bits: parte entera en SLOW_H)
        SLOW_H
        DIFF_H                  ; Parte entera de (rápido - lento)
        AUX_L                   ; Auxiliares del cálculo de promedios
        AUX_H
        SHIFT_K                 ; Desplazamiento del promedio que se actualiza
        LOOP_CNT                ; Contador de los lazos de desplazamiento
        ; --- Display ---
        DSPL_1                  ; Segmentos del dígito 1 (izquierda). DEBEN estar
        DSPL_2                  ; contiguos: la ISR los recorre con FSR
        DSPL_3
        DSPL_4
        MUX_IDX                 ; Dígito que se enciende en la próxima ISR (0..3)
        MUX_MASK                ; Patrón de control de PORTC del próximo dígito
        SNAKE_PAT               ; Patrón de la serpentina (un segmento en 0)
        SNAKE_TIMER             ; Ticks restantes para avanzar la serpentina
        BPM_VAL                 ; Frecuencia cardíaca en binario (0..255)
        HUNDREDS                ; Dígitos decimales de BPM_VAL
        TENS
        UNITS
        TBL_IDX                 ; Índice temporal de la tabla de segmentos
    ENDC

; Variables de guardado de contexto: banco común (0x70-0x7F, visible desde
; cualquier banco)
    CBLOCK 0x70
        W_TEMP
        STATUS_TEMP
        FSR_TEMP
    ENDC

;===============================================================================
; MACROS DE INICIALIZACIÓN
;===============================================================================
CONFIG_IO MACRO
    BANKSEL ANSEL
    MOVLW   b'00001001'         ; RA0 (AN0, sensor) y RA3 (AN3, Vref+) analógicos
    MOVWF   ANSEL
    CLRF    ANSELH              ; PORTB digital

    BANKSEL TRISA
    MOVLW   b'00001001'         ; RA0 y RA3 como entradas
    MOVWF   TRISA

    BANKSEL TRISB
    MOVLW   b'00000001'         ; RB0 entrada (botón). RB1 y RB2 salidas (LEDs)
    MOVWF   TRISB

    BANKSEL OPTION_REG
    BCF     OPTION_REG, 7       ; Habilita pull-ups de PORTB
    BANKSEL WPUB
    BSF     WPUB, 0             ; Pull-up activado en RB0

    BANKSEL PORTB
    CLRF    PORTB
    ENDM

CONFIG_ADC MACRO
    BANKSEL ADCON1
    MOVLW   b'00010000'         ; ADFM=0 (8 bits en ADRESH), VCFG0=1 (Vref+ en RA3)
    MOVWF   ADCON1

    BANKSEL ADCON0
    MOVLW   b'01000001'         ; Fosc/8, canal AN0, ADC encendido
    MOVWF   ADCON0
    ENDM

CONFIG_TIMER0 MACRO
    BANKSEL OPTION_REG
    MOVLW   b'01010101'         ; Pull-ups habilitados, Timer0 con prescaler 1:64
    MOVWF   OPTION_REG

    BANKSEL TMR0
    MOVLW   TMR0_PRELOAD
    MOVWF   TMR0
    BCF     INTCON, T0IF
    ENDM

CONFIG_DISPLAY MACRO
    ; RC y RD no tienen función analógica: no hace falta tocar ANSEL/ANSELH
    BANKSEL TRISC
    MOVLW   b'11110000'         ; RC0..RC3 salidas (control). RC4..RC7 quedan
    MOVWF   TRISC               ; como entradas (RC6/RC7 = EUSART)
    CLRF    TRISD               ; RD0..RD7 salidas (datos)

    ; Lógica negativa: todo apagado = 1
    BANKSEL PORTC
    MOVLW   b'11111111'
    MOVWF   PORTD
    MOVWF   PORTC
    ENDM

CONFIG_TIMER1_INT MACRO
    ; Timer1: reloj interno, prescaler 1:1, sin gate. Se habilita su interrupción.
    BANKSEL T1CON
    MOVLW   b'00000001'         ; TMR1ON=1, TMR1CS=0, T1CKPS=00, TMR1GE=0
    MOVWF   T1CON
    MOVLW   TMR1_PRELOAD_H
    MOVWF   TMR1H
    MOVLW   TMR1_PRELOAD_L
    MOVWF   TMR1L
    BCF     PIR1, TMR1IF

    BANKSEL PIE1
    BSF     PIE1, TMR1IE        ; Habilita interrupción de Timer1
    BSF     INTCON, PEIE        ; Habilita interrupciones de periféricos
    BSF     INTCON, GIE         ; Habilita interrupciones globales
    ENDM

;===============================================================================
; VECTORES DE INICIO
;===============================================================================
    ORG     0x00                ; Vector de Reset
    GOTO    INICIO
    ORG     0x04                ; Vector de Interrupción
    GOTO    ISR_INICIO
    ORG     0x05

;===============================================================================
; PROGRAMA PRINCIPAL
;===============================================================================
INICIO
    CONFIG_IO
    CONFIG_ADC
    CONFIG_TIMER0
    CONFIG_DISPLAY

    BANKSEL SYS_STATE
    CLRF    SYS_STATE
    CLRF    PULSE_COUNT
    CLRF    LED_TIMER
    CLRF    REFRACT
    CLRF    BEAT_LOCK

    ; Multiplexado: arranca por el dígito 1
    CLRF    MUX_IDX
    MOVLW   b'11111110'
    MOVWF   MUX_MASK
    CALL    MOSTRAR_G07         ; Display inicial: G07

    ; Promedios iniciales = primera lectura (diferencia 0)
    CALL    LEER_ADC
    BANKSEL CURRENT_ADC
    MOVF    CURRENT_ADC, W
    MOVWF   FAST_H
    MOVWF   SLOW_H
    CLRF    FAST_L
    CLRF    SLOW_L

    CONFIG_TIMER1_INT           ; Último: el display ya tiene datos válidos

MAIN_LOOP
    ; --- Espera del tick (desborde de Timer0) y recarga ---
    BTFSS   INTCON, T0IF
    GOTO    MAIN_LOOP
    BCF     INTCON, T0IF
    BANKSEL TMR0
    MOVLW   TMR0_PRELOAD
    MOVWF   TMR0

    ; --- En todos los estados: leer el sensor y actualizar los promedios ---
    CALL    LEER_ADC
    CALL    ACTUALIZAR_PROMEDIOS

    ; --- Botón (RB0, activo en bajo): inicia o reinicia la medición ---
    BANKSEL PORTB
    BTFSS   PORTB, 0
    GOTO    REINICIAR_SISTEMA

    ; --- Máquina de estados ---
    BANKSEL SYS_STATE
    MOVF    SYS_STATE, W
    BTFSC   STATUS, Z
    GOTO    STATE_WAIT_BUTTON

    XORLW   1
    BTFSC   STATUS, Z
    GOTO    STATE_MEASURE

    GOTO    STATE_PLAYBACK

;-------------------------------------------------------------------------------
; REINICIO: arranca una medición nueva
;-------------------------------------------------------------------------------
REINICIAR_SISTEMA:
    BANKSEL SYS_STATE
    MOVLW   1
    MOVWF   SYS_STATE           ; Estado 1: medición
    CLRF    TIME_L
    CLRF    TIME_H
    CLRF    PULSE_COUNT
    CLRF    ACCUM_L
    CLRF    ACCUM_H
    CLRF    LED_TIMER
    CLRF    REFRACT
    CLRF    BEAT_LOCK

    CALL    SERPENTINA_INICIAR  ; Display: arranca la serpentina

    BANKSEL PORTB
    CLRF    PORTB               ; Apaga ambos LEDs
    GOTO    MAIN_LOOP

;-------------------------------------------------------------------------------
; ESTADO 0: ESPERA (LED rojo fijo)
;-------------------------------------------------------------------------------
STATE_WAIT_BUTTON:
    BANKSEL PORTB
    BSF     PORTB, 1            ; LED rojo fijo
    BCF     PORTB, 2            ; LED verde apagado
    GOTO    MAIN_LOOP

;-------------------------------------------------------------------------------
; ESTADO 1: MEDICIÓN DE 15 s
;-------------------------------------------------------------------------------
STATE_MEASURE:
    BANKSEL TIME_L
    INCF    TIME_L, F
    BTFSC   STATUS, Z
    INCF    TIME_H, F

    ; ¿Se cumplieron los WINDOW_TICKS?
    MOVLW   WINDOW_H
    SUBWF   TIME_H, W
    BTFSS   STATUS, Z
    GOTO    CONTINUE_MEASURE
    MOVLW   WINDOW_L
    SUBWF   TIME_L, W
    BTFSS   STATUS, Z
    GOTO    CONTINUE_MEASURE

    ; --- Fin de la ventana: pasa a reproducción ---
    MOVLW   2
    MOVWF   SYS_STATE
    CLRF    LED_TIMER
    CLRF    ACCUM_L
    CLRF    ACCUM_H
    CALL    MOSTRAR_FRECUENCIA  ; Display: F + frecuencia cardíaca
    BANKSEL PORTB
    BCF     PORTB, 1            ; Apaga LED rojo
    BSF     PORTB, 2            ; Enciende LED verde (medición lista)
    GOTO    MAIN_LOOP

CONTINUE_MEASURE:
    CALL    DETECTAR_LATIDO
    CALL    LED_ROJO_TEMPORIZADO
    CALL    SERPENTINA_AVANZAR  ; Display: avanza la serpentina
    GOTO    MAIN_LOOP

;-------------------------------------------------------------------------------
; ESTADO 2: REPRODUCCIÓN (LED verde fijo, LED rojo destella PULSE_COUNT veces
; cada 15 s)
;-------------------------------------------------------------------------------
STATE_PLAYBACK:
    BANKSEL PULSE_COUNT
    MOVF    PULSE_COUNT, F
    BTFSC   STATUS, Z
    GOTO    MAIN_LOOP           ; Sin latidos: solo queda el LED verde

    ; ACCUM = ACCUM + PULSE_COUNT
    MOVF    PULSE_COUNT, W
    ADDWF   ACCUM_L, F
    BTFSC   STATUS, C
    INCF    ACCUM_H, F

    ; ¿ACCUM >= WINDOW_TICKS?
    MOVLW   WINDOW_H
    SUBWF   ACCUM_H, W
    BTFSS   STATUS, C
    GOTO    PLAY_LED            ; ACCUM_H < WINDOW_H: todavía no
    BTFSS   STATUS, Z
    GOTO    PLAY_BLINK          ; ACCUM_H > WINDOW_H: sí
    MOVLW   WINDOW_L
    SUBWF   ACCUM_L, W
    BTFSS   STATUS, C
    GOTO    PLAY_LED            ; ACCUM_L < WINDOW_L: todavía no

PLAY_BLINK:
    ; ACCUM = ACCUM - WINDOW_TICKS
    MOVLW   WINDOW_L
    SUBWF   ACCUM_L, F
    BTFSS   STATUS, C
    DECF    ACCUM_H, F
    MOVLW   WINDOW_H
    SUBWF   ACCUM_H, F

    BANKSEL PORTB
    BSF     PORTB, 1            ; Destello del LED rojo
    MOVLW   LED_PLAY_TICKS
    BANKSEL LED_TIMER
    MOVWF   LED_TIMER

PLAY_LED:
    CALL    LED_ROJO_TEMPORIZADO
    GOTO    MAIN_LOOP

;===============================================================================
; RUTINA DE SERVICIO DE INTERRUPCIÓN
;===============================================================================
;*******************************************************************************
; @brief ISR de Timer1: multiplexado del display (un dígito cada 5 ms).
;
; @details 1. Guarda W, STATUS y FSR (el lazo principal usa FSR en EWMA_UPDATE).
;          2. Recarga Timer1 (5 ms).
;          3. Apaga los 4 dígitos, saca por PORTD los segmentos del dígito
;             actual (DSPL_1 + MUX_IDX) y recién después lo habilita en PORTC.
;             Así no se ve el "fantasma" del dígito anterior.
;          4. Avanza MUX_IDX (0..3) y rota MUX_MASK: 1110, 1101, 1011, 0111
;             (RC0..RC3, lógica negativa).
;          5. Restaura el contexto.
;*******************************************************************************
ISR_INICIO
    ;----------Guardado de Contexto----------
    MOVWF   W_TEMP
    SWAPF   STATUS, W
    MOVWF   STATUS_TEMP
    MOVF    FSR, W
    MOVWF   FSR_TEMP
    BCF     STATUS, IRP         ; Direccionamiento indirecto en bancos 0 y 1
    ;----------------------------------------
    ;-----Identificación de Interrupción-----
    BANKSEL PIR1
    BTFSS   PIR1, TMR1IF
    GOTO    ISR_FIN             ; No fue Timer1
    BCF     PIR1, TMR1IF

    ; Recarga de Timer1
    MOVLW   TMR1_PRELOAD_H
    MOVWF   TMR1H
    MOVLW   TMR1_PRELOAD_L
    MOVWF   TMR1L

    ; --- Multiplexado ---
    MOVLW   b'11111111'
    MOVWF   PORTC               ; Todos los dígitos apagados
    MOVLW   DSPL_1
    ADDWF   MUX_IDX, W
    MOVWF   FSR                 ; FSR = &DSPL_1 + MUX_IDX
    MOVF    INDF, W
    MOVWF   PORTD               ; Segmentos del dígito actual
    MOVF    MUX_MASK, W
    MOVWF   PORTC               ; Habilita el dígito actual

    ; --- Siguiente dígito ---
    INCF    MUX_IDX, F
    BSF     STATUS, C
    RLF     MUX_MASK, F         ; Mueve el 0 al siguiente bit
    MOVF    MUX_IDX, W
    XORLW   d'4'
    BTFSS   STATUS, Z
    GOTO    ISR_FIN
    CLRF    MUX_IDX             ; Después del dígito 4 vuelve al 1
    MOVLW   b'11111110'
    MOVWF   MUX_MASK
    ;----------------------------------------

;===============================================================================
; FINALIZACIÓN DE RUTINA DE SERVICIO DE INTERRUPCIÓN
;===============================================================================
ISR_FIN
    ;--------Restauración de Contexto--------
    MOVF    FSR_TEMP, W
    MOVWF   FSR
    SWAPF   STATUS_TEMP, W
    MOVWF   STATUS
    SWAPF   W_TEMP, F
    SWAPF   W_TEMP, W
    RETFIE
    ;----------------------------------------

;===============================================================================
; SUBRUTINAS
;===============================================================================

;*******************************************************************************
; @brief Lee el ADC (canal AN0) y guarda los 8 bits altos en CURRENT_ADC.
;*******************************************************************************
LEER_ADC:
    BANKSEL ADCON0
    NOP
    NOP
    NOP
    BSF     ADCON0, 1           ; Inicia la conversión
WAIT_ADC:
    BTFSC   ADCON0, 1           ; Espera a que termine
    GOTO    WAIT_ADC

    BANKSEL ADRESH
    MOVF    ADRESH, W
    BANKSEL CURRENT_ADC
    MOVWF   CURRENT_ADC
    RETURN

;*******************************************************************************
; @brief Actualiza el promedio rápido y el promedio lento con CURRENT_ADC.
;*******************************************************************************
ACTUALIZAR_PROMEDIOS:
    BANKSEL FAST_L
    MOVLW   FAST_L
    MOVWF   FSR                 ; FSR apunta al promedio rápido
    MOVLW   FAST_SHIFT
    MOVWF   SHIFT_K
    CALL    EWMA_UPDATE

    MOVLW   SLOW_L
    MOVWF   FSR                 ; FSR apunta al promedio lento
    MOVLW   SLOW_SHIFT
    MOVWF   SHIFT_K
    CALL    EWMA_UPDATE
    RETURN

;*******************************************************************************
; @brief Actualiza un promedio exponencial de 16 bits.
;
; @details Entrada: FSR apunta a la parte baja del promedio (la parte alta está
;          en la dirección siguiente), SHIFT_K = k (entre 1 y 7) y CURRENT_ADC.
;          El promedio Y guarda la lectura x 256 (8 bits de parte entera y 8 de
;          fracción) y se actualiza así:
;               Y = Y - (Y >> k) + (CURRENT_ADC << (8 - k))
;          que equivale a  Y = Y + (X - Y) / 2^k  con X = CURRENT_ADC x 256.
;*******************************************************************************
EWMA_UPDATE:
    BANKSEL AUX_L

    ; AUX = Y
    MOVF    INDF, W
    MOVWF   AUX_L
    INCF    FSR, F
    MOVF    INDF, W
    MOVWF   AUX_H
    DECF    FSR, F

    ; AUX = AUX >> k
    MOVF    SHIFT_K, W
    MOVWF   LOOP_CNT
EW_SHR:
    BCF     STATUS, C
    RRF     AUX_H, F
    RRF     AUX_L, F
    DECFSZ  LOOP_CNT, F
    GOTO    EW_SHR

    ; Y = Y - AUX
    MOVF    AUX_L, W
    SUBWF   INDF, F             ; Y_L = Y_L - AUX_L (C=0 si hay préstamo)
    INCF    FSR, F
    BTFSS   STATUS, C
    DECF    INDF, F             ; Préstamo: Y_H = Y_H - 1
    MOVF    AUX_H, W
    SUBWF   INDF, F             ; Y_H = Y_H - AUX_H
    DECF    FSR, F

    ; AUX = CURRENT_ADC << (8 - k)
    CLRF    AUX_H
    MOVF    CURRENT_ADC, W
    MOVWF   AUX_L
    MOVF    SHIFT_K, W
    SUBLW   d'8'                ; W = 8 - k
    MOVWF   LOOP_CNT
EW_SHL:
    BCF     STATUS, C
    RLF     AUX_L, F
    RLF     AUX_H, F
    DECFSZ  LOOP_CNT, F
    GOTO    EW_SHL

    ; Y = Y + AUX
    MOVF    AUX_L, W
    ADDWF   INDF, F             ; Y_L = Y_L + AUX_L
    INCF    FSR, F
    BTFSC   STATUS, C
    INCF    INDF, F             ; Acarreo: Y_H = Y_H + 1
    MOVF    AUX_H, W
    ADDWF   INDF, F             ; Y_H = Y_H + AUX_H
    DECF    FSR, F
    RETURN

;*******************************************************************************
; @brief Indica si (promedio rápido - promedio lento) >= THR_CUENTAS.
;
; @details Salida: C = 1 si la diferencia es mayor o igual al umbral;
;          C = 0 si es menor (incluida una diferencia negativa).
;*******************************************************************************
DIFF_SOBRE_UMBRAL:
    BANKSEL FAST_H

    ; ¿promedio rápido >= promedio lento? (comparación de 16 bits)
    MOVF    SLOW_H, W
    SUBWF   FAST_H, W           ; W = FAST_H - SLOW_H
    BTFSS   STATUS, C
    GOTO    DSU_NO              ; FAST_H < SLOW_H: diferencia negativa
    BTFSS   STATUS, Z
    GOTO    DSU_CALCULAR        ; FAST_H > SLOW_H: diferencia positiva
    MOVF    SLOW_L, W
    SUBWF   FAST_L, W           ; FAST_H = SLOW_H: comparar partes bajas
    BTFSS   STATUS, C
    GOTO    DSU_NO

DSU_CALCULAR:
    ; DIFF_H = FAST_H - SLOW_H - préstamo de la parte baja
    MOVF    FAST_H, W
    MOVWF   DIFF_H
    MOVF    SLOW_H, W
    SUBWF   DIFF_H, F
    MOVF    SLOW_L, W
    SUBWF   FAST_L, W           ; C=0 si FAST_L < SLOW_L
    BTFSS   STATUS, C
    DECF    DIFF_H, F

    MOVLW   THR_CUENTAS
    SUBWF   DIFF_H, W           ; C=1 si DIFF_H >= THR_CUENTAS
    RETURN

DSU_NO:
    BCF     STATUS, C
    RETURN

;*******************************************************************************
; @brief Detección de latidos (se ejecuta una vez por tick en el estado 1).
;
; @details 1. Si el bloqueo está activo, lo descuenta y no evalúa nada.
;          2. Si el detector está armado (BEAT_LOCK = 0) y la diferencia supera
;             el umbral: latido nuevo.
;          3. Si ya contó el latido (BEAT_LOCK = 1): se rearma recién cuando la
;             diferencia vuelve a bajar del umbral.
;*******************************************************************************
DETECTAR_LATIDO:
    BANKSEL REFRACT
    MOVF    REFRACT, F
    BTFSC   STATUS, Z
    GOTO    DL_EVALUAR
    DECF    REFRACT, F          ; Bloqueo activo: se ignora esta muestra
    RETURN

DL_EVALUAR:
    CALL    DIFF_SOBRE_UMBRAL   ; C=1 si la diferencia >= umbral
    BANKSEL BEAT_LOCK
    MOVF    BEAT_LOCK, F
    BTFSS   STATUS, Z
    GOTO    DL_BLOQUEADO

    ; Armado: ¿supera el umbral?
    BTFSS   STATUS, C
    RETURN
    GOTO    LATIDO_DETECTADO

DL_BLOQUEADO:
    BTFSC   STATUS, C
    RETURN                      ; Sigue por encima del umbral: mismo latido
    CLRF    BEAT_LOCK           ; Bajó del umbral: se rearma
    RETURN

LATIDO_DETECTADO:
    BANKSEL PULSE_COUNT
    INCF    PULSE_COUNT, F      ; Cuenta el latido
    MOVLW   1
    MOVWF   BEAT_LOCK           ; No contar otro hasta que la diferencia baje
    MOVLW   REFRACT_TICKS
    MOVWF   REFRACT             ; Bloqueo de 250 ms
    MOVLW   LED_LIVE_TICKS
    MOVWF   LED_TIMER           ; Destello del LED rojo
    BANKSEL PORTB
    BSF     PORTB, 1
    RETURN

;*******************************************************************************
; @brief Apaga el LED rojo cuando termina su temporizador de destello.
;*******************************************************************************
LED_ROJO_TEMPORIZADO:
    BANKSEL LED_TIMER
    MOVF    LED_TIMER, F
    BTFSC   STATUS, Z
    RETURN                      ; Sin destello pendiente

    DECF    LED_TIMER, F
    BTFSS   STATUS, Z
    RETURN                      ; Todavía queda tiempo

    BANKSEL PORTB
    BCF     PORTB, 1            ; Terminó el destello: apaga el LED rojo
    RETURN

;*******************************************************************************
; @brief Display en espera: muestra G07 en los dígitos 1 a 3 (el 4 apagado).
;*******************************************************************************
MOSTRAR_G07:
    BANKSEL DSPL_1
    MOVLW   SEG_G
    MOVWF   DSPL_1
    MOVLW   d'0'
    CALL    TABLA_DECO
    MOVWF   DSPL_2
    MOVLW   d'7'
    CALL    TABLA_DECO
    MOVWF   DSPL_3
    MOVLW   SEG_OFF
    MOVWF   DSPL_4
    RETURN

;*******************************************************************************
; @brief Inicia la serpentina: segmento a en los 4 dígitos.
;
; @details SNAKE_PAT tiene un solo 0 (segmento encendido, lógica negativa):
;          0xFE = a, 0xFD = b, ... 0xBF = g.
;*******************************************************************************
SERPENTINA_INICIAR:
    BANKSEL SNAKE_PAT
    MOVLW   b'11111110'
    MOVWF   SNAKE_PAT
    MOVLW   SNAKE_TICKS
    MOVWF   SNAKE_TIMER
    GOTO    SERPENTINA_MOSTRAR

;*******************************************************************************
; @brief Avanza la serpentina un segmento cada SNAKE_TICKS ticks (a -> g -> a).
;
; @details Se rota SNAKE_PAT a la izquierda metiendo un 1 por la derecha. Tras
;          el segmento g (0xBF) la rotación da 0x7F (bit 7 = dp en 0): ahí se
;          vuelve a 0xFE, así el dp nunca se enciende.
;*******************************************************************************
SERPENTINA_AVANZAR:
    BANKSEL SNAKE_TIMER
    DECFSZ  SNAKE_TIMER, F
    RETURN                      ; Todavía no toca avanzar
    MOVLW   SNAKE_TICKS
    MOVWF   SNAKE_TIMER

    BSF     STATUS, C
    RLF     SNAKE_PAT, F
    BTFSC   SNAKE_PAT, 7        ; bit 7 = 1: sigue siendo a..g válido
    GOTO    SERPENTINA_MOSTRAR
    MOVLW   b'11111110'         ; Pasó de g: vuelve a a
    MOVWF   SNAKE_PAT

SERPENTINA_MOSTRAR:
    BANKSEL SNAKE_PAT
    MOVF    SNAKE_PAT, W
    MOVWF   DSPL_1
    MOVWF   DSPL_2
    MOVWF   DSPL_3
    MOVWF   DSPL_4
    RETURN

;*******************************************************************************
; @brief Muestra "F" en el dígito 1 y la frecuencia cardíaca en los dígitos 2 a 4.
;
; @details BPM = PULSE_COUNT x 4 (ventana de 15 s). Con el bloqueo de 250 ms
;          no pueden contarse más de 60 latidos en 15 s, así que BPM <= 240 y
;          entra en 8 bits. Si PULSE_COUNT = 0 (sin señal) muestra F---.
;*******************************************************************************
MOSTRAR_FRECUENCIA:
    BANKSEL PULSE_COUNT
    MOVF    PULSE_COUNT, W
    BTFSC   STATUS, Z
    GOTO    MF_SIN_SENAL

    MOVWF   BPM_VAL
    BCF     STATUS, C
    RLF     BPM_VAL, F          ; x2
    BCF     STATUS, C
    RLF     BPM_VAL, F          ; x4
    CALL    BIN_A_DEC

    MOVLW   SEG_F
    MOVWF   DSPL_1
    MOVF    HUNDREDS, W
    CALL    TABLA_DECO
    MOVWF   DSPL_2
    MOVF    TENS, W
    CALL    TABLA_DECO
    MOVWF   DSPL_3
    MOVF    UNITS, W
    CALL    TABLA_DECO
    MOVWF   DSPL_4
    RETURN

MF_SIN_SENAL:
    MOVLW   SEG_F
    MOVWF   DSPL_1
    MOVLW   SEG_DASH
    MOVWF   DSPL_2
    MOVWF   DSPL_3
    MOVWF   DSPL_4
    RETURN

;*******************************************************************************
; @brief Convierte BPM_VAL (0..255) a HUNDREDS, TENS y UNITS por restas
;        sucesivas. BPM_VAL queda con las unidades.
;*******************************************************************************
BIN_A_DEC:
    BANKSEL BPM_VAL
    CLRF    HUNDREDS
    CLRF    TENS
BD_CENTENAS:
    MOVLW   d'100'
    SUBWF   BPM_VAL, W          ; W = BPM_VAL - 100, C=1 si BPM_VAL >= 100
    BTFSS   STATUS, C
    GOTO    BD_DECENAS
    MOVWF   BPM_VAL
    INCF    HUNDREDS, F
    GOTO    BD_CENTENAS
BD_DECENAS:
    MOVLW   d'10'
    SUBWF   BPM_VAL, W
    BTFSS   STATUS, C
    GOTO    BD_UNIDADES
    MOVWF   BPM_VAL
    INCF    TENS, F
    GOTO    BD_DECENAS
BD_UNIDADES:
    MOVF    BPM_VAL, W
    MOVWF   UNITS
    RETURN

;===============================================================================
; TABLA DE SEGMENTOS (ÁNODO COMÚN, LÓGICA NEGATIVA)
;===============================================================================
; La rutina y la tabla se ubican juntas al inicio de una página de 256 palabras
; (ORG 0x0400) para que "ADDWF PCL" no cruce el límite de página: el salto
; calculado usa PCLATH como byte alto. Estas son las únicas instrucciones que
; modifican PCLATH; CALL y GOTO del resto del programa no se ven afectados
; (todo el código está por debajo de 0x0800).
;*******************************************************************************
; @brief Convierte un dígito decimal (W = 0..9) al patrón de segmentos.
;
; @details Entrada: W = 0..9. Salida: W = patrón (bit0 = a ... bit6 = g, dp = 1).
;*******************************************************************************
    ORG     0x0400
TABLA_DECO:
    BANKSEL TBL_IDX
    MOVWF   TBL_IDX
    MOVLW   HIGH TABLA_DECO
    MOVWF   PCLATH
    MOVF    TBL_IDX, W
    ADDWF   PCL, F              ; Salta a la entrada W de la tabla
    RETLW   0xC0                ; 0
    RETLW   0xF9                ; 1
    RETLW   0xA4                ; 2
    RETLW   0xB0                ; 3
    RETLW   0x99                ; 4
    RETLW   0x92                ; 5
    RETLW   0x82                ; 6
    RETLW   0xF8                ; 7
    RETLW   0x80                ; 8
    RETLW   0x90                ; 9

    END