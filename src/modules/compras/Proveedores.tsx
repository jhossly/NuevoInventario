import { useState, type FormEvent } from 'react';
import { enlace } from '@/shared/ruta';
import { AvisoError, Boton, Campo, Cargando, Casilla, Encabezado, Selector, Tarjeta } from '@/shared/ui';
import {
  TIPOS_IDENTIFICACION,
  useGuardarProveedor,
  useProveedores,
  type DatosProveedor,
  type Proveedor,
  type TipoIdentificacion,
} from './api';

const DIGITOS: Partial<Record<TipoIdentificacion, number>> = { RUC: 13, CEDULA: 10 };

export function Proveedores() {
  const proveedores = useProveedores();
  // null: ningún formulario; 'nuevo' o el id del que se edita.
  const [abierto, setAbierto] = useState<string | null>(null);

  return (
    <>
      <Encabezado
        titulo="Proveedores"
        volver={enlace({ nombre: 'compras' })}
        acciones={
          abierto === null && (
            <Boton onClick={() => setAbierto('nuevo')}>Nuevo</Boton>
          )
        }
      />
      {abierto === 'nuevo' && (
        <Tarjeta className="mb-4">
          <FormProveedor alTerminar={() => setAbierto(null)} />
        </Tarjeta>
      )}
      {proveedores.isPending && <Cargando />}
      <AvisoError error={proveedores.error} />
      {proveedores.isSuccess && proveedores.data.length === 0 && abierto === null && (
        <Tarjeta>Todavía no hay proveedores.</Tarjeta>
      )}
      <ul className="flex flex-col gap-2">
        {proveedores.data?.map((p) => (
          <li key={p.id} className={`rounded-xl border border-gray-200 bg-white p-3 ${p.activo ? '' : 'opacity-60'}`}>
            {abierto === p.id ? (
              <FormProveedor proveedor={p} alTerminar={() => setAbierto(null)} />
            ) : (
              <div className="flex items-center gap-3">
                <div className="min-w-0 flex-1">
                  <p className="truncate font-medium">
                    {p.nombre}
                    {!p.activo && ' (inactivo)'}
                  </p>
                  <p className="text-sm text-gray-500">
                    {TIPOS_IDENTIFICACION[p.tipo_identificacion]} {p.identificacion}
                    {p.telefono && ` · ${p.telefono}`}
                  </p>
                </div>
                {abierto === null && (
                  <Boton variante="secundario" onClick={() => setAbierto(p.id)}>
                    Editar
                  </Boton>
                )}
              </div>
            )}
          </li>
        ))}
      </ul>
    </>
  );
}

/** Crear (sin `proveedor`) o editar. También se usa dentro de «Nueva compra». */
export function FormProveedor({
  proveedor,
  alTerminar,
}: {
  proveedor?: Proveedor;
  alTerminar: (id?: string) => void;
}) {
  const guardar = useGuardarProveedor();
  const [tipo, setTipo] = useState<TipoIdentificacion>(proveedor?.tipo_identificacion ?? 'RUC');
  const [identificacion, setIdentificacion] = useState(proveedor?.identificacion ?? '');
  const [nombre, setNombre] = useState(proveedor?.nombre ?? '');
  const [telefono, setTelefono] = useState(proveedor?.telefono ?? '');
  const [activo, setActivo] = useState(proveedor?.activo ?? true);
  const [errores, setErrores] = useState<{ identificacion?: string; nombre?: string }>({});

  const enviar = (evento: FormEvent) => {
    evento.preventDefault();
    // El formulario puede estar dentro de otro (Nueva compra): no debe enviarlo.
    evento.stopPropagation();
    const nuevos: typeof errores = {};
    const id = identificacion.trim();
    const digitos = DIGITOS[tipo];
    if (digitos !== undefined && !new RegExp(`^\\d{${digitos}}$`).test(id)) {
      nuevos.identificacion = `${TIPOS_IDENTIFICACION[tipo]}: ${digitos} dígitos`;
    } else if (id === '') nuevos.identificacion = 'Obligatorio';
    if (nombre.trim() === '') nuevos.nombre = 'Obligatorio';
    setErrores(nuevos);
    if (Object.keys(nuevos).length > 0) return;

    const datos: DatosProveedor = {
      tipo_identificacion: tipo,
      identificacion: id,
      nombre: nombre.trim(),
      telefono: telefono.trim() || null,
    };
    if (proveedor) datos.activo = activo;
    guardar.mutate({ id: proveedor?.id ?? null, datos }, { onSuccess: (r) => alTerminar(r.id) });
  };

  return (
    <form onSubmit={enviar} className="flex flex-col gap-3" noValidate>
      <div className="grid grid-cols-[auto_1fr] gap-3">
        <Selector etiqueta="Tipo" value={tipo} onChange={(e) => setTipo(e.target.value as TipoIdentificacion)}>
          {Object.entries(TIPOS_IDENTIFICACION).map(([valor, texto]) => (
            <option key={valor} value={valor}>
              {texto}
            </option>
          ))}
        </Selector>
        <Campo
          etiqueta="Número"
          inputMode={tipo === 'PASAPORTE' ? 'text' : 'numeric'}
          value={identificacion}
          onChange={(e) => setIdentificacion(e.target.value)}
          error={errores.identificacion}
          autoComplete="off"
        />
      </div>
      <Campo etiqueta="Nombre o razón social" value={nombre} onChange={(e) => setNombre(e.target.value)} error={errores.nombre} />
      <Campo etiqueta="Teléfono (opcional)" type="tel" value={telefono} onChange={(e) => setTelefono(e.target.value)} />
      {proveedor && <Casilla etiqueta="Activo" checked={activo} onChange={(e) => setActivo(e.target.checked)} />}
      <AvisoError error={guardar.error} />
      <div className="flex gap-2">
        <Boton type="submit" disabled={guardar.isPending}>
          {guardar.isPending ? 'Guardando…' : 'Guardar'}
        </Boton>
        <Boton variante="secundario" onClick={() => alTerminar()}>
          Cancelar
        </Boton>
      </div>
    </form>
  );
}
