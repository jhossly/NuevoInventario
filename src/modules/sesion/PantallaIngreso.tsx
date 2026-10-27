import { useState, type FormEvent } from 'react';
import { useMutation } from '@tanstack/react-query';
import { supabase } from '@/lib/supabase';
import { Aviso, Boton, Campo } from '@/shared/ui';

/** Ingreso con correo y contraseña. No hay registro público: el Dueño invita (D-017). */
export function PantallaIngreso() {
  const [correo, setCorreo] = useState('');
  const [clave, setClave] = useState('');

  const ingresar = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.auth.signInWithPassword({ email: correo.trim(), password: clave });
      if (error) {
        throw new Error(
          error.code === 'invalid_credentials' ? 'Correo o contraseña incorrectos' : 'No se pudo ingresar. Intenta de nuevo.',
        );
      }
    },
  });

  const enviar = (evento: FormEvent) => {
    evento.preventDefault();
    ingresar.mutate();
  };

  return (
    <main className="mx-auto flex min-h-dvh max-w-sm flex-col justify-center gap-6 p-4">
      <h1 className="text-2xl font-semibold">Bodega</h1>
      <form onSubmit={enviar} className="flex flex-col gap-4">
        <Campo
          etiqueta="Correo"
          name="correo"
          type="email"
          autoComplete="username"
          required
          value={correo}
          onChange={(e) => setCorreo(e.target.value)}
        />
        <Campo
          etiqueta="Contraseña"
          name="clave"
          type="password"
          autoComplete="current-password"
          required
          value={clave}
          onChange={(e) => setClave(e.target.value)}
        />
        {ingresar.isError && <Aviso>{ingresar.error.message}</Aviso>}
        <Boton type="submit" disabled={ingresar.isPending}>
          {ingresar.isPending ? 'Ingresando…' : 'Ingresar'}
        </Boton>
      </form>
    </main>
  );
}
