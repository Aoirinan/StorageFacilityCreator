import * as functions from 'firebase-functions/v1';
import * as crypto from 'crypto';
import { getFacilityDataForUserOrThrow, validateSigningTokenForContract } from '@sfc/functions-shared';
import { enforceAppCheckOrThrow } from './guardrails';

/**
 * Compute SHA-256 hash of a document
 * Used for document integrity verification
 */
export const computeDocumentHash = functions.https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  try {
    const { fileData } = data;

    if (!fileData || !Array.isArray(fileData)) {
      throw new functions.https.HttpsError('invalid-argument', 'fileData must be a byte array');
    }

    const buffer = Buffer.from(fileData);

    const hash = crypto.createHash('sha256');
    hash.update(buffer);
    const sha256 = hash.digest('hex');

    functions.logger.info(`Computed SHA-256 hash for document (${buffer.length} bytes)`);

    return {
      sha256: sha256,
      size: buffer.length,
    };
  } catch (error: any) {
    functions.logger.error('Error computing document hash:', error);
    throw new functions.https.HttpsError('internal', `Failed to compute hash: ${error.message}`);
  }
});

/**
 * Merge signature image and optional text into the original contract PDF.
 * Returns the merged PDF as base64. Used when signing the uploaded contract (not a blank page).
 * placements: [{ type: 'image'|'text', pageIndex, x, y, width?, height?, imageBase64?, text?, fontSize? }]
 * PDF coordinates: origin bottom-left, units in points (72 per inch).
 */
export const mergeSignatureIntoPdf = functions.runWith({ timeoutSeconds: 120, memory: '512MB' }).https.onCall(
  async (
    data: {
      pdfBase64?: string;
      facilityId?: string;
      contractId?: string;
      signaturePngBase64?: string;
      signerName?: string;
      signerDate?: string;
      signingToken?: string;
      placements?: Array<{
        type: 'image' | 'text';
        pageIndex: number;
        x: number;
        y: number;
        width?: number;
        height?: number;
        imageBase64?: string;
        text?: string;
        fontSize?: number;
      }>;
    },
    context: functions.https.CallableContext,
  ) => {
    const pdfBase64 = (data?.pdfBase64 || '').toString().trim();
    const signaturePngBase64 = (data?.signaturePngBase64 || '').toString().trim();
    const signerName = (data?.signerName || '').toString().trim();
    const signerDate = (data?.signerDate || '').toString().trim();
    const facilityId = (data?.facilityId || '').toString().trim();
    const contractId = (data?.contractId || '').toString().trim();
    const signingToken = (data?.signingToken || '').toString().trim();
    const placements = (data?.placements || []) as Array<{
      type: 'image' | 'text';
      pageIndex: number;
      x: number;
      y: number;
      width?: number;
      height?: number;
      imageBase64?: string;
      text?: string;
      fontSize?: number;
    }>;

    if (!pdfBase64) {
      throw new functions.https.HttpsError('invalid-argument', 'pdfBase64 is required');
    }

    if (context.auth?.uid) {
      enforceAppCheckOrThrow(context);
      if (!facilityId) {
        throw new functions.https.HttpsError('invalid-argument', 'facilityId is required');
      }
      await getFacilityDataForUserOrThrow(context.auth.uid, facilityId);
    } else if (signingToken) {
      if (!facilityId || !contractId) {
        throw new functions.https.HttpsError(
          'invalid-argument',
          'facilityId, contractId, and signingToken are required',
        );
      }
      const valid = await validateSigningTokenForContract(signingToken, facilityId, contractId);
      if (!valid) {
        throw new functions.https.HttpsError('permission-denied', 'Invalid or expired signing token');
      }
    } else {
      throw new functions.https.HttpsError('unauthenticated', 'Authentication or signing token required');
    }

    try {
      const pdfBytes = Buffer.from(pdfBase64, 'base64');
      if (pdfBytes.length > 10 * 1024 * 1024) {
        throw new functions.https.HttpsError('invalid-argument', 'PDF too large (max 10MB)');
      }

      const { PDFDocument } = await import('pdf-lib');
      const pdfDoc = await PDFDocument.load(pdfBytes);
      const pages = pdfDoc.getPages();

      if (pages.length === 0) {
        throw new functions.https.HttpsError('invalid-argument', 'PDF has no pages');
      }

      const finalPlacements: Array<{
        type: 'image' | 'text';
        pageIndex: number;
        x: number;
        y: number;
        width?: number;
        height?: number;
        imageBase64?: string;
        text?: string;
        fontSize?: number;
      }> = placements.length > 0 ? placements : [];

      if (finalPlacements.length === 0 && signaturePngBase64) {
        const lastPageIndex = pages.length - 1;
        const page = pages[lastPageIndex];
        const defaultY = 100;
        const defaultX = 50;
        const sigW = 150;
        const sigH = 60;

        const pngBytes = Buffer.from(signaturePngBase64, 'base64');
        const pngImage = await pdfDoc.embedPng(pngBytes);
        page.drawImage(pngImage, { x: defaultX, y: defaultY, width: sigW, height: sigH });

        if (signerName) {
          page.drawText(signerName, { x: defaultX, y: defaultY + sigH + 8, size: 11 });
        }
        if (signerDate) {
          page.drawText(signerDate, { x: defaultX, y: defaultY + sigH + 20, size: 10 });
        }
      } else {
        for (const p of finalPlacements) {
          const pageIndex = Math.max(0, Math.min(p.pageIndex, pages.length - 1));
          const page = pages[pageIndex];
          if (p.type === 'image') {
            const b64 = p.imageBase64 || signaturePngBase64;
            if (b64) {
              const imgBytes = Buffer.from(b64, 'base64');
              const img = await pdfDoc.embedPng(imgBytes);
              const w = p.width ?? 150;
              const h = p.height ?? 60;
              page.drawImage(img, { x: p.x, y: p.y, width: w, height: h });
            }
          } else if (p.type === 'text' && p.text) {
            page.drawText(p.text, { x: p.x, y: p.y, size: p.fontSize ?? 11 });
          }
        }
      }

      const mergedPdfBytes = await pdfDoc.save();
      return { pdfBase64: Buffer.from(mergedPdfBytes).toString('base64') };
    } catch (err: any) {
      functions.logger.error('mergeSignatureIntoPdf error:', err?.message);
      if (err instanceof functions.https.HttpsError) throw err;
      throw new functions.https.HttpsError('internal', `Failed to merge: ${err?.message || 'Unknown error'}`);
    }
  },
);
