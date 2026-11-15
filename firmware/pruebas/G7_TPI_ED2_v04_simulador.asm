;*******************************************************************************
; @brief       ANEXO B - FIRMWARE DEL SEP.
;
; @brief       Pulsómetro digital con alarma térmica (PIC16F887, cristal 4 MHz).
;
; @details     Versión 0.4: integra la placa del grupo (display en RC/RD, botón
;              y LEDs en PORTB, buzzer en RA4) con el resto del sistema.
;
;              - Timer0 (interrupción cada ~10 ms): base de tiempo de todo el
;                programa. Cada tick se lee el sensor de pulso (AN1) y cada
;                100 ms el LM35 (AN0).
;              - Timer1 (interrupción cada 5 ms): multiplexado de los 4 dígitos
;                (ánodo común, PNP BC557 en RC0-RC3, segmentos en RD0-RD6).
;              - EUSART 9600 8N1: envía tramas de texto a la GUI y recibe las
;                teclas '1', '2', 'A' y 'D'. La transmisión usa un buffer
;                circular de 32 bytes y la interrupción TXIF.
;              - Máquina de estados: ESPERA -> MIDIENDO (15 s) -> RESULTADO.
;              - Latidos: umbral alto y umbral bajo (histéresis) + 250 ms de
;                tiempo muerto. BPM = latidos en 15 s x 4.
;              - Alarma térmica: T > 40 °C enciende LED rojo (RE0) y buzzer
;                intermitente; se apaga con T <= 39 °C.
;
;              PROTOCOLO SERIE (PIC -> PC), cada trama termina en \r\n:
;                T=025     temperatura, cada 500 ms
;                S=0       en espera
;                S=1,12    midiendo, segundos que faltan
;                S=2       resultado listo
;                B=072     resultado en BPM
;                A=1 / A=0 alarma térmica activada / desactivada
;                P=128     muestra del sensor de pulso (solo en modo 'D')
;              PC -> PIC: '1' temperatura, '2' pulso, 'A' medir, 'D' depuración
;
; @author      G7_TPI_ED2
;
; @date        12/11/2026
;
; @version     0.4
;*******************************************************************************

;===============================================================================
; DIRECTIVAS DE INCLUSIÓN
;===============================================================================
    LIST P=16F887
#include "p16f887.inc"
    ERRORLEVEL -302             ;Oculta el aviso "register not in bank 0"

;===============================================================================
; CONFIGURACIÓN GENERAL DEL MCU
;===============================================================================
    __CONFIG _CONFIG1, _FOSC_XT & _WDTE_OFF & _PWRTE_ON & _MCLRE_ON & _CP_OFF & _CPD_OFF & _BOREN_OFF & _IESO_OFF & _FCMEN_OFF & _LVP_OFF
    __CONFIG _CONFIG2, _BOR4V_BOR40V & _WRT_OFF

;===============================================================================
; DEFINICIÓN DE CONSTANTES
;===============================================================================
;--- Bases de tiempo -----------------------------------------------------------
TMR0_PRECARGA   EQU D'100'      ;(256-100) x 64 us = 9,984 ms por tick
TMR1H_PRECARGA  EQU 0xEC        ;65536 - 0xEC78 = 5000 cuentas = 5 ms
TMR1L_PRECARGA  EQU 0x78
TICKS_100MS     EQU D'10'       ;10 ticks = 100 ms
BLOQUES_500MS   EQU D'5'        ;5 bloques de 100 ms = 500 ms
TICKS_1S        EQU D'100'      ;100 ticks = 1 s
VENTANA_SEG     EQU D'15'       ;Duración de la medición
PRESENT_100MS   EQU D'20'       ;"G07" durante 2 s al encender

;--- Detección de latidos (cuentas del ADC, 1 cuenta = 9,77 mV) ----------------
; El XD-58C/HW-827 tiene la salida centrada en 2,5 V; con el divisor 1/2 queda
; en ~1,25 V = 128 cuentas. AJUSTAR con la señal real (modo 'D' de la GUI).
UMBRAL_ALTO     EQU D'145'      ;Se cuenta un latido al llegar a este valor
UMBRAL_BAJO     EQU D'130'      ;Se rearma al bajar de este valor
TIEMPO_MUERTO   EQU D'25'       ;25 ticks = 250 ms sin contar otro latido
LED_LAT_TICKS   EQU D'6'        ;Destello del LED de latido: 60 ms
BEEP_TICKS      EQU D'10'       ;Pitido de inicio y fin: 100 ms
BPM_MIN         EQU D'50'       ;Rango normal de frecuencia cardíaca
BPM_MAX         EQU D'120'

;--- Alarma térmica (Vref+ = 2,50 V -> 1 cuenta = 0,977 °C) --------------------
ALARMA_ON       EQU D'41'       ;41 cuentas = 40,0 °C: T > 40 °C enciende
ALARMA_OFF      EQU D'40'       ;40 cuentas = 39,1 °C: T <= 39 °C apaga

;--- ADC: valores de ADCON0 (ADCS=01 Fosc/8, ADON=1) ---------------------------
ADC_AN0         EQU B'01000001' ;CHS=0000: LM35
ADC_AN1         EQU B'01000101' ;CHS=0001: sensor de pulso

;--- EUSART --------------------------------------------------------------------
SPBRG_9600      EQU D'25'       ;4 MHz / (16 x 26) = 9615 bps (BRGH = 1)
TX_BUF          EQU 0x50        ;Buffer de transmisión: 0x50 a 0x6F
TX_MASCARA      EQU 0x1F        ;32 posiciones -> índices de 0 a 31

