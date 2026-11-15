;*******************************************************************************
; @brief       ANEXO B - FIRMWARE DEL SEP.
;
; @brief       Termómetro digital (LM35) + Pulsómetro a demanda por UART
;              (HW-827 @ 5V, divisor simétrico 22k/22k + 1 uF, filtro FIR de
;              4 muestras y pre-calibración continua de pendiente sistólica)
;              con display multiplexado de 4 dígitos, alarma lumínica/sonora y
;              telemetría ASCII por EUSART hacia interfaz web local.
;
; @details     - AN0 (RA0): Sensor de temperatura LM35 (10 mV/°C, Vref+ = 2.50 V).
;              - AN1 (RA1): Sensor de pulsos HW-827 (5 V) con divisor simétrico
;                           22k/22k y capacitor electrolítico de 1 uF a masa.
;              - EUSART (RC6/TX, RC7/RX @ 9600 Bd):
;                  * RX 'I'/'i': Inicia adquisición de pulsos (15 s) usando
;                                los umbrales pre-calibrados, cambia a vista
;                                Frecuencia y muestra cuenta regresiva
;                                t-15 .. t-01; al finalizar muestra FXXX o
;                                F--- si no detectó pulsos.
;                  * RX 'V'/'v': Alterna display entre Temperatura (XX°C) y
;                                Frecuencia cardíaca (FXXX / F---).
;                  * TX cada 250 ms: Envía trama "Txx,Myy,Bzzz\r\n" a la PC.
;              - Alarmas de temperatura (> 40 °C): LED rojo RB7 ON, LED verde
;                RB6 OFF y buzzer RC4 con ciclos de 0.25 s ON / 3.0 s OFF.
; 
; @author      Gx_TPI_ED2
;
; @date        15/11/2026
;
; @version     4.0
;*******************************************************************************
	    
;===============================================================================
; DIRECTIVAS DE INCLUSIÓN
;===============================================================================  
    LIST P=16F887
#include "p16f887.inc"
    ERRORLEVEL -302             ; Suprime avisos de banco (gestionado con BANKSEL)
    
;===============================================================================
; CONFIGURACIÓN GENERAL DEL MCU
;===============================================================================
    __CONFIG _CONFIG1, _XT_OSC & _WDT_OFF & _PWRTE_ON & _MCLRE_ON & _CP_OFF & _LVP_OFF
    __CONFIG _CONFIG2, _BOR40V & _WRT_OFF

;===============================================================================
; DEFINICIÓN DE CONSTANTES
;===============================================================================                
; --- Temporizadores ---
TMR0_PRELOAD    EQU d'100'      ; 156 cuentas x 64 us = 9.984 ms por tick
TMR1_PRELOAD_H  EQU 0xEC        ; 0xEC78 = 60536 -> 5000 us = 5 ms por dígito
TMR1_PRELOAD_L  EQU 0x78

; --- Temperatura y Buzzer ---
TEMP_UMBRAL     EQU d'40'       ; Umbral de alarma en °C
DISP_REF_TICKS  EQU d'25'       ; Refresco display y TX: 25 x 9.984 ms = ~250 ms
BUZZ_SUB_TICKS  EQU d'25'       ; Subintervalo base del buzzer: 0.25 s
BUZZ_TOTAL_STEP EQU d'13'       ; 1 paso ON (0.25 s) + 12 pasos OFF (3.0 s)

; --- Pulsómetro (FIR 4 muestras + Pre-calibración adaptativa 140 ms) ---
MEAS_SECONDS    EQU d'15'       ; Duración de la ventana de adquisición (15 s)
TICKS_PER_SEC   EQU d'100'      ; 100 x 9.984 ms = ~1.00 s por paso regresivo
REFRACT_TICKS   EQU d'45'       ; Bloqueo refractario: 45 x 9.984 ms = ~450 ms
DECAY_TICKS     EQU d'150'      ; Decaimiento de MAX_DROP: 150 ticks = ~1.50 s
DROP_THRESH_IDLE EQU d'5'       ; Umbral sin pulso confirmado (rechaza ruido)
DROP_THRESH_MIN EQU d'4'        ; Piso mínimo con pulso débil confirmado
DROP_THRESH_MAX EQU d'9'        ; Techo máximo del umbral adaptativo
DROP_CAP_MAX    EQU d'18'       ; Tope de almacenamiento para decaimiento ágil
DROP_TRANS_LIM  EQU d'28'       ; Límite superior para descartar transitorios

