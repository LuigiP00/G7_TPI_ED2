;*******************************************************************************
; @brief       ANEXO B - FIRMWARE DEL SEP (ARQUITECTURA POR INTERRUPCIONES).
;
; @brief       Termómetro digital (LM35) + Pulsómetro a demanda por UART
;              (HW-827 @ 5V, divisor simétrico 22k/22k + 1 uF, filtro FIR de
;              4 muestras y pre-calibración continua de pendiente sistólica)
;              con display multiplexado de 4 dígitos, alarma lumínica/sonora y
;              telemetría ASCII por EUSART hacia interfaz web local.
;
; @details     - Arquitectura 100 % dirigida por eventos (ISR multi-fuente):
;                  * Timer1 (5 ms)    -> ATENDER_MULTIPLEX_DISPLAY
;                  * EUSART RX        -> ATENDER_RECEPCION_UART ('I' / 'V' / 'G')
;                  * EUSART TX        -> ATENDER_TRANSMISION_UART
;                  * Timer0 (9.98 ms) -> ADQUISICION_SENALES_ADC (ADC, control y TX)
;              - AN0 (RA0): Sensor de temperatura LM35 (10 mV/°C, Vref+ = 2.50 V).
;              - AN1 (RA1): Sensor de pulsos HW-827 (5 V) con divisor simétrico
;                           22k/22k y capacitor electrolítico de 1 uF a masa.
;              - Alarmas de temperatura (> 40 °C): LED rojo RB7 ON, LED verde
;                RB6 OFF y buzzer RC4 encendido de forma continua.
;              - Comando 'G'/'g': Alterna volcado CSV "XXX,L\r\n" a 100 Hz con el
;                valor ADC de AN1 y el disparo de pulso para graficación.
; 
; @author      Gx_TPI_ED2
;
; @date        17/11/2026
;
; @version     6.4
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
PRECARGA_TMR0           EQU d'100'      ; 156 cuentas x 64 us = 9.984 ms por tick
PRECARGA_TMR1_H         EQU 0xEC        ; 0xEC78 = 60536 -> 5000 us = 5 ms por dígito
PRECARGA_TMR1_L         EQU 0x78

; --- Temperatura y Refresco ---
UMBRAL_TEMP_ALARMA      EQU d'40'       ; Umbral de alarma térmica en °C (> 40 °C)
TICKS_REFRESCO_DISP     EQU d'25'       ; Refresco display y TX: 25 x 9.984 ms = ~250 ms

; --- Pulsómetro (FIR 4 muestras + Pre-calibración adaptativa 140 ms) ---
SEGUNDOS_MEDICION       EQU d'15'       ; Duración de la ventana de medición (15 s)
TICKS_POR_SEGUNDO       EQU d'100'      ; 100 x 9.984 ms = ~1.00 s por paso regresivo
TICKS_BLOQUEO_LATIDO    EQU d'45'       ; Bloqueo refractario: 45 x 9.984 ms = ~450 ms
TICKS_DECAIMIENTO       EQU d'150'      ; Decaimiento de caída máx: 150 ticks = ~1.50 s
UMBRAL_CAIDA_REPOSO     EQU d'5'        ; Umbral sin pulso confirmado (rechaza ruido)
UMBRAL_CAIDA_MIN        EQU d'4'        ; Piso mínimo con pulso débil confirmado
UMBRAL_CAIDA_MAX        EQU d'9'        ; Techo máximo del umbral adaptativo
TOPE_CAIDA_MAX          EQU d'18'       ; Tope de almacenamiento para decaimiento ágil
LIMITE_RUIDO_TRANS      EQU d'28'       ; Límite superior para descartar transitorios

; --- Canales ADC (Fosc/8, ADON=1) ---
CANAL_ADC_TEMP          EQU b'01000001' ; Canal AN0 (LM35)
CANAL_ADC_PULSO         EQU b'01000101' ; Canal AN1 (HW-827)

; --- EUSART ---
BAUDIOS_9600            EQU d'25'       ; 4 MHz / (16 * (25 + 1)) = 9615 Bd (Error 0.16%)
LARGO_TRAMA_TX          EQU d'14'       ; Longitud de trama "Txx,Myy,Bzzz\r\n"
LARGO_TRAMA_GRAFICO     EQU d'7'        ; Longitud de trama CSV "XXX,L\r\n" (7.28 ms)

; --- Display 7 Segmentos (Ánodo común, lógica negativa) ---
CARACTER_T              EQU 0x87        ; Letra 't'   (d, e, f, g en 0)
CARACTER_F              EQU 0x8E        ; Letra 'F'   (a, e, f, g en 0)
CARACTER_GRADO          EQU 0x9C        ; Símbolo '°' (a, b, f, g en 0)
CARACTER_GUION          EQU 0xBF        ; Guion '-'   (g en 0)
CARACTER_C              EQU 0xC6        ; Letra 'C'   (a, d, e, f en 0)
DISPLAY_APAGADO         EQU 0xFF        ; Todos los segmentos apagados

; --- Bits del registro BANDERAS ---
BIT_MODO_DISPLAY        EQU 0           ; 0 = Muestra Temperatura, 1 = Muestra Frecuencia
BIT_MIDIENDO_PULSO      EQU 1           ; 1 = Medición de pulsos (15 s) en curso
BIT_LATIDO_DETECTADO    EQU 2           ; 1 = Latido detectado (esperar caída <= 1)
BIT_MODO_GRAFICO        EQU 3           ; 1 = Volcado CSV ADC de pulso a 100 Hz por UART

