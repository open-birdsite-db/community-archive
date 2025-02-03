-- Helper function to get current user's account_id
CREATE OR REPLACE FUNCTION tes.get_current_account_id()
RETURNS TEXT AS $$
DECLARE
    v_account_id TEXT;
BEGIN
    SELECT a.account_id INTO v_account_id
    FROM auth.users u
    JOIN account a ON a.account_id = u.raw_user_meta_data->>'provider_id'
    WHERE u.id = auth.uid();
    
    RETURN v_account_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;