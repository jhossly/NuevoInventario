import { Package } from 'lucide-react';
import { urlImagen } from './api';

/** La foto del producto o, si no tiene, un recuadro con su icono. */
export function FotoProducto({ imagen, className = 'size-14' }: { imagen: string | null; className?: string }) {
  if (imagen) {
    return <img src={urlImagen(imagen)} alt="" loading="lazy" className={`rounded-lg bg-white object-contain ${className}`} />;
  }
  return (
    <span className={`flex shrink-0 items-center justify-center rounded-lg bg-gray-100 text-gray-400 ${className}`}>
      <Package className="size-1/2" aria-hidden />
    </span>
  );
}
