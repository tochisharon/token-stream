;; Token Stream - Continuous Payment Streaming Protocol

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-unauthorized (err u100))
(define-constant err-invalid-stream (err u101))
(define-constant err-stream-exists (err u102))
(define-constant err-stream-not-found (err u103))
(define-constant err-insufficient-balance (err u104))
(define-constant err-invalid-amount (err u105))
(define-constant err-invalid-duration (err u106))
(define-constant err-stream-ended (err u107))
(define-constant err-stream-paused (err u108))
(define-constant err-nothing-to-claim (err u109))
(define-constant err-invalid-recipient (err u110))
(define-constant err-max-streams (err u111))
(define-constant err-invalid-rate (err u112))

;; Data Variables
(define-data-var stream-counter uint u0)
(define-data-var protocol-fee uint u10) ;; 0.1% = 10 basis points
(define-data-var total-fees-collected uint u0)
(define-data-var total-streamed uint u0)
(define-data-var emergency-pause bool false)

;; Data Maps
(define-map streams
    uint
    {
        sender: principal,
        recipient: principal,
        amount-total: uint,
        amount-per-block: uint,
        start-block: uint,
        end-block: uint,
        claimed-amount: uint,
        last-claim-block: uint,
        paused: bool,
        cancelled: bool,
        metadata: (string-utf8 256)
    }
)

(define-map user-streams 
    principal 
    {
        outgoing: (list 100 uint),
        incoming: (list 100 uint)
    }
)

(define-map stream-balances
    uint
    {
        deposited: uint,
        withdrawn: uint,
        refunded: uint
    }
)

(define-map user-stats
    principal
    {
        total-sent: uint,
        total-received: uint,
        active-outgoing: uint,
        active-incoming: uint,
        streams-created: uint
    }
)

;; Private Functions
(define-private (calculate-fee (amount uint))
    (/ (* amount (var-get protocol-fee)) u10000)
)

(define-private (calculate-claimable (stream-id uint))
    (match (map-get? streams stream-id)
        stream
        (if (or (get cancelled stream) (get paused stream))
            u0
            (let ((current-block (min stacks-block-height (get end-block stream)))
                  (last-claim (get last-claim-block stream))
                  (blocks-elapsed (- current-block last-claim)))
                (* blocks-elapsed (get amount-per-block stream))
            )
        )
        u0
    )
)

(define-private (min (a uint) (b uint))
    (if (<= a b) a b)
)

(define-private (update-user-stats (user principal) (field (string-ascii 20)) (amount uint) (increment bool))
    (let ((stats (default-to 
            {total-sent: u0, total-received: u0, active-outgoing: u0, 
             active-incoming: u0, streams-created: u0}
            (map-get? user-stats user))))
        (if (is-eq field "total-sent")
            (map-set user-stats user 
                (merge stats {total-sent: (if increment 
                    (+ (get total-sent stats) amount)
                    (- (get total-sent stats) amount))}))
        (if (is-eq field "total-received")
            (map-set user-stats user 
                (merge stats {total-received: (+ (get total-received stats) amount)}))
        (if (is-eq field "active-outgoing")
            (map-set user-stats user 
                (merge stats {active-outgoing: (if increment
                    (+ (get active-outgoing stats) u1)
                    (- (get active-outgoing stats) u1))}))
        (if (is-eq field "active-incoming")
            (map-set user-stats user 
                (merge stats {active-incoming: (if increment
                    (+ (get active-incoming stats) u1)
                    (- (get active-incoming stats) u1))}))
        (if (is-eq field "streams-created")
            (map-set user-stats user 
                (merge stats {streams-created: (+ (get streams-created stats) u1)}))
            false
        )))))
    )
)

(define-private (add-stream-to-user (user principal) (stream-id uint) (is-outgoing bool))
    (let ((current-streams (default-to {outgoing: (list), incoming: (list)} 
                                      (map-get? user-streams user))))
        (if is-outgoing
            (map-set user-streams user 
                (merge current-streams 
                    {outgoing: (unwrap! (as-max-len? (append (get outgoing current-streams) stream-id) u100) 
                                       err-max-streams)}))
            (map-set user-streams user 
                (merge current-streams 
                    {incoming: (unwrap! (as-max-len? (append (get incoming current-streams) stream-id) u100) 
                                       err-max-streams)}))
        )
        (ok true)
    )
)

