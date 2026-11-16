;===============================================================================
; @file     TPI
; @author   Marquez_Lionel, Rodriguez_Octavio, Pandolfi_Luigi_Nicola
; @date     14/11/2026
; @version  1.1
; @brief    Monitor de Temperatura y Frecuencia Cardíaca
;===============================================================================

;===============================================================================
; DIRECTIVAS DE INCLUSIÓN Y CONFIGURACIÓN
;===============================================================================
    LIST P=16F887
    #include "p16f887.inc"

; Bits de configuración simplificados para compatibilidad MPASM
    __CONFIG _CONFIG1, _XT_OSC & _WDTE_OFF & _PWRTE_ON & _MCLRE_ON & _LVP_OFF
    __CONFIG _CONFIG2, _WRT_OFF

;===============================================================================
; DEFINICIÓN DE CONSTANTES Y PINES
;===============================================================================
#Define BUZZER      PORTC,4     ; Buzzer activo de alarma térmica (RC4)
#Define LED_PULSE   PORTE,0     ; LED Indicador de Latido Vivo (RE0)
#Define DISP_D1     PORTC,0     ; Control Dígito 1 Display
#Define DISP_D2     PORTC,1     ; Control Dígito 2 Display
#Define DISP_D3     PORTC,2     ; Control Dígito 3 Display
#Define DISP_D4     PORTC,3     ; Control Dígito 4 Display

;===============================================================================
; DEFINICIÓN DE VARIABLES EN RAM
;===============================================================================
    CBLOCK 0X20
        ADC_BURST_STATE         ; Estado ráfaga ADC: 0=AN0 (Temp), 1=AN1 (Pulso)
        VAL_TEMP                ; Valor leído de temperatura (°C)
        VAL_PULSE               ; Valor analógico instantáneo del pulso
        BPM_VAL                 ; Valor calculado de BPM
        MODE_SEL                ; Modo Display: 0 = BPM, 1 = Temp
        DIGIT_SEL               ; Índice de dígito multiplexado (0 a 3)
        DIGIT_1                 ; Valor BCD Dígito 1
        DIGIT_2                 ; Valor BCD Dígito 2
        DIGIT_3                 ; Valor BCD Dígito 3
        DIGIT_4                 ; Valor BCD Dígito 4
        
        ; Variables de Filtro EWMA para Detección de Pulso
        EMA_FAST                ; Promedio móvil rápido
        EMA_SLOW                ; Promedio móvil lento
        PULSE_COUNT             ; Contador de muestras entre latidos
        REG_BCD                 ; Registro auxiliar para conversiones BCD
        VAL_UNI                 ; Resultado Unidades BCD
        VAL_DEC                 ; Resultado Decenas BCD
        VAL_CEN                 ; Resultado Centenas BCD
    ENDC

    CBLOCK 0X70
        W_TEMP                  ; Resguardo contexto W en ISR
        STATUS_TEMP             ; Resguardo contexto STATUS en ISR
    ENDC

;===============================================================================
; DECLARACIÓN DE MACROS DE CONFIGURACIÓN
;===============================================================================

CFG_PORTS MACRO
    BANKSEL ANSEL
    MOVLW   B'00000011'         ; AN0 (RA0) y AN1 (RA1) como entradas analógicas
    MOVWF   ANSEL
    CLRF    ANSELH

    BANKSEL TRISA
    MOVLW   B'00001011'         ; RA0, RA1 y RA3 (Vref+) Entradas
    MOVWF   TRISA

    CLRF    TRISC               ; RC0-RC3 (Displays), RC4 (Buzzer) Salidas
    BSF     TRISC, 7            ; RC7 (RX EUSART desde PC) Entrada
    BCF     TRISC, 6            ; RC6 (TX EUSART hacia PC) Salida

    CLRF    TRISD               ; PORTD completo (Segmentos a-g) Salida
    CLRF    TRISE               ; PORTE (LEDs indicativos RE0) Salida

    BANKSEL PORTC
    CLRF    PORTC
    CLRF    PORTD
    CLRF    PORTE
    ENDM

CFG_ADC MACRO
    BANKSEL ADCON1
    MOVLW   B'00010000'         ; VREF+ externa en pin RA3 (2.56V)
    MOVWF   ADCON1

    BANKSEL ADCON0
    MOVLW   B'01000001'         ; Clock ADC Fosc/8, Canal AN0 seleccionado, ADC ON
    MOVWF   ADCON0
    ENDM

CFG_TIMERS MACRO
    BANKSEL OPTION_REG
    BCF     OPTION_REG, T0CS    ; Reloj interno para Timer0
    BCF     OPTION_REG, PSA     ; Prescaler asignado a Timer0
    BSF     OPTION_REG, PS2     ; Prescaler 1:256
    BSF     OPTION_REG, PS1
    BSF     OPTION_REG, PS0

    BANKSEL T1CON
    MOVLW   B'00110001'         ; Prescaler 1:8, Reloj Interno, Timer1 ON
    MOVWF   T1CON
    ENDM