; --- Canales ADC (Fosc/8, ADON=1) ---
ADC_CH_AN0      EQU b'01000001' ; Canal AN0 (LM35)
ADC_CH_AN1      EQU b'01000101' ; Canal AN1 (HW-827)

; --- EUSART ---
SPBRG_9600      EQU d'25'       ; 4 MHz / (16 * (25 + 1)) = 9615 Bd (Error 0.16%)
TX_FRAME_LEN    EQU d'14'       ; Longitud de trama "Txx,Myy,Bzzz\r\n"

; --- Display 7 Segmentos (Ánodo común, lógica negativa) ---
SEG_T           EQU 0x87        ; Letra 't'   (d, e, f, g en 0)
SEG_F           EQU 0x8E        ; Letra 'F'   (a, e, f, g en 0)
SEG_DEG         EQU 0x9C        ; Símbolo '°' (a, b, f, g en 0)
SEG_DASH        EQU 0xBF        ; Guion '-'   (g en 0)
SEG_C           EQU 0xC6        ; Letra 'C'   (a, d, e, f en 0)
SEG_OFF         EQU 0xFF        ; Todos los segmentos apagados

; --- Bits de FLAGS ---
F_DISP_MODE     EQU 0           ; 0 = Muestra Temperatura, 1 = Muestra Frecuencia
F_MEAS_ACTIVE   EQU 1           ; 1 = Medición de pulsos (15 s) en curso
F_CMD_START     EQU 2           ; 1 = Comando 'I' recibido por UART
F_PULSE_LOCK    EQU 3           ; 1 = Latido detectado (esperar DROP <= 1)

;===============================================================================
; DEFINICIÓN DE VARIABLES
;=============================================================================== 
    CBLOCK 0x20                 ; Banco 0
        FLAGS                   ; Banderas de estado del sistema
        RX_TEMP                 ; Buffer temporal de carácter recibido por UART
        ; --- Temperatura y Buzzer ---
        TEMP_C                  ; Temperatura entera en °C
        PROD_L, PROD_H          ; Auxiliar de 16 bits para escalado ADC -> °C
        AUX_L, AUX_H            ; Auxiliar de cálculo y retardo de adquisición
        DISP_TMR                ; Temporizador de refresco visual (~250 ms)
        BUZZ_STEP               ; Pasos de 0.25 s del buzzer (13 = ON, 12..1 = OFF)
        BUZZ_SUB                ; Subcontador de 25 ticks (0.25 s)
        ; --- Pulsómetro (FIR 4-tap + Pre-calibración adaptativa) ---
        PULSE_ADC               ; Última muestra ADC de AN1 (0..255)
        S4_NOW_L, S4_NOW_H      ; Suma de las 4 muestras actuales (0..1020)
        S4_OLD_L, S4_OLD_H      ; Suma de hace 140 ms y diferencia DROP
        DROP_THRESH             ; Umbral dinámico de caída sistólica (4..9)
        MAX_DROP                ; Máxima caída sistólica reciente (con decaimiento)
        DECAY_TMR               ; Temporizador de decaimiento de MAX_DROP (1.5 s)
        REFRACT                 ; Ticks restantes de bloqueo refractario
        COUNTDOWN_SEC           ; Segundos restantes de medición (15..1)
        SEC_SUB_TMR             ; Subcontador de 100 ticks (~1 s)
        PULSE_COUNT             ; Latidos contados en la ventana de 15 s
        BPM_VAL                 ; Frecuencia cardíaca calculada (latidos x 4)
        PULSE_BUF:18            ; Historial circular de 18 muestras (180 ms)
        ; --- Display ---
        DSPL_1, DSPL_2          ; Segmentos dígito 1 (izq) y dígito 2
        DSPL_3, DSPL_4          ; Segmentos dígito 3 y dígito 4 (der)
        MUX_IDX, MUX_MASK       ; Índice y máscara de multiplexado (RC0..RC3)
        HUNDREDS, TENS, UNITS   ; Dígitos decimales para formateo
        ; --- Telemetría UART TX ---
        TX_LEN                  ; Bytes pendientes de envío (0 = libre)
        TX_IDX                  ; Índice actual dentro de TX_BUF
        TX_BUF:14               ; Trama ASCII "Txx,Myy,Bzzz\r\n"
    ENDC

    CBLOCK 0x70                 ; Memoria común (guardado de contexto ISR)
        W_TEMP, STATUS_TEMP, FSR_TEMP
    ENDC