;===============================================================================
; DEFINICIÓN DE VARIABLES EN RAM
;=============================================================================== 
    CBLOCK 0x20                         ; Banco 0
        BANDERAS                        ; Banderas de estado del sistema
        DATO_RX_UART                    ; Carácter recibido por puerto serie
        ; --- Temperatura y Cálculos Generales ---
        TEMP_ACTUAL_C                   ; Temperatura medida en °C enteros
        ACUM_16_L, ACUM_16_H            ; Acumulador de 16 bits (escalado temp y suma FIR)
        AUX_CALC_L, AUX_CALC_H          ; Registros auxiliares de cálculo y retardos
        CONT_REFRESCO_DISP              ; Contador de ticks para refresco visual (~250 ms)
        ; --- Pulsómetro (Filtro FIR 4 muestras + Umbral Adaptativo) ---
        MUESTRA_ADC_PULSO               ; Última conversión ADC de AN1 (0..255)
        SUMA_FIR_ACTUAL_L               ; Suma de las 4 muestras más recientes (byte bajo)
        SUMA_FIR_ACTUAL_H               ; Suma de las 4 muestras más recientes (byte alto)
        SUMA_FIR_ANTERIOR_L             ; Suma de hace 140 ms y luego caída sistólica (L)
        SUMA_FIR_ANTERIOR_H             ; Suma de hace 140 ms y luego caída sistólica (H)
        UMBRAL_CAIDA_ACTUAL             ; Umbral dinámico de detección de latido (4..9)
        CAIDA_MAX_RECIENTE              ; Máxima caída sistólica reciente (con decaimiento)
        CONT_DECAIMIENTO                ; Temporizador de decaimiento (1.5 s)
        CONT_BLOQUEO_LATIDO             ; Ticks restantes de bloqueo refractario
        SEGUNDOS_RESTANTES              ; Cuenta regresiva de medición (15..1 s)
        CONT_TICKS_SEGUNDO              ; Subcontador de 100 ticks (~1 s)
        CONTADOR_LATIDOS                ; Latidos detectados en la ventana de 15 s
        FRECUENCIA_BPM                  ; Frecuencia cardíaca calculada (latidos x 4)
        BUFFER_MUESTRAS_PULSO:18        ; Historial circular de 18 muestras (180 ms)
        ; --- Display 7 Segmentos ---
        DIGITO_1, DIGITO_2              ; Patrón de segmentos dígito 1 (izq) y dígito 2
        DIGITO_3, DIGITO_4              ; Patrón de segmentos dígito 3 y dígito 4 (der)
        INDICE_MULTIPLEX                ; Dígito activo actual en el barrido (0..3)
        MASCARA_DIGITO                  ; Máscara de habilitación en RC0..RC3
        CENTENAS, DECENAS, UNIDADES     ; Dígitos decimales para conversión BCD
        ; --- Telemetría Serie UART TX ---
        BYTES_PENDIENTES_TX             ; Cantidad de bytes por enviar (0 = libre)
        INDICE_TX                       ; Posición actual dentro de BUFFER_TRAMA_TX
        BUFFER_TRAMA_TX:14              ; Trama ASCII "Txx,Myy,Bzzz\r\n" o CSV "XXX,L\r\n"
    ENDC

    CBLOCK 0x70                         ; Memoria común (guardado de contexto ISR)
        W_TEMP, STATUS_TEMP, FSR_TEMP, PCLATH_TEMP
    ENDC

;===============================================================================
; DECLARACIÓN DE MACROS PARA CONFIGURACIÓN DE REGISTROS
;===============================================================================            
CFG_PORTA MACRO
    BANKSEL ANSEL
    MOVLW   b'00001011'                 ; RA0 (AN0, LM35), RA1 (AN1, pulso) y RA3 (Vref+) analógicos
    MOVWF   ANSEL
    BANKSEL TRISA
    MOVLW   b'00001011'                 ; RA0, RA1 y RA3 como entradas
    MOVWF   TRISA
    ENDM

CFG_PORTB MACRO
    BANKSEL ANSELH
    CLRF    ANSELH                      ; PORTB completamente digital
    BANKSEL TRISB
    MOVLW   b'00111111'                 ; RB6 (LED verde) y RB7 (LED rojo) como salidas
    MOVWF   TRISB
    BANKSEL PORTB
    CLRF    PORTB                       ; LEDs inicialmente apagados
    ENDM

CFG_PORTC MACRO
    BANKSEL TRISC
    MOVLW   b'11100000'                 ; RC0..RC3 (dígitos), RC4 (buzzer) salidas; RC6/RC7 UART
    MOVWF   TRISC
    BANKSEL PORTC
    MOVLW   b'11101111'                 ; Dígitos apagados (1) y buzzer RC4 apagado (0)
    MOVWF   PORTC
    ENDM

CFG_PORTD MACRO
    BANKSEL TRISD
    CLRF    TRISD                       ; RD0..RD7 (segmentos) como salidas
    BANKSEL PORTD
    MOVLW   DISPLAY_APAGADO             ; Segmentos apagados (ánodo común, lógica negativa)
    MOVWF   PORTD
    ENDM

CFG_ADC MACRO
    BANKSEL ADCON1
    MOVLW   b'00010000'                 ; ADFM=0 (8 bits en ADRESH), VCFG0=1 (Vref+ en RA3)
    MOVWF   ADCON1
    BANKSEL ADCON0
    MOVLW   CANAL_ADC_TEMP              ; Fosc/8, canal AN0, ADC encendido
    MOVWF   ADCON0
    ENDM

CFG_EUSART MACRO
    BANKSEL BAUDCTL
    BCF     BAUDCTL, BRG16              ; Generador de baudios de 8 bits
    BANKSEL SPBRG
    MOVLW   BAUDIOS_9600                ; 9600 Bd @ 4 MHz (BRGH=1, SYNC=0)
    MOVWF   SPBRG
    MOVLW   b'00100100'                 ; TXEN=1 (habilita TX), SYNC=0 (asíncrono), BRGH=1
    MOVWF   TXSTA
    BANKSEL PIE1
    BSF     PIE1, RCIE                  ; Habilita interrupción por recepción RX
    BCF     PIE1, TXIE                  ; TXIE se habilita bajo demanda al armar trama
    BANKSEL RCSTA
    MOVLW   b'10010000'                 ; SPEN=1 (habilita RC6/RC7), CREN=1 (RX continua)
    MOVWF   RCSTA
    ENDM

CFG_TIMER0 MACRO
    BANKSEL OPTION_REG
    MOVLW   b'11010101'                 ; Pull-ups deshabilitados, Timer0 prescaler 1:64
    MOVWF   OPTION_REG
    BANKSEL TMR0
    MOVLW   PRECARGA_TMR0               ; Precarga para base de tiempo de 9.984 ms
    MOVWF   TMR0
    BCF     INTCON, T0IF
    BSF     INTCON, T0IE                ; Habilita interrupción por desborde de Timer0
    ENDM

CFG_TIMER1 MACRO
    BANKSEL T1CON
    MOVLW   b'00000001'                 ; TMR1ON=1, reloj interno, prescaler 1:1
    MOVWF   T1CON
    MOVLW   PRECARGA_TMR1_H             ; Precarga para interrupción cada 5 ms
    MOVWF   TMR1H
    MOVLW   PRECARGA_TMR1_L
    MOVWF   TMR1L
    BCF     PIR1, TMR1IF
    BANKSEL PIE1
    BSF     PIE1, TMR1IE                ; Habilita interrupción de Timer1
    BANKSEL PORTB                       ; Selecciona Banco 0 de forma permanente
    ENDM