CFG_EUSART MACRO
    BANKSEL SPBRG
    MOVLW   .25                 ; Baud rate 9600 @ 4MHz (BRGH = 1)
    MOVWF   SPBRG

    BANKSEL TXSTA
    MOVLW   B'00100100'         ; TX habilitado, Modo Asíncrono, BRGH=1
    MOVWF   TXSTA

    BANKSEL RCSTA
    MOVLW   B'10010000'         ; Serial Port Enable (SPEN=1), Recepción continua (CREN=1)
    MOVWF   RCSTA
    ENDM

CFG_ISR MACRO
    BANKSEL PIE1
    BSF     PIE1, TMR1IE        ; Habilita Int. por Timer1 (Multiplexado Display)
    BSF     PIE1, ADIE          ; Habilita Int. por ADC (Fin de Conversión)
    BSF     PIE1, RCIE          ; Habilita Int. por Recepción EUSART

    BANKSEL INTCON
    BSF     INTCON, T0IE        ; Habilita Int. por Timer0 (Muestreo A/D)
    BSF     INTCON, PEIE        ; Habilita Int. de Periféricos
    BSF     INTCON, GIE         ; Habilita Int. Globales
    ENDM

;===============================================================================
; INICIALIZACIÓN DEL MCU (CÓDIGO ABSOLUTO)
;===============================================================================
    ORG     0x00
    GOTO    INICIO

    ORG     0x04
    GOTO    ISR_INICIO

    ORG     0x05

;===============================================================================
; TABLAS DE CONVERSIÓN BCD A 7 SEGMENTOS (CÁTODO COMÚN)
;===============================================================================
TABLE_7SEG
    ADDWF   PCL, F
    RETLW   B'00111111'         ; 0
    RETLW   B'00000110'         ; 1
    RETLW   B'01011011'         ; 2
    RETLW   B'01001111'         ; 3
    RETLW   B'01100110'         ; 4
    RETLW   B'01101101'         ; 5
    RETLW   B'01111101'         ; 6
    RETLW   B'00000111'         ; 7
    RETLW   B'01111111'         ; 8
    RETLW   B'01101111'         ; 9
    RETLW   B'01110011'         ; 10 -> Símbolo "P" (Pulso)
    RETLW   B'00111001'         ; 11 -> Símbolo "C" (Celsius)
    RETLW   B'00000000'         ; 12 -> Apagado

INICIO
    ; Reset de Variables en RAM
    CLRF    ADC_BURST_STATE
    CLRF    MODE_SEL
    CLRF    DIGIT_SEL
    CLRF    EMA_FAST
    CLRF    EMA_SLOW
    CLRF    PULSE_COUNT
    MOVLW   .75                 ; Valor BPM inicial (75 BPM)
    MOVWF   BPM_VAL

    ; Inicialización de Macros de Configuración
    CFG_PORTS
    CFG_ADC
    CFG_TIMERS
    CFG_EUSART
    CFG_ISR

;===============================================================================
; INICIO PROGRAMA PRINCIPAL (MAIN LOOP)
;===============================================================================
MAIN_LOOP
    CALL    ACTUALIZAR_BUFFER_DISPLAY
    CALL    UART_TX_TEMPERATURA
    GOTO    MAIN_LOOP

;===============================================================================
; INICIALIZACIÓN DE RUTINAS DE SERVICIO DE INTERRUPCIÓN (ISR)
;===============================================================================
ISR_INICIO
    ;--------Guardado de Contexto--------
    MOVWF   W_TEMP
    SWAPF   STATUS, W
    MOVWF   STATUS_TEMP

    ;--------Identificación de Interrupción--------
    BANKSEL INTCON
    BTFSC   INTCON, T0IF
    GOTO    ISR_TMR0            ; Disparo Muestreo ADC

    BANKSEL PIR1
    BTFSC   PIR1, TMR1IF
    GOTO    ISR_TMR1            ; Multiplexado Display 7-Seg

    BTFSC   PIR1, ADIF
    GOTO    ISR_ADC             ; Procesamiento Ráfaga ADC

    BTFSC   PIR1, RCIF
    GOTO    ISR_EUSART_RX       ; Recepción Tecla desde la PC

    GOTO    ISR_FIN

;-------------------------------------------------------------------------------
; RUTINA ISR: TIMER0 (Disparo de Ráfaga ADC)
;-------------------------------------------------------------------------------
ISR_TMR0
    BCF     INTCON, T0IF        ; Limpiar bandera TMR0
    MOVLW   .100
    MOVWF   TMR0                ; Recarga Timer0
    
    BANKSEL ADCON0
    CLRF    ADC_BURST_STATE
    BCF     ADCON0, CHS0        ; Forzar canal AN0 (LM35)
    BSF     ADCON0, GO          ; Iniciar primera conversión
    GOTO    ISR_FIN