;===============================================================================
; DECLARACIÓN DE MACROS PARA CONFIGURACIÓN DE REGISTROS
;===============================================================================            
CFG_PORTA MACRO
    BANKSEL ANSEL
    MOVLW   b'00001011'         ; RA0 (AN0, LM35), RA1 (AN1, pulso) y RA3 (Vref+) analógicos
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
    MOVLW   b'11100000'         ; RC0..RC3 (dígitos), RC4 (buzzer) salidas; RC6/RC7 UART
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

CFG_EUSART MACRO
    BANKSEL BAUDCTL
    BCF     BAUDCTL, BRG16      ; Generador de baudios de 8 bits
    BANKSEL SPBRG
    MOVLW   SPBRG_9600          ; 9600 Bd @ 4 MHz (BRGH=1, SYNC=0)
    MOVWF   SPBRG
    MOVLW   b'00100100'         ; TXEN=1 (habilita TX), SYNC=0 (asíncrono), BRGH=1
    MOVWF   TXSTA
    BANKSEL PIE1
    BSF     PIE1, RCIE          ; Habilita interrupción por recepción RX
    BANKSEL RCSTA
    MOVLW   b'10010000'         ; SPEN=1 (habilita RC6/RC7), CREN=1 (RX continua)
    MOVWF   RCSTA
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
    CFG_EUSART

    ;-----Inicialización de Variables----
    BANKSEL PORTB
    CLRF    FLAGS               ; Inicia mostrando Temperatura, medición inactiva
    CLRF    BUZZ_STEP
    CLRF    BPM_VAL
    CLRF    TX_LEN
    CLRF    TX_IDX
    CLRF    MUX_IDX
    MOVLW   b'11111110'
    MOVWF   MUX_MASK
    MOVLW   DISP_REF_TICKS
    MOVWF   DISP_TMR

    CALL    INIT_PULSO_BG       ; Precarga buffer AN1 y pre-calibración continua
    CALL    LEER_TEMP           ; Primera lectura válida antes de habilitar display
    CALL    EVALUAR_TEMP
    CALL    ACTUALIZAR_DISPLAY

    CFG_TIMER1                  ; Habilita Timer1, RX UART e interrupciones (Banco 0)

;===============================================================================
; INICIO PROGRAMA PRINCIPAL
;===============================================================================        
MAIN_LOOP  
    BTFSS   INTCON, T0IF        ; Espera tick de 9.984 ms por desborde de Timer0
    GOTO    MAIN_LOOP
    BCF     INTCON, T0IF
    MOVLW   TMR0_PRELOAD
    MOVWF   TMR0

    ; --- 1. Tarea permanente: Temperatura (AN0) y alarmas ---
    CALL    LEER_TEMP
    CALL    EVALUAR_TEMP

    ; --- 2. Tarea permanente de pulsómetro: pre-calibración y conteo ---
    BTFSC   FLAGS, F_CMD_START  ; ¿Se presionó 'I' en la PC?
    CALL    INICIAR_MEDICION_PULSO

    CALL    PROCESAR_PULSO      ; Corre continuo (pre-calibra en reposo y mide en activo)

    ; --- 3. Transmisión no bloqueante de telemetría (1 byte por tick) ---
    MOVF    TX_LEN, F
    BTFSS   STATUS, Z
    CALL    ENVIAR_BYTE_UART

    ; --- 4. Actualización periódica (250 ms) o por cambio de vista ('V') ---
    DECFSZ  DISP_TMR, F
    GOTO    MAIN_LOOP
    MOVLW   DISP_REF_TICKS
    MOVWF   DISP_TMR
    CALL    ACTUALIZAR_DISPLAY
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
    ; 1) Interrupción de Timer1: Multiplexado del display (5 ms)
    BTFSS   PIR1, TMR1IF
    GOTO    CHECK_UART_RX
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
    GOTO    CHECK_UART_RX
    CLRF    MUX_IDX
    MOVLW   b'11111110'
    MOVWF   MUX_MASK

    ; 2) Interrupción de EUSART RX: Comandos desde teclado/web ('I' y 'V')
CHECK_UART_RX:
    BTFSS   PIR1, RCIF
    GOTO    ISR_FIN

    BTFSS   RCSTA, OERR         ; Verifica error de saturación de buffer FIFO
    GOTO    UART_READ_CHAR
    BCF     RCSTA, CREN         ; Destraba receptor reiniciando CREN
    BSF     RCSTA, CREN

