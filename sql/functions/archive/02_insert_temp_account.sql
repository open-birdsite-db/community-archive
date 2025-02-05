CREATE OR REPLACE FUNCTION public.insert_temp_account(p_account JSONB, p_suffix TEXT)
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
    INSERT INTO temp.account_%s (
        account_id, created_via, username, created_at, account_display_name,
        num_tweets, num_following, num_followers, num_likes
    )
    SELECT
        $1->>''accountId'',
        $1->>''createdVia'',
        $1->>''username'',
        ($1->>''createdAt'')::TIMESTAMP WITH TIME ZONE,
        $1->>''accountDisplayName'',
        COALESCE(($1->>''num_tweets'')::INTEGER, 0),
        COALESCE(($1->>''num_following'')::INTEGER, 0),
        COALESCE(($1->>''num_followers'')::INTEGER, 0),
        COALESCE(($1->>''num_likes'')::INTEGER, 0)
    ', p_suffix)
    USING p_account;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;