;-------------------------------------------------------------------------------
; RUTINA ISR: TIMER1 (Multiplexado Displays RC0-RC3 / RD0-RD6)
;-------------------------------------------------------------------------------
ISR_TMR1
    BANKSEL PIR1
    BCF     PIR1, TMR1IF        ; Limpiar bandera TMR1
    MOVLW   0xFC
    MOVWF   TMR1H
    MOVLW   0x18
    MOVWF   TMR1L

    ; Apagar todos los dígitos (RC0-RC3)
    BANKSEL PORTC
    MOVLW   B'11110000'
    ANDWF   PORTC, F

    ; Conmutar Dígito Activo
    MOVF    DIGIT_SEL, W
    ADDWF   PCL, F
    GOTO    DISP_SEL_D1
    GOTO    DISP_SEL_D2
    GOTO    DISP_SEL_D3
    GOTO    DISP_SEL_D4

DISP_SEL_D1
    MOVF    DIGIT_1, W
    CALL    TABLE_7SEG
    MOVWF   PORTD
    BSF     DISP_D1             ; Enciende Dígito 1
    MOVLW   .1
    MOVWF   DIGIT_SEL
    GOTO    ISR_FIN

DISP_SEL_D2
    MOVF    DIGIT_2, W
    CALL    TABLE_7SEG
    MOVWF   PORTD
    BSF     DISP_D2             ; Enciende Dígito 2
    MOVLW   .2
    MOVWF   DIGIT_SEL
    GOTO    ISR_FIN

DISP_SEL_D3
    MOVF    DIGIT_3, W
    CALL    TABLE_7SEG
    MOVWF   PORTD
    BSF     DISP_D3             ; Enciende Dígito 3
    MOVLW   .3
    MOVWF   DIGIT_SEL
    GOTO    ISR_FIN

DISP_SEL_D4
    MOVF    DIGIT_4, W
    CALL    TABLE_7SEG
    MOVWF   PORTD
    BSF     DISP_D4             ; Enciende Dígito 4
    CLRF    DIGIT_SEL
    GOTO    ISR_FIN

;-------------------------------------------------------------------------------
; RUTINA ISR: ADC (Máquina de Estados Multicanal AN0 - AN1)
;-------------------------------------------------------------------------------
ISR_ADC
    MOVF    ADC_BURST_STATE, F
    BTFSC   STATUS, Z
    GOTO    ACQ_AN0
    GOTO    ACQ_AN1

; ----- Canal AN0: LM35 (Temperatura) -----
ACQ_AN0
    BANKSEL ADRESH
    MOVF    ADRESH, W           ; Lee temperatura
    MOVWF   VAL_TEMP

    ; Evaluación Alarma Térmica (Temp > 40°C)
    SUBLW   .40
    BTFSS   STATUS, C           ; Si C=0 -> Temp >= 40°C
    GOTO    ALARMA_ON
    BCF     BUZZER              ; Apaga Buzzer en RC4
    GOTO    PASAR_A_AN1

ALARMA_ON
    BSF     BUZZER              ; Enciende Buzzer Activo en RC4

PASAR_A_AN1
    MOVLW   .1
    MOVWF   ADC_BURST_STATE     ; Cambia estado a AN1
    BANKSEL ADCON0
    BSF     ADCON0, CHS0        ; Cambia HW a canal AN1
    BSF     ADCON0, GO          ; Dispara segunda conversión
    GOTO    CLR_FLAG_ADC

; ----- Canal AN1: Pulse Sensor -----
ACQ_AN1
    BANKSEL ADRESH
    MOVF    ADRESH, W
    MOVWF   VAL_PULSE

    CALL    PROCESAR_FILTRO_PULSO
    CLRF    ADC_BURST_STATE

CLR_FLAG_ADC
    BANKSEL PIR1
    BCF     PIR1, ADIF
    GOTO    ISR_FIN

;-------------------------------------------------------------------------------
; RUTINA ISR: RECEPCIÓN EUSART (Comandos desde PC)
;-------------------------------------------------------------------------------
ISR_EUSART_RX
    BANKSEL RCREG
    MOVF    RCREG, W            ; Lee tecla recibida desde PC

    ; Evaluar Tecla '1' o 'P' (Modo BPM)
    XORLW   '1'
    BTFSC   STATUS, Z
    GOTO    SET_MODO_BPM

    MOVF    RCREG, W
    XORLW   'P'
    BTFSC   STATUS, Z
    GOTO    SET_MODO_BPM

    ; Evaluar Tecla '2' o 'T' (Modo Temperatura)
    MOVF    RCREG, W
    XORLW   '2'
    BTFSC   STATUS, Z
    GOTO    SET_MODO_TEMP

    MOVF    RCREG, W
    XORLW   'T'
    BTFSC   STATUS, Z
    GOTO    SET_MODO_TEMP

    ; Conmutación alternada si es cualquier otra tecla
    MOVLW   .1
    XORWF   MODE_SEL, F
    GOTO    ISR_FIN

