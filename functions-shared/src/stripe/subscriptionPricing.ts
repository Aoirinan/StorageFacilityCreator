import * as functions from 'firebase-functions/v1';
import type Stripe from 'stripe';

export async function getOrCreateBasePriceId(stripe: Stripe): Promise<string> {
  try {
    const prices = await stripe.prices.list({
      lookup_keys: ['sfc_base_monthly_75'],
      limit: 1,
    });

    if (prices.data.length > 0) {
      const price = prices.data[0];
      if (price.active) {
        return price.id;
      }
      functions.logger.warn(`Base price ${price.id} exists but is inactive, creating new one`);
    }

    const product = await stripe.products.create({
      name: 'SFC Base Plan - First Facility',
      description: 'Storage Facility Creator base subscription - includes first facility ($75/month)',
    });

    const price = await stripe.prices.create({
      product: product.id,
      unit_amount: 7500,
      currency: 'usd',
      recurring: {
        interval: 'month',
      },
      lookup_key: 'sfc_base_monthly_75',
    });

    functions.logger.info(`Created base price: ${price.id} for $75/month`);
    return price.id;
  } catch (error: unknown) {
    const err = error as { message?: string; type?: string; code?: string };
    functions.logger.error('Error creating base price', {
      error: err.message,
      type: err.type,
      code: err.code,
    });
    throw error;
  }
}

export async function getOrCreateAddOnPriceId(stripe: Stripe): Promise<string> {
  try {
    const prices = await stripe.prices.list({
      lookup_keys: ['sfc_addon_monthly_75'],
      limit: 1,
    });

    if (prices.data.length > 0) {
      const price = prices.data[0];
      if (price.active) {
        return price.id;
      }
      functions.logger.warn(`Add-on price ${price.id} exists but is inactive, creating new one`);
    }

    const product = await stripe.products.create({
      name: 'SFC Additional Facility',
      description: 'Additional facility add-on - $75/month per facility',
    });

    const price = await stripe.prices.create({
      product: product.id,
      unit_amount: 7500,
      currency: 'usd',
      recurring: {
        interval: 'month',
      },
      lookup_key: 'sfc_addon_monthly_75',
    });

    functions.logger.info(`Created add-on price: ${price.id} for $75/month`);
    return price.id;
  } catch (error: unknown) {
    const err = error as { message?: string; type?: string; code?: string };
    functions.logger.error('Error creating add-on price', {
      error: err.message,
      type: err.type,
      code: err.code,
    });
    throw error;
  }
}