UART_READ_CHAR:
    MOVF    RCREG, W            ; Lee carácter recibido (limpia RCIF)
    MOVWF   RX_TEMP

    ; ¿Tecla 'I' (0x49) o 'i' (0x69)? -> Iniciar adquisición de pulsos
    XORLW   'I'
    BTFSC   STATUS, Z
    GOTO    UART_CMD_I
    MOVF    RX_TEMP, W
    XORLW   'i'
    BTFSC   STATUS, Z
    GOTO    UART_CMD_I

    ; ¿Tecla 'V' (0x56) o 'v' (0x76)? -> Alternar variable en display
    MOVF    RX_TEMP, W
    XORLW   'V'
    BTFSC   STATUS, Z
    GOTO    UART_CMD_V
    MOVF    RX_TEMP, W
    XORLW   'v'
    BTFSC   STATUS, Z
    GOTO    UART_CMD_V
    GOTO    ISR_FIN

UART_CMD_I:
    BSF     FLAGS, F_CMD_START
    GOTO    ISR_FIN

UART_CMD_V:
    MOVLW   (1 << F_DISP_MODE)
    XORWF   FLAGS, F            ; Invierte modo de display (0 <-> 1)
    MOVLW   d'1'
    MOVWF   DISP_TMR            ; Fuerza refresco inmediato en el próximo tick
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
; @brief    Selecciona el canal ADC en W, espera adquisición y lee ADRESH.
;           
; @details  Espera ~45 us para asegurar carga completa del S&H al conmutar
;           entre AN0 y AN1, y retorna los 8 bits altos en W.
;*******************************************************************************
LEER_ADC_CANAL:
    MOVWF   ADCON0              ; Selecciona canal ANx
    MOVLW   d'15'               ; ~45 us de tiempo de adquisición
    MOVWF   AUX_L
    DECFSZ  AUX_L, F
    GOTO    $-1
    BSF     ADCON0, 1           ; Inicia conversión (GO/DONE = 1)
    BTFSC   ADCON0, 1           ; Espera fin de conversión
    GOTO    $-1
    MOVF    ADRESH, W
    RETURN

;*******************************************************************************
; @brief    Adquiere el canal AN0 (LM35) y convierte el resultado a °C enteros.
;           
; @details  Con Vref+ = 2.50 V y LM35 = 10 mV/°C, cada cuenta equivale a
;           250/256 °C. Calcula TEMP_C = ((ADRESH << 8) - 6 * ADRESH) >> 8.
;******************************************************************************* 
LEER_TEMP:
    MOVLW   ADC_CH_AN0
    CALL    LEER_ADC_CANAL

    MOVWF   PROD_H              ; PROD = ADRESH * 256
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
; @brief    Inicializa en el arranque el buffer de AN1 y la pre-calibración.
;*******************************************************************************
INIT_PULSO_BG:
    CLRF    REFRACT
    CLRF    MAX_DROP
    MOVLW   DECAY_TICKS
    MOVWF   DECAY_TMR
    MOVLW   DROP_THRESH_IDLE    ; Arranca en 5 (rechaza ruido hasta detectar pulso)
    MOVWF   DROP_THRESH

    MOVLW   ADC_CH_AN1          ; Precarga buffer circular de 18 muestras
    CALL    LEER_ADC_CANAL
    MOVWF   PULSE_ADC

    BCF     STATUS, IRP         ; Direccionamiento indirecto en Banco 0
    MOVLW   PULSE_BUF
    MOVWF   FSR
    MOVLW   d'18'
    MOVWF   AUX_L
IPB_FILL:
    MOVF    PULSE_ADC, W
    MOVWF   INDF
    INCF    FSR, F
    DECFSZ  AUX_L, F
    GOTO    IPB_FILL
    RETURN

;*******************************************************************************
; @brief    Calcula DROP_THRESH en función de MAX_DROP actual.
;           
; @details  Si MAX_DROP < 6 (sin pulso confirmado): DROP_THRESH = 5.
;           Si MAX_DROP >= 6 (pulso confirmado): DROP_THRESH = clamp(MAX_DROP/2, 4, 9).
;*******************************************************************************
ACTUALIZAR_UMBRAL:
    MOVLW   d'6'
    SUBWF   MAX_DROP, W         ; C=1 si MAX_DROP >= 6
    BTFSC   STATUS, C
    GOTO    AU_CON_PULSO
    MOVLW   DROP_THRESH_IDLE    ; Sin pulso confirmado: umbral = 5
    MOVWF   DROP_THRESH
    RETURN

