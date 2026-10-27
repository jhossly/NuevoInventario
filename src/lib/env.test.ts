import { describe, expect, it } from 'vitest';
import { leerEnv } from './env';

const clave = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.prueba';

describe('leerEnv', () => {
  it('acepta una configuración completa', () => {
    expect(
      leerEnv({ VITE_SUPABASE_URL: 'http://127.0.0.1:54321', VITE_SUPABASE_ANON_KEY: clave }),
    ).toEqual({ VITE_SUPABASE_URL: 'http://127.0.0.1:54321', VITE_SUPABASE_ANON_KEY: clave });
  });

  it('ignora variables que no son del navegador', () => {
    const env = leerEnv({
      VITE_SUPABASE_URL: 'http://127.0.0.1:54321',
      VITE_SUPABASE_ANON_KEY: clave,
      SUPABASE_SERVICE_ROLE_KEY: 'secreto',
    });
    expect(env).not.toHaveProperty('SUPABASE_SERVICE_ROLE_KEY');
  });

  it('rechaza la clave vacía, como queda al copiar .env.example', () => {
    expect(() =>
      leerEnv({ VITE_SUPABASE_URL: 'http://127.0.0.1:54321', VITE_SUPABASE_ANON_KEY: '' }),
    ).toThrow(/VITE_SUPABASE_ANON_KEY/);
  });

  it('rechaza una URL inválida y explica qué hacer', () => {
    expect(() => leerEnv({ VITE_SUPABASE_URL: 'localhost', VITE_SUPABASE_ANON_KEY: clave })).toThrow(
      /Copia \.env\.example a \.env\.local/,
    );
  });

  it('rechaza una configuración ausente', () => {
    expect(() => leerEnv({})).toThrow(/VITE_SUPABASE_URL/);
  });
});
