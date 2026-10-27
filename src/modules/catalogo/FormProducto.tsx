import { useState, type FormEvent } from 'react';
import { leerDecimal, paraEditar } from '@/shared/decimal';
import { navegar } from '@/shared/ruta';
import { Aviso, AvisoError, Boton, Campo, Casilla, Selector } from '@/shared/ui';
import {
  OPCIONES_IVA,
  textoIva,
  useCategorias,
  useGuardarCategoria,
  useGuardarProducto,
  type DatosProducto,
  type Producto,
} from './api';

// Límites del formulario de productos del portal del SRI.
const LARGO_CODIGO = 25;
const LARGO_INFORMACION = 300;

interface Errores {
  nombre?: string;
  stock_minimo?: string;
  precio_venta?: string;
}

/** Crear (sin `producto`) o editar un producto. */
export function FormProducto({ producto, alGuardar }: { producto?: Producto; alGuardar?: () => void }) {
  const editando = Boolean(producto);
  const categorias = useCategorias();
  const guardar = useGuardarProducto();
  const crearCategoria = useGuardarCategoria();

  const [nombre, setNombre] = useState(producto?.nombre ?? '');
  const [categoriaId, setCategoriaId] = useState(producto?.categoria_id ?? '');
  const [unidad, setUnidad] = useState<'UND' | 'KG'>(producto?.unidad_base ?? 'UND');
  const [codigoIva, setCodigoIva] = useState(producto?.codigo_iva ?? '4');
  const [codigoPrincipal, setCodigoPrincipal] = useState(producto?.codigo_principal ?? '');
  const [codigoAuxiliar, setCodigoAuxiliar] = useState(producto?.codigo_auxiliar ?? '');
  const [informacion, setInformacion] = useState(producto?.informacion_adicional ?? '');
  const [stockMinimo, setStockMinimo] = useState(producto ? paraEditar(producto.stock_minimo) : '0');
  const [activo, setActivo] = useState(producto?.activo ?? true);
  const [precio, setPrecio] = useState('');
  const [codigo, setCodigo] = useState('');
  const [nuevaCategoria, setNuevaCategoria] = useState<string | null>(null);
  const [errores, setErrores] = useState<Errores>({});
  const [guardado, setGuardado] = useState(false);

  const enviar = (evento: FormEvent) => {
    evento.preventDefault();
    setGuardado(false);
    const nuevos: Errores = {};

    if (nombre.trim() === '') nuevos.nombre = 'El nombre es obligatorio';
    const minimo = leerDecimal(stockMinimo, { decimales: 3 });
    if (!minimo.ok) nuevos.stock_minimo = minimo.mensaje;
    const precioLeido = !editando && precio.trim() !== '' ? leerDecimal(precio, { decimales: 2 }) : null;
    if (precioLeido && !precioLeido.ok) nuevos.precio_venta = precioLeido.mensaje;

    setErrores(nuevos);
    if (Object.keys(nuevos).length > 0 || !minimo.ok) return;

    const datos: DatosProducto = {
      nombre: nombre.trim(),
      categoria_id: categoriaId || null,
      unidad_base: unidad,
      codigo_iva: codigoIva,
      stock_minimo: minimo.valor,
      codigo_principal: codigoPrincipal.trim() || null,
      codigo_auxiliar: codigoAuxiliar.trim() || null,
      informacion_adicional: informacion.trim() || null,
    };
    if (editando) datos.activo = activo;
    else {
      datos.precio_venta = precioLeido?.ok ? precioLeido.valor : null;
      datos.codigo_barras = codigo.trim() || null;
    }

    guardar.mutate(
      { id: producto?.id ?? null, datos },
      {
        onSuccess: ({ id }) => {
          if (editando) {
            setGuardado(true);
            alGuardar?.();
          } else navegar({ nombre: 'producto', id });
        },
      },
    );
  };

  const agregarCategoria = () => {
    const texto = nuevaCategoria?.trim() ?? '';
    if (texto === '') return;
    crearCategoria.mutate(texto, {
      onSuccess: ({ id }) => {
        setCategoriaId(id);
        setNuevaCategoria(null);
      },
    });
  };

  return (
    <form onSubmit={enviar} className="flex flex-col gap-4" noValidate>
      <Campo
        etiqueta="Nombre"
        name="nombre"
        value={nombre}
        onChange={(e) => setNombre(e.target.value)}
        error={errores.nombre}
        autoComplete="off"
      />

      {nuevaCategoria === null ? (
        <div className="flex items-end gap-2">
          <div className="flex-1">
            <Selector etiqueta="Categoría" value={categoriaId} onChange={(e) => setCategoriaId(e.target.value)}>
              <option value="">Sin categoría</option>
              {categorias.data?.map((c) => (
                <option key={c.id} value={c.id}>
                  {c.nombre}
                </option>
              ))}
            </Selector>
          </div>
          <Boton variante="secundario" onClick={() => setNuevaCategoria('')}>
            Nueva
          </Boton>
        </div>
      ) : (
        <div className="flex flex-col gap-2">
          <div className="flex items-end gap-2">
            <div className="flex-1">
              <Campo
                etiqueta="Nueva categoría"
                value={nuevaCategoria}
                onChange={(e) => setNuevaCategoria(e.target.value)}
                autoFocus
              />
            </div>
            <Boton variante="secundario" onClick={agregarCategoria} disabled={crearCategoria.isPending}>
              Crear
            </Boton>
            <Boton variante="secundario" onClick={() => setNuevaCategoria(null)}>
              ✕
            </Boton>
          </div>
          <AvisoError error={crearCategoria.error} />
        </div>
      )}

      <div className="grid grid-cols-2 gap-3">
        <Selector etiqueta="Se cuenta en" value={unidad} onChange={(e) => setUnidad(e.target.value as 'UND' | 'KG')}>
          <option value="UND">Unidades</option>
          <option value="KG">Kilos</option>
        </Selector>
        <Selector etiqueta="Tarifa IVA" value={codigoIva} onChange={(e) => setCodigoIva(e.target.value)}>
          {OPCIONES_IVA.map((o) => (
            <option key={o.codigo} value={o.codigo}>
              {o.texto}
            </option>
          ))}
          {!OPCIONES_IVA.some((o) => o.codigo === codigoIva) && (
            <option value={codigoIva}>{textoIva(codigoIva)} (anterior)</option>
          )}
        </Selector>
      </div>

      <div className="grid grid-cols-2 gap-3">
        <Campo
          etiqueta="Código principal"
          ayuda="El del portal del SRI"
          value={codigoPrincipal}
          maxLength={LARGO_CODIGO}
          onChange={(e) => setCodigoPrincipal(e.target.value)}
          autoComplete="off"
        />
        <Campo
          etiqueta="Código auxiliar"
          value={codigoAuxiliar}
          maxLength={LARGO_CODIGO}
          onChange={(e) => setCodigoAuxiliar(e.target.value)}
          autoComplete="off"
        />
      </div>

      <Campo
        etiqueta="Información adicional"
        value={informacion}
        maxLength={LARGO_INFORMACION}
        onChange={(e) => setInformacion(e.target.value)}
        autoComplete="off"
      />

      <Campo
        etiqueta={`Stock mínimo (${unidad === 'KG' ? 'kg' : 'unidades'})`}
        ayuda="Avisa cuando el stock llega a este número. 0 = sin aviso."
        inputMode="decimal"
        value={stockMinimo}
        onChange={(e) => setStockMinimo(e.target.value)}
        error={errores.stock_minimo}
      />

      {!editando && (
        <div className="grid grid-cols-2 gap-3">
          <Campo
            etiqueta={`Precio por ${unidad === 'KG' ? 'kilo' : 'unidad'}`}
            ayuda="Con IVA incluido"
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
      )}

      {editando && (
        <Casilla
          etiqueta="Activo (se puede comprar y vender)"
          checked={activo}
          onChange={(e) => setActivo(e.target.checked)}
        />
      )}

      <AvisoError error={guardar.error} />
      {guardado && <Aviso tipo="exito">Cambios guardados</Aviso>}

      <Boton type="submit" disabled={guardar.isPending}>
        {guardar.isPending ? 'Guardando…' : editando ? 'Guardar cambios' : 'Crear producto'}
      </Boton>
    </form>
  );
}