;--- Estados y modos -----------------------------------------------------------
EST_ESPERA      EQU D'0'
EST_MIDIENDO    EQU D'1'
EST_RESULTADO   EQU D'2'
MODO_PULSO      EQU D'0'
MODO_TEMP       EQU D'1'

;--- Segmentos (ánodo común: 0 = encendido; bit0=a ... bit6=g, bit7=dp) --------
SEG_F           EQU 0x8E        ;a, e, f, g
SEG_G           EQU 0xC2        ;a, c, d, e, f
SEG_T           EQU 0x87        ;d, e, f, g
SEG_GUION       EQU 0xBF        ;g
SEG_APAGADO     EQU 0xFF

;--- Bits del registro FLAGS ---------------------------------------------------
F_TICK          EQU 0           ;Pasaron 10 ms (lo pone ISR_TMR0)
F_RX            EQU 1           ;Llegó un carácter (lo pone ISR_RX)
F_ARMADO        EQU 2           ;Detector listo para contar un latido
F_ALARMA        EQU 3           ;Alarma térmica activa
F_BOTON_ANT     EQU 4           ;Estado anterior del botón (1 = suelto)
F_DEBUG         EQU 5           ;Envío de muestras del sensor activado
F_FASE          EQU 6           ;Fase del buzzer intermitente (500 ms)
F_DIV           EQU 7           ;Divide por 2 el envío de muestras

;--- Pines (bloque del informe) ------------------------------------------------
#define BUZZER          PORTA,4 ;SSE.3.3 vía BC337 (SSE.5.1)
#define BOTON           PORTB,0 ;Botón de inicio (activo en bajo)
#define LED_LATIDO      PORTB,1 ;SSE.3.4 destella con cada latido
#define LED_RESULTADO   PORTB,2 ;SSE.3.4 resultado listo (verde)
#define LED_ALARMA      PORTE,0 ;SSE.3.4 alarma térmica (rojo)
#define LED_RANGO       PORTE,1 ;SSE.3.4 frecuencia fuera de rango

;===============================================================================
; DEFINICIÓN DE VARIABLES
;===============================================================================
    CBLOCK 0x20                 ;Banco 0
        FLAGS
        ESTADO                  ;EST_ESPERA, EST_MIDIENDO o EST_RESULTADO
        MODO                    ;MODO_PULSO o MODO_TEMP
        PRESENT_CONT            ;Bloques de 100 ms que quedan de "G07"
        CONT_100MS              ;Ticks dentro del bloque de 100 ms (0-9)
        CONT_500MS              ;Bloques de 100 ms dentro de 500 ms (0-4)
        CONT_1S                 ;Ticks dentro del segundo de medición (0-99)
        SEGUNDOS                ;Segundos que faltan de la medición
        MUESTRA                 ;Última lectura del sensor de pulso
        TEMP_C                  ;Última lectura del LM35 (cuentas ~ °C)
        PULSOS                  ;Latidos contados en la ventana
        BPM                     ;Resultado: PULSOS x 4
        MUERTO_CONT             ;Ticks que faltan de tiempo muerto
        LED_LAT_CONT            ;Ticks que faltan del destello de latido
        BEEP_CONT               ;Ticks que faltan del pitido
        CENTENAS                ;Resultado de BIN_A_DEC
        DECENAS
        UNIDADES
        BCD_AUX
        ADC_DEMORA              ;Demora de adquisición del ADC
        RX_DATO                 ;Último carácter recibido
        TX_IN                   ;Próxima posición libre del buffer TX
        TX_OUT                  ;Próximo carácter a enviar
        TX_SIG                  ;Auxiliar de UART_PUT
        TX_CHAR                 ;Carácter a encolar
        DSPL_1                  ;Segmentos del dígito 1 (izquierda)
        DSPL_2                  ;DSPL_1 a DSPL_4 deben ser contiguos:
        DSPL_3                  ;la ISR los recorre con FSR
        DSPL_4
        MUX_IDX                 ;Dígito que enciende la próxima ISR (0-3)
        MUX_MASK                ;Patrón de PORTC de ese dígito
        TBL_IDX                 ;Índice auxiliar de TABLA_DECO
    ENDC
    IF TBL_IDX >= TX_BUF
        ERROR "Las variables pisan el buffer de transmisión"
    ENDIF

    CBLOCK 0x70                 ;RAM compartida (visible desde todos los bancos)
        W_TEMP
        STATUS_TEMP
        FSR_TEMP
        PCLATH_TEMP
    ENDC

;===============================================================================
; DECLARACIÓN DE MACROS PARA CONFIGURACIÓN DE REGISTROS
;===============================================================================
;-------------------------------------------------------------------------------
; CONFIG_PUERTOS: entradas analógicas, sentido de los pines, pull-up de RB0.
;-------------------------------------------------------------------------------
CONFIG_PUERTOS  MACRO
    BANKSEL PORTA
    CLRF    PORTA               ;Buzzer apagado
    CLRF    PORTB               ;LEDs de PORTB apagados
    CLRF    PORTE               ;LEDs de PORTE apagados
    MOVLW   B'11111111'         ;Lógica negativa: dígitos y segmentos apagados
    MOVWF   PORTC
    MOVWF   PORTD
    BANKSEL ANSEL
    MOVLW   B'00001011'         ;AN0 (LM35), AN1 (pulso), AN3 (Vref+)
    MOVWF   ANSEL
    CLRF    ANSELH              ;PORTB digital
    BANKSEL TRISA
    MOVLW   B'11001011'         ;RA0, RA1, RA3 entradas; RA4 salida (buzzer)
    MOVWF   TRISA               ;RA6/RA7: cristal
    MOVLW   B'00000001'         ;RB0 entrada (botón); RB1, RB2 salidas (LEDs)
    MOVWF   TRISB
    MOVLW   B'11110000'         ;RC0-RC3 salidas (dígitos); RC6/RC7 EUSART
    MOVWF   TRISC
    CLRF    TRISD               ;RD0-RD7 salidas (segmentos)
    CLRF    TRISE               ;RE0, RE1 salidas (LEDs)
    MOVLW   B'00000001'         ;Pull-up interna solo en RB0
    MOVWF   WPUB
    BANKSEL PORTA
    ENDM