;===============================================================================
; INICIALIZACIÓN DEL MCU (CÓDIGO ABSOLUTO)
;===============================================================================    
    ORG     0x00                        ; Vector de Reset
    GOTO    INICIO                      ; Salto al inicio del programa principal
    ORG     0x04                        ; Vector de Interrupción
    GOTO    ISR_INICIO                  ; Salto a la Rutina de Servicio de Interrupción
    ORG     0x05                        ; Inicio Página 0 - Tabla de conversión 7 segmentos

;*******************************************************************************
; @brief    Tabla de conversión BCD a 7 segmentos (ánodo común).
;           
; @details  Ubicada al inicio de Página 0 (0x05..0x0F) para evitar cruces de
;           frontera de 256 words en el salto calculado ADDWF PCL, F.
;*******************************************************************************
TABLA_7SEG:
    ADDWF   PCL, F
    RETLW   0xC0                        ; 0
    RETLW   0xF9                        ; 1
    RETLW   0xA4                        ; 2
    RETLW   0xB0                        ; 3
    RETLW   0x99                        ; 4
    RETLW   0x92                        ; 5
    RETLW   0x82                        ; 6
    RETLW   0xF8                        ; 7
    RETLW   0x80                        ; 8
    RETLW   0x90                        ; 9

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
    CFG_EUSART

    ;-----Inicialización de Variables----
    BANKSEL PORTB
    CLRF    BANDERAS                    ; Inicia mostrando Temperatura, medición inactiva
    CLRF    FRECUENCIA_BPM
    CLRF    BYTES_PENDIENTES_TX
    CLRF    INDICE_TX
    CLRF    INDICE_MULTIPLEX
    MOVLW   b'11111110'
    MOVWF   MASCARA_DIGITO
    MOVLW   TICKS_REFRESCO_DISP
    MOVWF   CONT_REFRESCO_DISP

    CALL    INICIALIZAR_SENSOR_PULSO    ; Precarga buffer AN1 y pre-calibración continua
    CALL    MEDIR_TEMPERATURA           ; Primera lectura válida antes de habilitar ISR
    CALL    CONTROLAR_ALARMA_TEMP
    CALL    ACTUALIZAR_PANTALLA_Y_TRAMA ; Prepara la primera trama UART (activa TXIE)

    ;-----Arranque de Temporizadores e Interrupciones-----
    CFG_TIMER0
    CFG_TIMER1                          ; Habilita Timer1 y selecciona Banco 0
    BSF     INTCON, PEIE                ; Habilita interrupciones de periféricos
    BSF     INTCON, GIE                 ; Habilita interrupciones globales

;===============================================================================
; INICIO PROGRAMA PRINCIPAL
;===============================================================================        
MAIN_LOOP  
    GOTO    MAIN_LOOP                   ; Ejecución gobernada íntegramente por la ISR
  
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
    MOVF    PCLATH, W
    MOVWF   PCLATH_TEMP
    CLRF    STATUS                      ; Selecciona Banco 0 e IRP=0
    CLRF    PCLATH                      ; Asegura Página 0 para saltos calculados
    ;----------------------------------------

    ;-----Identificación de Interrupción-----
    ; 1) Interrupción de Timer1 (5 ms): Multiplexado del display
    BTFSC   PIR1, TMR1IF
    CALL    ATENDER_MULTIPLEX_DISPLAY

    ; 2) Interrupción de EUSART RX: Comandos desde teclado/web ('I', 'V' y 'G')
    BTFSC   PIR1, RCIF
    CALL    ATENDER_RECEPCION_UART

    ; 3) Interrupción de EUSART TX: Envío de trama cuando TXREG está vacío
    MOVF    BYTES_PENDIENTES_TX, F
    BTFSC   STATUS, Z
    GOTO    VERIFICAR_TIMER0
    BTFSC   PIR1, TXIF
    CALL    ATENDER_TRANSMISION_UART

    ; 4) Interrupción de Timer0 (~10 ms): Adquisición ADC, control y refresco
VERIFICAR_TIMER0
    BTFSC   INTCON, T0IF
    CALL    ADQUISICION_SENALES_ADC
    ;----------------------------------------   
    
;===============================================================================
; FINALIZACIÓN DE RUTINAS DE SERVICIO DE INTERRUPCIÓN
;===============================================================================        
ISR_FIN     
    ;--------Restauración de Contexto--------        
    MOVF    PCLATH_TEMP, W
    MOVWF   PCLATH
    MOVF    FSR_TEMP, W
    MOVWF   FSR
    SWAPF   STATUS_TEMP, W
    MOVWF   STATUS
    SWAPF   W_TEMP, F
    SWAPF   W_TEMP, W
    RETFIE
    ;---------------------------------------- 

;===============================================================================
; SUBRUTINAS DE ATENCIÓN A EVENTOS DE INTERRUPCIÓN
;===============================================================================
;*******************************************************************************
; @brief    Atiende Timer1 (5 ms): multiplexa los 4 dígitos de 7 segmentos.
;*******************************************************************************
ATENDER_MULTIPLEX_DISPLAY
    BCF     PIR1, TMR1IF
    MOVLW   PRECARGA_TMR1_H             ; Recarga Timer1 (5 ms)
    MOVWF   TMR1H
    MOVLW   PRECARGA_TMR1_L
    MOVWF   TMR1L

    MOVLW   b'00001111'
    IORWF   PORTC, F                    ; Apaga dígitos RC0..RC3 preservando RC4 (buzzer)
    MOVLW   DIGITO_1
    ADDWF   INDICE_MULTIPLEX, W
    MOVWF   FSR
    MOVF    INDF, W
    MOVWF   PORTD                       ; Carga segmentos del dígito activo
    MOVF    PORTC, W
    IORLW   b'00001111'
    ANDWF   MASCARA_DIGITO, W
    MOVWF   PORTC                       ; Habilita dígito actual (0 en RC0..RC3)

    INCF    INDICE_MULTIPLEX, F
    BSF     STATUS, C
    RLF     MASCARA_DIGITO, F
    MOVF    INDICE_MULTIPLEX, W
    XORLW   d'4'
    BTFSS   STATUS, Z
    RETURN
    CLRF    INDICE_MULTIPLEX
    MOVLW   b'11111110'
    MOVWF   MASCARA_DIGITO
    RETURN

;*******************************************************************************
; @brief    Atiende EUSART RX: procesa comandos ASCII 'I'/'i', 'V'/'v' y 'G'/'g'.
;*******************************************************************************
ATENDER_RECEPCION_UART
    BTFSS   RCSTA, OERR                 ; Verifica error de saturación de buffer FIFO
    GOTO    LEER_CARACTER_UART
    BCF     RCSTA, CREN                 ; Destraba receptor reiniciando CREN
    BSF     RCSTA, CREN

