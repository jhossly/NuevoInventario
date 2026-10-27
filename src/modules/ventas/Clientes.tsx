import { useState, type FormEvent } from 'react';
import { useContexto } from '@/modules/sesion/sesion';
import { leerDecimal, paraEditar } from '@/shared/decimal';
import { formatearDinero } from '@/shared/formato';
import { enlace } from '@/shared/ruta';
import { AvisoError, Boton, Campo, Cargando, Casilla, Encabezado, Selector, Tarjeta } from '@/shared/ui';
import { useClientes, useGuardarCliente, type Cliente, type DatosCliente } from './api';

type TipoId = 'RUC' | 'CEDULA' | 'PASAPORTE' | '';
const DIGITOS: Partial<Record<TipoId, number>> = { RUC: 13, CEDULA: 10 };

export function Clientes() {
  const clientes = useClientes();
  const [abierto, setAbierto] = useState<string | null>(null);
  const [busqueda, setBusqueda] = useState('');
  const texto = busqueda.trim().toLowerCase();
  const visibles = (clientes.data ?? []).filter(
    (c) => texto === '' || c.nombre.toLowerCase().includes(texto) || (c.identificacion ?? '').includes(texto),
  );

  return (
    <>
      <Encabezado
        titulo="Clientes"
        volver={enlace({ nombre: 'ventas' })}
        acciones={abierto === null && <Boton onClick={() => setAbierto('nuevo')}>Nuevo</Boton>}
      />
      {abierto === 'nuevo' && (
        <Tarjeta className="mb-4">
          <FormCliente alTerminar={() => setAbierto(null)} />
        </Tarjeta>
      )}
      <input
        type="search"
        placeholder="Buscar por nombre o identificación"
        aria-label="Buscar cliente"
        value={busqueda}
        onChange={(e) => setBusqueda(e.target.value)}
        className="mb-3 min-h-11 w-full rounded-lg border border-gray-300 bg-white px-3 text-base"
      />
      {clientes.isPending && <Cargando />}
      <AvisoError error={clientes.error} />
      <ul className="flex flex-col gap-2">
        {visibles.map((c) => (
          <li key={c.id} className={`rounded-xl border border-gray-200 bg-white p-3 ${c.activo ? '' : 'opacity-60'}`}>
            {abierto === c.id ? (
              <FormCliente cliente={c} alTerminar={() => setAbierto(null)} />
            ) : (
              <div className="flex items-center gap-3">
                <div className="min-w-0 flex-1">
                  <p className="truncate font-medium">{c.nombre}</p>
                  <p className="text-sm text-gray-500">
                    {c.identificacion ?? 'Sin identificación'}
                    {c.fiado_permitido && ` · fiado hasta ${formatearDinero(c.limite_fiado)}`}
                  </p>
                </div>
                {abierto === null && (
                  <Boton variante="secundario" onClick={() => setAbierto(c.id)}>
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

/** Crear o editar un cliente. También se usa dentro del punto de venta. */
export function FormCliente({ cliente, alTerminar }: { cliente?: Cliente; alTerminar: (id?: string) => void }) {
  const esDueno = useContexto().rol === 'DUENO';
  const guardar = useGuardarCliente();
  const [tipo, setTipo] = useState<TipoId>(cliente?.tipo_identificacion ?? 'CEDULA');
  const [identificacion, setIdentificacion] = useState(cliente?.identificacion ?? '');
  const [nombre, setNombre] = useState(cliente?.nombre ?? '');
  const [telefono, setTelefono] = useState(cliente?.telefono ?? '');
  const [correo, setCorreo] = useState(cliente?.correo ?? '');
  const [direccion, setDireccion] = useState(cliente?.direccion ?? '');
  const [activo, setActivo] = useState(cliente?.activo ?? true);
  const [fiado, setFiado] = useState(cliente?.fiado_permitido ?? false);
  const [limite, setLimite] = useState(cliente ? paraEditar(cliente.limite_fiado) : '0');
  const [errores, setErrores] = useState<{ identificacion?: string; nombre?: string; limite?: string }>({});

  const enviar = (evento: FormEvent) => {
    evento.preventDefault();
    const nuevos: typeof errores = {};
    const id = identificacion.trim();
    const digitos = DIGITOS[tipo];
    if (tipo !== '' && id === '') nuevos.identificacion = 'Escribe el número o elige «Sin identificación»';
    else if (digitos !== undefined && !new RegExp(`^\\d{${digitos}}$`).test(id)) {
      nuevos.identificacion = `${tipo === 'RUC' ? 'RUC' : 'Cédula'}: ${digitos} dígitos`;
    }
    if (nombre.trim() === '') nuevos.nombre = 'Obligatorio';
    const limiteLeido = leerDecimal(limite, { decimales: 2 });
    if (esDueno && fiado && !limiteLeido.ok) nuevos.limite = limiteLeido.mensaje;
    setErrores(nuevos);
    if (Object.keys(nuevos).length > 0) return;

    const datos: DatosCliente = {
      tipo_identificacion: tipo === '' ? null : tipo,
      identificacion: tipo === '' ? null : id,
      nombre: nombre.trim(),
      telefono: telefono.trim() || null,
      correo: correo.trim() || null,
      direccion: direccion.trim() || null,
    };
    if (cliente) datos.activo = activo;
    if (esDueno) {
      datos.fiado_permitido = fiado;
      datos.limite_fiado = fiado && limiteLeido.ok ? limiteLeido.valor : '0';
    }
    guardar.mutate({ id: cliente?.id ?? null, datos }, { onSuccess: (r) => alTerminar(r.id) });
  };

  return (
    <form onSubmit={enviar} className="flex flex-col gap-3" noValidate>
      <div className="grid grid-cols-[auto_1fr] gap-3">
        <Selector etiqueta="Identificación" value={tipo} onChange={(e) => setTipo(e.target.value as TipoId)}>
          <option value="CEDULA">Cédula</option>
          <option value="RUC">RUC</option>
          <option value="PASAPORTE">Pasaporte</option>
          <option value="">Sin identificación</option>
        </Selector>
        <Campo
          etiqueta="Número"
          inputMode={tipo === 'PASAPORTE' ? 'text' : 'numeric'}
          disabled={tipo === ''}
          value={tipo === '' ? '' : identificacion}
          onChange={(e) => setIdentificacion(e.target.value)}
          error={errores.identificacion}
          autoComplete="off"
        />
      </div>
      <Campo etiqueta="Nombre" value={nombre} onChange={(e) => setNombre(e.target.value)} error={errores.nombre} />
      <div className="grid grid-cols-2 gap-3">
        <Campo etiqueta="Teléfono" type="tel" value={telefono} onChange={(e) => setTelefono(e.target.value)} />
        <Campo etiqueta="Correo" type="email" value={correo} onChange={(e) => setCorreo(e.target.value)} />
      </div>
      <Campo etiqueta="Dirección (para facturas)" value={direccion} onChange={(e) => setDireccion(e.target.value)} />
      {esDueno && (
        <div className="flex flex-wrap items-end gap-3">
          <Casilla etiqueta="Puede comprar al fiado" checked={fiado} onChange={(e) => setFiado(e.target.checked)} />
          {fiado && (
            <Campo
              etiqueta="Límite de fiado"
              inputMode="decimal"
              value={limite}
              onChange={(e) => setLimite(e.target.value)}
              error={errores.limite}
            />
          )}
        </div>
      )}
      {cliente && <Casilla etiqueta="Activo" checked={activo} onChange={(e) => setActivo(e.target.checked)} />}
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