;; Public Functions
(define-public (create-stream (recipient principal) (amount uint) (duration uint) 
                             (metadata (string-utf8 256)))
    (let ((stream-id (+ (var-get stream-counter) u1))
          (fee (calculate-fee amount))
          (total-required (+ amount fee))
          (amount-per-block (/ amount duration))
          (start-block stacks-block-height)
          (end-block (+ stacks-block-height duration)))
        
        (asserts! (not (var-get emergency-pause)) err-stream-paused)
        (asserts! (not (is-eq tx-sender recipient)) err-invalid-recipient)
        (asserts! (> amount u0) err-invalid-amount)
        (asserts! (> duration u0) err-invalid-duration)
        (asserts! (> amount-per-block u0) err-invalid-rate)
        (asserts! (>= (stx-get-balance tx-sender) total-required) err-insufficient-balance)
        
        (try! (stx-transfer? total-required tx-sender (as-contract tx-sender)))
        
        (map-set streams stream-id {
            sender: tx-sender,
            recipient: recipient,
            amount-total: amount,
            amount-per-block: amount-per-block,
            start-block: start-block,
            end-block: end-block,
            claimed-amount: u0,
            last-claim-block: start-block,
            paused: false,
            cancelled: false,
            metadata: metadata
        })
        
        (map-set stream-balances stream-id {
            deposited: amount,
            withdrawn: u0,
            refunded: u0
        })
        
        (try! (add-stream-to-user tx-sender stream-id true))
        (try! (add-stream-to-user recipient stream-id false))
        
        (update-user-stats tx-sender "streams-created" u1 true)
        (update-user-stats tx-sender "active-outgoing" u1 true)
        (update-user-stats recipient "active-incoming" u1 true)
        
        (var-set stream-counter stream-id)
        (var-set total-fees-collected (+ (var-get total-fees-collected) fee))
        
        (ok stream-id)
    )
)

(define-public (claim-from-stream (stream-id uint))
    (let ((stream (unwrap! (map-get? streams stream-id) err-stream-not-found))
          (claimable (calculate-claimable stream-id)))
        
        (asserts! (is-eq (get recipient stream) tx-sender) err-unauthorized)
        (asserts! (not (get cancelled stream)) err-stream-ended)
        (asserts! (> claimable u0) err-nothing-to-claim)
        
        (let ((new-claimed (+ (get claimed-amount stream) claimable))
              (current-block (min stacks-block-height (get end-block stream)))
              (balance (unwrap! (map-get? stream-balances stream-id) err-stream-not-found)))
            
            (try! (as-contract (stx-transfer? claimable tx-sender (get recipient stream))))
            
            (map-set streams stream-id 
                (merge stream {
                    claimed-amount: new-claimed,
                    last-claim-block: current-block
                }))
            
            (map-set stream-balances stream-id
                (merge balance {withdrawn: (+ (get withdrawn balance) claimable)}))
            
            (update-user-stats (get recipient stream) "total-received" claimable true)
            (var-set total-streamed (+ (var-get total-streamed) claimable))
            
            (if (>= current-block (get end-block stream))
                (begin
                    (update-user-stats (get sender stream) "active-outgoing" u1 false)
                    (update-user-stats (get recipient stream) "active-incoming" u1 false)
                    (ok claimable)
                )
                (ok claimable)
            )
        )
    )
)

(define-public (pause-stream (stream-id uint))
    (let ((stream (unwrap! (map-get? streams stream-id) err-stream-not-found)))
        (asserts! (is-eq (get sender stream) tx-sender) err-unauthorized)
        (asserts! (not (get cancelled stream)) err-stream-ended)
        (asserts! (not (get paused stream)) err-stream-paused)
        (asserts! (< stacks-block-height (get end-block stream)) err-stream-ended)
        
        ;; Auto-claim for recipient before pausing
        (let ((claimable (calculate-claimable stream-id)))
            (if (> claimable u0)
                (try! (as-contract (stx-transfer? claimable tx-sender (get recipient stream))))
                false
            )
            
            (map-set streams stream-id 
                (merge stream {
                    paused: true,
                    claimed-amount: (+ (get claimed-amount stream) claimable),
                    last-claim-block: stacks-block-height
                }))
            
            (if (> claimable u0)
                (begin
                    (update-user-stats (get recipient stream) "total-received" claimable true)
                    (var-set total-streamed (+ (var-get total-streamed) claimable))
                    (ok true)
                )
                (ok true)
            )
        )
    )
)

(define-public (resume-stream (stream-id uint))
    (let ((stream (unwrap! (map-get? streams stream-id) err-stream-not-found)))
        (asserts! (is-eq (get sender stream) tx-sender) err-unauthorized)
        (asserts! (not (get cancelled stream)) err-stream-ended)
        (asserts! (get paused stream) err-invalid-stream)
        
        (let ((pause-duration (- stacks-block-height (get last-claim-block stream)))
              (new-end-block (+ (get end-block stream) pause-duration)))
            
            (map-set streams stream-id 
                (merge stream {
                    paused: false,
                    end-block: new-end-block,
                    last-claim-block: stacks-block-height
                }))
            
            (ok true)
        )
    )
)

