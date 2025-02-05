CREATE OR REPLACE FUNCTION public.insert_temp_followers(p_followers JSONB, p_account_id TEXT, p_suffix TEXT)
RETURNS VOID AS $$
DECLARE
    v_provider_id TEXT;
BEGIN
    -- Get provider_id from JWT
    SELECT ((auth.jwt()->'app_metadata'->>'provider_id')::text) INTO v_provider_id;
    
    -- Verify the JWT provider_id matches the suffix
    IF current_user NOT IN ('postgres', 'service_role') AND (v_provider_id IS NULL OR v_provider_id != p_suffix) THEN
        RAISE EXCEPTION 'Unauthorized: provider_id % does not match account_id %', v_provider_id, p_suffix;
    END IF;

    IF auth.uid() IS NULL AND current_user NOT IN ('postgres', 'service_role') THEN
        RAISE EXCEPTION 'Not authenticated';
    END IF;

    EXECUTE format('
    INSERT INTO temp.followers_%s (account_id, follower_account_id, archive_upload_id)
    SELECT
        $2,
        (follower->''follower''->>''accountId'')::TEXT,
        -1
    FROM jsonb_array_elements($1) AS follower
    ', p_suffix)
    USING p_followers, p_account_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
