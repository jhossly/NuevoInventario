import { useState, type FormEvent } from 'react';
import { Plus, Ruler, Trash2 } from 'lucide-react';
import { AvisoError, Boton, Campo, Cargando, Encabezado, Tarjeta } from '@/shared/ui';
import { useEliminarMedida, useGuardarMedida, useMedidas } from './api';

/** Medidas con que se cuentan los productos: Unidad, Kilo, Paquete, Funda… (D-048). */
export function Medidas() {
  const medidas = useMedidas();
  const guardar = useGuardarMedida();
  const eliminar = useEliminarMedida();
  const [nombre, setNombre] = useState('');
  const [codigo, setCodigo] = useState('');

  const enviar = (evento: FormEvent) => {
    evento.preventDefault();
    guardar.mutate(
      { codigo, nombre },
      {
        onSuccess: () => {
          setNombre('');
          setCodigo('');
        },
      },
    );
  };

  return (
    <>
      <Encabezado titulo="Medidas" />
      <Tarjeta className="mb-4">
        <h2 className="mb-3 font-semibold">Nueva medida</h2>
        <form onSubmit={enviar} className="flex flex-col gap-3" noValidate>
          <div className="grid grid-cols-2 gap-3">
            <Campo
              etiqueta="Nombre"
              ayuda="Por ejemplo: Funda"
              value={nombre}
              maxLength={40}
              onChange={(e) => setNombre(e.target.value)}
              autoComplete="off"
            />
            <Campo
              etiqueta="Abreviatura"
              ayuda="Por ejemplo: fda"
              value={codigo}
              maxLength={8}
              onChange={(e) => setCodigo(e.target.value)}
              autoComplete="off"
            />
          </div>
          <AvisoError error={guardar.error} />
          <Boton type="submit" icono={Plus} disabled={guardar.isPending || !nombre.trim() || !codigo.trim()}>
            Agregar medida
          </Boton>
        </form>
      </Tarjeta>

      {medidas.isPending && <Cargando />}
      <AvisoError error={medidas.error ?? eliminar.error} />
      <ul className="flex flex-col gap-2">
        {medidas.data?.map((m) => (
          <li key={m.codigo} className="flex items-center gap-3 rounded-xl border border-gray-200 bg-white p-3">
            <Ruler className="size-5 text-gray-400" aria-hidden />
            <span className="flex-1 font-medium">{m.nombre}</span>
            <span className="text-sm text-gray-500">{m.codigo.toLowerCase()}</span>
            {m.codigo !== 'UND' && m.codigo !== 'KG' && (
              <button
                type="button"
                aria-label={`Eliminar ${m.nombre}`}
                disabled={eliminar.isPending}
                onClick={() => window.confirm(`¿Eliminar la medida ${m.nombre}?`) && eliminar.mutate(m.codigo)}
                className="flex size-11 items-center justify-center rounded-lg text-gray-500 hover:bg-red-50 hover:text-red-700"
              >
                <Trash2 className="size-5" aria-hidden />
              </button>
            )}
          </li>
        ))}
      </ul>
    </>
  );
}
