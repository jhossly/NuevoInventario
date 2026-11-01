/**
 * Dibuja la imagen en un lienzo de `lado` px como máximo. Lo que se guarda es
 * un archivo nuevo, no el que subió la persona.
 */
export async function reducirImagen(archivo: File, lado: number): Promise<HTMLCanvasElement> {
  const imagen = await createImageBitmap(archivo);
  const escala = Math.min(1, lado / Math.max(imagen.width, imagen.height));
  const lienzo = document.createElement('canvas');
  lienzo.width = Math.max(1, Math.round(imagen.width * escala));
  lienzo.height = Math.max(1, Math.round(imagen.height * escala));
  const dibujo = lienzo.getContext('2d');
  if (!dibujo) throw new Error('Este navegador no puede procesar la imagen');
  dibujo.drawImage(imagen, 0, 0, lienzo.width, lienzo.height);
  imagen.close();
  return lienzo;
}
