# Token Stream - Smart Contract Documentation

## Overview
Token Stream enables continuous, per-block token streaming for subscriptions, salaries, and recurring payments with pause/resume functionality and automatic pro-rata calculations.

## Problem Solved
- **Payment Inefficiency**: Eliminates manual recurring transactions
- **Cash Flow**: Enables real-time salary/subscription payments
- **Trust Issues**: Automated payments without intermediaries
- **Flexibility**: Pause/resume/cancel with automatic settlements

## Key Features

### Core Functionality
- Per-block continuous streaming
- Pause/resume capabilities
- Automatic pro-rata calculations
- Bidirectional cancellation rights
- Emergency pause mechanism

### Financial Features
- Ultra-low 0.1% protocol fee
- Automatic refunds on cancellation
- Real-time claimable balance
- Completed stream withdrawal

## Contract Functions

### Stream Management

#### `create-stream`
- **Parameters**: recipient, amount, duration, metadata
- **Returns**: stream-id
- **Effect**: Locks tokens, starts streaming

#### `claim-from-stream`
- **Parameters**: stream-id
- **Returns**: claimed amount
- **Requirement**: Must be recipient

#### `pause-stream`
- **Parameters**: stream-id
- **Effect**: Auto-claims, pauses streaming
- **Requirement**: Must be sender

#### `resume-stream`
- **Parameters**: stream-id
- **Effect**: Adjusts end-block, resumes
- **Requirement**: Must be sender

#### `cancel-stream`
- **Parameters**: stream-id
- **Returns**: {claimed, refunded}
- **Effect**: Settles and refunds remainder

#### `withdraw-completed-stream`
- **Parameters**: stream-id
- **Effect**: Claims remaining after end-block

### Read Functions
- `get-stream`: Stream details
- `get-claimable-amount`: Real-time claimable
- `get-user-streams`: User's stream lists
- `get-user-stats`: Streaming statistics
- `is-stream-active`: Check stream status

## Usage Examples

```clarity
;; Create monthly salary stream (30 days)
(contract-call? .token-stream create-stream
    'SP2J6Y09...  ;; employee
    u30000000     ;; 30 STX
    u129600       ;; ~30 days in blocks
    u"Monthly salary - November 2024")

;; Employee claims accumulated tokens
(contract-call? .token-stream claim-from-stream u1)

;; Pause stream (auto-claims for recipient)
(contract-call? .token-stream pause-stream u1)

;; Resume stream (extends deadline)
(contract-call? .token-stream resume-stream u1)

;; Cancel stream (settles balances)
(contract-call? .token-stream cancel-stream u1)
```

## Stream Calculations
- **Rate**: amount-per-block = total-amount / duration
- **Claimable**: (current-block - last-claim) * rate
- **Refundable**: total - claimed (on cancellation)

## Security Features
1. **Self-streaming prevention**
2. **Minimum rate validation**
3. **Balance verification**
4. **Emergency pause (owner only)**
5. **Automatic settlements**
6. **Maximum stream limits (100 per user)**

## Contract Limits
- 100 outgoing streams per user
- 100 incoming streams per user
- Maximum 1% protocol fee
- Minimum 1 micro-STX per block rate

## Deployment
1. Deploy contract
2. Set protocol fee (optional)
3. Monitor via read-only functions
4. Withdraw fees periodically

## Testing Checklist
- Stream creation and token locking
- Real-time claiming
- Pause/resume with duration adjustment
- Cancellation with refunds
- Edge cases (zero rates, completed streams)
- Emergency pause functionality

## Use Cases
- **Salaries**: Continuous payroll streaming
- **Subscriptions**: SaaS/content subscriptions
- **Vesting**: Token vesting schedules
- **Rent**: Continuous rent payments
- **DCA**: Dollar-cost averaging investments

## Gas Optimization
- Single transfer per claim
- Batched state updates
- Efficient block calculations
- Minimal storage per stream
