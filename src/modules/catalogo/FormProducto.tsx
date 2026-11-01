import { useState, type ChangeEvent, type FormEvent } from 'react';
import { Camera, Check, Plus, Trash2 } from 'lucide-react';
import { leerDecimal, paraEditar } from '@/shared/decimal';
import { useContexto } from '@/modules/sesion/sesion';
import { navegar } from '@/shared/ruta';
import { Aviso, AvisoError, Boton, Campo, Casilla, Selector } from '@/shared/ui';
import {
  OPCIONES_IVA,
  subirImagenProducto,
  textoIva,
  unidadCorta,
  useCategorias,
  useGuardarCategoria,
  useGuardarMedida,
  useGuardarProducto,
  useMedidas,
  type DatosProducto,
  type Producto,
} from './api';
import { FotoProducto } from './FotoProducto';

// Límites del formulario de productos del portal del SRI.
const LARGO_CODIGO = 25;
const LARGO_INFORMACION = 300;

interface Errores {
  nombre?: string;
  stock_minimo?: string;
  precio_venta?: string;
  costo_servicio?: string;
}

/**
 * Crear (sin `producto`) o editar un producto. `costoServicio` es el costo
 * por unidad de un producto sin stock, para quien ve costos (D-046).
 */
export function FormProducto({
  producto,
  costoServicio,
  inicial,
  alGuardar,
  alCrear,
}: {
  producto?: Producto;
  costoServicio?: string | null;
  /** Valores sugeridos para un producto nuevo (por ejemplo, de una factura del SRI). */
  inicial?: { nombre?: string; codigoIva?: string; codigoPrincipal?: string; precio?: string };
  alGuardar?: () => void;
  /** Si se da, al crear se llama en vez de ir a la ficha del producto. */
  alCrear?: (id: string) => void;
}) {
  const editando = Boolean(producto);
  const categorias = useCategorias();
  const guardar = useGuardarProducto();
  const crearCategoria = useGuardarCategoria();
  const contexto = useContexto();
  const medidas = useMedidas();
  const crearMedida = useGuardarMedida();

  const [nombre, setNombre] = useState(producto?.nombre ?? inicial?.nombre ?? '');
  const [categoriaId, setCategoriaId] = useState(producto?.categoria_id ?? '');
  const [unidad, setUnidad] = useState(producto?.unidad_base ?? 'UND');
  const [codigoIva, setCodigoIva] = useState(producto?.codigo_iva ?? inicial?.codigoIva ?? '4');
  const [codigoPrincipal, setCodigoPrincipal] = useState(producto?.codigo_principal ?? inicial?.codigoPrincipal ?? '');
  const [codigoAuxiliar, setCodigoAuxiliar] = useState(producto?.codigo_auxiliar ?? '');
  const [informacion, setInformacion] = useState(producto?.informacion_adicional ?? '');
  const [stockMinimo, setStockMinimo] = useState(producto ? paraEditar(producto.stock_minimo) : '0');
  const [activo, setActivo] = useState(producto?.activo ?? true);
  const [imagen, setImagen] = useState(producto?.imagen ?? null);
  const [subiendo, setSubiendo] = useState(false);
  const [errorImagen, setErrorImagen] = useState<string | null>(null);
  const [nuevaMedida, setNuevaMedida] = useState<{ nombre: string; codigo: string } | null>(null);
  const [controlaStock, setControlaStock] = useState(producto?.controla_stock ?? true);
  const [costo, setCosto] = useState(costoServicio ? paraEditar(costoServicio) : '');
  const [precio, setPrecio] = useState(inicial?.precio ?? '');
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
    const costoLeido = !controlaStock && costo.trim() !== '' ? leerDecimal(costo, { decimales: 6 }) : null;
    if (costoLeido && !costoLeido.ok) nuevos.costo_servicio = costoLeido.mensaje;

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
      controla_stock: controlaStock,
      imagen,
    };
    // Quien no ve costos no recibe el costo actual: no lo borra al guardar.
    if (!controlaStock && (costoServicio !== undefined || !editando)) {
      datos.costo_servicio = costoLeido?.ok ? costoLeido.valor : null;
    }
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
          } else if (alCrear) alCrear(id);
          else navegar({ nombre: 'producto', id });
        },
      },
    );
  };

  const nombreMedida = (medidas.data?.find((m) => m.codigo === unidad)?.nombre ?? 'unidad').toLowerCase();

  const elegirImagen = async (evento: ChangeEvent<HTMLInputElement>) => {
    const archivo = evento.target.files?.[0];
    evento.target.value = '';
    if (!archivo) return;
    setErrorImagen(null);
    setSubiendo(true);
    try {
      setImagen(await subirImagenProducto(archivo, contexto.empresa_id));
    } catch {
      setErrorImagen('No se pudo subir la imagen');
    }
    setSubiendo(false);
  };

  const agregarMedida = () => {
    if (!nuevaMedida) return;
    crearMedida.mutate(nuevaMedida, {
      onSuccess: ({ codigo }) => {
        setUnidad(codigo);
        setNuevaMedida(null);
      },
    });
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
      <div className="flex flex-wrap items-center gap-4">
        <FotoProducto imagen={imagen} className="size-24" />
        <div className="flex flex-wrap gap-2">
          <label className="inline-flex min-h-11 cursor-pointer items-center gap-2 rounded-lg border border-gray-300 bg-white px-4 font-medium hover:bg-gray-100">
            <Camera className="size-5" aria-hidden />
            {subiendo ? 'Subiendo…' : imagen ? 'Cambiar foto' : 'Poner foto'}
            <input type="file" accept="image/*" className="sr-only" onChange={elegirImagen} disabled={subiendo} />
          </label>
          {imagen && (
            <Boton variante="secundario" icono={Trash2} onClick={() => setImagen(null)}>
              Quitar
            </Boton>
          )}
        </div>
      </div>
      {errorImagen && <Aviso>{errorImagen}</Aviso>}

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

      {nuevaMedida && (
        <div className="flex flex-col gap-2 rounded-lg border border-gray-200 bg-gray-50 p-3">
          <div className="grid grid-cols-2 gap-3">
            <Campo
              etiqueta="Nueva medida"
              ayuda="Por ejemplo: Funda"
              value={nuevaMedida.nombre}
              maxLength={40}
              onChange={(e) => setNuevaMedida({ ...nuevaMedida, nombre: e.target.value })}
              autoFocus
            />
            <Campo
              etiqueta="Abreviatura"
              ayuda="Por ejemplo: fda"
              value={nuevaMedida.codigo}
              maxLength={8}
              onChange={(e) => setNuevaMedida({ ...nuevaMedida, codigo: e.target.value })}
            />
          </div>
          <AvisoError error={crearMedida.error} />
          <div className="flex gap-2">
            <Boton variante="secundario" icono={Check} onClick={agregarMedida} disabled={crearMedida.isPending}>
              Crear
            </Boton>
            <Boton variante="secundario" onClick={() => setNuevaMedida(null)}>
              Cancelar
            </Boton>
          </div>
        </div>
      )}

      <div className="grid grid-cols-2 gap-3">
        <div className="flex items-end gap-2">
          <div className="min-w-0 flex-1">
            <Selector etiqueta="Se cuenta en" value={unidad} onChange={(e) => setUnidad(e.target.value)}>
              {!medidas.data?.some((m) => m.codigo === unidad) && <option value={unidad}>{unidad}</option>}
              {medidas.data?.map((m) => (
                <option key={m.codigo} value={m.codigo}>
                  {m.nombre}
                </option>
              ))}
            </Selector>
          </div>
          <Boton
            variante="secundario"
            icono={Plus}
            aria-label="Nueva medida"
            className="px-3"
            onClick={() => setNuevaMedida({ nombre: '', codigo: '' })}
          />
        </div>
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

      <Casilla
        etiqueta="Controla stock (desmarca para recargas y servicios)"
        checked={controlaStock}
        onChange={(e) => setControlaStock(e.target.checked)}
      />

      {controlaStock ? (
        <Campo
          etiqueta={`Stock mínimo (${unidadCorta(unidad)})`}
          ayuda="Avisa cuando el stock llega a este número. 0 = sin aviso."
          inputMode="decimal"
          value={stockMinimo}
          onChange={(e) => setStockMinimo(e.target.value)}
          error={errores.stock_minimo}
        />
      ) : (
        (costoServicio !== undefined || !editando) && (
          <Campo
            etiqueta={`Costo por ${nombreMedida}`}
            ayuda="Lo que te cuesta (por ejemplo $0,95 por una recarga de $1). Sirve para la utilidad; las compras lo actualizan."
            inputMode="decimal"
            value={costo}
            onChange={(e) => setCosto(e.target.value)}
            error={errores.costo_servicio}
          />
        )
      )}

      {!editando && (
        <div className="grid grid-cols-2 gap-3">
          <Campo
            etiqueta={`Precio por ${nombreMedida}`}
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

      <Boton type="submit" icono={Check} disabled={guardar.isPending || subiendo}>
        {guardar.isPending ? 'Guardando…' : editando ? 'Guardar cambios' : 'Crear producto'}
      </Boton>
    </form>
  );
}
