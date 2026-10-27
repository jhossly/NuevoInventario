import { useId, type ButtonHTMLAttributes, type InputHTMLAttributes, type ReactNode, type SelectHTMLAttributes } from 'react';

/**
 * Piezas visuales comunes. Pensadas primero para el celular del Dueño:
 * controles de al menos 44 px de alto y texto de 16 px (evita el zoom de iOS).
 */

const estilosBoton = {
  primario: 'bg-gray-900 text-white hover:bg-gray-700 disabled:bg-gray-400',
  secundario: 'border border-gray-300 bg-white text-gray-900 hover:bg-gray-100 disabled:text-gray-400',
  peligro: 'bg-red-700 text-white hover:bg-red-600 disabled:bg-red-300',
} as const;

export function Boton({
  variante = 'primario',
  className = '',
  ...props
}: ButtonHTMLAttributes<HTMLButtonElement> & { variante?: keyof typeof estilosBoton }) {
  return (
    <button
      type="button"
      className={`min-h-11 rounded-lg px-4 text-base font-medium ${estilosBoton[variante]} ${className}`}
      {...props}
    />
  );
}

export function EnlaceBoton({
  href,
  children,
  variante = 'secundario',
}: {
  href: string;
  children: ReactNode;
  variante?: keyof typeof estilosBoton;
}) {
  return (
    <a
      href={href}
      className={`inline-flex min-h-11 items-center justify-center rounded-lg px-4 text-base font-medium ${estilosBoton[variante]}`}
    >
      {children}
    </a>
  );
}

export function Campo({
  etiqueta,
  ayuda,
  error,
  ...props
}: InputHTMLAttributes<HTMLInputElement> & { etiqueta: string; ayuda?: string; error?: string | null }) {
  const generado = useId();
  const id = props.id ?? generado;
  return (
    <div className="flex flex-col gap-1">
      <label htmlFor={id} className="text-sm font-medium text-gray-700">
        {etiqueta}
      </label>
      <input
        id={id}
        aria-invalid={error ? true : undefined}
        aria-describedby={error || ayuda ? `${id}-nota` : undefined}
        className={`min-h-11 rounded-lg border bg-white px-3 text-base ${error ? 'border-red-600' : 'border-gray-300'}`}
        {...props}
      />
      {(error || ayuda) && (
        <p id={`${id}-nota`} className={`text-sm ${error ? 'text-red-700' : 'text-gray-500'}`}>
          {error ?? ayuda}
        </p>
      )}
    </div>
  );
}

export function Selector({
  etiqueta,
  children,
  ...props
}: SelectHTMLAttributes<HTMLSelectElement> & { etiqueta: string }) {
  const generado = useId();
  const id = props.id ?? generado;
  return (
    <div className="flex flex-col gap-1">
      <label htmlFor={id} className="text-sm font-medium text-gray-700">
        {etiqueta}
      </label>
      <select id={id} className="min-h-11 rounded-lg border border-gray-300 bg-white px-3 text-base" {...props}>
        {children}
      </select>
    </div>
  );
}

export function Casilla({
  etiqueta,
  ...props
}: InputHTMLAttributes<HTMLInputElement> & { etiqueta: string }) {
  return (
    <label className="flex min-h-11 items-center gap-3 text-base">
      <input type="checkbox" className="size-5" {...props} />
      {etiqueta}
    </label>
  );
}

export function Aviso({ tipo = 'error', children }: { tipo?: 'error' | 'exito' | 'info'; children: ReactNode }) {
  const estilos = {
    error: 'border-red-300 bg-red-50 text-red-800',
    exito: 'border-green-300 bg-green-50 text-green-800',
    info: 'border-gray-300 bg-white text-gray-700',
  };
  return (
    <p role={tipo === 'error' ? 'alert' : 'status'} className={`rounded-lg border p-3 ${estilos[tipo]}`}>
      {children}
    </p>
  );
}

/** Mensaje de un error de consulta o mutación de TanStack Query. */
export function AvisoError({ error }: { error: unknown }) {
  if (!error) return null;
  return <Aviso>{error instanceof Error ? error.message : 'Ocurrió un error inesperado'}</Aviso>;
}

export function Cargando({ texto = 'Cargando…' }: { texto?: string }) {
  return (
    <p role="status" className="p-4 text-gray-500">
      {texto}
    </p>
  );
}

export function Encabezado({ titulo, volver, acciones }: { titulo: string; volver?: string; acciones?: ReactNode }) {
  return (
    <header className="mb-4 flex flex-wrap items-center gap-3">
      {volver && (
        <a href={volver} className="-ml-2 rounded-lg px-2 py-2 text-gray-600 hover:bg-gray-100" aria-label="Volver">
          ←
        </a>
      )}
      <h1 className="flex-1 text-xl font-semibold">{titulo}</h1>
      {acciones}
    </header>
  );
}

export function Tarjeta({ children, className = '' }: { children: ReactNode; className?: string }) {
  return <section className={`rounded-xl border border-gray-200 bg-white p-4 ${className}`}>{children}</section>;
}
