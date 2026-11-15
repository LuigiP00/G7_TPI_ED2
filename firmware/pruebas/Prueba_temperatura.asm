;*******************************************************************************
; @brief       ANEXO B - FIRMWARE DEL SEP.
;
; @brief       Termómetro digital con sensor LM35, visualización multiplexada
;              en display de 7 segmentos de 4 dígitos y alarma lumínica/sonora.
;
; @details     El sistema adquiere la señal analógica del sensor LM35 en AN0
;              (10 mV/°C, Vref+ = 2.50 V en RA3) con el ADC de 8 bits cada
;              9.984 ms (Timer0) y actualiza el display cada ~250 ms con el
;              formato [Decena][Unidad][°][C] mediante multiplexado por
;              interrupción de Timer1 cada 5 ms (PORTD y RC0..RC3).
;              Si la temperatura supera los 40 °C enciende el LED rojo (RB7) y
;              activa un buzzer (RC4) con ciclos de 0.25 s ON y 3.0 s OFF; por
;              debajo de 40 °C enciende el LED verde (RB6) y apaga el buzzer.
; 
; @author      Gx_TPI_ED2
;
; @date        15/11/2026
;
; @version     1.0
;*******************************************************************************
	    
;===============================================================================
; DIRECTIVAS DE INCLUSIÓN
;===============================================================================  
    LIST P=16F887
#include "p16f887.inc"
    
;===============================================================================
; CONFIGURACIÓN GENERAL DEL MCU
;===============================================================================
    __CONFIG _CONFIG1, _XT_OSC & _WDT_OFF & _PWRTE_ON & _MCLRE_ON & _CP_OFF & _LVP_OFF
    __CONFIG _CONFIG2, _BOR40V & _WRT_OFF

;===============================================================================
; DEFINICIÓN DE CONSTANTES
;===============================================================================                
TMR0_PRELOAD    EQU d'100'      ; 156 cuentas x 64 us = 9.984 ms por tick
TMR1_PRELOAD_H  EQU 0xEC        ; 0xEC78 = 60536 -> 5000 us = 5 ms por dígito
TMR1_PRELOAD_L  EQU 0x78

TEMP_UMBRAL     EQU d'40'       ; Umbral de alarma en °C
DISP_REF_TICKS  EQU d'25'       ; Refresco de display: 25 x 9.984 ms = ~250 ms
BUZZ_SUB_TICKS  EQU d'25'       ; Subintervalo base del buzzer: 0.25 s
BUZZ_TOTAL_STEP EQU d'13'       ; 1 paso ON (0.25 s) + 12 pasos OFF (3.0 s)

ADC_CH_AN0      EQU b'01000001' ; Fosc/8, canal AN0 (LM35), ADC encendido
SEG_DEG         EQU 0x9C        ; Símbolo '°' (segmentos a, b, f, g en 0)
SEG_C           EQU 0xC6        ; Letra 'C'   (segmentos a, d, e, f en 0)
SEG_OFF         EQU 0xFF        ; Todos los segmentos apagados (ánodo común)

;===============================================================================
; DEFINICIÓN DE VARIABLES
;=============================================================================== 
    CBLOCK 0x20                 ; Banco 0
        TEMP_C                  ; Temperatura entera en °C
        PROD_L, PROD_H          ; Registro auxiliar de 16 bits para escalado
        AUX_L, AUX_H            ; Auxiliar de cálculo y retardo de adquisición
        DISP_TMR                ; Temporizador de refresco visual (~250 ms)
        BUZZ_STEP               ; Pasos de 0.25 s del buzzer (13 = ON, 12..1 = OFF)
        BUZZ_SUB                ; Subcontador de 25 ticks (0.25 s)
        DSPL_1, DSPL_2          ; Segmentos dígito 1 (decena) y dígito 2 (unidad)
        DSPL_3, DSPL_4          ; Segmentos dígito 3 ('°') y dígito 4 ('C')
        MUX_IDX, MUX_MASK       ; Índice y máscara de multiplexado (RC0..RC3)
        TENS, UNITS             ; Dígitos BCD para el display
    ENDC

    CBLOCK 0x70                 ; Memoria común (guardado de contexto ISR)
        W_TEMP, STATUS_TEMP, FSR_TEMP
    ENDC

