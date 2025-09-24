;; Microgravity Process Oracle Contract
;; Real-time monitoring of manufacturing processes in zero-gravity environments

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u401))
(define-constant ERR_INVALID_PARAMETERS (err u400))
(define-constant ERR_PROCESS_NOT_FOUND (err u404))
(define-constant ERR_THRESHOLD_EXCEEDED (err u409))
(define-constant ERR_INSUFFICIENT_DATA (err u410))
(define-constant ERR_CALIBRATION_FAILED (err u411))

;; Process status constants
(define-constant STATUS_NORMAL u0)
(define-constant STATUS_WARNING u1)
(define-constant STATUS_CRITICAL u2)
(define-constant STATUS_FAILURE u3)

;; Data structures
(define-map process-parameters
    { process-id: uint }
    {
        temperature: uint,          ;; in Celsius * 100 (for 2 decimal places)
        pressure: uint,            ;; in Pascal
        acceleration: uint,        ;; in m/s^2 * 1000 (for 3 decimal places)
        vibration: uint,           ;; in Hz * 100
        power-consumption: uint,   ;; in Watts
        process-duration: uint,    ;; in seconds
        material-flow-rate: uint,  ;; in ml/min * 100
        contamination-level: uint, ;; in ppm * 100
        operator-id: principal,
        timestamp: uint,
        status: uint
    }
)

(define-map process-thresholds
    { process-id: uint }
    {
        temp-min: uint,
        temp-max: uint,
        pressure-min: uint,
        pressure-max: uint,
        accel-max: uint,
        vibration-max: uint,
        power-max: uint,
        contamination-max: uint,
        duration-max: uint
    }
)

(define-map process-history
    { process-id: uint, measurement-id: uint }
    {
        temperature: uint,
        pressure: uint,
        acceleration: uint,
        timestamp: uint,
        anomaly-detected: bool
    }
)

(define-map process-alerts
    { alert-id: uint }
    {
        process-id: uint,
        alert-type: uint,    ;; 1=temperature, 2=pressure, 3=acceleration, etc.
        severity: uint,      ;; 1=low, 2=medium, 3=high, 4=critical
        message: (string-ascii 256),
        triggered-at: uint,
        resolved: bool
    }
)

(define-map authorized-operators
    { operator: principal }
    { authorized: bool }
)

;; Variables
(define-data-var next-process-id uint u1)
(define-data-var next-measurement-id uint u1)
(define-data-var next-alert-id uint u1)
(define-data-var emergency-stop bool false)
(define-data-var calibration-status bool false)

;; Authorization functions
(define-private (is-authorized (operator principal))
    (or 
        (is-eq operator CONTRACT_OWNER)
        (default-to false (get authorized (map-get? authorized-operators { operator: operator })))
    )
)

(define-public (add-authorized-operator (operator principal))
    (begin
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
        (ok (map-set authorized-operators { operator: operator } { authorized: true }))
    )
)

(define-public (remove-authorized-operator (operator principal))
    (begin
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
        (ok (map-set authorized-operators { operator: operator } { authorized: false }))
    )
)

;; Process management functions
(define-public (initialize-process 
    (temp-min uint) (temp-max uint)
    (pressure-min uint) (pressure-max uint)
    (accel-max uint) (vibration-max uint)
    (power-max uint) (contamination-max uint)
    (duration-max uint))
    (let ((process-id (var-get next-process-id)))
        (asserts! (is-authorized tx-sender) ERR_UNAUTHORIZED)
        (asserts! (< temp-min temp-max) ERR_INVALID_PARAMETERS)
        (asserts! (< pressure-min pressure-max) ERR_INVALID_PARAMETERS)
        
        (map-set process-thresholds
            { process-id: process-id }
            {
                temp-min: temp-min,
                temp-max: temp-max,
                pressure-min: pressure-min,
                pressure-max: pressure-max,
                accel-max: accel-max,
                vibration-max: vibration-max,
                power-max: power-max,
                contamination-max: contamination-max,
                duration-max: duration-max
            }
        )
        
        (var-set next-process-id (+ process-id u1))
        (ok process-id)
    )
)

