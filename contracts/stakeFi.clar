;; Enhanced StakeFi Contract with Error Handling and Access Control

;; Data variables
(define-data-var total-staked uint u0)
(define-data-var total-shares uint u0)
(define-data-var contract-owner principal tx-sender)
(define-data-var is-paused bool false)
(define-data-var protocol-fee-rate uint u100) ;; 1% = 100 basis points
(define-data-var accumulated-fees uint u0)

;; Data maps
(define-map shares principal uint)
(define-map authorized-operators principal bool)

;; Error constants
(define-constant ERR-INVALID-AMOUNT (err u100))
(define-constant ERR-INSUFFICIENT-SHARES (err u101))
(define-constant ERR-TRANSFER-FAILED (err u102))
(define-constant ERR-ZERO-SHARES (err u103))
(define-constant ERR-CALCULATION-ERROR (err u104))
(define-constant ERR-NOT-AUTHORIZED (err u105))
(define-constant ERR-CONTRACT-PAUSED (err u106))
(define-constant ERR-INVALID-FEE-RATE (err u107))

;; Access control helper functions
(define-private (is-contract-owner)
  (is-eq tx-sender (var-get contract-owner)))

(define-private (is-authorized-operator)
  (or (is-contract-owner)
      (default-to false (map-get? authorized-operators tx-sender))))

(define-private (check-not-paused)
  (not (var-get is-paused)))

;; Administrative functions
(define-public (set-contract-owner (new-owner principal))
  (begin
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    (var-set contract-owner new-owner)
    (ok true)))

(define-public (add-operator (operator principal))
  (begin
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    (map-set authorized-operators operator true)
    (ok true)))

(define-public (remove-operator (operator principal))
  (begin
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    (map-delete authorized-operators operator)
    (ok true)))

(define-public (pause-contract)
  (begin
    (asserts! (is-authorized-operator) ERR-NOT-AUTHORIZED)
    (var-set is-paused true)
    (ok true)))

(define-public (unpause-contract)
  (begin
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    (var-set is-paused false)
    (ok true)))

(define-public (set-protocol-fee (new-fee-rate uint))
  (begin
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    (asserts! (<= new-fee-rate u1000) ERR-INVALID-FEE-RATE) ;; Max 10%
    (var-set protocol-fee-rate new-fee-rate)
    (ok true)))

(define-public (withdraw-fees (recipient principal))
  (begin
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    (let ((fees (var-get accumulated-fees)))
      (asserts! (> fees u0) ERR-INVALID-AMOUNT)
      (var-set accumulated-fees u0)
      (match (as-contract (stx-transfer? fees tx-sender recipient))
        success (ok fees)
        error ERR-TRANSFER-FAILED))))

;; Core staking functions with enhanced error handling
(define-public (stake (amount uint))
  (begin
    ;; Check contract state and input validation
    (asserts! (check-not-paused) ERR-CONTRACT-PAUSED)
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    
    ;; Calculate protocol fee
    (let ((fee (/ (* amount (var-get protocol-fee-rate)) u10000))
          (net-amount (- amount fee)))
      
      ;; Transfer full amount to contract with proper error handling
      (match (stx-transfer? amount tx-sender (as-contract tx-sender))
        success
          (let ((current-total-staked (var-get total-staked))
                (current-total-shares (var-get total-shares)))
            (let ((shares-minted 
                    (if (is-eq current-total-shares u0) 
                        net-amount 
                        (begin
                          ;; Prevent division by zero
                          (asserts! (> current-total-staked u0) ERR-CALCULATION-ERROR)
                          (/ (* net-amount current-total-shares) current-total-staked)))))
              
              ;; Ensure we're minting at least some shares
              (asserts! (> shares-minted u0) ERR-ZERO-SHARES)
              
              ;; Update state
              (map-set shares tx-sender (+ (default-to u0 (map-get? shares tx-sender)) shares-minted))
              (var-set total-shares (+ current-total-shares shares-minted))
              (var-set total-staked (+ current-total-staked net-amount))
              (var-set accumulated-fees (+ (var-get accumulated-fees) fee))
              (ok shares-minted)))
        error ERR-TRANSFER-FAILED))))

(define-public (redeem (share-amount uint))
  (begin
    ;; Check contract state and input validation
    (asserts! (check-not-paused) ERR-CONTRACT-PAUSED)
    (asserts! (> share-amount u0) ERR-INVALID-AMOUNT)
    
    (let ((user-shares (default-to u0 (map-get? shares tx-sender)))
          (current-total-staked (var-get total-staked))
          (current-total-shares (var-get total-shares)))
      
      ;; Check user has sufficient shares
      (asserts! (>= user-shares share-amount) ERR-INSUFFICIENT-SHARES)
      ;; Prevent division by zero
      (asserts! (> current-total-shares u0) ERR-CALCULATION-ERROR)
      
      (let ((amount (/ (* share-amount current-total-staked) current-total-shares)))
        ;; Ensure we're redeeming a positive amount
        (asserts! (> amount u0) ERR-CALCULATION-ERROR)
        
        ;; Update state before transfer
        (map-set shares tx-sender (- user-shares share-amount))
        (var-set total-shares (- current-total-shares share-amount))
        (var-set total-staked (- current-total-staked amount))
        
        ;; Transfer STX from contract to user
        (match (as-contract (stx-transfer? amount tx-sender tx-sender))
          success (ok amount)
          error ERR-TRANSFER-FAILED)))))

;; Emergency function to recover stuck funds (only owner, only when paused)
(define-public (emergency-withdraw (amount uint) (recipient principal))
  (begin
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    (asserts! (var-get is-paused) ERR-CONTRACT-PAUSED) ;; Only when paused
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (match (as-contract (stx-transfer? amount tx-sender recipient))
      success (ok amount)
      error ERR-TRANSFER-FAILED)))

;; Read-only functions for transparency and debugging
(define-read-only (get-user-shares (user principal))
  (default-to u0 (map-get? shares user)))

(define-read-only (get-total-staked)
  (var-get total-staked))

(define-read-only (get-total-shares)
  (var-get total-shares))

(define-read-only (calculate-share-value (share-amount uint))
  (let ((current-total-staked (var-get total-staked))
        (current-total-shares (var-get total-shares)))
    (if (is-eq current-total-shares u0)
        u0
        (/ (* share-amount current-total-staked) current-total-shares))))

(define-read-only (get-contract-info)
  {
    owner: (var-get contract-owner),
    is-paused: (var-get is-paused),
    protocol-fee-rate: (var-get protocol-fee-rate),
    accumulated-fees: (var-get accumulated-fees),
    total-staked: (var-get total-staked),
    total-shares: (var-get total-shares)
  })

(define-read-only (is-operator (user principal))
  (or (is-eq user (var-get contract-owner))
      (default-to false (map-get? authorized-operators user))))

(define-read-only (get-protocol-fee-rate)
  (var-get protocol-fee-rate))

(define-read-only (get-accumulated-fees)
  (var-get accumulated-fees))