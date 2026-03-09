// Script to create the AI Assistant feature flags config document in Firestore
// Run with: node scripts/create_ai_assistant_config.js

const admin = require('firebase-admin');

// Initialize Firebase Admin (will use default credentials or environment)
try {
  admin.initializeApp();
} catch (e) {
  // Already initialized
}

const db = admin.firestore();

async function createAIAssistantConfig() {
  try {
    console.log('🔄 Creating AI Assistant config document...');
    
    const configRef = db.collection('appConfig').doc('aiAssistant');
    const configDoc = await configRef.get();

    if (configDoc.exists) {
      console.log('⚠️  AI Assistant config already exists. Updating...');
      await configRef.update({
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      console.log('✅ AI Assistant config updated!');
    } else {
      const config = {
        enabled: false,
        allowlistFacilityIds: [],
        killSwitch: false,
        provider: 'openai', // or 'anthropic'
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      };

      await configRef.set(config);
      console.log('✅ AI Assistant config document created successfully!');
    }

    const updatedConfig = await configRef.get();
    console.log('\n📋 Current config:');
    console.log(JSON.stringify(updatedConfig.data(), null, 2));
    
    console.log('\n💡 To enable for a specific facility, add its ID to allowlistFacilityIds:');
    console.log('   Example: allowlistFacilityIds: ["facility-id-1", "facility-id-2"]');
    console.log('\n💡 To enable globally, set enabled: true');
    console.log('\n✅ Done!');
    process.exit(0);
  } catch (error) {
    console.error('❌ Error creating config:', error);
    console.error('\n💡 Make sure you have Firebase Admin SDK credentials configured.');
    console.error('   You can also create this manually in Firebase Console:');
    console.error('   Collection: appConfig');
    console.error('   Document ID: aiAssistant');
    console.error('   Fields: enabled (boolean), allowlistFacilityIds (array), killSwitch (boolean), provider (string)');
    process.exit(1);
  }
}

createAIAssistantConfig();
