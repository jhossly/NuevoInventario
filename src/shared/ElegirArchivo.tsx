import { useEffect, useId, useState, type ChangeEvent } from 'react';
import { Upload } from 'lucide-react';
import { Aviso } from './ui';

const MARCA = 'eligiendo-archivo';
const VIGENCIA_MS = 5 * 60_000;

function leerMarca(): number | null {
  try {
    const valor = sessionStorage.getItem(MARCA);
    return valor ? Number(valor) : null;
  } catch {
    return null;
  }
}

function ponerMarca(valor: number | null) {
  try {
    if (valor === null) sessionStorage.removeItem(MARCA);
    else sessionStorage.setItem(MARCA, String(valor));
  } catch {
    // Sin almacenamiento solo se pierde el aviso de recarga.
  }
}

/** Navegadores dentro de Facebook, Instagram o TikTok, que suelen fallar al elegir archivos. */
function navegadorDentroDeApp(): boolean {
  return /FBAN|FBAV|Instagram|Line\/|TikTok|musical_ly/i.test(navigator.userAgent);
}

/**
 * Botón para elegir archivos que nunca se queda callado (D-061). En Android el
 * navegador puede cerrar la página mientras se elige el archivo (falta de
 * memoria) y volver a abrirla sin él, o devolver la elección vacía: en ambos
 * casos se avisa qué pasó. Sin filtro de tipo: algunos celulares no entregan
 * el archivo si el tipo no coincide; quien lo recibe revisa el contenido.
 */
export function ElegirArchivo({
  etiqueta,
  ocupado,
  multiple = false,
  alElegir,
}: {
  etiqueta: string;
  ocupado?: string;
  multiple?: boolean;
  alElegir: (archivos: File[]) => void;
}) {
  const id = useId();
  const [aviso, setAviso] = useState<string | null>(null);
  const [elegidos, setElegidos] = useState<string[]>([]);

  useEffect(() => {
    const marca = leerMarca();
    if (marca !== null && Date.now() - marca < VIGENCIA_MS) {
      setAviso(
        'La página se volvió a abrir mientras elegías el archivo: el celular la cerró para ahorrar memoria. ' +
          'Cierra otras aplicaciones y vuelve a intentarlo.',
      );
    }
    ponerMarca(null);
  }, []);

  const recibir = (evento: ChangeEvent<HTMLInputElement>) => {
    ponerMarca(null);
    const archivos = Array.from(evento.target.files ?? []);
    evento.target.value = '';
    if (archivos.length === 0) {
      setAviso(
        navegadorDentroDeApp()
          ? 'Este navegador no entregó el archivo. Abre la página en Chrome y vuelve a intentarlo.'
          : 'El celular no entregó ningún archivo. Búscalo en «Descargas» o «Archivos» y vuelve a intentarlo.',
      );
      return;
    }
    setAviso(null);
    setElegidos(archivos.map((a) => a.name));
    alElegir(archivos);
  };

  return (
    <div className="flex flex-col gap-2">
      <label
        htmlFor={id}
        onClick={() => ponerMarca(Date.now())}
        className={`inline-flex min-h-11 w-fit items-center gap-2 rounded-lg px-4 font-medium text-white ${
          ocupado ? 'cursor-wait bg-gray-400' : 'cursor-pointer bg-emerald-700 hover:bg-emerald-800'
        }`}
      >
        <Upload className="size-5" aria-hidden />
        {ocupado ?? etiqueta}
      </label>
      <input
        id={id}
        type="file"
        multiple={multiple}
        className="sr-only"
        disabled={Boolean(ocupado)}
        onChange={recibir}
      />
      {elegidos.length > 0 && (
        <p className="text-sm text-gray-600">
          {elegidos.length === 1 ? `Archivo: ${elegidos[0]}` : `${elegidos.length} archivos elegidos`}
        </p>
      )}
      {aviso && <Aviso>{aviso}</Aviso>}
    </div>
  );
}
