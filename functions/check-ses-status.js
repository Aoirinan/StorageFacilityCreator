// Check AWS SES account status
const { SESClient, GetAccountSendingEnabledCommand, GetSendQuotaCommand } = require('@aws-sdk/client-ses');
require('dotenv').config();

async function checkSESStatus() {
  console.log('🔍 Checking AWS SES Account Status...\n');

  const sesClient = new SESClient({
    region: process.env.SES_REGION,
    credentials: {
      accessKeyId: process.env.SES_ACCESS_KEY_ID,
      secretAccessKey: process.env.SES_SECRET_ACCESS_KEY,
    },
  });

  try {
    // Check sending quota
    const quotaCommand = new GetSendQuotaCommand({});
    const quotaResult = await sesClient.send(quotaCommand);
    
    console.log('📊 Sending Quota Information:');
    console.log('   Max 24 Hour Send:', quotaResult.Max24HourSend);
    console.log('   Max Send Rate:', quotaResult.MaxSendRate, 'emails/second');
    console.log('   Sent Last 24 Hours:', quotaResult.SentLast24Hours);
    console.log('');

    // Determine sandbox status
    const isSandbox = quotaResult.Max24HourSend === 200;
    
    if (isSandbox) {
      console.log('⚠️  SANDBOX MODE DETECTED');
      console.log('   You can only send to verified email addresses.');
      console.log('   Daily limit: 200 emails');
      console.log('');
      console.log('🎯 TO REQUEST PRODUCTION ACCESS:');
      console.log('   1. Go to: https://console.aws.amazon.com/ses/');
      console.log('   2. Click "Account Dashboard" in the left menu');
      console.log('   3. Click "Request production access" button');
      console.log('   4. Fill out the form explaining your use case');
      console.log('   5. Wait 24-48 hours for approval');
    } else {
      console.log('✅ PRODUCTION MODE ACTIVE!');
      console.log('   You can send to ANY email address!');
      console.log(`   Daily limit: ${quotaResult.Max24HourSend.toLocaleString()} emails`);
      console.log(`   Sending rate: ${quotaResult.MaxSendRate} emails/second`);
      console.log('');
      console.log('🎉 Your SES account is ready for production use!');
    }

  } catch (error) {
    console.error('❌ Error checking SES status:', error.message);
  }
}

checkSESStatus();