;===============================================================================
; DECLARACIÓN DE MACROS PARA CONFIGURACIÓN DE REGISTROS
;===============================================================================            
CFG_PORTA MACRO
    BANKSEL ANSEL
    MOVLW   b'00001011'         ; RA0 (AN0, LM35), RA1 (AN1) y RA3 (Vref+) analógicos
    MOVWF   ANSEL
    BANKSEL TRISA
    MOVLW   b'00001011'         ; RA0, RA1 y RA3 como entradas
    MOVWF   TRISA
    ENDM

CFG_PORTB MACRO
    BANKSEL ANSELH
    CLRF    ANSELH              ; PORTB completamente digital
    BANKSEL TRISB
    MOVLW   b'00111111'         ; RB6 (LED verde) y RB7 (LED rojo) como salidas
    MOVWF   TRISB
    BANKSEL PORTB
    CLRF    PORTB               ; LEDs inicialmente apagados
    ENDM

CFG_PORTC MACRO
    BANKSEL TRISC
    MOVLW   b'11100000'         ; RC0..RC3 (dígitos) y RC4 (buzzer) como salidas
    MOVWF   TRISC
    BANKSEL PORTC
    MOVLW   b'11101111'         ; Dígitos apagados (1) y buzzer RC4 apagado (0)
    MOVWF   PORTC
    ENDM

CFG_PORTD MACRO
    BANKSEL TRISD
    CLRF    TRISD               ; RD0..RD7 (segmentos) como salidas
    BANKSEL PORTD
    MOVLW   SEG_OFF             ; Segmentos apagados (ánodo común, lógica negativa)
    MOVWF   PORTD
    ENDM

CFG_ADC MACRO
    BANKSEL ADCON1
    MOVLW   b'00010000'         ; ADFM=0 (8 bits en ADRESH), VCFG0=1 (Vref+ en RA3)
    MOVWF   ADCON1
    BANKSEL ADCON0
    MOVLW   ADC_CH_AN0          ; Fosc/8, canal AN0, ADC encendido
    MOVWF   ADCON0
    ENDM

CFG_TIMER0 MACRO
    BANKSEL OPTION_REG
    MOVLW   b'11010101'         ; Pull-ups deshabilitados, Timer0 prescaler 1:64
    MOVWF   OPTION_REG
    BANKSEL TMR0
    MOVLW   TMR0_PRELOAD        ; Precarga para base de tiempo de 9.984 ms
    MOVWF   TMR0
    BCF     INTCON, T0IF
    ENDM

CFG_TIMER1 MACRO
    BANKSEL T1CON
    MOVLW   b'00000001'         ; TMR1ON=1, reloj interno, prescaler 1:1
    MOVWF   T1CON
    MOVLW   TMR1_PRELOAD_H      ; Precarga para interrupción cada 5 ms
    MOVWF   TMR1H
    MOVLW   TMR1_PRELOAD_L
    MOVWF   TMR1L
    BCF     PIR1, TMR1IF
    BANKSEL PIE1
    BSF     PIE1, TMR1IE        ; Habilita interrupción de Timer1
    BANKSEL PORTB               ; Selecciona Banco 0 de forma permanente
    BSF     INTCON, PEIE        ; Habilita interrupciones de periféricos
    BSF     INTCON, GIE         ; Habilita interrupciones globales
    ENDM

;===============================================================================
; INICIALIZACIÓN DEL MCU (CÓDIGO ABSOLUTO)
;===============================================================================    
    ORG     0x00                ; Vector de Reset
    GOTO    INICIO              ; Salto al inicio del programa principal
    ORG     0x04                ; Vector de Interrupción
    GOTO    ISR_INICIO          ; Salto a la Rutina de Servicio de Interrupción
    ORG     0x05                ; Ubicación Programa Principal en la memoria 

;===============================================================================
; INICIALIZACIÓN DE MACROS PARA CONFIGURACIÓN DE REGISTROS
;=============================================================================== 
INICIO      
    ;-----Inicialización de Macros-------
    CFG_PORTA
    CFG_PORTB
    CFG_PORTC
    CFG_PORTD
    CFG_ADC
    CFG_TIMER0

    ;-----Inicialización de Variables----
    BANKSEL PORTB
    CLRF    BUZZ_STEP
    CLRF    MUX_IDX
    MOVLW   b'11111110'
    MOVWF   MUX_MASK
    MOVLW   DISP_REF_TICKS
    MOVWF   DISP_TMR

    CALL    LEER_TEMP           ; Primera lectura válida antes de habilitar display
    CALL    EVALUAR_TEMP
    CALL    MOSTRAR_TEMP

    CFG_TIMER1                  ; Habilita Timer1 e interrupciones (queda en Banco 0)

