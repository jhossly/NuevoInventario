import { Eye, EyeOff, Store } from 'lucide-react';
import { useState, type FormEvent } from 'react';
import { useMutation } from '@tanstack/react-query';
import type { AuthError } from '@supabase/supabase-js';
import { supabase } from '@/lib/supabase';
import { Aviso, Boton, Campo } from '@/shared/ui';

/** Lo que dice Supabase, en palabras para quien usa la app. */
export function mensajeDeAcceso(error: AuthError | Error): string {
  const codigo = 'code' in error ? error.code : undefined;
  if (codigo === 'invalid_credentials' || /invalid login credentials/i.test(error.message)) {
    return 'Correo o contraseña incorrectos';
  }
  if (codigo === 'email_not_confirmed') return 'Este correo todavía no está confirmado';
  if (codigo === 'over_request_rate_limit' || codigo === 'over_email_send_rate_limit' || /rate limit/i.test(error.message)) {
    return 'Demasiados intentos seguidos: espera unos minutos y vuelve a probar';
  }
  if (codigo === 'weak_password') return 'La contraseña es muy débil: usa al menos 8 caracteres';
  if (codigo === 'same_password') return 'La contraseña nueva es igual a la anterior';
  if (/fetch|network/i.test(error.message)) return 'No hay conexión con el servidor. Revisa tu internet';
  return `No se pudo completar: ${error.message}`;
}

export function CampoClave({
  etiqueta,
  valor,
  alCambiar,
  autoComplete,
}: {
  etiqueta: string;
  valor: string;
  alCambiar: (valor: string) => void;
  autoComplete: string;
}) {
  const [ver, setVer] = useState(false);
  return (
    <div className="flex items-end gap-2">
      <div className="min-w-0 flex-1">
        <Campo
          etiqueta={etiqueta}
          type={ver ? 'text' : 'password'}
          autoComplete={autoComplete}
          required
          value={valor}
          onChange={(e) => alCambiar(e.target.value)}
        />
      </div>
      <button
        type="button"
        aria-label={ver ? 'Ocultar contraseña' : 'Ver contraseña'}
        onClick={() => setVer(!ver)}
        className="flex size-11 items-center justify-center rounded-lg border border-gray-300 bg-white text-gray-600"
      >
        {ver ? <EyeOff className="size-5" aria-hidden /> : <Eye className="size-5" aria-hidden />}
      </button>
    </div>
  );
}

/** Ingreso con correo y contraseña. No hay registro público: el Dueño invita (D-017). */
export function PantallaIngreso() {
  const [modo, setModo] = useState<'ingresar' | 'recuperar'>('ingresar');
  const [correo, setCorreo] = useState('');
  const [clave, setClave] = useState('');

  const ingresar = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.auth.signInWithPassword({ email: correo.trim(), password: clave });
      if (error) throw new Error(mensajeDeAcceso(error));
    },
  });

  // El enlace vuelve a esta misma página, que entonces pide la contraseña nueva.
  const recuperar = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.auth.resetPasswordForEmail(correo.trim(), {
        redirectTo: `${window.location.origin}${window.location.pathname}`,
      });
      if (error) throw new Error(mensajeDeAcceso(error));
    },
  });

  const enviar = (evento: FormEvent) => {
    evento.preventDefault();
    if (modo === 'ingresar') ingresar.mutate();
    else recuperar.mutate();
  };

  const cambiarModo = (nuevo: typeof modo) => {
    setModo(nuevo);
    ingresar.reset();
    recuperar.reset();
  };

  return (
    <main className="mx-auto flex min-h-dvh max-w-sm flex-col justify-center gap-6 p-4">
      <div className="flex items-center gap-3">
        <span className="flex size-12 items-center justify-center rounded-xl bg-emerald-700 text-white">
          <Store className="size-7" aria-hidden />
        </span>
        <h1 className="text-2xl font-bold">Bodega</h1>
      </div>
      <form onSubmit={enviar} className="flex flex-col gap-4">
        {modo === 'recuperar' && (
          <p className="text-sm text-gray-600">
            Escribe tu correo y te enviaremos un enlace para poner una contraseña nueva.
          </p>
        )}
        <Campo
          etiqueta="Correo"
          name="correo"
          type="email"
          autoComplete="username"
          required
          value={correo}
          onChange={(e) => setCorreo(e.target.value)}
        />
        {modo === 'ingresar' && (
          <CampoClave etiqueta="Contraseña" valor={clave} alCambiar={setClave} autoComplete="current-password" />
        )}
        {ingresar.isError && <Aviso>{ingresar.error.message}</Aviso>}
        {recuperar.isError && <Aviso>{recuperar.error.message}</Aviso>}
        {recuperar.isSuccess && (
          <Aviso tipo="exito">
            Si ese correo está registrado, te llegará un enlace en unos minutos. Revisa también la carpeta de spam.
          </Aviso>
        )}
        <Boton type="submit" disabled={ingresar.isPending || recuperar.isPending}>
          {modo === 'ingresar'
            ? ingresar.isPending
              ? 'Ingresando…'
              : 'Ingresar'
            : recuperar.isPending
              ? 'Enviando…'
              : 'Enviar enlace'}
        </Boton>
        <button
          type="button"
          onClick={() => cambiarModo(modo === 'ingresar' ? 'recuperar' : 'ingresar')}
          className="min-h-11 text-sm font-medium text-emerald-800 underline"
        >
          {modo === 'ingresar' ? '¿Olvidaste tu contraseña?' : 'Volver a ingresar'}
        </button>
      </form>
    </main>
  );
}

/** Después de abrir el enlace del correo, o desde el menú: poner una contraseña nueva. */
export function NuevaClave({ alTerminar }: { alTerminar?: () => void }) {
  const [clave, setClave] = useState('');
  const [repetida, setRepetida] = useState('');
  const [aviso, setAviso] = useState<string | null>(null);

  const guardar = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.auth.updateUser({ password: clave });
      if (error) throw new Error(mensajeDeAcceso(error));
    },
    onSuccess: () => alTerminar?.(),
  });

  const enviar = (evento: FormEvent) => {
    evento.preventDefault();
    if (clave.length < 8) return setAviso('Usa al menos 8 caracteres');
    if (clave !== repetida) return setAviso('Las dos contraseñas no son iguales');
    setAviso(null);
    guardar.mutate();
  };

  return (
    <form onSubmit={enviar} className="flex flex-col gap-4">
      <CampoClave etiqueta="Contraseña nueva" valor={clave} alCambiar={setClave} autoComplete="new-password" />
      <CampoClave etiqueta="Repite la contraseña" valor={repetida} alCambiar={setRepetida} autoComplete="new-password" />
      {aviso && <Aviso>{aviso}</Aviso>}
      {guardar.isError && <Aviso>{guardar.error.message}</Aviso>}
      {guardar.isSuccess && <Aviso tipo="exito">Contraseña cambiada.</Aviso>}
      <Boton type="submit" disabled={guardar.isPending}>
        {guardar.isPending ? 'Guardando…' : 'Guardar contraseña'}
      </Boton>
    </form>
  );
}
