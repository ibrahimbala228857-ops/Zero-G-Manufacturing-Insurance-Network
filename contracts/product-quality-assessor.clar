;; Product Quality Assessor Contract
;; Automated quality control for space-manufactured products and Earth-return logistics

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u401))
(define-constant ERR_INVALID_PARAMETERS (err u400))
(define-constant ERR_PRODUCT_NOT_FOUND (err u404))
(define-constant ERR_QUALITY_FAILED (err u409))
(define-constant ERR_CERTIFICATION_DENIED (err u410))
(define-constant ERR_INSPECTION_INCOMPLETE (err u411))
(define-constant ERR_BATCH_CONTAMINATED (err u412))

;; Quality status constants
(define-constant QUALITY_PASS u0)
(define-constant QUALITY_WARNING u1)
(define-constant QUALITY_FAIL u2)
(define-constant QUALITY_CRITICAL_FAIL u3)

;; Certification status constants
(define-constant CERT_PENDING u0)
(define-constant CERT_APPROVED u1)
(define-constant CERT_REJECTED u2)
(define-constant CERT_REVOKED u3)

;; Product data structures
(define-map product-specifications
    { product-id: uint }
    {
        product-type: (string-ascii 64),
        batch-id: (string-ascii 32),
        target-density: uint,      ;; g/cm^3 * 1000
        target-purity: uint,       ;; percentage * 100
        target-dimensions: { length: uint, width: uint, height: uint }, ;; in micrometers
        tolerance-range: uint,     ;; +/- percentage * 100
        manufacturing-date: uint,
        expiration-date: uint,
        manufacturer-id: principal,
        specification-version: uint
    }
)

(define-map quality-assessments
    { product-id: uint }
    {
        actual-density: uint,
        actual-purity: uint,
        actual-dimensions: { length: uint, width: uint, height: uint },
        surface-quality: uint,     ;; 0-100 score
        structural-integrity: uint, ;; 0-100 score
        contamination-detected: bool,
        defect-count: uint,
        visual-inspection-score: uint, ;; 0-100
        stress-test-result: uint,  ;; 0-100 score
        assessment-timestamp: uint,
        assessor-id: principal,
        overall-quality-score: uint ;; 0-100
    }
)

(define-map quality-standards
    { product-type: (string-ascii 64) }
    {
        min-density: uint,
        max-density: uint,
        min-purity: uint,
        min-surface-quality: uint,
        min-structural-integrity: uint,
        max-defect-count: uint,
        min-visual-score: uint,
        min-stress-score: uint,
        earth-return-eligible: bool
    }
)

(define-map certifications
    { cert-id: uint }
    {
        product-id: uint,
        certification-type: (string-ascii 64), ;; "EARTH_RETURN", "SPACE_GRADE", "RESEARCH_ONLY"
        status: uint,
        issued-date: uint,
        valid-until: uint,
        certifying-authority: principal,
        conditions: (string-ascii 256),
        quality-score: uint
    }
)

(define-map batch-quality
    { batch-id: (string-ascii 32) }
    {
        total-products: uint,
        passed-products: uint,
        failed-products: uint,
        average-quality-score: uint,
        batch-status: uint,        ;; QUALITY_PASS, QUALITY_WARNING, etc.
        contamination-risk: uint,  ;; 0-100 risk score
        recall-issued: bool
    }
)

(define-map authorized-assessors
    { assessor: principal }
    { 
        authorized: bool,
        specializations: (list 5 (string-ascii 64)),
        certification-level: uint  ;; 1=basic, 2=advanced, 3=expert
    }
)

;; Variables
(define-data-var next-product-id uint u1)
(define-data-var next-cert-id uint u1)
(define-data-var quality-check-enabled bool true)
(define-data-var automated-assessment-threshold uint u70) ;; products below this score get manual review
(define-data-var earth-return-threshold uint u85) ;; minimum score for Earth return eligibility

;; Authorization functions
(define-private (is-authorized-assessor (assessor principal))
    (or 
        (is-eq assessor CONTRACT_OWNER)
        (default-to false (get authorized (map-get? authorized-assessors { assessor: assessor })))
    )
)

