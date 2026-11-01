import { useState } from 'react';
import { Buscador } from '@/shared/ui';

/** Lista con búsqueda para elegir un producto: un selector no sirve con cientos. */
export function ElegirProducto({
  opciones,
  disabled,
  alElegir,
}: {
  opciones: { id: string; texto: string }[];
  disabled?: boolean;
  alElegir: (id: string) => void;
}) {
  const [busqueda, setBusqueda] = useState('');
  const texto = busqueda.trim().toLowerCase();
  const encontradas = texto === '' ? [] : opciones.filter((o) => o.texto.toLowerCase().includes(texto)).slice(0, 8);
  return (
    <div className="relative">
      <Buscador
        etiqueta="Buscar el producto"
        value={busqueda}
        disabled={disabled}
        onChange={(e) => setBusqueda(e.target.value)}
      />
      {texto !== '' && (
        <ul className="absolute z-10 mt-1 w-full divide-y divide-gray-100 rounded-lg border border-gray-200 bg-white shadow-lg">
          {encontradas.map((o) => (
            <li key={o.id}>
              <button
                type="button"
                className="flex min-h-11 w-full items-center px-3 text-left hover:bg-gray-50"
                onClick={() => {
                  setBusqueda('');
                  alElegir(o.id);
                }}
              >
                {o.texto}
              </button>
            </li>
          ))}
          {encontradas.length === 0 && <li className="p-3 text-gray-500">Ningún producto coincide.</li>}
        </ul>
      )}
    </div>
  );
}
