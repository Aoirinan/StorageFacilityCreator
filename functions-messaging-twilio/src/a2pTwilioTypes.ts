/**
 * The slice of the Twilio client the A2P registration flow uses, typed from the
 * SDK's own option interfaces.
 *
 * The registration code used to take `twilio: any`, which hid two bugs that
 * would only have surfaced after an owner paid: the brand was created with
 * `a2pProfileBundleSid` (the SDK field is `a2PProfileBundleSid`), and campaigns
 * were created through `messaging.v1.campaigns`, which does not exist. Typing
 * the parameters from the SDK makes both compile errors.
 *
 * It is a narrow structural interface rather than the full `Twilio` class so a
 * test can supply a small fake; `getA2PTwilioClient` in twilioClient.ts checks
 * at compile time that the real client satisfies it.
 */
import type {
  CustomerProfilesContextUpdateOptions,
  CustomerProfilesListInstanceCreateOptions,
  CustomerProfilesListInstanceOptions,
} from 'twilio/lib/rest/trusthub/v1/customerProfiles';
import type {
  TrustProductsContextUpdateOptions,
  TrustProductsListInstanceCreateOptions,
} from 'twilio/lib/rest/trusthub/v1/trustProducts';
import type {
  EndUserContextUpdateOptions,
  EndUserListInstanceCreateOptions,
} from 'twilio/lib/rest/trusthub/v1/endUser';
import type {
  SupportingDocumentContextUpdateOptions,
  SupportingDocumentListInstanceCreateOptions,
} from 'twilio/lib/rest/trusthub/v1/supportingDocument';
import type {
  AddressContextUpdateOptions,
  AddressListInstanceCreateOptions,
} from 'twilio/lib/rest/api/v2010/account/address';
import type { BrandRegistrationListInstanceCreateOptions } from 'twilio/lib/rest/messaging/v1/brandRegistration';
import type { UsAppToPersonListInstanceCreateOptions } from 'twilio/lib/rest/messaging/v1/service/usAppToPerson';
import type { ServiceListInstanceCreateOptions } from 'twilio/lib/rest/messaging/v1/service';
import type { PhoneNumberListInstanceCreateOptions as MessagingServicePhoneNumberCreateOptions } from 'twilio/lib/rest/messaging/v1/service/phoneNumber';
import type { LocalListInstanceOptions } from 'twilio/lib/rest/api/v2010/account/availablePhoneNumberCountry/local';
import type { IncomingPhoneNumberListInstanceCreateOptions } from 'twilio/lib/rest/api/v2010/account/incomingPhoneNumber';

export type {
  BrandRegistrationListInstanceCreateOptions,
  UsAppToPersonListInstanceCreateOptions,
};

/** A customer profile or trust product as TrustHub returns it. */
export interface TrustHubBundleRecord {
  sid: string;
  status: string;
  policySid: string;
}

export interface TrustHubEvaluationRecord {
  sid: string;
  policySid: string;
  status: string;
  results: any[];
}

export interface TrustHubAssignmentList {
  (assignmentSid: string): { remove(): Promise<boolean> };
  list(params: { limit?: number }): Promise<Array<{ sid: string; objectSid: string }>>;
  create(params: { objectSid: string }): Promise<{ sid: string }>;
}

export interface TrustHubEvaluationList {
  create(params: { policySid: string }): Promise<TrustHubEvaluationRecord>;
}

export interface CustomerProfileContext {
  fetch(): Promise<TrustHubBundleRecord>;
  update(params: CustomerProfilesContextUpdateOptions): Promise<TrustHubBundleRecord>;
  customerProfilesEntityAssignments: TrustHubAssignmentList;
  customerProfilesEvaluations: TrustHubEvaluationList;
}

export interface TrustProductContext {
  fetch(): Promise<TrustHubBundleRecord>;
  update(params: TrustProductsContextUpdateOptions): Promise<TrustHubBundleRecord>;
  trustProductsEntityAssignments: TrustHubAssignmentList;
  trustProductsEvaluations: TrustHubEvaluationList;
}

/** Either kind of bundle, for code that treats them alike. */
export interface TrustHubBundleContext {
  fetch(): Promise<TrustHubBundleRecord>;
  update(params: { status?: 'pending-review' }): Promise<TrustHubBundleRecord>;
}

export interface BrandRegistrationRecord {
  sid: string;
  status: string;
  errors: Array<any>;
  failureReason: string;
}

/** A campaign: `sid` is the QE... resource, `campaignId` the carrier CM... id. */
export interface UsAppToPersonRecord {
  sid: string;
  campaignId: string;
  campaignStatus: string;
  errors: Array<any>;
}

export interface UsAppToPersonList {
  (sid: string): { fetch(): Promise<UsAppToPersonRecord>; remove(): Promise<boolean> };
  create(params: UsAppToPersonListInstanceCreateOptions): Promise<UsAppToPersonRecord>;
  list(params: { limit?: number }): Promise<UsAppToPersonRecord[]>;
}

export interface A2PTwilioClient {
  trusthub: {
    v1: {
      customerProfiles: {
        (sid: string): CustomerProfileContext;
        create(params: CustomerProfilesListInstanceCreateOptions): Promise<TrustHubBundleRecord>;
        list(params: CustomerProfilesListInstanceOptions): Promise<TrustHubBundleRecord[]>;
      };
      trustProducts: {
        (sid: string): TrustProductContext;
        create(params: TrustProductsListInstanceCreateOptions): Promise<TrustHubBundleRecord>;
      };
      endUsers: {
        (sid: string): { update(params: EndUserContextUpdateOptions): Promise<{ sid: string }> };
        create(params: EndUserListInstanceCreateOptions): Promise<{ sid: string }>;
      };
      supportingDocuments: {
        (sid: string): {
          update(params: SupportingDocumentContextUpdateOptions): Promise<{ sid: string }>;
        };
        create(params: SupportingDocumentListInstanceCreateOptions): Promise<{ sid: string }>;
      };
    };
  };
  addresses: {
    (sid: string): { update(params: AddressContextUpdateOptions): Promise<{ sid: string }> };
    create(params: AddressListInstanceCreateOptions): Promise<{ sid: string }>;
  };
  /** Local numbers for sale, e.g. availablePhoneNumbers('US').local.list(...). */
  availablePhoneNumbers: (country: string) => {
    local: { list(params: LocalListInstanceOptions): Promise<Array<{ phoneNumber: string }>> };
  };
  incomingPhoneNumbers: {
    create(params: IncomingPhoneNumberListInstanceCreateOptions): Promise<{ sid: string; phoneNumber: string }>;
  };
  messaging: {
    v1: {
      brandRegistrations: {
        (sid: string): {
          fetch(): Promise<BrandRegistrationRecord>;
          /**
           * POST /v1/a2p/BrandRegistrations/{Sid}: resubmit a FAILED brand for
           * vetting (Twilio error 21725 otherwise). Free up to three times.
           */
          update(): Promise<BrandRegistrationRecord>;
        };
        create(params: BrandRegistrationListInstanceCreateOptions): Promise<{ sid: string }>;
      };
      services: {
        (sid: string): {
          usAppToPerson: UsAppToPersonList;
          /** A messaging-service number's `sid` IS the PN... phone number SID. */
          phoneNumbers: {
            list(params: { limit?: number }): Promise<Array<{ sid: string }>>;
            create(params: MessagingServicePhoneNumberCreateOptions): Promise<{ sid: string }>;
          };
        };
        create(params: ServiceListInstanceCreateOptions): Promise<{ sid: string }>;
      };
    };
  };
}