LEER_CARACTER_UART
    MOVF    RCREG, W                    ; Lee carácter recibido (limpia RCIF)
    MOVWF   DATO_RX_UART
    BCF     DATO_RX_UART, 5             ; Normaliza minúsculas ('i','v','g') a mayúsculas

    ; ¿Tecla 'I' o 'i'? -> Inicia ventana de medición de pulsos (15 s)
    MOVF    DATO_RX_UART, W
    XORLW   'I'
    BTFSC   STATUS, Z
    GOTO    ARRANCAR_CONTEO_15S

    ; ¿Tecla 'V' o 'v'? -> Alterna vista del display (Temperatura <-> Frecuencia)
    MOVF    DATO_RX_UART, W
    XORLW   'V'
    BTFSC   STATUS, Z
    GOTO    CONMUTAR_VISTA_DISPLAY

    ; ¿Tecla 'G' o 'g'? -> Alterna salida CSV de ADC de pulso en vivo (100 Hz)
    MOVF    DATO_RX_UART, W
    XORLW   'G'
    BTFSC   STATUS, Z
    GOTO    CONMUTAR_MODO_GRAFICO
    RETURN

CONMUTAR_VISTA_DISPLAY
    MOVLW   (1 << BIT_MODO_DISPLAY)
    XORWF   BANDERAS, F                 ; Invierte modo de display (0 <-> 1)
    MOVLW   d'1'
    MOVWF   CONT_REFRESCO_DISP          ; Fuerza refresco inmediato en el próximo tick
    RETURN

CONMUTAR_MODO_GRAFICO
    MOVLW   (1 << BIT_MODO_GRAFICO)
    XORWF   BANDERAS, F                 ; Activa/desactiva streaming CSV "XXX,L\r\n"
    RETURN

;*******************************************************************************
; @brief    Atiende EUSART TX: envía 1 byte de BUFFER_TRAMA_TX por hardware.
;*******************************************************************************
ATENDER_TRANSMISION_UART
    BCF     STATUS, IRP                 ; Direccionamiento indirecto en Banco 0
    MOVLW   BUFFER_TRAMA_TX
    ADDWF   INDICE_TX, W
    MOVWF   FSR
    MOVF    INDF, W
    MOVWF   TXREG                       ; Transmite carácter
    INCF    INDICE_TX, F
    DECFSZ  BYTES_PENDIENTES_TX, F
    RETURN                              ; Aún quedan bytes pendientes

    CLRF    INDICE_TX                   ; Trama completa enviada
    BANKSEL PIE1
    BCF     PIE1, TXIE                  ; Deshabilita interrupción TX hasta próxima trama
    BANKSEL PORTB                       ; Retorna a Banco 0
    RETURN

;*******************************************************************************
; @brief    Atiende Timer0 (~10 ms): adquiere señales ADC, evalúa alarmas y refresca.
;*******************************************************************************
ADQUISICION_SENALES_ADC
    BCF     INTCON, T0IF
    MOVLW   PRECARGA_TMR0               ; Recarga Timer0 (9.984 ms)
    MOVWF   TMR0

    ; --- 1. Tarea permanente: Temperatura (AN0) y control de alarmas ---
    CALL    MEDIR_TEMPERATURA
    CALL    CONTROLAR_ALARMA_TEMP

    ; --- 2. Tarea permanente de pulsómetro: pre-calibración y conteo ---
    CALL    PROCESAR_SENAL_PULSO

    ; --- 3. Si el modo gráfico está activo, envía muestra CSV a 100 Hz ---
    BTFSC   BANDERAS, BIT_MODO_GRAFICO
    CALL    ENVIAR_TRAMA_ADC_PULSO

    ; --- 4. Actualización periódica (250 ms) o por cambio de vista ('V') ---
    DECFSZ  CONT_REFRESCO_DISP, F
    RETURN
    MOVLW   TICKS_REFRESCO_DISP
    MOVWF   CONT_REFRESCO_DISP
    CALL    ACTUALIZAR_PANTALLA_Y_TRAMA
    RETURN
 
;===============================================================================
; SUBRUTINAS DE ADQUISICIÓN Y CONTROL DE TEMPERATURA
;===============================================================================		
;*******************************************************************************
; @brief    Selecciona el canal ADC en W, espera adquisición y retorna ADRESH.
;*******************************************************************************
CONVERTIR_CANAL_ADC
    MOVWF   ADCON0                      ; Selecciona canal ANx
    MOVLW   d'15'                       ; ~45 us de tiempo de adquisición S&H
    MOVWF   AUX_CALC_L
    DECFSZ  AUX_CALC_L, F
    GOTO    $-1
    BSF     ADCON0, GO_DONE             ; Inicia conversión (GO/DONE = 1)
    BTFSC   ADCON0, GO_DONE             ; Espera fin de conversión
    GOTO    $-1
    MOVF    ADRESH, W
    RETURN

;*******************************************************************************
; @brief    Adquiere AN0 (LM35) y convierte el resultado a °C redondeados.
;           
; @details  Con Vref+ = 2.50 V y LM35 = 10 mV/°C:
;           TEMP_ACTUAL_C = ((ADRESH << 8) + 128 - 6 * ADRESH) >> 8.
;******************************************************************************* 
MEDIR_TEMPERATURA
    MOVLW   CANAL_ADC_TEMP
    CALL    CONVERTIR_CANAL_ADC

    MOVWF   ACUM_16_H                   ; ACUM_16 = ADRESH * 256 + 128 (+0.5 redondeo)
    MOVLW   d'128'
    MOVWF   ACUM_16_L
    MOVF    ACUM_16_H, W
    MOVWF   AUX_CALC_L
    CLRF    AUX_CALC_H
    BCF     STATUS, C
    RLF     AUX_CALC_L, F               ; AUX_CALC = 2 * ADRESH
    RLF     AUX_CALC_H, F
    CALL    RESTAR_16_BITS              ; ACUM_16 -= 2 * ADRESH
    BCF     STATUS, C
    RLF     AUX_CALC_L, F               ; AUX_CALC = 4 * ADRESH
    RLF     AUX_CALC_H, F
    CALL    RESTAR_16_BITS              ; ACUM_16 -= 4 * ADRESH (total: 250 * ADRESH + 128)
    MOVF    ACUM_16_H, W
    MOVWF   TEMP_ACTUAL_C
    RETURN

