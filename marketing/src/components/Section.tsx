import { ReactNode } from 'react';

type Props = {
  children: ReactNode;
  className?: string;
  tint?: boolean;
  id?: string;
};

export function Section({ children, className = '', tint, id }: Props) {
  return (
    <section
      id={id}
      className={`py-12 sm:py-16 lg:py-20 ${tint ? 'bg-surface' : ''} ${className}`}
    >
      <div className="mx-auto max-w-6xl px-4 sm:px-6 lg:px-8">
        {children}
      </div>
    </section>
  );
}
