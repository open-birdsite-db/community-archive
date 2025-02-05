CREATE OR REPLACE FUNCTION public.insert_temp_archive_upload(
    p_account_id TEXT,
    p_archive_at timestamp with time zone,
    p_keep_private BOOLEAN,
    p_upload_likes BOOLEAN,
    p_start_date DATE,
    p_end_date DATE,
    p_suffix TEXT
)
RETURNS BIGINT AS $$
DECLARE
    v_id BIGINT;
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
        INSERT INTO temp.archive_upload_%s (
            account_id,
            archive_at,
            keep_private,
            upload_likes,
            start_date,
            end_date
        )
        VALUES ($1, $2, $3, $4, $5, $6)
        RETURNING id
    ', p_suffix)
    USING
        p_account_id,
        p_archive_at,
        p_keep_private,
        p_upload_likes,
        p_start_date,
        p_end_date
    INTO v_id;

    RETURN v_id;
    RAISE NOTICE 'insert_temp_archive_upload called with account_id: %, archive_at: %, suffix: %', p_account_id, p_archive_at, p_suffix;

END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