AU_CON_PULSO:
    BCF     STATUS, C
    RRF     MAX_DROP, W         ; W = MAX_DROP / 2
    MOVWF   AUX_L

    MOVLW   DROP_THRESH_MIN     ; Piso mínimo = 4
    SUBWF   AUX_L, W
    MOVLW   DROP_THRESH_MIN
    BTFSC   STATUS, C
    MOVF    AUX_L, W
    MOVWF   AUX_L

    MOVLW   DROP_THRESH_MAX + 1 ; Techo máximo = 9
    SUBWF   AUX_L, W
    MOVLW   DROP_THRESH_MAX
    BTFSS   STATUS, C
    MOVF    AUX_L, W
    MOVWF   DROP_THRESH
    RETURN

;*******************************************************************************
; @brief    Inicia la ventana de conteo (15 s) usando los umbrales ya calibrados.
;           
; @details  Conserva PULSE_BUF y DROP_THRESH pre-calibrados en segundo plano,
;           cambia el display a Frecuencia (t-15 .. t-01) y resetea PULSE_COUNT.
;*******************************************************************************
INICIAR_MEDICION_PULSO:
    BCF     FLAGS, F_CMD_START
    BSF     FLAGS, F_MEAS_ACTIVE
    BSF     FLAGS, F_DISP_MODE  ; Cambia automáticamente el display a Frecuencia

    MOVLW   MEAS_SECONDS        ; Arranca cuenta regresiva en 15 s (t-15)
    MOVWF   COUNTDOWN_SEC
    MOVLW   TICKS_PER_SEC       ; 100 ticks (~1 s) por segundo regresivo
    MOVWF   SEC_SUB_TMR
    CLRF    PULSE_COUNT

    MOVLW   d'1'
    MOVWF   DISP_TMR            ; Refresca display inmediatamente (muestra t-15)
    RETURN

;*******************************************************************************
; @brief    Adquiere AN1, filtra 50 Hz (FIR 4-tap), pre-calibra umbrales de
;           forma continua y cuenta latidos cuando F_MEAS_ACTIVE = 1.
;*******************************************************************************
PROCESAR_PULSO:
    MOVLW   ADC_CH_AN1
    CALL    LEER_ADC_CANAL
    MOVWF   PULSE_ADC

    MOVF    REFRACT, F          ; Descuenta bloqueo refractario si está activo
    BTFSS   STATUS, Z
    DECF    REFRACT, F

    ; --- 1. Decaimiento lento de MAX_DROP (cada 1.5 s) para bajar umbral solo ---
    DECFSZ  DECAY_TMR, F
    GOTO    PP_SHIFT_START
    MOVLW   DECAY_TICKS
    MOVWF   DECAY_TMR
    MOVF    MAX_DROP, F
    BTFSS   STATUS, Z
    DECF    MAX_DROP, F
    CALL    ACTUALIZAR_UMBRAL

    ; --- 2. Desplaza buffer circular de 18 muestras (PULSE_BUF[17..0]) ---
PP_SHIFT_START:
    BCF     STATUS, IRP         ; Direccionamiento indirecto en Banco 0
    MOVLW   PULSE_BUF + d'16'
    MOVWF   FSR
    MOVLW   d'17'
    MOVWF   AUX_L
