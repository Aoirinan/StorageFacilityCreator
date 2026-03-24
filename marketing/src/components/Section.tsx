import { ReactNode } from 'react';

type Props = {
  children: ReactNode;
  className?: string;
  tint?: boolean;
  id?: string;
};

export function Section({ children, className = '', tint, id }: Props) {
  const toneClass = tint
    ? 'bg-gradient-to-b from-sky-50/85 via-blue-50/55 to-indigo-50/50'
    : 'bg-white';

  return (
    <section
      id={id}
      className={`py-12 sm:py-16 lg:py-20 ${toneClass} ${className}`}
    >
      <div className="mx-auto max-w-6xl px-4 sm:px-6 lg:px-8">
        {children}
      </div>
    </section>
  );
}
