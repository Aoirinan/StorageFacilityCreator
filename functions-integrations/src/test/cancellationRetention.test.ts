import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import {
  DEFAULT_CANCELLATION_RETENTION_CONFIG,
} from '../cancellationRetentionDefaults';

describe('cancellation retention defaults', () => {
  it('includes primary reasons with matching detail options', () => {
    const { primaryReasons, detailReasonsByPrimary } =
      DEFAULT_CANCELLATION_RETENTION_CONFIG;
    assert.ok(primaryReasons.length >= 4);
    for (const reason of primaryReasons) {
      const details = detailReasonsByPrimary[reason.id] || [];
      assert.ok(
        details.length >= 2,
        `expected details for ${reason.id}`,
      );
    }
  });

  it('seeds active promos for platform and website', () => {
    const promos = DEFAULT_CANCELLATION_RETENTION_CONFIG.promos.filter((p) => p.active);
    assert.ok(promos.some((p) => p.planTypes.includes('platform')));
    assert.ok(promos.some((p) => p.planTypes.includes('website')));
    for (const promo of promos) {
      assert.ok(
        (promo.percentOff ?? 0) > 0 || (promo.amountOffCents ?? 0) > 0,
      );
      assert.ok(promo.durationMonths >= 1);
    }
  });

  it('has loss copy for both plan types', () => {
    assert.ok(DEFAULT_CANCELLATION_RETENTION_CONFIG.lossCopy.platform.length >= 2);
    assert.ok(DEFAULT_CANCELLATION_RETENTION_CONFIG.lossCopy.website.length >= 2);
  });
});