(define-public (add-authorized-assessor (assessor principal) (specializations (list 5 (string-ascii 64))) (level uint))
    (begin
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
        (asserts! (<= level u3) ERR_INVALID_PARAMETERS)
        (ok (map-set authorized-assessors 
            { assessor: assessor } 
            { authorized: true, specializations: specializations, certification-level: level }
        ))
    )
)

(define-public (revoke-assessor-authorization (assessor principal))
    (begin
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
        (ok (map-set authorized-assessors 
            { assessor: assessor } 
            (merge 
                (unwrap-panic (map-get? authorized-assessors { assessor: assessor }))
                { authorized: false }
            )
        ))
    )
)

;; Quality standard management
(define-public (set-quality-standards 
    (product-type (string-ascii 64))
    (min-density uint) (max-density uint) (min-purity uint)
    (min-surface-quality uint) (min-structural-integrity uint)
    (max-defect-count uint) (min-visual-score uint)
    (min-stress-score uint) (earth-return-eligible bool))
    (begin
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
        (asserts! (< min-density max-density) ERR_INVALID_PARAMETERS)
        (asserts! (<= min-purity u10000) ERR_INVALID_PARAMETERS) ;; max 100.00%
        
        (ok (map-set quality-standards
            { product-type: product-type }
            {
                min-density: min-density,
                max-density: max-density,
                min-purity: min-purity,
                min-surface-quality: min-surface-quality,
                min-structural-integrity: min-structural-integrity,
                max-defect-count: max-defect-count,
                min-visual-score: min-visual-score,
                min-stress-score: min-stress-score,
                earth-return-eligible: earth-return-eligible
            }
        ))
    )
)

;; Product registration and specification
(define-public (register-product
    (product-type (string-ascii 64)) (batch-id (string-ascii 32))
    (target-density uint) (target-purity uint)
    (target-length uint) (target-width uint) (target-height uint)
    (tolerance-range uint) (expiration-date uint))
    (let ((product-id (var-get next-product-id)))
        (asserts! (is-authorized-assessor tx-sender) ERR_UNAUTHORIZED)
        (asserts! (<= target-purity u10000) ERR_INVALID_PARAMETERS)
        (asserts! (<= tolerance-range u5000) ERR_INVALID_PARAMETERS) ;; max 50% tolerance
        
        (map-set product-specifications
            { product-id: product-id }
            {
                product-type: product-type,
                batch-id: batch-id,
                target-density: target-density,
                target-purity: target-purity,
                target-dimensions: { length: target-length, width: target-width, height: target-height },
                tolerance-range: tolerance-range,
                manufacturing-date: u1000000,
                expiration-date: expiration-date,
                manufacturer-id: tx-sender,
                specification-version: u1
            }
        )
        
        (var-set next-product-id (+ product-id u1))
        (ok product-id)
    )
)

;; Quality assessment functions
(define-public (perform-quality-assessment
    (product-id uint) (actual-density uint) (actual-purity uint)
    (actual-length uint) (actual-width uint) (actual-height uint)
    (surface-quality uint) (structural-integrity uint)
    (contamination-detected bool) (defect-count uint)
    (visual-score uint) (stress-score uint))
    (let 
        (
            (product-spec (unwrap! (map-get? product-specifications { product-id: product-id }) ERR_PRODUCT_NOT_FOUND))
            (overall-score (calculate-overall-quality-score 
                            actual-density actual-purity surface-quality structural-integrity
                            defect-count visual-score stress-score contamination-detected
                            product-spec))
            (timestamp u1000000)
        )
        (asserts! (is-authorized-assessor tx-sender) ERR_UNAUTHORIZED)
        (asserts! (var-get quality-check-enabled) ERR_UNAUTHORIZED)
        (asserts! (<= surface-quality u100) ERR_INVALID_PARAMETERS)
        (asserts! (<= structural-integrity u100) ERR_INVALID_PARAMETERS)
        (asserts! (<= visual-score u100) ERR_INVALID_PARAMETERS)
        (asserts! (<= stress-score u100) ERR_INVALID_PARAMETERS)
        
        (map-set quality-assessments
            { product-id: product-id }
            {
                actual-density: actual-density,
                actual-purity: actual-purity,
                actual-dimensions: { length: actual-length, width: actual-width, height: actual-height },
                surface-quality: surface-quality,
                structural-integrity: structural-integrity,
                contamination-detected: contamination-detected,
                defect-count: defect-count,
                visual-inspection-score: visual-score,
                stress-test-result: stress-score,
                assessment-timestamp: timestamp,
                assessor-id: tx-sender,
                overall-quality-score: overall-score
            }
        )
        
        ;; Update batch statistics
        (unwrap-panic (update-batch-statistics (get batch-id product-spec) overall-score))
        
        (ok overall-score)
    )
)

