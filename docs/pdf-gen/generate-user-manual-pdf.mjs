import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { mdToPdf } from 'md-to-pdf';

const __dirname = dirname(fileURLToPath(import.meta.url));
const manualMd = join(__dirname, '..', 'USER_MANUAL.md');
const outPdf = join(__dirname, '..', 'USER_MANUAL.pdf');

await mdToPdf(
  { path: manualMd },
  {
    dest: outPdf,
    document_title: 'Storage Facility Creator — User Manual',
    pdf_options: {
      format: 'Letter',
      printBackground: true,
      margin: { top: '20mm', right: '18mm', bottom: '20mm', left: '18mm' },
    },
  },
);

console.log('Wrote', outPdf);
