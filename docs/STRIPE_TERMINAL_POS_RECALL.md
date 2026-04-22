# Stripe Terminal (card reader) — recall notes

Use this when you pick up POS + Stripe reader work again (hardware was pending as of initial integration).

## What was added

- **Firebase callable functions** (`functions/src/index.ts`):
  - `listPosTerminalReaders` — readers on the facility’s **Stripe Connect** account
  - `processPosTerminalPayment` — creates a `card_present` PaymentIntent and sends it to the selected reader (server-driven Terminal flow)
  - `getPosTerminalPaymentStatus` — poll until the reader flow completes

- **Flutter**
  - `lib/services/stripe_service.dart` — wraps the three callables above
  - `lib/screens/pos_screen.dart` — **“Use Stripe card reader”** toggle under card payment; when **off**, behavior stays the existing embedded Payment Element flow

## Deploy (when ready)

Deploy the new functions, for example:

```bash
firebase deploy --only functions:listPosTerminalReaders,functions:processPosTerminalPayment,functions:getPosTerminalPaymentStatus
```

## When the reader arrives

1. Register / assign the reader in **Stripe** for the same **connected account** the facility uses.
2. Open **Retail (POS)** on **web**, choose **Credit Card**, turn on **Use Stripe card reader**, complete sale, pick reader.
3. Confirm in Stripe: PaymentIntent succeeded.
4. Confirm in app: sale recorded with `stripePaymentIntentId`.

## Related Stripe docs

- [Collect card payment (Terminal, JS)](https://docs.stripe.com/terminal/payments/collect-card-payment?terminal-sdk-platform=js) — conceptual flow (`card_present`, collect, process)
- [Connect to a reader](https://docs.stripe.com/terminal/payments/connect-reader) — reader discovery / registration context