;-------------------------------------------------------------------------------
; CONFIG_ADC: Vref+ externa en RA3, resultado justificado a izquierda, AN1.
;-------------------------------------------------------------------------------
CONFIG_ADC      MACRO
    BANKSEL ADCON1
    MOVLW   B'00010000'         ;ADFM=0, VCFG1=0 (Vref- = GND), VCFG0=1 (RA3)
    MOVWF   ADCON1
    BANKSEL ADCON0
    MOVLW   ADC_AN1
    MOVWF   ADCON0
    ENDM

;-------------------------------------------------------------------------------
; CONFIG_TMR0: reloj interno, prescaler 1:64, pull-ups de PORTB habilitadas.
;-------------------------------------------------------------------------------
CONFIG_TMR0     MACRO
    BANKSEL OPTION_REG
    MOVLW   B'00000101'         ;RBPU=0, T0CS=0, PSA=0, PS=101 (1:64)
    MOVWF   OPTION_REG
    BANKSEL TMR0
    MOVLW   TMR0_PRECARGA
    MOVWF   TMR0
    ENDM

;-------------------------------------------------------------------------------
; CONFIG_TMR1: reloj interno, prescaler 1:1, 5 ms, encendido.
;-------------------------------------------------------------------------------
CONFIG_TMR1     MACRO
    BANKSEL T1CON
    MOVLW   TMR1H_PRECARGA
    MOVWF   TMR1H
    MOVLW   TMR1L_PRECARGA
    MOVWF   TMR1L
    MOVLW   B'00000001'         ;T1CKPS=00, TMR1CS=0, TMR1ON=1
    MOVWF   T1CON
    ENDM

;-------------------------------------------------------------------------------
; CONFIG_EUSART: asíncrona, 9600 bps, 8N1, transmisión y recepción.
;-------------------------------------------------------------------------------
CONFIG_EUSART   MACRO
    BANKSEL BAUDCTL
    BCF     BAUDCTL,BRG16       ;Generador de baudios de 8 bits
    BANKSEL SPBRG
    MOVLW   SPBRG_9600
    MOVWF   SPBRG
    CLRF    SPBRGH
    MOVLW   B'00100100'         ;TXEN=1, SYNC=0, BRGH=1
    MOVWF   TXSTA
    BANKSEL RCSTA
    MOVLW   B'10010000'         ;SPEN=1, CREN=1
    MOVWF   RCSTA
    ENDM

;-------------------------------------------------------------------------------
; INIT_VARIABLES: estado inicial del programa.
;-------------------------------------------------------------------------------
INIT_VARIABLES  MACRO
    BANKSEL FLAGS
    MOVLW   FLAGS
    MOVWF   FSR                 ;Pone en 0 desde FLAGS hasta TBL_IDX
INIT_LIMPIAR
    CLRF    INDF
    INCF    FSR,F
    MOVF    FSR,W
    XORLW   TBL_IDX + 1
    BTFSS   STATUS,Z
    GOTO    INIT_LIMPIAR
    BSF     FLAGS,F_BOTON_ANT   ;El botón arranca suelto
    MOVLW   PRESENT_100MS
    MOVWF   PRESENT_CONT
    MOVLW   B'11111110'
    MOVWF   MUX_MASK            ;El multiplexado arranca por el dígito 1
    ENDM

;-------------------------------------------------------------------------------
; CONFIG_INTERRUPCIONES: Timer0, Timer1 y recepción serie. TXIE lo maneja
; UART_PUT / ISR_TX según haya o no datos para enviar.
;-------------------------------------------------------------------------------
CONFIG_INTERRUPCIONES MACRO
    BANKSEL PIE1
    BSF     PIE1,TMR1IE
    BSF     PIE1,RCIE
    BANKSEL PIR1
    BCF     PIR1,TMR1IF
    MOVLW   B'11100000'         ;GIE=1, PEIE=1, T0IE=1
    MOVWF   INTCON
    ENDM

;===============================================================================
; INICIALIZACIÓN DEL MCU (CÓDIGO ABSOLUTO)
;===============================================================================
    ORG     0x00                ;Vector de Reset
    GOTO    INICIO
    ORG     0x04                ;Vector de Interrupción
    GOTO    ISR_INICIO
    ORG     0x05

;===============================================================================
; INICIALIZACIÓN DE MACROS PARA CONFIGURACIÓN DE REGISTROS
;===============================================================================
INICIO
    CONFIG_PUERTOS
    CONFIG_ADC
    CONFIG_TMR0
    CONFIG_TMR1
    CONFIG_EUSART
    INIT_VARIABLES
    CALL    MOSTRAR_G07         ;El display ya tiene datos válidos
    MOVLW   '0'
    CALL    ENVIAR_ESTADO       ;"S=0": en espera
    CONFIG_INTERRUPCIONES       ;Última: recién acá arrancan las ISR

;===============================================================================
; INICIO PROGRAMA PRINCIPAL
;===============================================================================
MAIN_LOOP
    BTFSC   FLAGS,F_RX          ;¿Llegó una tecla desde la GUI?
    CALL    PROCESAR_RX
    BTFSS   FLAGS,F_TICK        ;¿Pasaron 10 ms?
    GOTO    MAIN_LOOP
    BCF     FLAGS,F_TICK
    CALL    TAREA_10MS
    GOTO    MAIN_LOOP

