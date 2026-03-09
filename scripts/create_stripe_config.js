// Script to create the Stripe feature flags config document in Firestore
// Run with: node scripts/create_stripe_config.js

const admin = require('firebase-admin');
const serviceAccount = require('../functions/serviceAccountKey.json'); // You may need to adjust this path

admin.initializeApp({
  credential: admin.credential.cert(serviceAccount),
});

const db = admin.firestore();

async function createStripeConfig() {
  try {
    const config = {
      connectEnabledGlobal: false,
      tenantAutopayEnabledGlobal: false,
      storeEnabledGlobal: false,
      checkoutEnabledGlobal: false,
      allowlistFacilityIds: [],
      killSwitch: false,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    };

    await db.collection('appConfig').doc('stripe').set(config);
    console.log('✅ Stripe config document created successfully!');
    console.log('Config:', JSON.stringify(config, null, 2));
    process.exit(0);
  } catch (error) {
    console.error('❌ Error creating config:', error);
    process.exit(1);
  }
}

createStripeConfig();
