import { useState, type FormEvent } from 'react';
import { leerDecimal, paraEditar } from '@/shared/decimal';
import { AvisoError, Boton, Campo, Casilla } from '@/shared/ui';
import { useGuardarPresentacion, type DatosPresentacion, type Presentacion, type Producto } from './api';

interface Errores {
  nombre?: string;
  factor?: string;
  precio_venta?: string;
}

/** Crear (sin `presentacion`) o editar una presentación de `producto`. */
export function FormPresentacion({
  producto,
  presentacion,
  alTerminar,
}: {
  producto: Producto;
  presentacion?: Presentacion;
  alTerminar: () => void;
}) {
  const guardar = useGuardarPresentacion();
  const unidad = producto.unidad_base === 'KG' ? 'kg' : 'unidades';

  const [nombre, setNombre] = useState(presentacion?.nombre ?? '');
  const [factor, setFactor] = useState(presentacion ? paraEditar(presentacion.factor) : '');
  const [precio, setPrecio] = useState(presentacion?.precio_venta ? paraEditar(presentacion.precio_venta) : '');
  const [codigo, setCodigo] = useState(presentacion?.codigo_barras ?? '');
  const [seVende, setSeVende] = useState(presentacion?.se_vende ?? true);
  const [seCompra, setSeCompra] = useState(presentacion?.se_compra ?? true);
  const [activa, setActiva] = useState(presentacion?.activo ?? true);
  const [errores, setErrores] = useState<Errores>({});

  const enviar = (evento: FormEvent) => {
    evento.preventDefault();
    const nuevos: Errores = {};
    if (nombre.trim() === '') nuevos.nombre = 'El nombre es obligatorio';
    const factorLeido = leerDecimal(factor, { decimales: 6, permitirCero: false });
    if (!factorLeido.ok) nuevos.factor = factorLeido.mensaje;
    const precioLeido = precio.trim() === '' ? null : leerDecimal(precio, { decimales: 2 });
    if (precioLeido && !precioLeido.ok) nuevos.precio_venta = precioLeido.mensaje;
    setErrores(nuevos);
    if (Object.keys(nuevos).length > 0 || !factorLeido.ok) return;

    const datos: DatosPresentacion = {
      nombre: nombre.trim(),
      factor: factorLeido.valor,
      precio_venta: precioLeido?.ok ? precioLeido.valor : null,
      codigo_barras: codigo.trim() || null,
      se_vende: seVende,
      se_compra: seCompra,
    };
    if (presentacion) datos.activo = activa;
    else datos.producto_id = producto.id;

    guardar.mutate({ id: presentacion?.id ?? null, datos }, { onSuccess: alTerminar });
  };

  return (
    <form onSubmit={enviar} className="flex flex-col gap-3 rounded-lg bg-gray-50 p-3" noValidate>
      <div className="grid grid-cols-2 gap-3">
        <Campo
          etiqueta="Nombre"
          placeholder="Caja 12, Libra…"
          value={nombre}
          onChange={(e) => setNombre(e.target.value)}
          error={errores.nombre}
          autoFocus
        />
        <Campo
          etiqueta={`Equivale a (${unidad})`}
          ayuda={producto.unidad_base === 'KG' ? 'Libra = 0,453592' : 'Caja de 12 = 12'}
          inputMode="decimal"
          value={factor}
          onChange={(e) => setFactor(e.target.value)}
          error={errores.factor}
        />
        <Campo
          etiqueta="Precio de venta"
          ayuda="Con IVA. Vacío si no se vende así."
          inputMode="decimal"
          value={precio}
          onChange={(e) => setPrecio(e.target.value)}
          error={errores.precio_venta}
        />
        <Campo
          etiqueta="Código de barras"
          inputMode="numeric"
          value={codigo}
          onChange={(e) => setCodigo(e.target.value)}
          autoComplete="off"
        />
      </div>
      <div className="flex flex-wrap gap-x-6">
        <Casilla etiqueta="Se vende" checked={seVende} onChange={(e) => setSeVende(e.target.checked)} />
        <Casilla etiqueta="Se compra" checked={seCompra} onChange={(e) => setSeCompra(e.target.checked)} />
        {presentacion && <Casilla etiqueta="Activa" checked={activa} onChange={(e) => setActiva(e.target.checked)} />}
      </div>
      <AvisoError error={guardar.error} />
      <div className="flex gap-2">
        <Boton type="submit" disabled={guardar.isPending}>
          {guardar.isPending ? 'Guardando…' : 'Guardar'}
        </Boton>
        <Boton variante="secundario" onClick={alTerminar}>
          Cancelar
        </Boton>
      </div>
    </form>
  );
}