;===============================================================================
; INICIO PROGRAMA PRINCIPAL
;===============================================================================        
MAIN_LOOP  
    BTFSS   INTCON, T0IF        ; Espera tick de 9.984 ms por desborde de Timer0
    GOTO    MAIN_LOOP
    BCF     INTCON, T0IF
    MOVLW   TMR0_PRELOAD
    MOVWF   TMR0

    CALL    LEER_TEMP           ; Adquiere LM35 en AN0 y calcula °C
    CALL    EVALUAR_TEMP        ; Actualiza LEDs (RB6/RB7) y buzzer (RC4)

    DECFSZ  DISP_TMR, F         ; Refresca display cada 25 ticks (~250 ms)
    GOTO    MAIN_LOOP
    MOVLW   DISP_REF_TICKS
    MOVWF   DISP_TMR
    CALL    MOSTRAR_TEMP
    GOTO    MAIN_LOOP
  
;===============================================================================
; INICIALIZACIÓN DE RUTINAS DE SERVICIO DE INTERRUPCIÓN
;===============================================================================        
ISR_INICIO      
    ;----------Guardado de Contexto----------
    MOVWF   W_TEMP
    SWAPF   STATUS, W
    MOVWF   STATUS_TEMP
    MOVF    FSR, W
    MOVWF   FSR_TEMP
    CLRF    STATUS              ; Selecciona Banco 0 e IRP=0
    ;----------------------------------------
    ;-----Identificación de Interrupción----- 
    BTFSS   PIR1, TMR1IF
    GOTO    ISR_FIN
    BCF     PIR1, TMR1IF

    MOVLW   TMR1_PRELOAD_H      ; Recarga Timer1 (5 ms)
    MOVWF   TMR1H
    MOVLW   TMR1_PRELOAD_L
    MOVWF   TMR1L

    MOVLW   b'00001111'
    IORWF   PORTC, F            ; Apaga dígitos RC0..RC3 preservando RC4 (buzzer)
    MOVLW   DSPL_1
    ADDWF   MUX_IDX, W
    MOVWF   FSR
    MOVF    INDF, W
    MOVWF   PORTD               ; Carga segmentos del dígito activo
    MOVF    PORTC, W
    IORLW   b'00001111'
    ANDWF   MUX_MASK, W
    MOVWF   PORTC               ; Habilita dígito actual (0 en RC0..RC3)

    INCF    MUX_IDX, F
    BSF     STATUS, C
    RLF     MUX_MASK, F
    MOVF    MUX_IDX, W
    XORLW   d'4'
    BTFSS   STATUS, Z
    GOTO    ISR_FIN
    CLRF    MUX_IDX
    MOVLW   b'11111110'
    MOVWF   MUX_MASK
    ;----------------------------------------   
    
;===============================================================================
; FINALIZACIÓN DE RUTINAS DE SERVICIO DE INTERRUPCIÓN
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
; @brief    Tabla de conversión BCD a 7 segmentos (ánodo común).
;           
; @details  Recibe un dígito decimal (0..9) en W y retorna el patrón en lógica
;           negativa (bit0=a .. bit6=g, bit7=dp apagado). Ubicada en Página 0.
;*******************************************************************************
TABLA_7SEG:
    ADDWF   PCL, F
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

;*******************************************************************************
; @brief    Adquiere el canal AN0 (LM35) y convierte el resultado a °C enteros.
;           
; @details  Con Vref+ = 2.50 V y LM35 = 10 mV/°C, cada cuenta equivale a
;           250/256 °C. Calcula TEMP_C = ((ADRESH << 8) - 6 * ADRESH) >> 8.
;******************************************************************************* 
LEER_TEMP:
    MOVLW   ADC_CH_AN0          ; Selecciona canal AN0
    MOVWF   ADCON0
    MOVLW   d'8'                ; ~24 us de tiempo de adquisición
    MOVWF   AUX_L
    DECFSZ  AUX_L, F
    GOTO    $-1

    BSF     ADCON0, 1           ; Inicia conversión (GO/DONE = 1)
    BTFSC   ADCON0, 1           ; Espera fin de conversión
    GOTO    $-1

    MOVF    ADRESH, W           ; PROD = ADRESH * 256
    MOVWF   PROD_H
    CLRF    PROD_L
    MOVWF   AUX_L
    CLRF    AUX_H
    BCF     STATUS, C
    RLF     AUX_L, F            ; AUX = 2 * ADRESH
    RLF     AUX_H, F
    CALL    SUB_PROD_AUX        ; PROD -= 2 * ADRESH
    BCF     STATUS, C
    RLF     AUX_L, F            ; AUX = 4 * ADRESH
    RLF     AUX_H, F
    CALL    SUB_PROD_AUX        ; PROD -= 4 * ADRESH (total: 250 * ADRESH)
    MOVF    PROD_H, W
    MOVWF   TEMP_C
    RETURN