(define-public (update-process-data
    (process-id uint)
    (temperature uint) (pressure uint) (acceleration uint)
    (vibration uint) (power-consumption uint)
    (material-flow-rate uint) (contamination-level uint)
    (process-duration uint))
    (let 
        (
            (current-status (analyze-process-status process-id temperature pressure acceleration 
                           vibration power-consumption contamination-level process-duration))
            (timestamp u1000000)
        )
        (asserts! (is-authorized tx-sender) ERR_UNAUTHORIZED)
        (asserts! (not (var-get emergency-stop)) ERR_UNAUTHORIZED)
        
        ;; Store current process parameters
        (map-set process-parameters
            { process-id: process-id }
            {
                temperature: temperature,
                pressure: pressure,
                acceleration: acceleration,
                vibration: vibration,
                power-consumption: power-consumption,
                process-duration: process-duration,
                material-flow-rate: material-flow-rate,
                contamination-level: contamination-level,
                operator-id: tx-sender,
                timestamp: timestamp,
                status: current-status
            }
        )
        
        ;; Store in history for trend analysis
        (let ((measurement-id (var-get next-measurement-id)))
            (map-set process-history
                { process-id: process-id, measurement-id: measurement-id }
                {
                    temperature: temperature,
                    pressure: pressure,
                    acceleration: acceleration,
                    timestamp: timestamp,
                    anomaly-detected: (> current-status STATUS_NORMAL)
                }
            )
            (var-set next-measurement-id (+ measurement-id u1))
        )
        
        ;; Generate alerts if necessary
        (if (> current-status STATUS_WARNING)
            (begin (unwrap-panic (create-alert process-id current-status "Process parameters exceed normal ranges" timestamp)) u1)
            u0
        )
        
        (ok current-status)
    )
)

;; Analysis functions
(define-private (analyze-process-status
    (process-id uint) (temperature uint) (pressure uint) (acceleration uint)
    (vibration uint) (power-consumption uint) (contamination-level uint)
    (process-duration uint))
    (let 
        (
            (thresholds (unwrap-panic (map-get? process-thresholds { process-id: process-id })))
            (temp-violation (or (< temperature (get temp-min thresholds)) 
                               (> temperature (get temp-max thresholds))))
            (pressure-violation (or (< pressure (get pressure-min thresholds)) 
                                   (> pressure (get pressure-max thresholds))))
            (accel-violation (> acceleration (get accel-max thresholds)))
            (vibration-violation (> vibration (get vibration-max thresholds)))
            (power-violation (> power-consumption (get power-max thresholds)))
            (contamination-violation (> contamination-level (get contamination-max thresholds)))
            (duration-violation (> process-duration (get duration-max thresholds)))
        )
        
        (if (or contamination-violation duration-violation)
            STATUS_FAILURE
            (if (or temp-violation pressure-violation accel-violation)
                STATUS_CRITICAL
                (if (or vibration-violation power-violation)
                    STATUS_WARNING
                    STATUS_NORMAL
                )
            )
        )
    )
)

(define-private (create-alert (process-id uint) (severity uint) (message (string-ascii 256)) (timestamp uint))
    (let ((alert-id (var-get next-alert-id)))
        (map-set process-alerts
            { alert-id: alert-id }
            {
                process-id: process-id,
                alert-type: u1,  ;; General process alert
                severity: severity,
                message: message,
                triggered-at: timestamp,
                resolved: false
            }
        )
        (var-set next-alert-id (+ alert-id u1))
        (ok alert-id)
    )
)

;; Emergency controls
(define-public (emergency-stop-all)
    (begin
        (asserts! (is-authorized tx-sender) ERR_UNAUTHORIZED)
        (var-set emergency-stop true)
        (ok true)
    )
)

(define-public (resume-operations)
    (begin
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
        (var-set emergency-stop false)
        (ok true)
    )
)

;; Calibration functions
(define-public (calibrate-sensors (process-id uint))
    (begin
        (asserts! (is-authorized tx-sender) ERR_UNAUTHORIZED)
        (asserts! (is-some (map-get? process-thresholds { process-id: process-id })) ERR_PROCESS_NOT_FOUND)
        
        ;; Simulate calibration process
        (var-set calibration-status true)
        (ok true)
    )
)

(define-public (resolve-alert (alert-id uint))
    (let ((alert (unwrap! (map-get? process-alerts { alert-id: alert-id }) ERR_PROCESS_NOT_FOUND)))
        (asserts! (is-authorized tx-sender) ERR_UNAUTHORIZED)
        
        (map-set process-alerts
            { alert-id: alert-id }
            (merge alert { resolved: true })
        )
        (ok true)
    )
)

;; Read-only functions
(define-read-only (get-process-data (process-id uint))
    (map-get? process-parameters { process-id: process-id })
)

(define-read-only (get-process-thresholds (process-id uint))
    (map-get? process-thresholds { process-id: process-id })
)

(define-read-only (get-process-history (process-id uint) (measurement-id uint))
    (map-get? process-history { process-id: process-id, measurement-id: measurement-id })
)

(define-read-only (get-alert (alert-id uint))
    (map-get? process-alerts { alert-id: alert-id })
)

(define-read-only (get-system-status)
    {
        emergency-stop: (var-get emergency-stop),
        calibration-status: (var-get calibration-status),
        next-process-id: (var-get next-process-id),
        next-alert-id: (var-get next-alert-id)
    }
)

(define-read-only (is-operator-authorized (operator principal))
    (is-authorized operator)
)

(define-read-only (get-process-count)
    (- (var-get next-process-id) u1)
)

(define-read-only (get-alert-count)
    (- (var-get next-alert-id) u1)
)