;===============================================================================
; INICIALIZACIÓN DE RUTINAS DE SERVICIO DE INTERRUPCIÓN
;===============================================================================
ISR_INICIO
    ;----------Guardado de Contexto----------
    MOVWF   W_TEMP
    SWAPF   STATUS,W
    CLRF    STATUS              ;Banco 0, IRP = 0
    MOVWF   STATUS_TEMP
    MOVF    PCLATH,W
    MOVWF   PCLATH_TEMP
    CLRF    PCLATH
    MOVF    FSR,W
    MOVWF   FSR_TEMP
    ;----------------------------------------
    ;-----Identificación de Interrupción-----
    BTFSC   INTCON,T0IF         ;¿Timer0? (base de 10 ms)
    GOTO    ISR_TMR0
    BTFSC   PIR1,TMR1IF         ;¿Timer1? (multiplexado)
    GOTO    ISR_TMR1
    BTFSC   PIR1,RCIF           ;¿Llegó un carácter?
    GOTO    ISR_RX
    BTFSS   PIR1,TXIF           ;¿TXREG libre?...
    GOTO    ISR_FIN
    BANKSEL PIE1
    BTFSC   PIE1,TXIE           ;...¿y hay datos esperando? (TXIE = 1)
    GOTO    ISR_TX
    GOTO    ISR_FIN
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
    SWAPF   STATUS_TEMP,W
    MOVWF   STATUS
    SWAPF   W_TEMP,F
    SWAPF   W_TEMP,W
    RETFIE
    ;----------------------------------------

;*******************************************************************************
; @brief    ISR_TMR0: base de tiempo de 10 ms. Solo avisa con F_TICK.
;*******************************************************************************
ISR_TMR0
    BCF     INTCON,T0IF
    MOVLW   TMR0_PRECARGA
    MOVWF   TMR0
    BSF     FLAGS,F_TICK
    GOTO    ISR_FIN

;*******************************************************************************
; @brief    ISR_TMR1: multiplexado, un dígito cada 5 ms (código de la placa).
;
; @details  Apaga los 4 dígitos, carga los segmentos del dígito actual
;           (DSPL_1 + MUX_IDX) y recién después lo habilita.
;*******************************************************************************
ISR_TMR1
    BCF     PIR1,TMR1IF
    MOVLW   TMR1H_PRECARGA
    MOVWF   TMR1H
    MOVLW   TMR1L_PRECARGA
    MOVWF   TMR1L
    MOVLW   B'11111111'
    MOVWF   PORTC               ;Todos los dígitos apagados
    MOVLW   DSPL_1
    ADDWF   MUX_IDX,W
    MOVWF   FSR                 ;FSR = &DSPL_1 + MUX_IDX
    MOVF    INDF,W
    MOVWF   PORTD               ;Segmentos del dígito actual
    MOVF    MUX_MASK,W
    MOVWF   PORTC               ;Habilita el dígito actual
    INCF    MUX_IDX,F
    BSF     STATUS,C
    RLF     MUX_MASK,F          ;Corre el 0 al dígito siguiente
    MOVF    MUX_IDX,W
    XORLW   D'4'
    BTFSS   STATUS,Z
    GOTO    ISR_FIN
    CLRF    MUX_IDX             ;Después del dígito 4 vuelve al 1
    MOVLW   B'11111110'
    MOVWF   MUX_MASK
    GOTO    ISR_FIN

;*******************************************************************************
; @brief    ISR_RX: guarda el carácter recibido y avisa con F_RX.
;
; @details  Si hubo desborde (OERR), la recepción se reinicia con CREN.
;*******************************************************************************
ISR_RX
    BTFSS   RCSTA,OERR
    GOTO    ISR_RX_LEER
    BCF     RCSTA,CREN          ;Desborde: reiniciar la recepción
    BSF     RCSTA,CREN
ISR_RX_LEER
    MOVF    RCREG,W             ;Leer RCREG baja RCIF
    MOVWF   RX_DATO
    BSF     FLAGS,F_RX
    GOTO    ISR_FIN

;*******************************************************************************
; @brief    ISR_TX: envía el próximo carácter del buffer circular.
;
; @details  Si el buffer quedó vacío (TX_OUT = TX_IN), apaga TXIE para que
;           TXIF no siga pidiendo interrupciones.
;*******************************************************************************
ISR_TX
    BANKSEL TX_OUT
    MOVF    TX_OUT,W
    XORWF   TX_IN,W             ;¿TX_OUT = TX_IN?
    BTFSS   STATUS,Z
    GOTO    ISR_TX_ENVIAR
    BANKSEL PIE1
    BCF     PIE1,TXIE           ;Vacío: no hay nada más que enviar
    GOTO    ISR_FIN
ISR_TX_ENVIAR
    MOVF    TX_OUT,W
    ADDLW   TX_BUF
    MOVWF   FSR                 ;FSR = &TX_BUF[TX_OUT]
    MOVF    INDF,W
    MOVWF   TXREG               ;Escribir TXREG baja TXIF
    INCF    TX_OUT,W
    ANDLW   TX_MASCARA          ;31 + 1 vuelve a 0
    MOVWF   TX_OUT
    GOTO    ISR_FIN