(define-public (cancel-stream (stream-id uint))
    (let ((stream (unwrap! (map-get? streams stream-id) err-stream-not-found)))
        (asserts! (or (is-eq (get sender stream) tx-sender)
                     (is-eq (get recipient stream) tx-sender)) err-unauthorized)
        (asserts! (not (get cancelled stream)) err-stream-ended)
        
        ;; Calculate and transfer any unclaimed amount to recipient
        (let ((claimable (if (get paused stream) u0 (calculate-claimable stream-id)))
              (total-claimable (+ (get claimed-amount stream) claimable))
              (refundable (- (get amount-total stream) total-claimable))
              (balance (unwrap! (map-get? stream-balances stream-id) err-stream-not-found)))
            
            (if (> claimable u0)
                (try! (as-contract (stx-transfer? claimable tx-sender (get recipient stream))))
                false
            )
            
            (if (> refundable u0)
                (try! (as-contract (stx-transfer? refundable tx-sender (get sender stream))))
                false
            )
            
            (map-set streams stream-id 
                (merge stream {
                    cancelled: true,
                    claimed-amount: total-claimable,
                    last-claim-block: stacks-block-height
                }))
            
            (map-set stream-balances stream-id
                (merge balance {
                    withdrawn: (+ (get withdrawn balance) claimable),
                    refunded: refundable
                }))
            
            (update-user-stats (get sender stream) "active-outgoing" u1 false)
            (update-user-stats (get recipient stream) "active-incoming" u1 false)
            
            (if (> claimable u0)
                (begin
                    (update-user-stats (get recipient stream) "total-received" claimable true)
                    (var-set total-streamed (+ (var-get total-streamed) claimable))
                    (ok {claimed: claimable, refunded: refundable})
                )
                (ok {claimed: u0, refunded: refundable})
            )
        )
    )
)

(define-public (withdraw-completed-stream (stream-id uint))
    (let ((stream (unwrap! (map-get? streams stream-id) err-stream-not-found)))
        (asserts! (is-eq (get recipient stream) tx-sender) err-unauthorized)
        (asserts! (>= stacks-block-height (get end-block stream)) err-invalid-stream)
        (asserts! (not (get cancelled stream)) err-stream-ended)
        
        (let ((final-claim (- (get amount-total stream) (get claimed-amount stream))))
            (asserts! (> final-claim u0) err-nothing-to-claim)
            
            (try! (as-contract (stx-transfer? final-claim tx-sender (get recipient stream))))
            
            (map-set streams stream-id 
                (merge stream {
                    claimed-amount: (get amount-total stream),
                    last-claim-block: (get end-block stream)
                }))
            
            (update-user-stats (get sender stream) "active-outgoing" u1 false)
            (update-user-stats (get recipient stream) "active-incoming" u1 false)
            (update-user-stats (get recipient stream) "total-received" final-claim true)
            (var-set total-streamed (+ (var-get total-streamed) final-claim))
            
            (ok final-claim)
        )
    )
)

(define-public (toggle-emergency-pause)
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-unauthorized)
        (var-set emergency-pause (not (var-get emergency-pause)))
        (ok (var-get emergency-pause))
    )
)

(define-public (update-protocol-fee (new-fee uint))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-unauthorized)
        (asserts! (<= new-fee u100) err-invalid-amount) ;; Max 1%
        (var-set protocol-fee new-fee)
        (ok true)
    )
)

(define-public (withdraw-fees)
    (let ((fees (var-get total-fees-collected)))
        (asserts! (is-eq tx-sender contract-owner) err-unauthorized)
        (asserts! (> fees u0) err-nothing-to-claim)
        
        (try! (as-contract (stx-transfer? fees tx-sender contract-owner)))
        (var-set total-fees-collected u0)
        (ok fees)
    )
)

;; Read-only Functions
(define-read-only (get-stream (stream-id uint))
    (map-get? streams stream-id)
)

(define-read-only (get-stream-balance (stream-id uint))
    (map-get? stream-balances stream-id)
)

(define-read-only (get-claimable-amount (stream-id uint))
    (calculate-claimable stream-id)
)

(define-read-only (get-user-streams (user principal))
    (default-to {outgoing: (list), incoming: (list)} 
        (map-get? user-streams user))
)

(define-read-only (get-user-stats (user principal))
    (default-to {total-sent: u0, total-received: u0, active-outgoing: u0, 
                active-incoming: u0, streams-created: u0}
        (map-get? user-stats user))
)

(define-read-only (get-protocol-stats)
    {
        total-streams: (var-get stream-counter),
        total-streamed: (var-get total-streamed),
        total-fees: (var-get total-fees-collected),
        protocol-fee: (var-get protocol-fee),
        emergency-pause: (var-get emergency-pause)
    }
)

(define-read-only (is-stream-active (stream-id uint))
    (match (map-get? streams stream-id)
        stream (and (not (get cancelled stream))
                   (not (get paused stream))
                   (< stacks-block-height (get end-block stream)))
        false
    )
)