import Image from 'next/image';
import { DEMO_IMAGE_PATH } from '@/config/site';

type DemoFrameProps = {
  /** Override main demo image (used for hero). */
  src?: string;
  alt?: string;
  priority?: boolean;
  sizes?: string;
};

export function DemoFrame({
  src = DEMO_IMAGE_PATH,
  alt = 'Storage Facility Creator dashboard',
  priority = false,
  sizes = '(max-width: 768px) 100vw, 50vw',
}: DemoFrameProps) {
  return (
    <div className="relative rounded-xl overflow-hidden shadow-xl border border-slate-200/80 bg-white">
      <div className="flex items-center gap-2 px-4 py-3 border-b border-slate-200 bg-slate-50/80">
        <span className="w-3 h-3 rounded-full bg-slate-300" aria-hidden />
        <span className="w-3 h-3 rounded-full bg-slate-300" aria-hidden />
        <span className="w-3 h-3 rounded-full bg-slate-300" aria-hidden />
      </div>
      <div className="relative aspect-4/3 sm:aspect-video bg-slate-100">
        <Image
          src={src}
          alt={alt}
          fill
          className="object-contain"
          sizes={sizes}
          priority={priority}
        />
      </div>
    </div>
  );
}
