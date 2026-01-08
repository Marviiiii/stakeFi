;; Enhanced StakeFi Contract with Error Handling, Access Control, and Security Improvements

;; Data variables
(define-data-var total-staked uint u0)
(define-data-var total-shares uint u0)
(define-data-var contract-owner principal tx-sender)
(define-data-var is-paused bool false)
(define-data-var protocol-fee-rate uint u100) ;; 1% = 100 basis points
(define-data-var accumulated-fees uint u0)
(define-data-var minimum-stake-amount uint u1000000) ;; 1 STX minimum (1,000,000 microSTX)
(define-data-var minimum-shares-minted uint u1000000) ;; Prevent dust attacks

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
(define-constant ERR-SLIPPAGE-EXCEEDED (err u108))
(define-constant ERR-INSUFFICIENT-BALANCE (err u109))
(define-constant ERR-MINIMUM-STAKE-NOT-MET (err u110))
(define-constant ERR-NO-YIELD (err u111))

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

(define-public (set-minimum-stake (new-minimum uint))
  (begin
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    (asserts! (> new-minimum u0) ERR-INVALID-AMOUNT)
    (var-set minimum-stake-amount new-minimum)
    (ok true)))

(define-public (set-minimum-shares (new-minimum uint))
  (begin
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    (asserts! (> new-minimum u0) ERR-INVALID-AMOUNT)
    (var-set minimum-shares-minted new-minimum)
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
    (asserts! (>= amount (var-get minimum-stake-amount)) ERR-MINIMUM-STAKE-NOT-MET)
    
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
              
              ;; Ensure we're minting meaningful shares (prevent dust attacks)
              (asserts! (>= shares-minted (var-get minimum-shares-minted)) ERR-ZERO-SHARES)
              
              ;; Update state
              (map-set shares tx-sender (+ (default-to u0 (map-get? shares tx-sender)) shares-minted))
              (var-set total-shares (+ current-total-shares shares-minted))
              (var-set total-staked (+ current-total-staked net-amount))
              (var-set accumulated-fees (+ (var-get accumulated-fees) fee))
              (ok shares-minted)))
        error ERR-TRANSFER-FAILED))))

;; Enhanced stake function with slippage protection
(define-public (stake-with-slippage (amount uint) (min-shares-expected uint))
  (begin
    ;; Check contract state and input validation
    (asserts! (check-not-paused) ERR-CONTRACT-PAUSED)
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (asserts! (>= amount (var-get minimum-stake-amount)) ERR-MINIMUM-STAKE-NOT-MET)
    
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
              
              ;; Slippage protection: ensure user gets at least expected shares
              (asserts! (>= shares-minted min-shares-expected) ERR-SLIPPAGE-EXCEEDED)
              ;; Ensure we're minting meaningful shares (prevent dust attacks)
              (asserts! (>= shares-minted (var-get minimum-shares-minted)) ERR-ZERO-SHARES)
              
              ;; Update state
              (map-set shares tx-sender (+ (default-to u0 (map-get? shares tx-sender)) shares-minted))
              (var-set total-shares (+ current-total-shares shares-minted))
              (var-set total-staked (+ current-total-staked net-amount))
              (var-set accumulated-fees (+ (var-get accumulated-fees) fee))
              (ok shares-minted)))
        error ERR-TRANSFER-FAILED))))

;; FIXED: Corrected redeem function with proper STX transfer
(define-public (redeem (share-amount uint))
  (begin
    ;; Check contract state and input validation
    (asserts! (check-not-paused) ERR-CONTRACT-PAUSED)
    (asserts! (> share-amount u0) ERR-INVALID-AMOUNT)
    
    (let ((caller tx-sender)
          (user-shares (default-to u0 (map-get? shares tx-sender)))
          (current-total-staked (var-get total-staked))
          (current-total-shares (var-get total-shares)))
      
      ;; Check user has sufficient shares
      (asserts! (>= user-shares share-amount) ERR-INSUFFICIENT-SHARES)
      ;; Prevent division by zero
      (asserts! (> current-total-shares u0) ERR-CALCULATION-ERROR)
      
      (let ((amount (/ (* share-amount current-total-staked) current-total-shares)))
        ;; Ensure we're redeeming a positive amount
        (asserts! (> amount u0) ERR-CALCULATION-ERROR)
        ;; Ensure contract has sufficient balance
        (asserts! (>= (stx-get-balance (as-contract tx-sender)) amount) ERR-INSUFFICIENT-BALANCE)
        
        ;; Update state before transfer (reentrancy protection)
        (map-set shares tx-sender (- user-shares share-amount))
        (var-set total-shares (- current-total-shares share-amount))
        (var-set total-staked (- current-total-staked amount))
        
        ;; FIXED: Transfer STX from contract to user (corrected the transfer direction)
        (match (as-contract (stx-transfer? amount tx-sender caller))
          success (ok amount)
          error (begin
            ;; Rollback state changes on transfer failure
            (map-set shares tx-sender user-shares)
            (var-set total-shares current-total-shares)
            (var-set total-staked current-total-staked)
            ERR-TRANSFER-FAILED))))))