;; Quality score calculation
(define-private (calculate-overall-quality-score
    (density uint) (purity uint) (surface uint) (structural uint)
    (defects uint) (visual uint) (stress uint) (contaminated bool)
    (spec (tuple 
        (product-type (string-ascii 64)) (batch-id (string-ascii 32))
        (target-density uint) (target-purity uint)
        (target-dimensions (tuple (length uint) (width uint) (height uint)))
        (tolerance-range uint) (manufacturing-date uint)
        (expiration-date uint) (manufacturer-id principal) (specification-version uint)
    )))
    (let 
        (
            (density-score (if (and (>= density (- (get target-density spec) 
                                                   (* (get target-density spec) (/ (get tolerance-range spec) u10000))))
                                   (<= density (+ (get target-density spec) 
                                                   (* (get target-density spec) (/ (get tolerance-range spec) u10000)))))
                              u100 u0))
            (purity-score (if (>= purity (- (get target-purity spec) 
                                            (* (get target-purity spec) (/ (get tolerance-range spec) u10000))))
                             (if (<= (/ (* purity u100) (get target-purity spec)) u100) (/ (* purity u100) (get target-purity spec)) u100) u0))
            (defect-penalty (if (> defects u10) u0 (- u100 (* defects u10))))
            (contamination-penalty (if contaminated u0 u100))
            (base-score (/ (+ density-score purity-score surface structural visual stress 
                              defect-penalty contamination-penalty) u8))
        )
        (if (<= base-score u100) base-score u100)
    )
)

;; Batch management
(define-private (update-batch-statistics (batch-id (string-ascii 32)) (quality-score uint))
    (let 
        (
            (current-batch (default-to 
                            { total-products: u0, passed-products: u0, failed-products: u0,
                              average-quality-score: u0, batch-status: QUALITY_PASS,
                              contamination-risk: u0, recall-issued: false }
                            (map-get? batch-quality { batch-id: batch-id })))
            (new-total (+ (get total-products current-batch) u1))
            (passed (if (>= quality-score (var-get automated-assessment-threshold)) 
                       (+ (get passed-products current-batch) u1)
                       (get passed-products current-batch)))
            (failed (if (< quality-score (var-get automated-assessment-threshold))
                       (+ (get failed-products current-batch) u1)
                       (get failed-products current-batch)))
            (new-avg (/ (+ (* (get average-quality-score current-batch) (get total-products current-batch)) quality-score) new-total))
            (new-status (determine-batch-status new-avg failed new-total))
        )
        
        (ok (map-set batch-quality
            { batch-id: batch-id }
            {
                total-products: new-total,
                passed-products: passed,
                failed-products: failed,
                average-quality-score: new-avg,
                batch-status: new-status,
                contamination-risk: (calculate-contamination-risk failed new-total),
                recall-issued: false
            }
        ))
    )
)

(define-private (determine-batch-status (avg-score uint) (failed uint) (total uint))
    (let ((failure-rate (/ (* failed u100) total)))
        (if (> failure-rate u50) QUALITY_CRITICAL_FAIL
            (if (> failure-rate u25) QUALITY_FAIL
                (if (or (> failure-rate u10) (< avg-score u70)) QUALITY_WARNING
                    QUALITY_PASS
                )
            )
        )
    )
)

(define-private (calculate-contamination-risk (failed uint) (total uint))
    (if (<= (/ (* failed u100) total) u100) (/ (* failed u100) total) u100)
)

