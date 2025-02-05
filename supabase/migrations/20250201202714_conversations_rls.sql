
CREATE OR REPLACE FUNCTION public.apply_readonly_rls_policies(schema_name TEXT, table_name TEXT) 
RETURNS void AS $$
DECLARE
    policy_name TEXT;
    full_table_name TEXT;
BEGIN
    full_table_name := schema_name || '.' || table_name;

    -- Enable RLS on the table
    EXECUTE format('ALTER TABLE %I.%I ENABLE ROW LEVEL SECURITY', schema_name, table_name);

    -- Drop existing policies
    FOR policy_name IN (
        SELECT policyname
        FROM pg_policies
        WHERE schemaname = schema_name AND tablename = table_name
    ) LOOP
        EXECUTE format('DROP POLICY IF EXISTS %I ON %I.%I', policy_name, schema_name, table_name);
    END LOOP; 

    -- Only create read policy, writes will be handled by service role/postgres
    EXECUTE format('CREATE POLICY "Public read access" ON %I.%I FOR SELECT USING (true)', schema_name, table_name);
END;
$$ LANGUAGE plpgsql;
ALTER TABLE public.conversations ENABLE ROW LEVEL SECURITY;
SELECT public.apply_readonly_rls_policies('public', 'conversations');