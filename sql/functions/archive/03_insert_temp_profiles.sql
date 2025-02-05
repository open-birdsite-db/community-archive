CREATE OR REPLACE FUNCTION public.insert_temp_profiles(p_profile JSONB, p_account_id TEXT, p_suffix TEXT)
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
    INSERT INTO temp.profile_%s (bio, website, location, avatar_media_url, header_media_url, account_id, archive_upload_id)
    SELECT
        ($1->''description''->>''bio'')::TEXT,
        ($1->''description''->>''website'')::TEXT,
        ($1->''description''->>''location'')::TEXT,
        ($1->>''avatarMediaUrl'')::TEXT,
        ($1->>''headerMediaUrl'')::TEXT,
        $2,
        -1
    ', p_suffix)
    USING p_profile, p_account_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