;===============================================================================
; SUBRUTINAS
;===============================================================================
;*******************************************************************************
; @brief    TAREA_10MS: lo que se hace en cada tick de Timer0.
;*******************************************************************************
TAREA_10MS
    MOVLW   ADC_AN1
    CALL    ADC_LEER            ;W = muestra del sensor de pulso
    MOVWF   MUESTRA
    CALL    LEER_BOTON
    MOVF    ESTADO,W
    XORLW   EST_MIDIENDO        ;¿Midiendo?
    BTFSC   STATUS,Z
    CALL    TAREA_MEDICION
    BTFSC   FLAGS,F_DEBUG       ;¿Modo depuración?
    CALL    ENVIAR_MUESTRA
    CALL    ACTUALIZAR_SALIDAS  ;LED de latido y buzzer
    INCF    CONT_100MS,F
    MOVF    CONT_100MS,W
    XORLW   TICKS_100MS         ;¿Pasaron 100 ms?
    BTFSS   STATUS,Z
    RETURN
    CLRF    CONT_100MS
    CALL    TAREA_100MS
    RETURN

;*******************************************************************************
; @brief    TAREA_100MS: temperatura, alarma y display.
;*******************************************************************************
TAREA_100MS
    MOVLW   ADC_AN0
    CALL    ADC_LEER            ;W = LM35 (cuentas ~ °C)
    MOVWF   TEMP_C
    CALL    EVALUAR_ALARMA
    MOVF    PRESENT_CONT,F      ;¿Sigue la presentación "G07"?
    BTFSS   STATUS,Z
    DECF    PRESENT_CONT,F
    CALL    ACTUALIZAR_DISPLAY
    INCF    CONT_500MS,F
    MOVF    CONT_500MS,W
    XORLW   BLOQUES_500MS       ;¿Pasaron 500 ms?
    BTFSS   STATUS,Z
    RETURN
    CLRF    CONT_500MS
    MOVLW   1 << F_FASE
    XORWF   FLAGS,F             ;Invierte la fase del buzzer intermitente
    CALL    ENVIAR_TEMP         ;"T=025"
    RETURN

;*******************************************************************************
; @brief    TAREA_MEDICION: cada tick mientras se mide.
;
; @details  Detecta latidos y lleva la cuenta regresiva de 15 s.
;*******************************************************************************
TAREA_MEDICION
    CALL    DETECTAR_LATIDO
    INCF    CONT_1S,F
    MOVF    CONT_1S,W
    XORLW   TICKS_1S            ;¿Pasó 1 s?
    BTFSS   STATUS,Z
    RETURN
    CLRF    CONT_1S
    DECFSZ  SEGUNDOS,F          ;Un segundo menos; ¿llegó a 0?
    GOTO    ENVIAR_MIDIENDO     ;No: "S=1,ss" (vuelve desde ahí)
    GOTO    FIN_MEDICION        ;Sí: calcular el resultado

;*******************************************************************************
; @brief    DETECTAR_LATIDO: umbral alto + umbral bajo + tiempo muerto.
;
; @details  - Desarmado (F_ARMADO = 0): espera a que la señal baje de
;             UMBRAL_BAJO y recién ahí se arma.
;           - Armado: si pasó el tiempo muerto y la señal llega a UMBRAL_ALTO,
;             cuenta un latido, se desarma y arranca 250 ms de tiempo muerto.
;           Así, un pico con ruido que cruza el umbral varias veces cuenta
;           una sola vez.
;*******************************************************************************
DETECTAR_LATIDO
    MOVF    MUERTO_CONT,F
    BTFSS   STATUS,Z
    DECF    MUERTO_CONT,F       ;Descuenta el tiempo muerto
    BTFSC   FLAGS,F_ARMADO
    GOTO    DL_ARMADO
    MOVLW   UMBRAL_BAJO
    SUBWF   MUESTRA,W           ;C = 1 si MUESTRA >= UMBRAL_BAJO
    BTFSS   STATUS,C
    BSF     FLAGS,F_ARMADO      ;Bajó del umbral bajo: se arma
    RETURN
DL_ARMADO
    MOVF    MUERTO_CONT,F
    BTFSS   STATUS,Z            ;¿Terminó el tiempo muerto?
    RETURN
    MOVLW   UMBRAL_ALTO
    SUBWF   MUESTRA,W           ;C = 1 si MUESTRA >= UMBRAL_ALTO
    BTFSS   STATUS,C
    RETURN
    INCF    PULSOS,F            ;¡Latido!
    BCF     FLAGS,F_ARMADO
    MOVLW   TIEMPO_MUERTO
    MOVWF   MUERTO_CONT
    MOVLW   LED_LAT_TICKS
    MOVWF   LED_LAT_CONT
    BSF     LED_LATIDO
    RETURN

;*******************************************************************************
; @brief    INICIAR_MEDICION: arranca (o reinicia) una medición de 15 s.
;*******************************************************************************
INICIAR_MEDICION
    MOVLW   EST_MIDIENDO
    MOVWF   ESTADO
    MOVLW   VENTANA_SEG
    MOVWF   SEGUNDOS
    CLRF    CONT_1S
    CLRF    PULSOS
    CLRF    MUERTO_CONT
    CLRF    PRESENT_CONT        ;Corta la presentación si seguía
    BCF     FLAGS,F_ARMADO      ;Espera a que la señal baje antes de contar
    BCF     LED_RESULTADO
    BCF     LED_RANGO
    MOVLW   BEEP_TICKS
    MOVWF   BEEP_CONT           ;Pitido de inicio
    CALL    ACTUALIZAR_DISPLAY
    GOTO    ENVIAR_MIDIENDO     ;"S=1,15" (vuelve desde ahí)

