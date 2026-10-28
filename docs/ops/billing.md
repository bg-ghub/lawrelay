# Billing operations

LawRelay's initial paid-pilot path is a manual Belgian B2B invoice/Peppol handoff with bank reconciliation. The application does not yet create a Mollie checkout, transmit a Peppol invoice, or reconcile a bank account automatically.

## Safety defaults

- Production enforces posting entitlements by default. `LAWRELAY_BILLING_ENFORCED=false` must never be used as an informal production workaround.
- Development and test remain unenforced unless the variable is explicitly set to `true`.
- Lawyer-to-lawyer assignment fees stay entirely outside LawRelay.
- An active paid entitlement expires at its recorded period end.
- Cancelled, refunded, and charged-back subscriptions cannot regain access from a late payment callback.

## Manual invoice and payment flow

1. A firm owner/administrator requests an invoice from the billing page.
2. The application issues an invoice and marks it as requiring manual accounting/Peppol handoff.
3. The named billing operator validates the firm's legal/VAT details, sends the compliant invoice through the selected accounting/Peppol system, and records that system's reference.
4. After cleared funds are independently confirmed, a system administrator confirms the pending LawRelay payment from a protected production console:

```sh
PAYMENT_ID=123 \
ACTOR_EMAIL=operator@your-firm.example \
PAYMENT_REFERENCE=bank-or-peppol-reference \
bin/rails lawrelay:confirm_manual_payment
```

The task refuses non-admin actors, non-manual or non-pending payments, total mismatches, missing references, and cancelled/suspended billing. A successful run marks the payment and invoice paid, grants exactly one month, and writes `billing.manual_payment_confirmed` to the audit trail. Repeating the same confirmation is idempotent and does not extend the period again.

Record the bank/Peppol evidence, operator, time, payment ID, invoice number, and audit-event ID in the reconciliation register. Never put bank credentials or full bank statements in LawRelay.

## Mollie boundary

The repository contains authoritative-fetch webhook processing for already-created Mollie payments, including idempotent lifecycle handling and entitlement revocation. It deliberately does not claim a working self-service checkout. Before enabling Mollie, add hosted-checkout/payment creation, provider-side cancellation, sandbox tests, refund/credit operations, reconciliation ownership, and reviewed customer communications.