RESTAR_16_BITS
    MOVF    AUX_CALC_L, W
    SUBWF   ACUM_16_L, F
    BTFSS   STATUS, C
    DECF    ACUM_16_H, F
    MOVF    AUX_CALC_H, W
    SUBWF   ACUM_16_H, F
    RETURN

;*******************************************************************************
; @brief    Evalúa TEMP_ACTUAL_C contra 40 °C y gobierna LEDs y buzzer (RC4).
;           
; @details  Temp > 40 °C : LED rojo RB7 ON, verde RB6 OFF, buzzer RC4 ON continuo.
;           Temp <= 40 °C: LED rojo OFF, verde ON, buzzer OFF.
;******************************************************************************* 
CONTROLAR_ALARMA_TEMP
    MOVLW   UMBRAL_TEMP_ALARMA + 1
    SUBWF   TEMP_ACTUAL_C, W            ; C=1 si TEMP_ACTUAL_C >= 41 (> 40 °C)
    BTFSS   STATUS, C
    GOTO    ESTADO_TEMP_NORMAL          ; TEMP_ACTUAL_C <= 40 °C

    BSF     PORTB, 7                    ; Temp > 40 °C: LED rojo ON, verde OFF
    BCF     PORTB, 6
    BSF     PORTC, 4                    ; Buzzer ON continuo
    RETURN

ESTADO_TEMP_NORMAL
    BCF     PORTB, 7                    ; Temp <= 40 °C: LED rojo OFF, verde ON
    BSF     PORTB, 6
    BCF     PORTC, 4                    ; Buzzer OFF
    RETURN

;===============================================================================
; SUBRUTINAS DE PROCESAMIENTO DEL PULSÓMETRO (HW-827)
;===============================================================================
;*******************************************************************************
; @brief    Inicializa en el arranque el buffer de AN1 y la pre-calibración.
;*******************************************************************************
INICIALIZAR_SENSOR_PULSO
    CLRF    CONT_BLOQUEO_LATIDO
    CLRF    CAIDA_MAX_RECIENTE
    MOVLW   TICKS_DECAIMIENTO
    MOVWF   CONT_DECAIMIENTO
    MOVLW   UMBRAL_CAIDA_REPOSO         ; Arranca en 5 (rechaza ruido hasta detectar pulso)
    MOVWF   UMBRAL_CAIDA_ACTUAL

    MOVLW   CANAL_ADC_PULSO             ; Precarga buffer circular de 18 muestras
    CALL    CONVERTIR_CANAL_ADC
    MOVWF   MUESTRA_ADC_PULSO

    BCF     STATUS, IRP                 ; Direccionamiento indirecto en Banco 0
    MOVLW   BUFFER_MUESTRAS_PULSO
    MOVWF   FSR
    MOVLW   d'18'
    MOVWF   AUX_CALC_L
LLENAR_BUFFER_INICIAL
    MOVF    MUESTRA_ADC_PULSO, W
    MOVWF   INDF
    INCF    FSR, F
    DECFSZ  AUX_CALC_L, F
    GOTO    LLENAR_BUFFER_INICIAL
    RETURN

;*******************************************************************************
; @brief    Calcula UMBRAL_CAIDA_ACTUAL en función de CAIDA_MAX_RECIENTE.
;*******************************************************************************
RECALCULAR_UMBRAL_PULSO
    MOVLW   d'6'
    SUBWF   CAIDA_MAX_RECIENTE, W       ; C=1 si CAIDA_MAX_RECIENTE >= 6
    BTFSC   STATUS, C
    GOTO    AJUSTAR_UMBRAL_ACTIVO
    MOVLW   UMBRAL_CAIDA_REPOSO         ; Sin pulso confirmado: umbral = 5
    MOVWF   UMBRAL_CAIDA_ACTUAL
    RETURN

AJUSTAR_UMBRAL_ACTIVO
    BCF     STATUS, C
    RRF     CAIDA_MAX_RECIENTE, W       ; W = CAIDA_MAX_RECIENTE / 2
    MOVWF   AUX_CALC_L

    MOVLW   UMBRAL_CAIDA_MIN            ; Piso mínimo = 4
    SUBWF   AUX_CALC_L, W
    MOVLW   UMBRAL_CAIDA_MIN
    BTFSC   STATUS, C
    MOVF    AUX_CALC_L, W
    MOVWF   AUX_CALC_L

    MOVLW   UMBRAL_CAIDA_MAX + 1        ; Techo máximo = 9
    SUBWF   AUX_CALC_L, W
    MOVLW   UMBRAL_CAIDA_MAX
    BTFSS   STATUS, C
    MOVF    AUX_CALC_L, W
    MOVWF   UMBRAL_CAIDA_ACTUAL
    RETURN

;*******************************************************************************
; @brief    Inicia la ventana de conteo (15 s) usando los umbrales calibrados.
;*******************************************************************************
ARRANCAR_CONTEO_15S
    BSF     BANDERAS, BIT_MIDIENDO_PULSO
    BSF     BANDERAS, BIT_MODO_DISPLAY  ; Cambia automáticamente el display a Frecuencia

    MOVLW   SEGUNDOS_MEDICION           ; Arranca cuenta regresiva en 15 s (t-15)
    MOVWF   SEGUNDOS_RESTANTES
    MOVLW   TICKS_POR_SEGUNDO           ; 100 ticks (~1 s) por segundo regresivo
    MOVWF   CONT_TICKS_SEGUNDO
    CLRF    CONTADOR_LATIDOS

    MOVLW   d'1'
    MOVWF   CONT_REFRESCO_DISP          ; Refresca display inmediatamente (muestra t-15)
    RETURN

;*******************************************************************************
; @brief    Suma 4 muestras consecutivas apuntadas por FSR en ACUM_16_H:L.
;*******************************************************************************
CALCULAR_FILTRO_4_MUESTRAS
    CLRF    ACUM_16_L
    CLRF    ACUM_16_H
    MOVLW   d'4'
    MOVWF   AUX_CALC_L
LAZO_SUMA_FIR
    MOVF    INDF, W
    ADDWF   ACUM_16_L, F
    BTFSC   STATUS, C
    INCF    ACUM_16_H, F
    INCF    FSR, F
    DECFSZ  AUX_CALC_L, F
    GOTO    LAZO_SUMA_FIR
    RETURN

