/** A 1x1 PNG, standing in for the renter's signature. */
export const SIGNATURE_PNG_BASE64 =
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

/** A completed move-in form, as the page sends it to createPublicMoveInCheckout. */
export const MOVE_IN_FORM = {
  name: 'Rita Renter',
  email: 'renter@example.com',
  phone: '5551234567',
  address: '1 Main St',
  addressLine2: '',
  city: 'Springfield',
  state: 'IL',
  zipCode: '62701',
  country: 'US',
  emergencyContactName: 'Ed Emergency',
  emergencyContactPhone: '5559876543',
  emergencyContactRelationship: 'Brother',
  emergencyContactEmail: 'ed@example.com',
  governmentIdType: 'driversLicense',
  governmentIdNumber: 'D1234567',
  governmentIdState: 'IL',
  governmentIdCountry: 'US',
  notes: '',
  signaturePngBase64: SIGNATURE_PNG_BASE64,
  signatureSignedAt: '2026-09-24T12:00:00.000Z',
  enrollAutopayInterest: false,
};