PP_SHIFT_BUF:
    MOVF    INDF, W             ; Lee PULSE_BUF[i]
    INCF    FSR, F
    MOVWF   INDF                ; Escribe en PULSE_BUF[i+1]
    DECF    FSR, F
    DECF    FSR, F
    DECFSZ  AUX_L, F
    GOTO    PP_SHIFT_BUF
    MOVF    PULSE_ADC, W
    MOVWF   PULSE_BUF           ; PULSE_BUF[0] = muestra actual

    ; --- 3. Suma FIR 4 muestras actuales: S4_NOW = BUF[0]+BUF[1]+BUF[2]+BUF[3] ---
    CLRF    S4_NOW_H
    MOVF    PULSE_BUF + d'0', W
    MOVWF   S4_NOW_L

    MOVF    PULSE_BUF + d'1', W
    ADDWF   S4_NOW_L, F
    BTFSC   STATUS, C
    INCF    S4_NOW_H, F

    MOVF    PULSE_BUF + d'2', W
    ADDWF   S4_NOW_L, F
    BTFSC   STATUS, C
    INCF    S4_NOW_H, F

    MOVF    PULSE_BUF + d'3', W
    ADDWF   S4_NOW_L, F
    BTFSC   STATUS, C
    INCF    S4_NOW_H, F

    ; --- 4. Suma FIR de hace 140 ms: S4_OLD = BUF[14]+BUF[15]+BUF[16]+BUF[17] ---
    CLRF    S4_OLD_H
    MOVF    PULSE_BUF + d'14', W
    MOVWF   S4_OLD_L

    MOVF    PULSE_BUF + d'15', W
    ADDWF   S4_OLD_L, F
    BTFSC   STATUS, C
    INCF    S4_OLD_H, F

    MOVF    PULSE_BUF + d'16', W
    ADDWF   S4_OLD_L, F
    BTFSC   STATUS, C
    INCF    S4_OLD_H, F

    MOVF    PULSE_BUF + d'17', W
    ADDWF   S4_OLD_L, F
    BTFSC   STATUS, C
    INCF    S4_OLD_H, F

    ; --- 5. Caída sistólica con signo: DROP (en S4_OLD_H:L) = S4_OLD - S4_NOW ---
    MOVF    S4_NOW_L, W
    SUBWF   S4_OLD_L, F
    BTFSS   STATUS, C
    DECF    S4_OLD_H, F
    MOVF    S4_NOW_H, W
    SUBWF   S4_OLD_H, F

    ; --- 6. Histéresis de rearmado: si DROP <= 1, libera F_PULSE_LOCK ---
    BTFSC   S4_OLD_H, 7         ; ¿DROP < 0?
    GOTO    PP_REARMAR
    MOVF    S4_OLD_H, F
    BTFSS   STATUS, Z           ; ¿DROP >= 256?
    GOTO    PP_EVAL_DISPARO
    MOVLW   d'2'
    SUBWF   S4_OLD_L, W         ; C=0 si DROP < 2 (es decir, DROP <= 1)
    BTFSC   STATUS, C
    GOTO    PP_EVAL_DISPARO

PP_REARMAR:
    BCF     FLAGS, F_PULSE_LOCK
    GOTO    PP_CHECK_VENTANA

    ; --- 7. Evaluación de latido: DROP >= DROP_THRESH, libre y sin refract ---
PP_EVAL_DISPARO:
    BTFSC   FLAGS, F_PULSE_LOCK
    GOTO    PP_ADAPTAR_UMBRAL
    MOVF    REFRACT, F
    BTFSS   STATUS, Z
    GOTO    PP_CHECK_VENTANA

    MOVF    S4_OLD_H, F
    BTFSS   STATUS, Z           ; Si S4_OLD_H > 0, DROP >= 256 >= DROP_THRESH
    GOTO    PP_LATIDO_VALIDO
    MOVF    DROP_THRESH, W
    SUBWF   S4_OLD_L, W         ; C=1 si S4_OLD_L >= DROP_THRESH
    BTFSS   STATUS, C
    GOTO    PP_CHECK_VENTANA

PP_LATIDO_VALIDO:
    BTFSC   FLAGS, F_MEAS_ACTIVE ; Solo suma latidos si la ventana de 15 s está activa
    INCF    PULSE_COUNT, F
    BSF     FLAGS, F_PULSE_LOCK
    MOVLW   REFRACT_TICKS
    MOVWF   REFRACT

    ; --- 8. Pre-calibración continua de MAX_DROP y DROP_THRESH ---
PP_ADAPTAR_UMBRAL:
    MOVF    S4_OLD_H, F
    BTFSS   STATUS, Z           ; Ignora transitorios > 28
    GOTO    PP_CHECK_VENTANA
    MOVLW   DROP_TRANS_LIM + 1
    SUBWF   S4_OLD_L, W
    BTFSC   STATUS, C
    GOTO    PP_CHECK_VENTANA

    MOVLW   DROP_CAP_MAX + 1    ; Acota caída almacenada en 18 para decaimiento ágil
    SUBWF   S4_OLD_L, W
    MOVLW   DROP_CAP_MAX
    BTFSS   STATUS, C
    MOVF    S4_OLD_L, W
    MOVWF   AUX_L

    MOVF    AUX_L, W            ; Actualiza MAX_DROP si AUX_L > MAX_DROP
    SUBWF   MAX_DROP, W
    BTFSC   STATUS, C
    GOTO    PP_CHECK_VENTANA

    MOVF    AUX_L, W
    MOVWF   MAX_DROP
    CALL    ACTUALIZAR_UMBRAL

    ; --- 9. Temporización de 1 s (100 ticks) solo si medición activa ---