;*******************************************************************************
; @brief    Adquiere AN1, filtra 50 Hz (FIR 4-tap), pre-calibra umbrales de
;           forma continua y cuenta latidos cuando BIT_MIDIENDO_PULSO = 1.
;*******************************************************************************
PROCESAR_SENAL_PULSO
    MOVLW   CANAL_ADC_PULSO
    CALL    CONVERTIR_CANAL_ADC
    MOVWF   MUESTRA_ADC_PULSO

    MOVF    CONT_BLOQUEO_LATIDO, F      ; Descuenta bloqueo refractario si está activo
    BTFSS   STATUS, Z
    DECF    CONT_BLOQUEO_LATIDO, F

    ; --- 1. Decaimiento lento de CAIDA_MAX_RECIENTE (cada 1.5 s) ---
    DECFSZ  CONT_DECAIMIENTO, F
    GOTO    DESPLAZAR_BUFFER_PULSO
    MOVLW   TICKS_DECAIMIENTO
    MOVWF   CONT_DECAIMIENTO
    MOVF    CAIDA_MAX_RECIENTE, F
    BTFSS   STATUS, Z
    DECF    CAIDA_MAX_RECIENTE, F
    CALL    RECALCULAR_UMBRAL_PULSO

    ; --- 2. Desplaza buffer circular de 18 muestras (BUFFER[17..0]) ---
DESPLAZAR_BUFFER_PULSO
    BCF     STATUS, IRP                 ; Direccionamiento indirecto en Banco 0
    MOVLW   BUFFER_MUESTRAS_PULSO + d'16'
    MOVWF   FSR
    MOVLW   d'17'
    MOVWF   AUX_CALC_L
LAZO_DESPLAZAR_BUF
    MOVF    INDF, W                     ; Lee BUFFER[i]
    INCF    FSR, F
    MOVWF   INDF                        ; Escribe en BUFFER[i+1]
    DECF    FSR, F
    DECF    FSR, F
    DECFSZ  AUX_CALC_L, F
    GOTO    LAZO_DESPLAZAR_BUF
    MOVF    MUESTRA_ADC_PULSO, W
    MOVWF   BUFFER_MUESTRAS_PULSO       ; BUFFER[0] = muestra actual

    ; --- 3. Suma FIR 4 muestras actuales: SUMA_FIR_ACTUAL = BUF[0..3] ---
    MOVLW   BUFFER_MUESTRAS_PULSO
    MOVWF   FSR
    CALL    CALCULAR_FILTRO_4_MUESTRAS
    MOVF    ACUM_16_L, W
    MOVWF   SUMA_FIR_ACTUAL_L
    MOVF    ACUM_16_H, W
    MOVWF   SUMA_FIR_ACTUAL_H

    ; --- 4. Suma FIR de hace 140 ms: SUMA_FIR_ANTERIOR = BUF[14..17] ---
    MOVLW   BUFFER_MUESTRAS_PULSO + d'14'
    MOVWF   FSR
    CALL    CALCULAR_FILTRO_4_MUESTRAS
    MOVF    ACUM_16_L, W
    MOVWF   SUMA_FIR_ANTERIOR_L
    MOVF    ACUM_16_H, W
    MOVWF   SUMA_FIR_ANTERIOR_H

    ; --- 5. Caída sistólica con signo: CAIDA = SUMA_FIR_ANTERIOR - SUMA_FIR_ACTUAL ---
    MOVF    SUMA_FIR_ACTUAL_L, W
    SUBWF   SUMA_FIR_ANTERIOR_L, F
    BTFSS   STATUS, C
    DECF    SUMA_FIR_ANTERIOR_H, F
    MOVF    SUMA_FIR_ACTUAL_H, W
    SUBWF   SUMA_FIR_ANTERIOR_H, F

    ; --- 6. Histéresis de rearmado: si CAIDA <= 1, libera BIT_LATIDO_DETECTADO ---
    BTFSC   SUMA_FIR_ANTERIOR_H, 7      ; ¿CAIDA < 0?
    GOTO    REARMAR_DETECTOR_PULSO
    MOVF    SUMA_FIR_ANTERIOR_H, F
    BTFSS   STATUS, Z                   ; ¿CAIDA >= 256?
    GOTO    EVALUAR_DISPARO_LATIDO
    MOVLW   d'2'
    SUBWF   SUMA_FIR_ANTERIOR_L, W      ; C=0 si CAIDA < 2 (es decir, CAIDA <= 1)
    BTFSC   STATUS, C
    GOTO    EVALUAR_DISPARO_LATIDO

REARMAR_DETECTOR_PULSO
    BCF     BANDERAS, BIT_LATIDO_DETECTADO
    GOTO    ACTUALIZAR_RELOJ_MEDICION

    ; --- 7. Evaluación de latido: CAIDA >= UMBRAL_CAIDA_ACTUAL y sin bloqueo ---
EVALUAR_DISPARO_LATIDO
    BTFSC   BANDERAS, BIT_LATIDO_DETECTADO
    GOTO    ADAPTAR_UMBRAL_SISTOLICO
    MOVF    CONT_BLOQUEO_LATIDO, F
    BTFSS   STATUS, Z
    GOTO    ACTUALIZAR_RELOJ_MEDICION

    MOVF    SUMA_FIR_ANTERIOR_H, F
    BTFSS   STATUS, Z                   ; Si byte alto > 0, CAIDA >= 256 >= UMBRAL
    GOTO    REGISTRAR_LATIDO_VALIDO
    MOVF    UMBRAL_CAIDA_ACTUAL, W
    SUBWF   SUMA_FIR_ANTERIOR_L, W      ; C=1 si CAIDA >= UMBRAL_CAIDA_ACTUAL
    BTFSS   STATUS, C
    GOTO    ACTUALIZAR_RELOJ_MEDICION

REGISTRAR_LATIDO_VALIDO
    BTFSC   BANDERAS, BIT_MIDIENDO_PULSO ; Solo suma latidos si ventana de 15 s activa
    INCF    CONTADOR_LATIDOS, F
    BSF     BANDERAS, BIT_LATIDO_DETECTADO
    MOVLW   TICKS_BLOQUEO_LATIDO
    MOVWF   CONT_BLOQUEO_LATIDO

    ; --- 8. Pre-calibración continua de CAIDA_MAX_RECIENTE y umbral ---