SUB_PROD_AUX:
    MOVF    AUX_L, W
    SUBWF   PROD_L, F
    BTFSS   STATUS, C
    DECF    PROD_H, F
    MOVF    AUX_H, W
    SUBWF   PROD_H, F
    RETURN

;*******************************************************************************
; @brief    Evalúa TEMP_C contra 40 °C y gobierna LEDs (RB6/RB7) y buzzer (RC4).
;           
; @details  Temp > 40 °C: RB7 ON, RB6 OFF, buzzer 0.25 s ON / 3.0 s OFF.
;           Temp < 40 °C: RB7 OFF, RB6 ON, buzzer apagado.
;******************************************************************************* 
EVALUAR_TEMP:
    MOVLW   TEMP_UMBRAL
    SUBWF   TEMP_C, W           ; W = TEMP_C - 40
    BTFSS   STATUS, C
    GOTO    TEMP_BAJA           ; TEMP_C < 40 °C
    BTFSC   STATUS, Z
    GOTO    TEMP_IGUAL          ; TEMP_C == 40 °C

    BSF     PORTB, 7            ; Temp > 40 °C: LED rojo ON, verde OFF
    BCF     PORTB, 6
    MOVF    BUZZ_STEP, F
    BTFSC   STATUS, Z
    GOTO    BUZZ_START          ; Arranca ciclo si estaba apagado
    DECFSZ  BUZZ_SUB, F
    RETURN
    MOVLW   BUZZ_SUB_TICKS      ; Pasaron 25 ticks (0.25 s)
    MOVWF   BUZZ_SUB
    DECFSZ  BUZZ_STEP, F
    GOTO    BUZZ_SILENCIO
BUZZ_START:
    MOVLW   BUZZ_TOTAL_STEP     ; 1 paso ON (0.25 s) + 12 pasos OFF (3.0 s)
    MOVWF   BUZZ_STEP
    MOVLW   BUZZ_SUB_TICKS
    MOVWF   BUZZ_SUB
    BSF     PORTC, 4            ; Buzzer ON
    RETURN
BUZZ_SILENCIO:
    BCF     PORTC, 4            ; Buzzer OFF
    RETURN

TEMP_BAJA:
    BCF     PORTB, 7            ; LED rojo OFF, verde ON
    BSF     PORTB, 6
    CLRF    BUZZ_STEP
    BCF     PORTC, 4
    RETURN

TEMP_IGUAL:
    BCF     PORTB, 7            ; Ambos LEDs OFF
    BCF     PORTB, 6
    CLRF    BUZZ_STEP
    BCF     PORTC, 4
    RETURN

;*******************************************************************************
; @brief    Formatea TEMP_C para el display de 4 dígitos: [Decena][Unidad][°][C].
;           
; @details  Separa decenas y unidades mediante restas sucesivas (saturando en
;           99 °C) y actualiza los buffers DSPL_1..DSPL_4 que lee la ISR.
;******************************************************************************* 
MOSTRAR_TEMP:
    MOVF    TEMP_C, W
    MOVWF   UNITS
    MOVLW   d'100'
    SUBWF   UNITS, W
    BTFSS   STATUS, C
    GOTO    $+3
    MOVLW   d'99'               ; Satura en 99 °C
    MOVWF   UNITS

    CLRF    TENS
DIV10_LOOP:
    MOVLW   d'10'
    SUBWF   UNITS, W
    BTFSS   STATUS, C
    GOTO    WRITE_DSPL
    MOVWF   UNITS
    INCF    TENS, F
    GOTO    DIV10_LOOP

WRITE_DSPL:
    MOVF    TENS, W
    CALL    TABLA_7SEG
    MOVWF   DSPL_1              ; Dígito 1: Decena
    MOVF    UNITS, W
    CALL    TABLA_7SEG
    MOVWF   DSPL_2              ; Dígito 2: Unidad
    MOVLW   SEG_DEG             ; Dígito 3: '°' (segmentos a, b, f, g)
    MOVWF   DSPL_3
    MOVLW   SEG_C               ; Dígito 4: 'C'
    MOVWF   DSPL_4
    RETURN
    
;===============================================================================        
    END
;===============================================================================