;*******************************************************************************
; @brief    FIN_MEDICION: calcula BPM, evalúa el rango y avisa a la GUI.
;
; @details  BPM = PULSOS x 4 (dos rotaciones a la izquierda). Con 250 ms de
;           tiempo muerto entran como máximo 60 latidos en 15 s: BPM <= 240.
;*******************************************************************************
FIN_MEDICION
    MOVF    PULSOS,W
    MOVWF   BPM
    BCF     STATUS,C
    RLF     BPM,F               ;x 2
    BCF     STATUS,C
    RLF     BPM,F               ;x 4
    MOVLW   EST_RESULTADO
    MOVWF   ESTADO
    BSF     LED_RESULTADO
    MOVLW   BEEP_TICKS
    MOVWF   BEEP_CONT           ;Pitido de fin
    MOVF    PULSOS,F            ;Sin latidos: no se evalúa el rango
    BTFSC   STATUS,Z
    GOTO    FM_AVISAR
    MOVLW   BPM_MIN
    SUBWF   BPM,W               ;C = 0 si BPM < 50
    BTFSS   STATUS,C
    BSF     LED_RANGO
    MOVF    BPM,W
    SUBLW   BPM_MAX             ;W = 120 - BPM; C = 0 si BPM > 120
    BTFSS   STATUS,C
    BSF     LED_RANGO
FM_AVISAR
    CALL    ACTUALIZAR_DISPLAY
    CALL    ENVIAR_BPM          ;"B=072"
    MOVLW   '2'
    GOTO    ENVIAR_ESTADO       ;"S=2" (vuelve desde ahí)

;*******************************************************************************
; @brief    LEER_BOTON: inicia una medición al apretar RB0 (flanco de bajada).
;
; @details  Se lee cada 10 ms, lo que ya filtra la mayor parte del rebote.
;*******************************************************************************
LEER_BOTON
    BTFSC   BOTON               ;¿Apretado? (0 = apretado)
    GOTO    LB_SUELTO
    BTFSC   FLAGS,F_BOTON_ANT   ;Apretado ahora y suelto antes: flanco
    CALL    INICIAR_MEDICION
    BCF     FLAGS,F_BOTON_ANT
    RETURN
LB_SUELTO
    BSF     FLAGS,F_BOTON_ANT
    RETURN

;*******************************************************************************
; @brief    PROCESAR_RX: ejecuta la tecla recibida desde la GUI.
;*******************************************************************************
PROCESAR_RX
    BCF     FLAGS,F_RX
    MOVF    RX_DATO,W
    XORLW   'A'
    BTFSC   STATUS,Z
    GOTO    INICIAR_MEDICION
    MOVF    RX_DATO,W
    XORLW   'a'
    BTFSC   STATUS,Z
    GOTO    INICIAR_MEDICION
    MOVF    RX_DATO,W
    XORLW   '1'
    BTFSC   STATUS,Z
    GOTO    PR_TEMP
    MOVF    RX_DATO,W
    XORLW   '2'
    BTFSC   STATUS,Z
    GOTO    PR_PULSO
    MOVF    RX_DATO,W
    XORLW   'D'
    BTFSC   STATUS,Z
    GOTO    PR_DEBUG
    MOVF    RX_DATO,W
    XORLW   'd'
    BTFSC   STATUS,Z
    GOTO    PR_DEBUG
    RETURN                      ;Otra tecla: se ignora
PR_TEMP
    MOVLW   MODO_TEMP
    MOVWF   MODO
    GOTO    ACTUALIZAR_DISPLAY
PR_PULSO
    MOVLW   MODO_PULSO
    MOVWF   MODO
    GOTO    ACTUALIZAR_DISPLAY
PR_DEBUG
    MOVLW   1 << F_DEBUG
    XORWF   FLAGS,F             ;Activa o desactiva el envío de muestras
    RETURN

;*******************************************************************************
; @brief    EVALUAR_ALARMA: alarma térmica con histéresis.
;*******************************************************************************
EVALUAR_ALARMA
    BTFSC   FLAGS,F_ALARMA
    GOTO    EA_ACTIVA
    MOVLW   ALARMA_ON
    SUBWF   TEMP_C,W            ;C = 1 si TEMP_C >= 41
    BTFSS   STATUS,C
    RETURN
    BSF     FLAGS,F_ALARMA
    BSF     LED_ALARMA
    MOVLW   '1'
    GOTO    ENVIAR_ALARMA       ;"A=1"
EA_ACTIVA
    MOVF    TEMP_C,W
    SUBLW   ALARMA_OFF          ;W = 40 - TEMP_C; C = 1 si TEMP_C <= 40
    BTFSS   STATUS,C
    RETURN
    BCF     FLAGS,F_ALARMA
    BCF     LED_ALARMA
    MOVLW   '0'
    GOTO    ENVIAR_ALARMA       ;"A=0"

;*******************************************************************************
; @brief    ACTUALIZAR_SALIDAS: LED de latido y buzzer, cada 10 ms.
;
; @details  Buzzer encendido si hay un pitido en curso, o si hay alarma y la
;           fase de 500 ms está en 1 (intermitente).
;*******************************************************************************
ACTUALIZAR_SALIDAS
    MOVF    LED_LAT_CONT,F
    BTFSC   STATUS,Z
    GOTO    AS_BUZZER
    DECFSZ  LED_LAT_CONT,F
    GOTO    AS_BUZZER
    BCF     LED_LATIDO          ;Terminó el destello
AS_BUZZER
    MOVF    BEEP_CONT,F
    BTFSC   STATUS,Z
    GOTO    AS_SIN_BEEP
    DECF    BEEP_CONT,F
    GOTO    AS_BUZZ_ON
AS_SIN_BEEP
    BTFSS   FLAGS,F_ALARMA
    GOTO    AS_BUZZ_OFF
    BTFSS   FLAGS,F_FASE
    GOTO    AS_BUZZ_OFF
AS_BUZZ_ON
    BSF     BUZZER
    RETURN
AS_BUZZ_OFF
    BCF     BUZZER
    RETURN

