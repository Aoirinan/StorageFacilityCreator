import { withSenderPrefix } from './a2pCampaign';

/**
 * The exact body sendSMS sends: the STOP/HELP footer, and the facility's name
 * in front.
 *
 * The name goes on every text, whichever number sends it. On the shared
 * platform number it is the only way the recipient can tell who is texting; on
 * a facility's own registered number it keeps live traffic identical to the
 * samples filed with the facility's campaign, which all open with the name.
 * It is added once (a body already opening with the name is left alone), and
 * before the message is logged or counted, so the log shows what was sent.
 */
export async function composeOutboundSmsBody(
  facilityData: Record<string, any>,
  message: string,
  addFooter: (message: string) => Promise<string>,
): Promise<string> {
  return withSenderPrefix(facilityData, await addFooter(message));
}
