-- Migración para implementar planes dinámicos y sincronización
-- Corrige el problema de UUID y mejora la gestión de planes

-- Primero, verificar y corregir la estructura de la tabla plans
DO $$ 
BEGIN
  -- Verificar si la columna id es de tipo text o uuid
  IF EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'plans' 
    AND column_name = 'id' 
    AND data_type = 'uuid'
  ) THEN
    -- Si id es UUID, necesitamos trabajar diferente
    -- Crear una columna temporal para el plan_code
    IF NOT EXISTS (
      SELECT 1 FROM information_schema.columns 
      WHERE table_name = 'plans' 
      AND column_name = 'plan_code'
    ) THEN
      ALTER TABLE plans ADD COLUMN plan_code text;
    END IF;
    
    -- Actualizar plan_code basado en el nombre
    UPDATE plans SET plan_code = LOWER(REPLACE(TRIM(name), ' ', '_')) WHERE plan_code IS NULL;
    
    -- Crear índice único en plan_code
    CREATE UNIQUE INDEX IF NOT EXISTS idx_plans_plan_code ON plans(plan_code);
    
  ELSE
    -- Si id es text, podemos actualizarlo directamente
    -- Asegurar que todos los planes tienen IDs consistentes (solo si no están vacíos)
    UPDATE plans 
    SET id = LOWER(REPLACE(TRIM(name), ' ', '_')) 
    WHERE (id IS NULL OR TRIM(id) = '') AND name IS NOT NULL AND TRIM(name) != '';
  END IF;
END $$;

-- Crear función mejorada para obtener límites de plan
CREATE OR REPLACE FUNCTION get_plan_limits(user_plan_identifier text)
RETURNS TABLE(max_stores int, max_products int, max_categories int) AS $$
DECLARE
  plan_record RECORD;
BEGIN
  -- Intentar encontrar el plan por id o plan_code
  SELECT p.max_stores, p.max_products, p.max_categories
  INTO plan_record
  FROM plans p
  WHERE p.id = user_plan_identifier 
     OR p.plan_code = user_plan_identifier
     OR LOWER(p.name) = LOWER(user_plan_identifier)
  LIMIT 1;
  
  -- Si no se encuentra el plan, usar valores por defecto del plan gratuito
  IF NOT FOUND THEN
    SELECT p.max_stores, p.max_products, p.max_categories
    INTO plan_record
    FROM plans p
    WHERE p.is_free = true
    LIMIT 1;
    
    -- Si tampoco hay plan gratuito, usar valores hardcodeados
    IF NOT FOUND THEN
      plan_record.max_stores := 1;
      plan_record.max_products := 10;
      plan_record.max_categories := 3;
    END IF;
  END IF;
  
  RETURN QUERY SELECT plan_record.max_stores, plan_record.max_products, plan_record.max_categories;
END;
$$ LANGUAGE plpgsql;

-- Mejorar función de validación de límites de tiendas
CREATE OR REPLACE FUNCTION validate_store_limit()
RETURNS TRIGGER AS $$
DECLARE
  user_plan_id TEXT;
  user_store_count INTEGER;
  plan_limits RECORD;
BEGIN
  -- Obtener el plan del usuario
  SELECT plan INTO user_plan_id FROM users WHERE id = NEW.user_id;
  
  -- Obtener el número de tiendas que ya tiene el usuario
  SELECT COUNT(*) INTO user_store_count FROM stores WHERE user_id = NEW.user_id;
  
  -- Obtener los límites del plan
  SELECT * INTO plan_limits FROM get_plan_limits(user_plan_id);
  
  -- Verificar si excede el límite
  IF user_store_count >= plan_limits.max_stores THEN
    RAISE EXCEPTION 'Has alcanzado el límite de % tienda(s) para tu plan. Actualiza tu plan para crear más tiendas.', plan_limits.max_stores;
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Mejorar función de validación de límites de productos
CREATE OR REPLACE FUNCTION validate_product_limit()
RETURNS TRIGGER AS $$
DECLARE
  store_user_id UUID;
  user_plan_id TEXT;
  store_product_count INTEGER;
  plan_limits RECORD;