;; Certification functions
(define-public (issue-certification (product-id uint) (cert-type (string-ascii 64)) (valid-days uint))
    (let 
        (
            (assessment (unwrap! (map-get? quality-assessments { product-id: product-id }) ERR_PRODUCT_NOT_FOUND))
            (cert-id (var-get next-cert-id))
            (current-time u1000000)
            (valid-until (+ current-time (* valid-days u86400))) ;; 86400 seconds per day
        )
        (asserts! (is-authorized-assessor tx-sender) ERR_UNAUTHORIZED)
        (asserts! (>= (get overall-quality-score assessment) (var-get automated-assessment-threshold)) ERR_QUALITY_FAILED)
        
        ;; Additional check for Earth return certification
        (asserts! (or (not (is-eq cert-type "EARTH_RETURN")) 
                     (>= (get overall-quality-score assessment) (var-get earth-return-threshold)))
                 ERR_CERTIFICATION_DENIED)
        
        (map-set certifications
            { cert-id: cert-id }
            {
                product-id: product-id,
                certification-type: cert-type,
                status: CERT_APPROVED,
                issued-date: current-time,
                valid-until: valid-until,
                certifying-authority: tx-sender,
                conditions: "Standard quality requirements met",
                quality-score: (get overall-quality-score assessment)
            }
        )
        
        (var-set next-cert-id (+ cert-id u1))
        (ok cert-id)
    )
)

(define-public (revoke-certification (cert-id uint) (reason (string-ascii 256)))
    (let ((cert (unwrap! (map-get? certifications { cert-id: cert-id }) ERR_PRODUCT_NOT_FOUND)))
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
        
        (ok (map-set certifications
            { cert-id: cert-id }
            (merge cert { status: CERT_REVOKED, conditions: reason })
        ))
    )
)

;; Emergency controls
(define-public (issue-batch-recall (batch-id (string-ascii 32)) (reason (string-ascii 256)))
    (let ((batch (unwrap! (map-get? batch-quality { batch-id: batch-id }) ERR_PRODUCT_NOT_FOUND)))
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
        
        (ok (map-set batch-quality
            { batch-id: batch-id }
            (merge batch { recall-issued: true, batch-status: QUALITY_CRITICAL_FAIL })
        ))
    )
)

(define-public (toggle-quality-checks (enabled bool))
    (begin
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
        (var-set quality-check-enabled enabled)
        (ok enabled)
    )
)

;; Configuration functions
(define-public (update-quality-thresholds (assessment-threshold uint) (earth-return-min-threshold uint))
    (begin
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
        (asserts! (<= assessment-threshold u100) ERR_INVALID_PARAMETERS)
        (asserts! (<= earth-return-min-threshold u100) ERR_INVALID_PARAMETERS)
        (asserts! (<= assessment-threshold earth-return-min-threshold) ERR_INVALID_PARAMETERS)
        
        (var-set automated-assessment-threshold assessment-threshold)
        (var-set earth-return-threshold earth-return-min-threshold)
        (ok true)
    )
)

;; Read-only functions
(define-read-only (get-product-specification (product-id uint))
    (map-get? product-specifications { product-id: product-id })
)

(define-read-only (get-quality-assessment (product-id uint))
    (map-get? quality-assessments { product-id: product-id })
)

(define-read-only (get-quality-standards (product-type (string-ascii 64)))
    (map-get? quality-standards { product-type: product-type })
)

(define-read-only (get-certification (cert-id uint))
    (map-get? certifications { cert-id: cert-id })
)

(define-read-only (get-batch-quality (batch-id (string-ascii 32)))
    (map-get? batch-quality { batch-id: batch-id })
)

(define-read-only (get-assessor-info (assessor principal))
    (map-get? authorized-assessors { assessor: assessor })
)

(define-read-only (is-earth-return-eligible (product-id uint))
    (match (map-get? quality-assessments { product-id: product-id })
        assessment (>= (get overall-quality-score assessment) (var-get earth-return-threshold))
        false
    )
)

(define-read-only (get-system-configuration)
    {
        quality-check-enabled: (var-get quality-check-enabled),
        assessment-threshold: (var-get automated-assessment-threshold),
        earth-return-threshold: (var-get earth-return-threshold),
        next-product-id: (var-get next-product-id),
        next-cert-id: (var-get next-cert-id)
    }
)

(define-read-only (get-product-count)
    (- (var-get next-product-id) u1)
)

(define-read-only (get-certification-count)
    (- (var-get next-cert-id) u1)
)
