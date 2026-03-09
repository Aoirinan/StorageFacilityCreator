// Script to enable Stripe Connect feature flag
// Run from functions directory: node enable_connect.js

const admin = require('firebase-admin');

// Initialize with explicit project ID
admin.initializeApp({
  projectId: 'storage-facility-creator',
});

const db = admin.firestore();

async function enableStripeConnect() {
  try {
    console.log('🔄 Enabling Stripe Connect feature flag...');
    
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
    console.log('\n📋 Current config:');
    console.log(JSON.stringify(updatedConfig.data(), null, 2));
    
    console.log('\n✅ Done! Stripe Connect is now enabled.');
    process.exit(0);
  } catch (error) {
    console.error('❌ Error enabling Stripe Connect:', error);
    process.exit(1);
  }
}

enableStripeConnect();