;*******************************************************************************
; @brief    ADC_LEER: convierte el canal indicado en W (valor de ADCON0).
;
; @details  Espera ~20 us de adquisición (necesaria al cambiar de canal),
;           arranca la conversión y devuelve ADRESH en W.
;*******************************************************************************
ADC_LEER
    MOVWF   ADCON0              ;Elige el canal
    MOVLW   D'7'
    MOVWF   ADC_DEMORA
AL_ADQUISICION
    DECFSZ  ADC_DEMORA,F        ;7 vueltas x 3 us = ~20 us
    GOTO    AL_ADQUISICION
    BSF     ADCON0,GO           ;Arranca la conversión
AL_ESPERA
    BTFSC   ADCON0,GO           ;GO vuelve a 0 al terminar
    GOTO    AL_ESPERA
    MOVF    ADRESH,W
    RETURN

;*******************************************************************************
; @brief    ACTUALIZAR_DISPLAY: elige qué mostrar según estado y modo.
;
; @details  Presentación -> "G07"; midiendo -> cuenta regresiva;
;           modo temperatura -> "t 25"; resultado -> "F072"; espera -> "F---".
;*******************************************************************************
ACTUALIZAR_DISPLAY
    MOVF    PRESENT_CONT,F
    BTFSS   STATUS,Z
    GOTO    MOSTRAR_G07
    MOVF    ESTADO,W
    XORLW   EST_MIDIENDO
    BTFSC   STATUS,Z
    GOTO    MOSTRAR_CUENTA
    MOVF    MODO,W
    XORLW   MODO_TEMP
    BTFSC   STATUS,Z
    GOTO    MOSTRAR_TEMP
    MOVF    ESTADO,W
    XORLW   EST_RESULTADO
    BTFSC   STATUS,Z
    GOTO    MOSTRAR_FRECUENCIA
    GOTO    MOSTRAR_SIN_DATO

MOSTRAR_G07
    MOVLW   SEG_G
    MOVWF   DSPL_1
    MOVLW   D'0'
    CALL    TABLA_DECO
    MOVWF   DSPL_2
    MOVLW   D'7'
    CALL    TABLA_DECO
    MOVWF   DSPL_3
    MOVLW   SEG_APAGADO
    MOVWF   DSPL_4
    RETURN

MOSTRAR_CUENTA                  ;"  15" ... "   1"
    MOVLW   SEG_APAGADO
    MOVWF   DSPL_1
    MOVWF   DSPL_2
    MOVF    SEGUNDOS,W
    CALL    BIN_A_DEC
    MOVF    DECENAS,W
    CALL    DIGITO_O_APAGADO
    MOVWF   DSPL_3
    MOVF    UNIDADES,W
    CALL    TABLA_DECO
    MOVWF   DSPL_4
    RETURN

MOSTRAR_TEMP                    ;"t 25"
    MOVLW   SEG_T
    MOVWF   DSPL_1
    MOVF    TEMP_C,W
    CALL    BIN_A_DEC
    MOVF    CENTENAS,W
    CALL    DIGITO_O_APAGADO
    MOVWF   DSPL_2
    MOVF    DECENAS,W
    CALL    TABLA_DECO
    MOVWF   DSPL_3
    MOVF    UNIDADES,W
    CALL    TABLA_DECO
    MOVWF   DSPL_4
    RETURN

MOSTRAR_FRECUENCIA              ;"F072" (o "F---" sin latidos)
    MOVF    PULSOS,F
    BTFSC   STATUS,Z
    GOTO    MOSTRAR_SIN_DATO
    MOVLW   SEG_F
    MOVWF   DSPL_1
    MOVF    BPM,W
    CALL    BIN_A_DEC
    MOVF    CENTENAS,W
    CALL    TABLA_DECO
    MOVWF   DSPL_2
    MOVF    DECENAS,W
    CALL    TABLA_DECO
    MOVWF   DSPL_3
    MOVF    UNIDADES,W
    CALL    TABLA_DECO
    MOVWF   DSPL_4
    RETURN

MOSTRAR_SIN_DATO                ;"F---"
    MOVLW   SEG_F
    MOVWF   DSPL_1
    MOVLW   SEG_GUION
    MOVWF   DSPL_2
    MOVWF   DSPL_3
    MOVWF   DSPL_4
    RETURN

;*******************************************************************************
; @brief    DIGITO_O_APAGADO: como TABLA_DECO, pero un 0 se muestra apagado.
;*******************************************************************************
DIGITO_O_APAGADO
    ANDLW   0xFF                ;Z = 1 si W = 0
    BTFSC   STATUS,Z
    RETLW   SEG_APAGADO
    GOTO    TABLA_DECO

;*******************************************************************************
; @brief    BIN_A_DEC: separa W (0-255) en CENTENAS, DECENAS y UNIDADES
;           por restas sucesivas.
;*******************************************************************************
BIN_A_DEC
    MOVWF   BCD_AUX
    CLRF    CENTENAS
    CLRF    DECENAS
BD_CENTENAS
    MOVLW   D'100'
    SUBWF   BCD_AUX,W           ;C = 1 si BCD_AUX >= 100
    BTFSS   STATUS,C
    GOTO    BD_DECENAS
    MOVWF   BCD_AUX
    INCF    CENTENAS,F
    GOTO    BD_CENTENAS
BD_DECENAS
    MOVLW   D'10'
    SUBWF   BCD_AUX,W
    BTFSS   STATUS,C
    GOTO    BD_UNIDADES
    MOVWF   BCD_AUX
    INCF    DECENAS,F
    GOTO    BD_DECENAS
BD_UNIDADES
    MOVF    BCD_AUX,W
    MOVWF   UNIDADES
    RETURN