SET_MODO_BPM
    CLRF    MODE_SEL
    GOTO    ISR_FIN

SET_MODO_TEMP
    MOVLW   .1
    MOVWF   MODE_SEL
    GOTO    ISR_FIN

;===============================================================================
; FINALIZACIÓN DE RUTINAS DE SERVICIO DE INTERRUPCIÓN
;===============================================================================
ISR_FIN
    ;--------Restauración de Contexto--------
    SWAPF   STATUS_TEMP, W
    MOVWF   STATUS
    SWAPF   W_TEMP, F
    SWAPF   W_TEMP, W
    RETFIE

;===============================================================================
; SUBRUTINAS DEL SISTEMA
;===============================================================================

ACTUALIZAR_BUFFER_DISPLAY
    MOVF    MODE_SEL, F
    BTFSS   STATUS, Z
    GOTO    MOSTRAR_TEMP

MOSTRAR_BPM
    MOVF    BPM_VAL, W
    MOVWF   REG_BCD
    CALL    CNV_BCD
    MOVF    VAL_UNI, W
    MOVWF   DIGIT_1             ; Unidades BPM
    MOVF    VAL_DEC, W
    MOVWF   DIGIT_2             ; Decenas BPM
    MOVF    VAL_CEN, W
    MOVWF   DIGIT_3             ; Centenas BPM
    MOVLW   .10                 ; Símbolo "P"
    MOVWF   DIGIT_4
    RETURN

MOSTRAR_TEMP
    MOVF    VAL_TEMP, W
    MOVWF   REG_BCD
    CALL    CNV_BCD
    MOVF    VAL_UNI, W
    MOVWF   DIGIT_1             ; Unidades Temp
    MOVF    VAL_DEC, W
    MOVWF   DIGIT_2             ; Decenas Temp
    MOVF    VAL_CEN, W
    MOVWF   DIGIT_3             ; Centenas Temp
    MOVLW   .11                 ; Símbolo "C"
    MOVWF   DIGIT_4
    RETURN

PROCESAR_FILTRO_PULSO
    INCF    PULSE_COUNT, F

    ; Actualización Promedio Rápido (EMA_FAST)
    MOVF    VAL_PULSE, W
    SUBWF   EMA_FAST, W
    MOVWF   REG_BCD
    RRF     REG_BCD, F
    MOVF    REG_BCD, W
    ADDWF   EMA_FAST, F

    ; Actualización Promedio Lento (EMA_SLOW)
    MOVF    VAL_PULSE, W
    SUBWF   EMA_SLOW, W
    MOVWF   REG_BCD
    RRF     REG_BCD, F
    RRF     REG_BCD, F
    MOVF    REG_BCD, W
    ADDWF   EMA_SLOW, F

    ; Verificación de latido
    MOVF    EMA_SLOW, W
    ADDLW   .10
    SUBWF   EMA_FAST, W
    BTFSS   STATUS, C
    GOTO    SIN_LATIDO

    BSF     LED_PULSE           ; Enciende LED Latido (RE0)
    CLRF    PULSE_COUNT
    RETURN

SIN_LATIDO
    BCF     LED_PULSE           ; Apaga LED Latido
    RETURN

UART_TX_TEMPERATURA
    BANKSEL PIR1
    BTFSS   PIR1, TXIF          ; ¿Buffer TX libre?
    RETURN
    BANKSEL TXREG
    MOVF    VAL_TEMP, W
    MOVWF   TXREG
    RETURN

CNV_BCD
    CLRF    VAL_CEN
    CLRF    VAL_DEC
    CLRF    VAL_UNI

BCD_CENTENAS
    MOVLW   .100
    SUBWF   REG_BCD, W
    BTFSS   STATUS, C
    GOTO    BCD_DECENAS
    MOVWF   REG_BCD
    INCF    VAL_CEN, F
    GOTO    BCD_CENTENAS

BCD_DECENAS
    MOVLW   .10
    SUBWF   REG_BCD, W
    BTFSS   STATUS, C
    GOTO    BCD_UNIDADES
    MOVWF   REG_BCD
    INCF    VAL_DEC, F
    GOTO    BCD_DECENAS

BCD_UNIDADES
    MOVF    REG_BCD, W
    MOVWF   VAL_UNI
    RETURN

    END