;; Enhanced redeem function with slippage protection
(define-public (redeem-with-slippage (share-amount uint) (min-stx-expected uint))
  (begin
    ;; Check contract state and input validation
    (asserts! (check-not-paused) ERR-CONTRACT-PAUSED)
    (asserts! (> share-amount u0) ERR-INVALID-AMOUNT)
    
    (let ((caller tx-sender)
          (user-shares (default-to u0 (map-get? shares tx-sender)))
          (current-total-staked (var-get total-staked))
          (current-total-shares (var-get total-shares)))
      
      ;; Check user has sufficient shares
      (asserts! (>= user-shares share-amount) ERR-INSUFFICIENT-SHARES)
      ;; Prevent division by zero
      (asserts! (> current-total-shares u0) ERR-CALCULATION-ERROR)
      
      (let ((amount (/ (* share-amount current-total-staked) current-total-shares)))
        ;; Slippage protection: ensure user gets at least expected STX
        (asserts! (>= amount min-stx-expected) ERR-SLIPPAGE-EXCEEDED)
        ;; Ensure we're redeeming a positive amount
        (asserts! (> amount u0) ERR-CALCULATION-ERROR)
        ;; Ensure contract has sufficient balance
        (asserts! (>= (stx-get-balance (as-contract tx-sender)) amount) ERR-INSUFFICIENT-BALANCE)
        
        ;; Update state before transfer (reentrancy protection)
        (map-set shares tx-sender (- user-shares share-amount))
        (var-set total-shares (- current-total-shares share-amount))
        (var-set total-staked (- current-total-staked amount))
        
        ;; Transfer STX from contract to user
        (match (as-contract (stx-transfer? amount tx-sender caller))
          success (ok amount)
          error (begin
            ;; Rollback state changes on transfer failure
            (map-set shares tx-sender user-shares)
            (var-set total-shares current-total-shares)
            (var-set total-staked current-total-staked)
            ERR-TRANSFER-FAILED))))))

;; Synchronize the internal accounting with the on-chain balance and optionally mint shares
(define-public (sync-balance (beneficiary (optional principal)))
  (begin
    (asserts! (check-not-paused) ERR-CONTRACT-PAUSED)
    (asserts! (is-authorized-operator) ERR-NOT-AUTHORIZED)
    (let (
          (old-total-staked (var-get total-staked))
          (old-total-shares (var-get total-shares))
          (actual-balance (stx-get-balance (as-contract tx-sender))))
      (let ((delta (if (> actual-balance old-total-staked)
                       (- actual-balance old-total-staked)
                       u0)))
        (asserts! (> delta u0) ERR-NO-YIELD)
        (var-set total-staked (+ old-total-staked delta))
        (match beneficiary mint-beneficiary
          (let ((minted (if (is-eq old-total-shares u0)
                            delta
                            (begin
                              (asserts! (> old-total-staked u0) ERR-CALCULATION-ERROR)
                              (/ (* delta old-total-shares) old-total-staked)))))
            (if (> minted u0)
                (begin
                  (map-set shares mint-beneficiary (+ (default-to u0 (map-get? shares mint-beneficiary)) minted))
                  (var-set total-shares (+ old-total-shares minted))
                  (ok { added-staked: delta, minted-shares: minted }))
                (ok { added-staked: delta, minted-shares: u0 })))
          (ok { added-staked: delta, minted-shares: u0 })))))) 

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

(define-read-only (get-minimum-stake-amount)
  (var-get minimum-stake-amount))

(define-read-only (get-minimum-shares-minted)
  (var-get minimum-shares-minted))

(define-read-only (calculate-share-value (share-amount uint))
  (let ((current-total-staked (var-get total-staked))
        (current-total-shares (var-get total-shares)))
    (if (is-eq current-total-shares u0)
        u0
        (/ (* share-amount current-total-staked) current-total-shares))))

;; Helper function to preview stake operations
(define-read-only (preview-stake (amount uint))
  (let ((fee (/ (* amount (var-get protocol-fee-rate)) u10000))
        (net-amount (- amount fee))
        (current-total-staked (var-get total-staked))
        (current-total-shares (var-get total-shares)))
    (if (is-eq current-total-shares u0)
        { shares: net-amount, fee: fee }
        { shares: (/ (* net-amount current-total-shares) current-total-staked), fee: fee })))

;; Helper function to preview redeem operations
(define-read-only (preview-redeem (share-amount uint))
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
    total-shares: (var-get total-shares),
    minimum-stake-amount: (var-get minimum-stake-amount),
    minimum-shares-minted: (var-get minimum-shares-minted)
  })

(define-read-only (is-operator (user principal))
  (or (is-eq user (var-get contract-owner))
      (default-to false (map-get? authorized-operators user))))

(define-read-only (get-protocol-fee-rate)
  (var-get protocol-fee-rate))

(define-read-only (get-accumulated-fees)
  (var-get accumulated-fees))
