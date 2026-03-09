// Script to enable Stripe Connect feature flag in Firestore
// Run with: node scripts/enable_stripe_connect.js

const admin = require('firebase-admin');

// Initialize Firebase Admin (uses default credentials from environment)
admin.initializeApp();

const db = admin.firestore();

async function enableStripeConnect() {
  try {
    const configRef = db.collection('appConfig').doc('stripe');
    const configDoc = await configRef.get();

    if (!configDoc.exists) {
      // Create config document with Connect enabled
      await configRef.set({
        connectEnabledGlobal: true,
        tenantAutopayEnabledGlobal: false,
        storeEnabledGlobal: false,
        checkoutEnabledGlobal: false,
        allowlistFacilityIds: [],
        killSwitch: false,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      console.log('✅ Stripe config document created with Connect enabled!');
    } else {
      // Update existing config to enable Connect
      await configRef.update({
        connectEnabledGlobal: true,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      console.log('✅ Stripe Connect enabled in existing config!');
    }

    const updatedConfig = await configRef.get();
    console.log('Current config:', JSON.stringify(updatedConfig.data(), null, 2));
    process.exit(0);
  } catch (error) {
    console.error('❌ Error enabling Stripe Connect:', error);
    process.exit(1);
  }
}

enableStripeConnect();
