import { z } from 'zod';

/** numeric de Postgres pedido como texto (`columna::text`, D-019). */
export const decimal = z.string().regex(/^-?\d+(\.\d+)?$/, 'decimal inválido');

export const uuid = z.string().uuid();