;*******************************************************************************
; @brief    Tramas hacia la GUI. Todas terminan con UART_CRLF.
;*******************************************************************************
ENVIAR_TEMP                     ;"T=025"
    MOVLW   'T'
    CALL    UART_PUT
    MOVLW   '='
    CALL    UART_PUT
    MOVF    TEMP_C,W
    CALL    UART_3DIG
    GOTO    UART_CRLF

ENVIAR_BPM                      ;"B=072"
    MOVLW   'B'
    CALL    UART_PUT
    MOVLW   '='
    CALL    UART_PUT
    MOVF    BPM,W
    CALL    UART_3DIG
    GOTO    UART_CRLF

ENVIAR_MUESTRA                  ;"P=128", una de cada dos muestras (50 Hz)
    MOVLW   1 << F_DIV
    XORWF   FLAGS,F
    BTFSS   FLAGS,F_DIV
    RETURN
    MOVLW   'P'
    CALL    UART_PUT
    MOVLW   '='
    CALL    UART_PUT
    MOVF    MUESTRA,W
    CALL    UART_3DIG
    GOTO    UART_CRLF

ENVIAR_MIDIENDO                 ;"S=1,ss"
    MOVLW   'S'
    CALL    UART_PUT
    MOVLW   '='
    CALL    UART_PUT
    MOVLW   '1'
    CALL    UART_PUT
    MOVLW   ','
    CALL    UART_PUT
    MOVF    SEGUNDOS,W
    CALL    BIN_A_DEC
    MOVF    DECENAS,W
    ADDLW   '0'
    CALL    UART_PUT
    MOVF    UNIDADES,W
    ADDLW   '0'
    CALL    UART_PUT
    CALL    ACTUALIZAR_DISPLAY
    GOTO    UART_CRLF

ENVIAR_ESTADO                   ;"S=" + W ('0' o '2')
    MOVWF   TX_CHAR
    MOVLW   'S'
    GOTO    ENVIAR_PAR

ENVIAR_ALARMA                   ;"A=" + W ('0' o '1')
    MOVWF   TX_CHAR
    MOVLW   'A'
ENVIAR_PAR                      ;Letra en W, valor en TX_CHAR
    MOVWF   BCD_AUX             ;(TX_CHAR lo usa UART_PUT)
    MOVF    TX_CHAR,W
    MOVWF   UNIDADES
    MOVF    BCD_AUX,W
    CALL    UART_PUT
    MOVLW   '='
    CALL    UART_PUT
    MOVF    UNIDADES,W
    CALL    UART_PUT
    GOTO    UART_CRLF

;*******************************************************************************
; @brief    UART_3DIG: encola W (0-255) como tres dígitos ASCII.
;*******************************************************************************
UART_3DIG
    CALL    BIN_A_DEC
    MOVF    CENTENAS,W
    ADDLW   '0'                 ;Número -> carácter ASCII
    CALL    UART_PUT
    MOVF    DECENAS,W
    ADDLW   '0'
    CALL    UART_PUT
    MOVF    UNIDADES,W
    ADDLW   '0'
    GOTO    UART_PUT

;*******************************************************************************
; @brief    UART_CRLF: encola el fin de trama "\r\n".
;*******************************************************************************
UART_CRLF
    MOVLW   0x0D                ;\r
    CALL    UART_PUT
    MOVLW   0x0A                ;\n
    GOTO    UART_PUT

;*******************************************************************************
; @brief    UART_PUT: agrega W al buffer circular y habilita TXIE.
;
; @details  No espera a que salga el carácter: lo envía ISR_TX. Si el buffer
;           está lleno, el carácter se descarta.
;*******************************************************************************
UART_PUT
    MOVWF   TX_CHAR
    INCF    TX_IN,W
    ANDLW   TX_MASCARA
    MOVWF   TX_SIG              ;Posición siguiente a TX_IN
    XORWF   TX_OUT,W            ;¿Alcanzaría a TX_OUT?
    BTFSC   STATUS,Z
    RETURN                      ;Lleno: se descarta
    MOVF    TX_IN,W
    ADDLW   TX_BUF
    MOVWF   FSR
    BCF     STATUS,IRP
    MOVF    TX_CHAR,W
    MOVWF   INDF                ;TX_BUF[TX_IN] = carácter
    MOVF    TX_SIG,W
    MOVWF   TX_IN               ;Recién ahora queda visible para la ISR
    BANKSEL PIE1
    BSF     PIE1,TXIE           ;Pide la interrupción de transmisión
    BANKSEL FLAGS
    RETURN

;===============================================================================
; TABLA DE SEGMENTOS (código de la placa)
;===============================================================================
; Ubicada en 0x0400 para que ADDWF PCL no cruce un límite de 256 palabras.
; Carga PCLATH antes del salto; los CALL y GOTO del resto del programa no se
; ven afectados porque todo el código está por debajo de 0x0800.
;*******************************************************************************
; @brief    TABLA_DECO: dígito (W = 0-9) -> segmentos (ánodo común).
;*******************************************************************************
    ORG     0x0400
TABLA_DECO
    MOVWF   TBL_IDX
    MOVLW   HIGH TABLA_DECO
    MOVWF   PCLATH
    MOVF    TBL_IDX,W
    ADDWF   PCL,F
    RETLW   0xC0                ;0
    RETLW   0xF9                ;1
    RETLW   0xA4                ;2
    RETLW   0xB0                ;3
    RETLW   0x99                ;4
    RETLW   0x92                ;5
    RETLW   0x82                ;6
    RETLW   0xF8                ;7
    RETLW   0x80                ;8
    RETLW   0x90                ;9

;===============================================================================
    END
;===============================================================================