BEGIN
  -- Obtener el usuario propietario de la tienda
  SELECT user_id INTO store_user_id FROM stores WHERE id = NEW.store_id;
  
  -- Obtener el plan del usuario
  SELECT plan INTO user_plan_id FROM users WHERE id = store_user_id;
  
  -- Obtener el número de productos que ya tiene la tienda
  SELECT COUNT(*) INTO store_product_count FROM products WHERE store_id = NEW.store_id;
  
  -- Obtener los límites del plan
  SELECT * INTO plan_limits FROM get_plan_limits(user_plan_id);
  
  -- Verificar si excede el límite
  IF store_product_count >= plan_limits.max_products THEN
    RAISE EXCEPTION 'Has alcanzado el límite de % producto(s) para tu plan. Actualiza tu plan para añadir más productos.', plan_limits.max_products;
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Mejorar función de validación de límites de categorías
CREATE OR REPLACE FUNCTION validate_category_limit()
RETURNS TRIGGER AS $$
DECLARE
  store_user_id UUID;
  user_plan_id TEXT;
  store_category_count INTEGER;
  plan_limits RECORD;
BEGIN
  -- Obtener el usuario propietario de la tienda
  SELECT user_id INTO store_user_id FROM stores WHERE id = NEW.store_id;
  
  -- Obtener el plan del usuario
  SELECT plan INTO user_plan_id FROM users WHERE id = store_user_id;
  
  -- Obtener el número de categorías que ya tiene la tienda
  SELECT COUNT(*) INTO store_category_count FROM categories WHERE store_id = NEW.store_id;
  
  -- Obtener los límites del plan
  SELECT * INTO plan_limits FROM get_plan_limits(user_plan_id);
  
  -- Verificar si excede el límite (999999 significa ilimitado)
  IF plan_limits.max_categories < 999999 AND store_category_count >= plan_limits.max_categories THEN
    RAISE EXCEPTION 'Has alcanzado el límite de % categoría(s) para tu plan. Actualiza tu plan para añadir más categorías.', plan_limits.max_categories;
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Crear función para notificar cambios en planes
CREATE OR REPLACE FUNCTION notify_plan_changes()
RETURNS TRIGGER AS $$
DECLARE
  payload JSONB;
  record_data RECORD;
BEGIN
  -- Usar NEW para INSERT/UPDATE, OLD para DELETE
  IF TG_OP = 'DELETE' THEN
    record_data := OLD;
  ELSE
    record_data := NEW;
  END IF;
  
  payload := jsonb_build_object(
    'event', TG_OP,
    'schema', TG_TABLE_SCHEMA,
    'table', TG_TABLE_NAME,
    'id', record_data.id,
    'record', row_to_json(record_data)
  );
  
  -- Notificar cambios a través de canal de Supabase
  PERFORM pg_notify('plan_changes', payload::text);
  
  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  ELSE
    RETURN NEW;
  END IF;
END;
$$ LANGUAGE plpgsql;

-- Crear trigger para notificar cambios en planes
DROP TRIGGER IF EXISTS notify_plan_changes_trigger ON plans;
CREATE TRIGGER notify_plan_changes_trigger
AFTER INSERT OR UPDATE OR DELETE ON plans
FOR EACH ROW EXECUTE FUNCTION notify_plan_changes();

-- Crear función para notificar cambios en usuarios
CREATE OR REPLACE FUNCTION notify_user_plan_changes()
RETURNS TRIGGER AS $$
DECLARE
  payload JSONB;