PP_CHECK_VENTANA:
    BTFSS   FLAGS, F_MEAS_ACTIVE
    RETURN

    DECFSZ  SEC_SUB_TMR, F
    RETURN
    MOVLW   TICKS_PER_SEC
    MOVWF   SEC_SUB_TMR

    MOVLW   d'1'
    MOVWF   DISP_TMR            ; Actualiza display inmediatamente cada segundo
    DECFSZ  COUNTDOWN_SEC, F
    RETURN                      ; Aún quedan segundos (14..1)

    ; --- Fin de los 15 s: calcula BPM = PULSE_COUNT * 4 (0 si no hubo pulsos) ---
    BCF     FLAGS, F_MEAS_ACTIVE
    MOVF    PULSE_COUNT, W
    MOVWF   BPM_VAL
    BCF     STATUS, C
    RLF     BPM_VAL, F          ; x2
    MOVLW   0xFF
    BTFSC   STATUS, C
    MOVWF   BPM_VAL             ; Satura en 255 si desbordó
    BCF     STATUS, C
    RLF     BPM_VAL, F          ; x4
    MOVLW   0xFF
    BTFSC   STATUS, C
    MOVWF   BPM_VAL             ; Satura en 255 si desbordó
    RETURN

;*******************************************************************************
; @brief    Divide UNITS entre 10: cociente en TENS y resto en UNITS.
;*******************************************************************************
DIV_UNITS_10:
    CLRF    TENS
DU10_LOOP:
    MOVLW   d'10'
    SUBWF   UNITS, W
    BTFSS   STATUS, C
    RETURN
    MOVWF   UNITS
    INCF    TENS, F
    GOTO    DU10_LOOP

;*******************************************************************************
; @brief    Actualiza los 4 dígitos del display y prepara la trama UART TX.
;******************************************************************************* 
ACTUALIZAR_DISPLAY:
    BTFSC   FLAGS, F_DISP_MODE
    GOTO    MOSTRAR_FREC

; --- Formateo de Temperatura: [Decena][Unidad][°][C] ---
MOSTRAR_TEMP:
    MOVF    TEMP_C, W
    MOVWF   UNITS
    MOVLW   d'100'
    SUBWF   UNITS, W
    BTFSS   STATUS, C
    GOTO    $+3
    MOVLW   d'99'               ; Satura en 99 °C
    MOVWF   UNITS

    CALL    DIV_UNITS_10
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
    GOTO    PREPARAR_TRAMA_UART

; --- Formateo de Cuenta Regresiva (t-15..t-01) o Frecuencia (FXXX / F---) ---
MOSTRAR_FREC:
    BTFSS   FLAGS, F_MEAS_ACTIVE
    GOTO    MF_RESULTADO

    ; Medición en curso: muestra [t][-][Decena][Unidad]
    MOVLW   SEG_T
    MOVWF   DSPL_1              ; Dígito 1: 't'
    MOVLW   SEG_DASH
    MOVWF   DSPL_2              ; Dígito 2: '-'

    MOVF    COUNTDOWN_SEC, W
    MOVWF   UNITS
    CALL    DIV_UNITS_10
    MOVF    TENS, W
    CALL    TABLA_7SEG
    MOVWF   DSPL_3              ; Dígito 3: Decena de segundos (1 o 0)
    MOVF    UNITS, W
    CALL    TABLA_7SEG
    MOVWF   DSPL_4              ; Dígito 4: Unidad de segundos (5..0 / 9..1)
    GOTO    PREPARAR_TRAMA_UART

    ; Medición finalizada: muestra F--- si BPM_VAL = 0, o FXXX si > 0
MF_RESULTADO:
    MOVLW   SEG_F               ; Dígito 1: 'F'
    MOVWF   DSPL_1

    MOVF    BPM_VAL, F
    BTFSS   STATUS, Z
    GOTO    MF_CALC_BCD
    MOVLW   SEG_DASH
    MOVWF   DSPL_2
    MOVWF   DSPL_3
    MOVWF   DSPL_4
    GOTO    PREPARAR_TRAMA_UART

MF_CALC_BCD:
    MOVF    BPM_VAL, W
    MOVWF   UNITS
    CLRF    HUNDREDS

MF_DIV100:
    MOVLW   d'100'
    SUBWF   UNITS, W
    BTFSS   STATUS, C
    GOTO    MF_WRITE
    MOVWF   UNITS
    INCF    HUNDREDS, F
    GOTO    MF_DIV100

