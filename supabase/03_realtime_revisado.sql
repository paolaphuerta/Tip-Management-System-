-- EL SAUCE — instalación 03 revisada. Ejecutar DESPUÉS de 02_borradores.sql.
-- No ejecutarlo sobre producción hasta disponer de respaldo y revisar en entorno de prueba.
BEGIN;
ALTER TABLE public.reparto_borrador ADD COLUMN IF NOT EXISTS revision bigint NOT NULL DEFAULT 0;

CREATE OR REPLACE FUNCTION public.patch_tip_draft(p_workspace uuid, p_changes jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  current_data jsonb; current_rev bigint; change_item jsonb; path text[];
  expected jsonb; new_value jsonb; found_value jsonb; updated jsonb;
  k text; idx int; element jsonb;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_member(p_workspace) THEN RAISE EXCEPTION 'Acceso denegado'; END IF;
  IF jsonb_typeof(p_changes) IS DISTINCT FROM 'array' OR jsonb_array_length(p_changes) NOT BETWEEN 1 AND 200 THEN RAISE EXCEPTION 'Cambios inválidos'; END IF;
  INSERT INTO public.reparto_borrador(workspace_id,data,updated_by)
    VALUES (p_workspace,'{"period":"","days":7,"total":10000,"areas":[{"name":"Cocina","pct":45},{"name":"Meseras","pct":40},{"name":"Administración","pct":15}],"employees":[]}'::jsonb,auth.uid())
    ON CONFLICT DO NOTHING;
  SELECT data,revision INTO current_data,current_rev FROM public.reparto_borrador WHERE workspace_id=p_workspace FOR UPDATE;
  updated:=current_data;
  FOR change_item IN SELECT value FROM jsonb_array_elements(p_changes) LOOP
    IF jsonb_typeof(change_item) IS DISTINCT FROM 'object' OR jsonb_typeof(change_item->'path') IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'Ruta inválida'; END IF;
    SELECT array_agg(value ORDER BY ord) INTO path FROM jsonb_array_elements_text(change_item->'path') WITH ORDINALITY AS x(value,ord);
    IF cardinality(path) NOT BETWEEN 1 AND 3 THEN RAISE EXCEPTION 'Ruta inválida'; END IF;
    k:=path[1];
    IF k IN ('period','days','total') AND cardinality(path)=1 THEN NULL;
    ELSIF k='areas' AND cardinality(path)=3 AND path[3]='pct' AND path[2] ~ '^[0-9]+$' AND path[2]::int BETWEEN 0 AND 2 THEN NULL;
    ELSIF k='employees' AND cardinality(path)=1 THEN NULL;
    ELSIF k='employees' AND cardinality(path)=3 AND path[2] ~ '^[0-9]+$' AND path[2]::int BETWEEN 0 AND 999 AND path[3] IN ('name','area','active','weight','rest','unjust') THEN
      idx:=path[2]::int;
      element:=updated #> ARRAY['employees',path[2]];
      IF element IS NULL OR (change_item->>'employee_id') IS DISTINCT FROM (element->>'id') THEN
        RETURN jsonb_build_object('ok',false,'conflict',path,'server',current_data,'revision',current_rev);
      END IF;
    ELSE RAISE EXCEPTION 'Ruta no permitida'; END IF;
    IF NOT (change_item ? 'before' AND change_item ? 'after') THEN RAISE EXCEPTION 'Cambio incompleto'; END IF;
    expected:=change_item->'before';new_value:=change_item->'after';found_value:=updated #> path;
    IF found_value IS DISTINCT FROM expected THEN RETURN jsonb_build_object('ok',false,'conflict',path,'server',current_data,'revision',current_rev); END IF;
    IF k='period' AND (jsonb_typeof(new_value) <> 'string' OR length(new_value #>> '{}')>200) THEN RAISE EXCEPTION 'Periodo inválido'; END IF;
    IF k='days' AND (jsonb_typeof(new_value) <> 'number' OR (new_value #>> '{}')::numeric NOT BETWEEN 1 AND 31 OR (new_value #>> '{}')::numeric <> trunc((new_value #>> '{}')::numeric)) THEN RAISE EXCEPTION 'Días inválidos'; END IF;
    IF k='total' AND (jsonb_typeof(new_value) <> 'number' OR (new_value #>> '{}')::numeric NOT BETWEEN 0 AND 100000000 OR (new_value #>> '{}')::numeric <> round((new_value #>> '{}')::numeric,2)) THEN RAISE EXCEPTION 'Total inválido'; END IF;
    IF k='areas' AND (jsonb_typeof(new_value) <> 'number' OR (new_value #>> '{}')::numeric NOT BETWEEN 0 AND 100) THEN RAISE EXCEPTION 'Porcentaje inválido'; END IF;
    IF k='employees' AND cardinality(path)=1 AND (jsonb_typeof(new_value)<>'array' OR jsonb_array_length(new_value)>500) THEN RAISE EXCEPTION 'Lista de empleados inválida'; END IF;
    IF k='employees' AND cardinality(path)=3 THEN
       IF path[3]='name' AND (jsonb_typeof(new_value)<>'string' OR length(new_value #>> '{}')>160) THEN RAISE EXCEPTION 'Nombre inválido'; END IF;
       IF path[3]='active' AND jsonb_typeof(new_value)<>'boolean' THEN RAISE EXCEPTION 'Activo inválido'; END IF;
       IF path[3]='area' AND (jsonb_typeof(new_value)<>'number' OR (new_value #>> '{}')::numeric NOT IN (0,1,2)) THEN RAISE EXCEPTION 'Área inválida'; END IF;
       IF path[3]='weight' AND (jsonb_typeof(new_value)<>'number' OR (new_value #>> '{}')::numeric NOT BETWEEN 0 AND 100000) THEN RAISE EXCEPTION 'Peso inválido'; END IF;
       IF path[3] IN ('rest','unjust') AND (jsonb_typeof(new_value)<>'number' OR (new_value #>> '{}')::numeric NOT BETWEEN 0 AND 31 OR (new_value #>> '{}')::numeric<>trunc((new_value #>> '{}')::numeric)) THEN RAISE EXCEPTION 'Asistencia inválida'; END IF;
    END IF;
    updated:=jsonb_set(updated,path,new_value,false);
  END LOOP;
  UPDATE public.reparto_borrador SET data=updated,updated_by=auth.uid(),revision=revision+1 WHERE workspace_id=p_workspace RETURNING revision INTO current_rev;
  RETURN jsonb_build_object('ok',true,'data',updated,'revision',current_rev);
END $$;

-- Cierre único y atómico. Recalcula las asignaciones con aritmética decimal del servidor.
CREATE OR REPLACE FUNCTION public.close_tip_draft(p_workspace uuid,p_revision bigint,p_snapshot jsonb)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
 d jsonb; r bigint; new_id uuid; total_money numeric; n_days int;
 area_row jsonb; employee_row jsonb; i int; j int; area_pct numeric; pct_sum numeric:=0;
 area_score numeric; emp_score numeric; expected_amount numeric; actual_amount numeric;
 distributed numeric:=0; seen_names text[]:=ARRAY[]::text[]; rest_days int; unjust_days int;
 employee_count int;
BEGIN
 IF auth.uid() IS NULL OR NOT public.is_member(p_workspace) THEN RAISE EXCEPTION 'Acceso denegado'; END IF;
 SELECT data,revision INTO d,r FROM public.reparto_borrador WHERE workspace_id=p_workspace FOR UPDATE;
 IF d IS NULL OR r IS DISTINCT FROM p_revision THEN RAISE EXCEPTION 'El borrador cambió. Actualiza antes de cerrar'; END IF;
 IF jsonb_typeof(p_snapshot) IS DISTINCT FROM 'object' OR (p_snapshot - 'payouts' - 'worked' - 'distributed') IS DISTINCT FROM d THEN RAISE EXCEPTION 'El reparto no coincide con el borrador'; END IF;
 IF jsonb_typeof(d->'period')<>'string' OR length(trim(d->>'period')) NOT BETWEEN 1 AND 200 THEN RAISE EXCEPTION 'Periodo inválido'; END IF;
 IF jsonb_typeof(d->'days')<>'number' OR (d->>'days')::numeric NOT BETWEEN 1 AND 31 OR (d->>'days')::numeric <> trunc((d->>'days')::numeric) THEN RAISE EXCEPTION 'Días inválidos'; END IF;
 n_days:=(d->>'days')::int;
 IF jsonb_typeof(d->'total')<>'number' OR (d->>'total')::numeric NOT BETWEEN 0 AND 100000000 OR (d->>'total')::numeric<>round((d->>'total')::numeric,2) THEN RAISE EXCEPTION 'Total inválido'; END IF;
 total_money:=(d->>'total')::numeric;
 IF jsonb_typeof(d->'areas')<>'array' OR jsonb_array_length(d->'areas')<>3 THEN RAISE EXCEPTION 'Áreas inválidas'; END IF;
 FOR i IN 0..2 LOOP
   area_row:=d->'areas'->i;
   IF jsonb_typeof(area_row->'pct')<>'number' OR (area_row->>'pct')::numeric NOT BETWEEN 0 AND 100 THEN RAISE EXCEPTION 'Porcentaje inválido'; END IF;
   pct_sum:=pct_sum+(area_row->>'pct')::numeric;
 END LOOP;
 IF abs(pct_sum-100)>0.00001 THEN RAISE EXCEPTION 'Las áreas deben sumar 100'; END IF;
 IF jsonb_typeof(d->'employees')<>'array' THEN RAISE EXCEPTION 'Empleados inválidos'; END IF;
 employee_count:=jsonb_array_length(d->'employees');
 IF employee_count NOT BETWEEN 1 AND 500 OR jsonb_typeof(p_snapshot->'payouts')<>'array' OR jsonb_array_length(p_snapshot->'payouts')<>employee_count OR jsonb_typeof(p_snapshot->'worked')<>'array' OR jsonb_array_length(p_snapshot->'worked')<>employee_count THEN RAISE EXCEPTION 'Lista de pagos inválida'; END IF;
 FOR i IN 0..employee_count-1 LOOP
   employee_row:=d->'employees'->i;
   IF jsonb_typeof(employee_row->'name')<>'string' OR length(trim(employee_row->>'name')) NOT BETWEEN 1 AND 160 THEN RAISE EXCEPTION 'Nombre inválido'; END IF;
   IF lower(trim(employee_row->>'name'))=ANY(seen_names) THEN RAISE EXCEPTION 'Nombres duplicados'; END IF;
   seen_names:=array_append(seen_names,lower(trim(employee_row->>'name')));
   IF jsonb_typeof(employee_row->'area')<>'number' OR (employee_row->>'area')::numeric NOT IN (0,1,2) OR jsonb_typeof(employee_row->'active')<>'boolean' THEN RAISE EXCEPTION 'Datos de empleado inválidos'; END IF;
   IF jsonb_typeof(employee_row->'weight')<>'number' OR (employee_row->>'weight')::numeric NOT BETWEEN 0 AND 100000 THEN RAISE EXCEPTION 'Peso inválido'; END IF;
   IF jsonb_typeof(employee_row->'rest')<>'number' OR jsonb_typeof(employee_row->'unjust')<>'number' THEN RAISE EXCEPTION 'Asistencia inválida'; END IF;
   IF (employee_row->>'rest')::numeric NOT BETWEEN 0 AND n_days OR (employee_row->>'unjust')::numeric NOT BETWEEN 0 AND n_days OR (employee_row->>'rest')::numeric<>trunc((employee_row->>'rest')::numeric) OR (employee_row->>'unjust')::numeric<>trunc((employee_row->>'unjust')::numeric) THEN RAISE EXCEPTION 'Asistencia inválida'; END IF;
   rest_days:=(employee_row->>'rest')::int;unjust_days:=(employee_row->>'unjust')::int;
   IF rest_days+unjust_days>n_days THEN RAISE EXCEPTION 'Asistencia excede periodo'; END IF;
   IF jsonb_typeof(p_snapshot->'worked'->i)<>'number' OR (p_snapshot->'worked'->>i)::numeric<>(n_days-rest_days-unjust_days) THEN RAISE EXCEPTION 'Días trabajados no coinciden'; END IF;
 END LOOP;
 FOR i IN 0..employee_count-1 LOOP
   employee_row:=d->'employees'->i;
   rest_days:=(employee_row->>'rest')::int;unjust_days:=(employee_row->>'unjust')::int;
   emp_score:=CASE WHEN (employee_row->>'active')::boolean AND unjust_days=0 THEN (employee_row->>'weight')::numeric * (n_days-rest_days-unjust_days) ELSE 0 END;
   area_pct:=(d->'areas'->((employee_row->>'area')::int)->>'pct')::numeric;
   area_score:=0;
   FOR j IN 0..employee_count-1 LOOP
     area_row:=d->'employees'->j;
     IF (area_row->>'area')::int=(employee_row->>'area')::int AND (area_row->>'active')::boolean AND (area_row->>'unjust')::int=0 THEN
       area_score:=area_score+(area_row->>'weight')::numeric*(n_days-(area_row->>'rest')::int-(area_row->>'unjust')::int);
     END IF;
   END LOOP;
   expected_amount:=CASE WHEN area_score>0 THEN total_money*area_pct/100*emp_score/area_score ELSE 0 END;
   IF jsonb_typeof(p_snapshot->'payouts'->i)<>'number' THEN RAISE EXCEPTION 'Monto de pago inválido'; END IF;
   actual_amount:=(p_snapshot->'payouts'->>i)::numeric;
   IF actual_amount<0 OR abs(actual_amount-expected_amount)>0.005001 THEN RAISE EXCEPTION 'Importe de propina no coincide con cálculo'; END IF;
   distributed:=distributed+expected_amount;
 END LOOP;
 IF abs(distributed-total_money)>0.011 THEN RAISE EXCEPTION 'Existe dinero sin asignar'; END IF;
 IF jsonb_typeof(p_snapshot->'distributed')<>'number' OR abs((p_snapshot->>'distributed')::numeric-distributed)>0.011 THEN RAISE EXCEPTION 'Total distribuido inválido'; END IF;
 INSERT INTO public.repartos(workspace_id,period,days,total,snapshot,created_by)
 VALUES(p_workspace,d->>'period',n_days,total_money,p_snapshot,auth.uid()) RETURNING id INTO new_id;
 DELETE FROM public.reparto_borrador WHERE workspace_id=p_workspace;
 RETURN new_id;
END $$;

REVOKE ALL ON FUNCTION public.patch_tip_draft(uuid,jsonb),public.close_tip_draft(uuid,bigint,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.patch_tip_draft(uuid,jsonb),public.close_tip_draft(uuid,bigint,jsonb) TO authenticated;
-- Nunca permitir la escritura directa del borrador por cliente: se hace mediante las RPC verificadas.
DROP POLICY IF EXISTS "borrador insert" ON public.reparto_borrador;
DROP POLICY IF EXISTS "borrador update" ON public.reparto_borrador;
DROP POLICY IF EXISTS "borrador delete" ON public.reparto_borrador;
-- Histórico: bloquear escritura directa desde cliente DESPUÉS de verificar que el nuevo frontend funciona.
-- En el momento del cambio a producción, ejecutar por separado:
-- DROP POLICY IF EXISTS "repartos insert" ON public.repartos;
COMMIT;