BEGIN
  -- Solo notificar si el plan cambió
  IF OLD.plan IS DISTINCT FROM NEW.plan OR 
     OLD.subscription_status IS DISTINCT FROM NEW.subscription_status THEN
    
    payload := jsonb_build_object(
      'event', 'UPDATE',
      'schema', TG_TABLE_SCHEMA,
      'table', TG_TABLE_NAME,
      'id', NEW.id,
      'changes', jsonb_build_object(
        'old_plan', OLD.plan,
        'new_plan', NEW.plan,
        'old_status', OLD.subscription_status,
        'new_status', NEW.subscription_status
      )
    );
    
    -- Notificar cambios a través de canal de Supabase
    PERFORM pg_notify('user_plan_changes', payload::text);
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Crear trigger para notificar cambios en planes de usuarios
DROP TRIGGER IF EXISTS notify_user_plan_changes_trigger ON users;
CREATE TRIGGER notify_user_plan_changes_trigger
AFTER UPDATE ON users
FOR EACH ROW EXECUTE FUNCTION notify_user_plan_changes();

-- Normalizar planes de usuarios existentes
DO $$
DECLARE
  plan_mapping RECORD;
  default_plan_id TEXT;
BEGIN
  -- Obtener el ID del plan gratuito por defecto
  SELECT id INTO default_plan_id FROM plans WHERE is_free = true LIMIT 1;
  
  -- Si no hay plan gratuito, usar 'gratuito'
  IF default_plan_id IS NULL THEN
    default_plan_id := 'gratuito';
  END IF;
  
  -- Mapear planes conocidos
  FOR plan_mapping IN 
    SELECT DISTINCT u.plan as old_plan, p.id as new_plan
    FROM users u
    LEFT JOIN plans p ON (
      p.id = u.plan OR 
      p.plan_code = u.plan OR 
      LOWER(p.name) = LOWER(u.plan) OR
      (LOWER(u.plan) LIKE '%empren%' AND LOWER(p.name) LIKE '%empren%') OR
      (LOWER(u.plan) LIKE '%profesional%' AND LOWER(p.name) LIKE '%profesional%') OR
      (LOWER(u.plan) LIKE '%gratu%' AND p.is_free = true)
    )
    WHERE u.plan IS NOT NULL 
    AND u.plan != ''
    AND p.id IS NOT NULL
  LOOP
    -- Actualizar usuarios con el mapeo correcto
    UPDATE users 
    SET plan = plan_mapping.new_plan 
    WHERE plan = plan_mapping.old_plan;
    
    RAISE NOTICE 'Mapped plan "%" to "%"', plan_mapping.old_plan, plan_mapping.new_plan;
  END LOOP;
  
  -- Asegurar que todos los usuarios sin plan válido tengan el plan gratuito
  UPDATE users 
  SET plan = default_plan_id
  WHERE plan IS NULL 
     OR plan = ''
     OR NOT EXISTS (
       SELECT 1 FROM plans 
       WHERE id = users.plan 
          OR plan_code = users.plan
     );
     
  RAISE NOTICE 'Updated users without valid plans to default plan: %', default_plan_id;
END $$;

-- Crear vista para facilitar consultas de planes
CREATE OR REPLACE VIEW user_plan_details AS
SELECT 
  u.id as user_id,
  u.email,
  u.name,
  u.plan as plan_identifier,
  p.id as plan_id,
  p.name as plan_name,
  p.level as plan_level,
  p.max_stores,
  p.max_products,
  p.max_categories,
  p.price as plan_price,
  p.is_free,
  u.subscription_status,
  u.subscription_start_date,
  u.subscription_end_date
FROM users u
LEFT JOIN plans p ON (
  p.id = u.plan OR 
  p.plan_code = u.plan OR
  LOWER(p.name) = LOWER(u.plan)
);

-- Comentarios para documentar los cambios
COMMENT ON FUNCTION get_plan_limits(text) IS 'Obtiene los límites de un plan por ID, código o nombre';
COMMENT ON FUNCTION notify_plan_changes() IS 'Notifica cambios en la tabla de planes via pg_notify';
COMMENT ON FUNCTION notify_user_plan_changes() IS 'Notifica cambios en planes de usuarios via pg_notify';
COMMENT ON VIEW user_plan_details IS 'Vista que combina información de usuarios y sus planes';