ADAPTAR_UMBRAL_SISTOLICO
    MOVF    SUMA_FIR_ANTERIOR_H, F
    BTFSS   STATUS, Z                   ; Ignora transitorios > 28
    GOTO    ACTUALIZAR_RELOJ_MEDICION
    MOVLW   LIMITE_RUIDO_TRANS + 1
    SUBWF   SUMA_FIR_ANTERIOR_L, W
    BTFSC   STATUS, C
    GOTO    ACTUALIZAR_RELOJ_MEDICION

    MOVLW   TOPE_CAIDA_MAX + 1          ; Acota caída almacenada en 18
    SUBWF   SUMA_FIR_ANTERIOR_L, W
    MOVLW   TOPE_CAIDA_MAX
    BTFSS   STATUS, C
    MOVF    SUMA_FIR_ANTERIOR_L, W
    MOVWF   AUX_CALC_L

    MOVF    AUX_CALC_L, W               ; Actualiza si AUX_CALC_L > CAIDA_MAX_RECIENTE
    SUBWF   CAIDA_MAX_RECIENTE, W
    BTFSC   STATUS, C
    GOTO    ACTUALIZAR_RELOJ_MEDICION

    MOVF    AUX_CALC_L, W
    MOVWF   CAIDA_MAX_RECIENTE
    CALL    RECALCULAR_UMBRAL_PULSO

    ; --- 9. Temporización de 1 s (100 ticks) solo si medición activa ---
ACTUALIZAR_RELOJ_MEDICION
    BTFSS   BANDERAS, BIT_MIDIENDO_PULSO
    RETURN

    DECFSZ  CONT_TICKS_SEGUNDO, F
    RETURN
    MOVLW   TICKS_POR_SEGUNDO
    MOVWF   CONT_TICKS_SEGUNDO

    MOVLW   d'1'
    MOVWF   CONT_REFRESCO_DISP          ; Actualiza display inmediatamente cada segundo
    DECFSZ  SEGUNDOS_RESTANTES, F
    RETURN                              ; Aún quedan segundos (14..1)

    ; --- Fin de los 15 s: calcula BPM = CONTADOR_LATIDOS * 4 ---
    BCF     BANDERAS, BIT_MIDIENDO_PULSO
    MOVF    CONTADOR_LATIDOS, W
    MOVWF   FRECUENCIA_BPM
    BCF     STATUS, C
    RLF     FRECUENCIA_BPM, F           ; x2
    MOVLW   0xFF
    BTFSC   STATUS, C
    MOVWF   FRECUENCIA_BPM              ; Satura en 255 si desbordó
    BCF     STATUS, C
    RLF     FRECUENCIA_BPM, F           ; x4
    MOVLW   0xFF
    BTFSC   STATUS, C
    MOVWF   FRECUENCIA_BPM              ; Satura en 255 si desbordó
    RETURN

;===============================================================================
; SUBRUTINAS DE FORMATEO DECIMAL, DISPLAY Y TELEMETRÍA UART
;===============================================================================
;*******************************************************************************
; @brief    Carga TEMP_ACTUAL_C en UNIDADES saturado a un máximo de 99 °C.
;*******************************************************************************
LIMITAR_TEMP_A_99
    MOVF    TEMP_ACTUAL_C, W
    SUBLW   d'99'                       ; C=0 si TEMP_ACTUAL_C > 99
    MOVF    TEMP_ACTUAL_C, W
    BTFSS   STATUS, C
    MOVLW   d'99'
    MOVWF   UNIDADES
    RETURN

;*******************************************************************************
; @brief    Convierte el byte en W (0..255) a BCD: CENTENAS, DECENAS y UNIDADES.
;*******************************************************************************
CONVERTIR_A_3_DIGITOS
    MOVWF   UNIDADES
    CLRF    CENTENAS
LAZO_RESTAR_100
    MOVLW   d'100'
    SUBWF   UNIDADES, W
    BTFSS   STATUS, C
    GOTO    EXTRAER_DECENAS_UNIDADES
    MOVWF   UNIDADES
    INCF    CENTENAS, F
    GOTO    LAZO_RESTAR_100

;*******************************************************************************
; @brief    Divide UNIDADES entre 10: cociente en DECENAS y resto en UNIDADES.
;*******************************************************************************
EXTRAER_DECENAS_UNIDADES
    CLRF    DECENAS
LAZO_RESTAR_10
    MOVLW   d'10'
    SUBWF   UNIDADES, W
    BTFSS   STATUS, C
    RETURN
    MOVWF   UNIDADES
    INCF    DECENAS, F
    GOTO    LAZO_RESTAR_10

;*******************************************************************************
; @brief    Actualiza los 4 dígitos del display y dispara la trama UART TX.
;******************************************************************************* 
ACTUALIZAR_PANTALLA_Y_TRAMA
    BTFSC   BANDERAS, BIT_MODO_DISPLAY
    GOTO    CARGAR_VISTA_FRECUENCIA

; --- Formateo de Temperatura: [Decena][Unidad][°][C] ---
CARGAR_VISTA_TEMPERATURA
    CALL    LIMITAR_TEMP_A_99
    CALL    EXTRAER_DECENAS_UNIDADES
    MOVF    DECENAS, W
    CALL    TABLA_7SEG
    MOVWF   DIGITO_1                    ; Dígito 1: Decena
    MOVF    UNIDADES, W
    CALL    TABLA_7SEG
    MOVWF   DIGITO_2                    ; Dígito 2: Unidad
    MOVLW   CARACTER_GRADO              ; Dígito 3: '°'
    MOVWF   DIGITO_3
    MOVLW   CARACTER_C                  ; Dígito 4: 'C'
    MOVWF   DIGITO_4
    GOTO    ARMAR_Y_ENVIAR_TRAMA_UART

; --- Formateo de Cuenta Regresiva (t-15..t-01) o Frecuencia (FXXX / F---) ---
CARGAR_VISTA_FRECUENCIA
    BTFSS   BANDERAS, BIT_MIDIENDO_PULSO
    GOTO    MOSTRAR_RESULTADO_BPM

    ; Medición en curso: muestra [t][-][Decena][Unidad]
    MOVLW   CARACTER_T
    MOVWF   DIGITO_1                    ; Dígito 1: 't'
    MOVLW   CARACTER_GUION
    MOVWF   DIGITO_2                    ; Dígito 2: '-'

    MOVF    SEGUNDOS_RESTANTES, W
    MOVWF   UNIDADES
    CALL    EXTRAER_DECENAS_UNIDADES
    MOVF    DECENAS, W
    CALL    TABLA_7SEG
    MOVWF   DIGITO_3                    ; Dígito 3: Decena de segundos
    MOVF    UNIDADES, W
    CALL    TABLA_7SEG
    MOVWF   DIGITO_4                    ; Dígito 4: Unidad de segundos
    GOTO    ARMAR_Y_ENVIAR_TRAMA_UART

    ; Medición finalizada: muestra F--- si FRECUENCIA_BPM = 0, o FXXX si > 0
