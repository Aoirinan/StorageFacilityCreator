/** Map Stripe error codes to user-friendly messages */
export function mapStripeErrorToUserMessage(error: { code?: string; type?: string }): string {
  const errorCode = error?.code || error?.type || '';

  switch (errorCode) {
    case 'card_declined':
      return 'Your card was declined. Please try another card or contact your bank.';
    case 'insufficient_funds':
      return 'Insufficient funds. Please use a different payment method.';
    case 'expired_card':
      return 'Your card has expired. Please use a different card.';
    case 'incorrect_cvc':
      return 'The security code is incorrect. Please check and try again.';
    case 'incorrect_number':
      return 'The card number is incorrect. Please check and try again.';
    case 'processing_error':
      return 'An error occurred while processing your card. Please try again.';
    case 'generic_decline':
      return 'Your card was declined. Please try another card.';
    case 'lost_card':
    case 'stolen_card':
    case 'pickup_card':
    case 'restricted_card':
      return 'Your card was declined. Please contact your bank.';
    case 'security_violation':
      return 'Your card was declined due to a security violation. Please contact your bank.';
    case 'service_not_allowed':
      return 'This card type is not accepted. Please use a different card.';
    case 'do_not_honor':
      return 'Your card was declined. Please try another card or contact your bank.';
    default:
      return 'Failed to process payment. Please try again or contact support.';
  }
}