MF_WRITE:
    CALL    DIV_UNITS_10
    MOVF    HUNDREDS, W
    CALL    TABLA_7SEG
    MOVWF   DSPL_2              ; Dígito 2: Centena de BPM
    MOVF    TENS, W
    CALL    TABLA_7SEG
    MOVWF   DSPL_3              ; Dígito 3: Decena de BPM
    MOVF    UNITS, W
    CALL    TABLA_7SEG
    MOVWF   DSPL_4              ; Dígito 4: Unidad de BPM

;*******************************************************************************
; @brief    Construye la trama ASCII "Txx,Myy,Bzzz\r\n" en TX_BUF si está libre.
;*******************************************************************************
PREPARAR_TRAMA_UART:
    MOVF    TX_LEN, F
    BTFSS   STATUS, Z           ; Si aún hay una trama enviándose, no sobreescribe
    RETURN

    MOVLW   'T'
    MOVWF   TX_BUF + d'0'
    MOVLW   ','
    MOVWF   TX_BUF + d'3'
    MOVLW   'M'
    MOVWF   TX_BUF + d'4'
    MOVLW   ','
    MOVWF   TX_BUF + d'7'
    MOVLW   'B'
    MOVWF   TX_BUF + d'8'
    MOVLW   0x0D                ; CR (\r)
    MOVWF   TX_BUF + d'12'
    MOVLW   0x0A                ; LF (\n)
    MOVWF   TX_BUF + d'13'

    ; --- Temperatura (Txx) ---
    MOVF    TEMP_C, W
    MOVWF   UNITS
    MOVLW   d'100'
    SUBWF   UNITS, W
    BTFSS   STATUS, C
    GOTO    $+3
    MOVLW   d'99'
    MOVWF   UNITS
    CALL    DIV_UNITS_10
    MOVF    TENS, W
    ADDLW   '0'
    MOVWF   TX_BUF + d'1'
    MOVF    UNITS, W
    ADDLW   '0'
    MOVWF   TX_BUF + d'2'

    ; --- Estado de medición / cuenta regresiva (Myy) ---
    BTFSC   FLAGS, F_MEAS_ACTIVE
    GOTO    PTU_MEAS_ON
    MOVLW   '0'
    MOVWF   TX_BUF + d'5'
    MOVWF   TX_BUF + d'6'
    GOTO    PTU_BPM

PTU_MEAS_ON:
    MOVF    COUNTDOWN_SEC, W
    MOVWF   UNITS
    CALL    DIV_UNITS_10
    MOVF    TENS, W
    ADDLW   '0'
    MOVWF   TX_BUF + d'5'
    MOVF    UNITS, W
    ADDLW   '0'
    MOVWF   TX_BUF + d'6'

    ; --- Frecuencia cardíaca (Bzzz) ---
PTU_BPM:
    MOVF    BPM_VAL, W
    MOVWF   UNITS
    CLRF    HUNDREDS
PTU_DIV100:
    MOVLW   d'100'
    SUBWF   UNITS, W
    BTFSS   STATUS, C
    GOTO    PTU_BPM_10
    MOVWF   UNITS
    INCF    HUNDREDS, F
    GOTO    PTU_DIV100
PTU_BPM_10:
    CALL    DIV_UNITS_10
    MOVF    HUNDREDS, W
    ADDLW   '0'
    MOVWF   TX_BUF + d'9'
    MOVF    TENS, W
    ADDLW   '0'
    MOVWF   TX_BUF + d'10'
    MOVF    UNITS, W
    ADDLW   '0'
    MOVWF   TX_BUF + d'11'

    CLRF    TX_IDX
    MOVLW   TX_FRAME_LEN
    MOVWF   TX_LEN
    RETURN

;*******************************************************************************
; @brief    Envía 1 byte de TX_BUF por EUSART TX sin bloquear el lazo principal.
;*******************************************************************************
ENVIAR_BYTE_UART:
    BTFSS   PIR1, TXIF          ; ¿Buffer TXREG disponible?
    RETURN
    BCF     STATUS, IRP         ; Direccionamiento indirecto en Banco 0
    MOVLW   TX_BUF
    ADDWF   TX_IDX, W
    MOVWF   FSR
    MOVF    INDF, W
    MOVWF   TXREG               ; Transmite carácter
    INCF    TX_IDX, F
    DECFSZ  TX_LEN, F
    RETURN
    CLRF    TX_IDX              ; Trama completa enviada
    RETURN
    
;===============================================================================        
    END
;===============================================================================