MOSTRAR_RESULTADO_BPM
    MOVLW   CARACTER_F                  ; Dígito 1: 'F'
    MOVWF   DIGITO_1

    MOVF    FRECUENCIA_BPM, F
    BTFSS   STATUS, Z
    GOTO    FORMATEAR_DIGITOS_BPM
    MOVLW   CARACTER_GUION
    MOVWF   DIGITO_2
    MOVWF   DIGITO_3
    MOVWF   DIGITO_4
    GOTO    ARMAR_Y_ENVIAR_TRAMA_UART

FORMATEAR_DIGITOS_BPM
    MOVF    FRECUENCIA_BPM, W
    CALL    CONVERTIR_A_3_DIGITOS
    MOVF    CENTENAS, W
    CALL    TABLA_7SEG
    MOVWF   DIGITO_2                    ; Dígito 2: Centena de BPM
    MOVF    DECENAS, W
    CALL    TABLA_7SEG
    MOVWF   DIGITO_3                    ; Dígito 3: Decena de BPM
    MOVF    UNIDADES, W
    CALL    TABLA_7SEG
    MOVWF   DIGITO_4                    ; Dígito 4: Unidad de BPM

;*******************************************************************************
; @brief    Construye la trama ASCII "Txx,Myy,Bzzz\r\n" y activa TXIE
;           (se omite si BIT_MODO_GRAFICO = 1 para no interferir el CSV).
;*******************************************************************************
ARMAR_Y_ENVIAR_TRAMA_UART
    BTFSC   BANDERAS, BIT_MODO_GRAFICO  ; Si está graficando ADC, prioriza trama CSV
    RETURN
    MOVF    BYTES_PENDIENTES_TX, F
    BTFSS   STATUS, Z                   ; Si aún hay una trama enviándose, no sobreescribe
    RETURN

    MOVLW   'T'
    MOVWF   BUFFER_TRAMA_TX + d'0'
    MOVLW   ','
    MOVWF   BUFFER_TRAMA_TX + d'3'
    MOVLW   'M'
    MOVWF   BUFFER_TRAMA_TX + d'4'
    MOVLW   ','
    MOVWF   BUFFER_TRAMA_TX + d'7'
    MOVLW   'B'
    MOVWF   BUFFER_TRAMA_TX + d'8'
    MOVLW   0x0D                        ; CR (\r)
    MOVWF   BUFFER_TRAMA_TX + d'12'
    MOVLW   0x0A                        ; LF (\n)
    MOVWF   BUFFER_TRAMA_TX + d'13'

    ; --- Temperatura (Txx) ---
    CALL    LIMITAR_TEMP_A_99
    CALL    EXTRAER_DECENAS_UNIDADES
    MOVF    DECENAS, W
    ADDLW   '0'
    MOVWF   BUFFER_TRAMA_TX + d'1'
    MOVF    UNIDADES, W
    ADDLW   '0'
    MOVWF   BUFFER_TRAMA_TX + d'2'

    ; --- Estado de medición / cuenta regresiva (Myy) ---
    BTFSC   BANDERAS, BIT_MIDIENDO_PULSO
    GOTO    CARGAR_SEGUNDOS_TRAMA
    MOVLW   '0'
    MOVWF   BUFFER_TRAMA_TX + d'5'
    MOVWF   BUFFER_TRAMA_TX + d'6'
    GOTO    CARGAR_BPM_TRAMA

CARGAR_SEGUNDOS_TRAMA
    MOVF    SEGUNDOS_RESTANTES, W
    MOVWF   UNIDADES
    CALL    EXTRAER_DECENAS_UNIDADES
    MOVF    DECENAS, W
    ADDLW   '0'
    MOVWF   BUFFER_TRAMA_TX + d'5'
    MOVF    UNIDADES, W
    ADDLW   '0'
    MOVWF   BUFFER_TRAMA_TX + d'6'

    ; --- Frecuencia cardíaca (Bzzz) ---
CARGAR_BPM_TRAMA
    MOVF    FRECUENCIA_BPM, W
    CALL    CONVERTIR_A_3_DIGITOS
    MOVF    CENTENAS, W
    ADDLW   '0'
    MOVWF   BUFFER_TRAMA_TX + d'9'
    MOVF    DECENAS, W
    ADDLW   '0'
    MOVWF   BUFFER_TRAMA_TX + d'10'
    MOVF    UNIDADES, W
    ADDLW   '0'
    MOVWF   BUFFER_TRAMA_TX + d'11'

    CLRF    INDICE_TX
    MOVLW   LARGO_TRAMA_TX
    MOVWF   BYTES_PENDIENTES_TX

    BANKSEL PIE1
    BSF     PIE1, TXIE                  ; Dispara transmisión por interrupción EUSART TX
    BANKSEL PORTB                       ; Retorna a Banco 0
    RETURN

;*******************************************************************************
; @brief    Construye la trama CSV "XXX,L\r\n" con la muestra ADC de AN1 y el
;           estado del detector de latido (100 Hz) para graficación.
;*******************************************************************************
ENVIAR_TRAMA_ADC_PULSO
    MOVF    BYTES_PENDIENTES_TX, F
    BTFSS   STATUS, Z                   ; Si el transmisor está ocupado, evita sobreescribir
    RETURN

    MOVF    MUESTRA_ADC_PULSO, W
    CALL    CONVERTIR_A_3_DIGITOS
    MOVF    CENTENAS, W
    ADDLW   '0'
    MOVWF   BUFFER_TRAMA_TX + d'0'
    MOVF    DECENAS, W
    ADDLW   '0'
    MOVWF   BUFFER_TRAMA_TX + d'1'
    MOVF    UNIDADES, W
    ADDLW   '0'
    MOVWF   BUFFER_TRAMA_TX + d'2'

    MOVLW   ','
    MOVWF   BUFFER_TRAMA_TX + d'3'

    MOVLW   '0'
    BTFSC   BANDERAS, BIT_LATIDO_DETECTADO
    MOVLW   '1'
    MOVWF   BUFFER_TRAMA_TX + d'4'

    MOVLW   0x0D                        ; CR (\r)
    MOVWF   BUFFER_TRAMA_TX + d'5'
    MOVLW   0x0A                        ; LF (\n)
    MOVWF   BUFFER_TRAMA_TX + d'6'

    CLRF    INDICE_TX
    MOVLW   LARGO_TRAMA_GRAFICO
    MOVWF   BYTES_PENDIENTES_TX

    BANKSEL PIE1
    BSF     PIE1, TXIE                  ; Inicia transmisión por interrupción EUSART TX
    BANKSEL PORTB                       ; Retorna a Banco 0
    RETURN
    
;===============================================================================        
    END
;===============================================================================