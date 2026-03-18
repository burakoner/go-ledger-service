package worker

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log"
	"time"

	"github.com/lib/pq"
)

const transactionProcessTimeout = 10 * time.Second

type pendingTransaction struct {
	ID        string
	Reference string
	Type      string
	Amount    int64
}

type processedTransaction struct {
	TenantID      string
	TenantSchema  string
	TransactionID string
	Reference     string
	Status        string
}

func (r *runtime) processNextPendingTransaction(ctx context.Context, tenantValue activeTenant) (*processedTransaction, error) {
	if r == nil || r.db == nil {
		return nil, errors.New("worker runtime is not initialized")
	}

	processCtx, cancel := context.WithTimeout(ctx, transactionProcessTimeout)
	defer cancel()

	tx, err := r.db.BeginTx(processCtx, &sql.TxOptions{Isolation: sql.LevelReadCommitted})
	if err != nil {
		return nil, fmt.Errorf("begin transaction: %w", err)
	}
	defer func() {
		_ = tx.Rollback()
	}()

	pending, found, err := claimPendingTransaction(processCtx, tx, tenantValue.TenantSchema)
	if err != nil {
		return nil, err
	}
	if !found {
		return nil, nil
	}

	currentBalance, err := lockCurrentBalance(processCtx, tx, tenantValue.TenantSchema)
	if err != nil {
		return nil, err
	}

	status, newBalance, changeAmount, failureCode, failureReason := evaluateTransaction(pending, currentBalance)

	if status == "completed" {
		if err := applyCompletedTransaction(processCtx, tx, tenantValue.TenantSchema, pending, currentBalance, newBalance, changeAmount); err != nil {
			return nil, err
		}
	}

	if err := updateTransactionTerminalStatus(processCtx, tx, tenantValue.TenantSchema, pending.ID, status, failureCode, failureReason); err != nil {
		return nil, err
	}

	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("commit transaction processing: %w", err)
	}

	if err := r.dispatchTransactionWebhookNow(
		context.Background(),
		tenantValue.TenantID,
		pending.ID,
		pending.Reference,
		status,
		pending.Amount,
	); err != nil {
		log.Printf(
			"direct webhook delivery failed tenant=%s transaction=%s reference=%s: %v",
			tenantValue.TenantID,
			pending.ID,
			pending.Reference,
			err,
		)
	}

	return &processedTransaction{
		TenantID:      tenantValue.TenantID,
		TenantSchema:  tenantValue.TenantSchema,
		TransactionID: pending.ID,
		Reference:     pending.Reference,
		Status:        status,
	}, nil
}

func claimPendingTransaction(ctx context.Context, tx *sql.Tx, tenantSchema string) (pendingTransaction, bool, error) {
	query := fmt.Sprintf(
		`SELECT id::text, reference, type, amount
		FROM %s.transactions
		WHERE status = 'pending'
		ORDER BY created_at ASC, id ASC
		FOR UPDATE SKIP LOCKED
		LIMIT 1`,
		pq.QuoteIdentifier(tenantSchema),
	)

	var row pendingTransaction
	err := tx.QueryRowContext(ctx, query).Scan(
		&row.ID,
		&row.Reference,
		&row.Type,
		&row.Amount,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return pendingTransaction{}, false, nil
	}
	if err != nil {
		return pendingTransaction{}, false, fmt.Errorf("claim pending transaction from schema %q: %w", tenantSchema, err)
	}

	return row, true, nil
}

func lockCurrentBalance(ctx context.Context, tx *sql.Tx, tenantSchema string) (int64, error) {
	query := fmt.Sprintf(`SELECT balance FROM %s.balances WHERE id = 1 FOR UPDATE`, pq.QuoteIdentifier(tenantSchema))

	var balance int64
	err := tx.QueryRowContext(ctx, query).Scan(&balance)
	if errors.Is(err, sql.ErrNoRows) {
		insertQuery := fmt.Sprintf(
			`INSERT INTO %s.balances (id, balance, updated_at) VALUES (1, 0, now()) ON CONFLICT (id) DO NOTHING`,
			pq.QuoteIdentifier(tenantSchema),
		)
		if _, insertErr := tx.ExecContext(ctx, insertQuery); insertErr != nil {
			return 0, fmt.Errorf("initialize balance row in schema %q: %w", tenantSchema, insertErr)
		}

		err = tx.QueryRowContext(ctx, query).Scan(&balance)
	}
	if err != nil {
		return 0, fmt.Errorf("lock balance row in schema %q: %w", tenantSchema, err)
	}

	return balance, nil
}

func evaluateTransaction(row pendingTransaction, currentBalance int64) (string, int64, int64, string, string) {
	switch row.Type {
	case "credit":
		return "completed", currentBalance + row.Amount, row.Amount, "", ""
	case "debit":
		if currentBalance < row.Amount {
			reason := fmt.Sprintf("Debit of %d exceeds available balance of %d", row.Amount, currentBalance)
			return "failed", currentBalance, 0, "INSUFFICIENT_BALANCE", reason
		}
		return "completed", currentBalance - row.Amount, -row.Amount, "", ""
	default:
		reason := fmt.Sprintf("Unsupported transaction type %q", row.Type)
		return "failed", currentBalance, 0, "INVALID_TRANSACTION_TYPE", reason
	}
}

func applyCompletedTransaction(ctx context.Context, tx *sql.Tx, tenantSchema string, row pendingTransaction, previousBalance, newBalance, changeAmount int64) error {
	updateBalanceQuery := fmt.Sprintf(
		`UPDATE %s.balances SET balance = $1, updated_at = now() WHERE id = 1`,
		pq.QuoteIdentifier(tenantSchema),
	)
	if _, err := tx.ExecContext(ctx, updateBalanceQuery, newBalance); err != nil {
		return fmt.Errorf("update balance in schema %q: %w", tenantSchema, err)
	}

	insertLedgerQuery := fmt.Sprintf(
		`INSERT INTO %s.ledger_entries (
			transaction_id,
			reference,
			change_amount,
			previous_balance,
			new_balance
		)
		VALUES ($1::uuid, $2, $3, $4, $5)`,
		pq.QuoteIdentifier(tenantSchema),
	)
	if _, err := tx.ExecContext(ctx, insertLedgerQuery, row.ID, row.Reference, changeAmount, previousBalance, newBalance); err != nil {
		return fmt.Errorf("insert ledger entry in schema %q: %w", tenantSchema, err)
	}

	return nil
}

func updateTransactionTerminalStatus(ctx context.Context, tx *sql.Tx, tenantSchema, transactionID, status, failureCode, failureReason string) error {
	query := fmt.Sprintf(
		`UPDATE %s.transactions
		SET
			status = $2,
			failure_code = $3,
			failure_reason = $4,
			processed_at = now(),
			updated_at = now()
		WHERE id = $1::uuid`,
		pq.QuoteIdentifier(tenantSchema),
	)

	var failureCodeValue interface{}
	var failureReasonValue interface{}
	if failureCode != "" {
		failureCodeValue = failureCode
	}
	if failureReason != "" {
		failureReasonValue = failureReason
	}

	if _, err := tx.ExecContext(ctx, query, transactionID, status, failureCodeValue, failureReasonValue); err != nil {
		return fmt.Errorf("update transaction terminal status in schema %q: %w", tenantSchema, err)
	}

	return nil
}
