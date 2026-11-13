-- IVA elegido por línea en la compra a mano (D-064).
--
-- La bodega vende con 0 % (D-045) pero algunos proveedores le cobran 15 %. Cada
-- línea de p_lineas puede traer "tarifa_iva" (0, 5, 12, 13, 14 o 15): esa es la
-- que se registra para esta compra. Sin ella, la del producto, como antes. La
-- tarifa del producto no cambia. El IVA pagado sigue sumando al costo si
-- iva_compras_es_costo. La compra desde XML no pasa por aquí: usa la del XML.

create or replace function privado.calcular_lineas_compra(p_empresa uuid, p_lineas jsonb)
returns setof privado.linea_compra
language plpgsql
set search_path = ''
as $$
declare
  v_iva_es_costo boolean;
  v_entrada      record;
  v_pres         record;
  v_linea        privado.linea_compra;
  v_base         numeric;
  v_tarifa       numeric;
begin
  if jsonb_typeof(p_lineas) is distinct from 'array' or jsonb_array_length(p_lineas) = 0 then
    perform privado.fallar('DATOS_INVALIDOS', 'La compra necesita al menos una línea');
  end if;

  select e.iva_compras_es_costo into v_iva_es_costo from public.empresas e where e.id = p_empresa;

  for v_entrada in
    select l.ordinality::int as orden, l.value as datos
      from jsonb_array_elements(p_lineas) with ordinality l
  loop
    begin
      v_linea.orden          := v_entrada.orden;
      v_linea.presentacion_id := (v_entrada.datos ->> 'presentacion_id')::uuid;
      v_linea.cantidad       := round((v_entrada.datos ->> 'cantidad')::numeric, 3);
      v_linea.costo_unitario := round((v_entrada.datos ->> 'costo_unitario')::numeric, 6);
      v_linea.descuento      := round(coalesce((v_entrada.datos ->> 'descuento')::numeric, 0), 2);
      v_tarifa               := (v_entrada.datos ->> 'tarifa_iva')::numeric;
    exception
      when invalid_text_representation or numeric_value_out_of_range then
        perform privado.fallar('DATOS_INVALIDOS', 'Hay un número mal escrito',
                               jsonb_build_object('linea', v_entrada.orden));
    end;

    select r.factor, r.producto_id, p.tarifa_iva
      into v_pres
      from public.presentaciones r
      join public.productos p on p.id = r.producto_id
     where r.id = v_linea.presentacion_id
       and r.empresa_id = p_empresa
       and r.activo and r.se_compra and p.activo;
    if not found then
      perform privado.fallar('DATOS_INVALIDOS', 'La presentación no existe o no se compra',
                             jsonb_build_object('linea', v_entrada.orden));
    end if;

    if v_linea.cantidad is null or v_linea.cantidad <= 0 then
      perform privado.fallar('DATOS_INVALIDOS', 'La cantidad debe ser mayor que cero',
                             jsonb_build_object('linea', v_entrada.orden));
    end if;
    if v_linea.costo_unitario is null or v_linea.costo_unitario < 0 then
      perform privado.fallar('DATOS_INVALIDOS', 'Falta el costo o es negativo',
                             jsonb_build_object('linea', v_entrada.orden));
    end if;

    v_linea.producto_id   := v_pres.producto_id;
    -- La factura del proveedor manda: puede cobrar IVA aunque el producto se
    -- venda con 0 % (D-064). Sin tarifa, la del producto.
    if v_tarifa is not null and privado.codigo_tarifa_iva(v_tarifa) is null then
      perform privado.fallar('DATOS_INVALIDOS', 'Esa tarifa de IVA no existe',
                             jsonb_build_object('linea', v_entrada.orden));
    end if;
    v_linea.tarifa_iva    := coalesce(v_tarifa, v_pres.tarifa_iva);
    v_linea.subtotal      := round(v_linea.cantidad * v_linea.costo_unitario, 2);
    if v_linea.descuento < 0 or v_linea.descuento > v_linea.subtotal then
      perform privado.fallar('DATOS_INVALIDOS', 'El descuento no puede superar el subtotal',
                             jsonb_build_object('linea', v_entrada.orden));
    end if;
    v_base                := v_linea.subtotal - v_linea.descuento;
    v_linea.iva           := round(v_base * v_linea.tarifa_iva / 100, 2);
    v_linea.cantidad_base := round(v_linea.cantidad * v_pres.factor, 3);
    if v_linea.cantidad_base <= 0 then
      perform privado.fallar('DATOS_INVALIDOS', 'La cantidad es demasiado pequeña',
                             jsonb_build_object('linea', v_entrada.orden));
    end if;
    v_linea.costo_unitario_base :=
      (v_base + case when v_iva_es_costo then v_linea.iva else 0 end) / v_linea.cantidad_base;

    return next v_linea;
  end loop;
end;
$$;
