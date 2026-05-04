import { registerSfcLeadConfigProvider } from '@sfc/functions-shared';

import {
  SFC_LEAD_FORWARD_TO_NUMBER,
  SFC_LEAD_LINE_NUMBER,
  SFC_LEAD_SMS_AUTO_REPLY,
} from './secrets';

registerSfcLeadConfigProvider({
  getLeadLine: () => SFC_LEAD_LINE_NUMBER.value(),
  getSmsAutoReply: () => SFC_LEAD_SMS_AUTO_REPLY.value(),
  getForwardTo: () => SFC_LEAD_FORWARD_TO_NUMBER.value(),
});
